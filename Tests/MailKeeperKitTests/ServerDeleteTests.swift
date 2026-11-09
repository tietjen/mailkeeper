import Foundation
import Testing
@testable import MailKeeperKit

/// What a dropped connection throws in these tests (the app's is IMAPError.closed/.connection).
struct LostConnection: Error {}

/// An IMAP server in memory: one account, mailboxes with UIDVALIDITY and messages.
actor FakeTrashServer: ServerTrashActions {
    struct Message { var messageID: String?; var data: Data; var flags: [String] }
    var mailboxes: [String: (validity: UInt32, messages: [UInt32: Message])] = [:]
    var trash: String? = "Trash"
    var selected: String?
    var moves = 0
    var moveDoesNothing = false
    var refuseMoveIn: String?
    var refuseSelectOf: String?
    var connects = 0
    /// The next n moves lose the connection: after the server did the move (its answer never
    /// arrives), or before it did anything.
    var dropAfterMove = 0
    var dropBeforeMove = 0
    /// UIDs whose header does not come back in a batch answer (Gmail, 2026-11-09).
    var headerMissing: Set<UInt32> = []

    init(mailboxes: [String: (validity: UInt32, messages: [UInt32: Message])], trash: String? = "Trash") {
        self.mailboxes = mailboxes
        self.trash = trash
        if let trash, self.mailboxes[trash] == nil { self.mailboxes[trash] = (1, [:]) }
    }

    func setFlags(_ flags: [String], uid: UInt32, in box: String) { mailboxes[box]?.messages[uid]?.flags = flags }
    func replace(uid: UInt32, in box: String, with m: Message) { mailboxes[box]?.messages[uid] = m }
    func remove(uid: UInt32, in box: String) { mailboxes[box]?.messages[uid] = nil }
    func setValidity(_ v: UInt32, of box: String) { mailboxes[box]?.validity = v }
    func setMoveDoesNothing() { moveDoesNothing = true }
    func setRefuseMove(in box: String) { refuseMoveIn = box }
    func setRefuseSelect(of box: String) { refuseSelectOf = box }
    func uids(in box: String) -> Set<UInt32> { Set(mailboxes[box]?.messages.keys ?? [:].keys) }
    /// Connection numbers (1-based) that fail to open, as when the network is still away.
    var failConnects: Set<Int> = []
    func connected() throws -> FakeTrashServer {
        connects += 1
        if failConnects.contains(connects) { throw LostConnection() }
        return self
    }
    func setFailConnects(_ numbers: Set<Int>) { failConnects = numbers }
    func setDrop(after: Int = 0, before: Int = 0) { dropAfterMove = after; dropBeforeMove = before }
    func setHeaderMissing(_ uids: Set<UInt32>) { headerMissing = uids }

    func trashMailbox() async throws -> String? { trash }
    func selectForChange(_ mailbox: String) async throws -> UInt32 {
        if mailbox == refuseSelectOf { throw ServerRefusal("[NOPERM] keine Rechte") }
        selected = mailbox
        return mailboxes[mailbox]?.validity ?? 0
    }
    func identities(_ uids: [UInt32]) async throws -> [UInt32: RemoteIdentity] {
        var out: [UInt32: RemoteIdentity] = [:]
        for uid in uids {
            guard let m = mailboxes[selected!]?.messages[uid] else { continue }
            let partial = uids.count > 1 && headerMissing.contains(uid)
            out[uid] = RemoteIdentity(messageID: partial ? nil : m.messageID, size: partial ? nil : m.data.count, flags: m.flags)
        }
        return out
    }
    func bodies(_ uids: [UInt32]) async throws -> [UInt32: Data] {
        Dictionary(uniqueKeysWithValues: uids.compactMap { uid in mailboxes[selected!]?.messages[uid].map { (uid, $0.data) } })
    }
    func moveToTrash(_ uids: [UInt32]) async throws {
        if selected == refuseMoveIn { throw ServerRefusal("[READ-ONLY] Postfach schreibgeschützt") }
        moves += 1
        if dropBeforeMove > 0 { dropBeforeMove -= 1; throw LostConnection() }
        guard !moveDoesNothing, let trash else { return }
        for uid in uids {
            if let m = mailboxes[selected!]?.messages.removeValue(forKey: uid) {
                let next = (mailboxes[trash]!.messages.keys.max() ?? 0) + 1
                mailboxes[trash]!.messages[next] = m
            }
        }
        if dropAfterMove > 0 { dropAfterMove -= 1; throw LostConnection() }
    }
    func present(_ uids: [UInt32]) async throws -> Set<UInt32> { Set(uids).intersection(mailboxes[selected!]?.messages.keys ?? [:].keys) }
    func close() async {}
}

@Suite("Deleting on the server (ADR-0006)")
struct ServerDeleteTests {
    struct Setup {
        let layout: ArchiveLayout
        let writer: ArchiveWriter
        let server: FakeTrashServer
        let store: ActionStore
        let audit: AuditLog
        var job: ActionJob
    }

    /// A normal, B flagged on the server after planning, C another message under that UID, D
    /// already gone, E without Message-ID, F with a damaged archive copy.
    static func setup(plan: Bool = true) async throws -> Setup {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "sd"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "imap", kind: "imap", name: "I"))
        let noID = eml("From: n@t.test\nSubject: E no id\nDate: Thu, 14 Mar 2019 10:00:00 +0100\n\nohne id")
        let mails: [(UInt32, Data)] = [
            (1, sampleMessage(id: "<a@t.test>", subject: "A")), (2, sampleMessage(id: "<b@t.test>", subject: "B")),
            (3, sampleMessage(id: "<c@t.test>", subject: "C")), (4, sampleMessage(id: "<d@t.test>", subject: "D")),
            (5, noID), (6, sampleMessage(id: "<f@t.test>", subject: "F")),
        ]
        _ = try await writer.ingest(mails.map { uid, data in
            (data, LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 9, uid: uid))
        })
        var serverMessages: [UInt32: FakeTrashServer.Message] = [:]
        for (uid, data) in mails { serverMessages[uid] = .init(messageID: MIMEParser.parse(data).messageID, data: data, flags: []) }
        let server = FakeTrashServer(mailboxes: ["INBOX": (9, serverMessages)])
        let reader = try ArchiveReader(layout: layout)
        let accounts = [AccountConfig.imap(id: "imap", username: "u", host: "mail.example.test")]
        let (job, _) = try reader.planServerDelete(MessageFilter(), title: "alle", accounts: accounts, graceDays: 0)
        let store = ActionStore(layout: layout)
        if plan { try store.create(job) }
        return Setup(layout: layout, writer: writer, server: server, store: store,
                     audit: AuditLog(url: tempDir().appending(path: "audit.jsonl")), job: job)
    }

    @Test func eachSafeguardHoldsAndTheArchiveLearnsWhatWentAway() async throws {
        let s = try await Self.setup()
        #expect(s.job.count(.planned) == 6)
        // after planning: B flagged, C replaced by another message, D deleted elsewhere, F's blob damaged
        await s.server.setFlags(["\\Flagged"], uid: 2, in: "INBOX")
        await s.server.replace(uid: 3, in: "INBOX", with: .init(messageID: "<other@t.test>", data: Data("x".utf8), flags: []))
        await s.server.remove(uid: 4, in: "INBOX")
        let f = try #require(s.job.items.first { $0.location?.uid == 6 })
        try Data("tampered".utf8).write(to: s.layout.blobs.url(for: f.sha256))

        let executor = ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit)
        let job = try await executor.run(s.job.id) { _ in s.server }
        let byUID = Dictionary(uniqueKeysWithValues: job.items.map { ($0.location!.uid, $0) })
        #expect(byUID[1]?.state == .done && byUID[5]?.state == .done)
        #expect(byUID[2]?.state == .skipped && byUID[2]?.reason == "inzwischen markiert")
        #expect(byUID[3]?.state == .failed && byUID[3]?.reason == "Mail auf dem Server stimmt nicht mit dem Archiv überein")
        #expect(byUID[4]?.state == .done && byUID[4]?.reason == "war bereits nicht mehr auf dem Server")
        #expect(byUID[6]?.state == .failed && byUID[6]?.reason == "Archivkopie beschädigt")
        #expect(await s.server.uids(in: "INBOX") == [2, 3, 6])
        #expect(await s.server.uids(in: "Trash").count == 2)
        // the queue on disk agrees, the audit has one line per item, the archive knows
        #expect(try s.store.load(s.job.id).items.map(\.state) == job.items.map(\.state))
        #expect(s.audit.entries().count == 6)
        let subjects = { (q: String) in
            Set(try ArchiveReader(layout: s.layout).summaries(try ArchiveReader(layout: s.layout).messageIDs(MessageFilter(text: q + " "))).compactMap(\.subject))
        }
        #expect(try subjects("only:archive") == ["A", "D", "E no id"])
        _ = try await s.writer.rebuildIndex()  // journalled: survives a rebuild
        #expect(try subjects("only:archive") == ["A", "D", "E no id"])
    }

    @Test func staleNumberingNoTrashAndAFailedMoveStopIt() async throws {
        var s = try await Self.setup()
        await s.server.setValidity(10, of: "INBOX")
        var server = s.server
        var job = try await ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit).run(s.job.id) { [server] _ in server }
        #expect(job.count(.failed) == 6 && job.items[0].reason?.contains("UIDVALIDITY") == true)
        #expect(await s.server.moves == 0)

        s = try await Self.setup()
        let noTrash = FakeTrashServer(mailboxes: [:], trash: nil)
        job = try await ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit).run(s.job.id) { _ in noTrash }
        #expect(job.count(.failed) == 6 && job.items[0].reason == "Kein Papierkorb (\\Trash) auf dem Server gefunden")

        s = try await Self.setup()
        await s.server.setMoveDoesNothing()
        server = s.server
        job = try await ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit).run(s.job.id) { [server] _ in server }
        #expect(job.count(.failed) == 6 && job.items.allSatisfy { $0.reason == "nach dem Verschieben noch auf dem Server" })
        #expect(try ArchiveReader(layout: s.layout).count(MessageFilter(text: "only:archive ")) == 0)
    }

    /// Review 4.7: a server that says no (read-only mailbox, no rights) fails those messages with
    /// its reason; the job does not die with them.
    @Test func serverRefusalsFailTheirMessagesNotTheJob() async throws {
        var s = try await Self.setup()
        await s.server.setRefuseMove(in: "INBOX")
        var server = s.server
        var job = try await ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit).run(s.job.id) { [server] _ in server }
        #expect(job.isFinished && job.items.allSatisfy { $0.state == .failed && $0.reason == "vom Server abgelehnt: [READ-ONLY] Postfach schreibgeschützt" })
        #expect(try ArchiveReader(layout: s.layout).count(MessageFilter(text: "only:archive ")) == 0)  // nothing marked gone

        s = try await Self.setup()
        await s.server.setRefuseSelect(of: "INBOX")
        server = s.server
        job = try await ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit).run(s.job.id) { [server] _ in server }
        #expect(job.items.allSatisfy { $0.state == .failed && $0.reason == "vom Server abgelehnt: [NOPERM] keine Rechte" })
    }

    @Test("A crash after claiming: resume checks again instead of acting twice")
    func resumeAfterCrash() async throws {
        let s = try await Self.setup()
        try s.store.record(job: s.job.id, item: 0, state: .claimed)  // uid 1: claimed, then the app died …
        let moved = try #require(s.job.items.first { $0.location?.uid == 1 })
        _ = moved
        await s.server.remove(uid: 1, in: "INBOX")                    // … after the server had moved it
        let job = try await ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit).run(s.job.id) { _ in s.server }
        // a claim from an earlier run proves less (the app may have died before the move, and
        // days may have passed): "was gone already", as before
        #expect(job.items[0].state == .done && job.items[0].reason == ServerDeleteExecutor.alreadyGone)
        #expect(job.count(.done) == 6)
    }

    /// 2026-11-09, Gmail: the connection was closed under a MOVE the server then carried out.
    /// The executor opens it again and goes on; what it had sent the move for counts as its own.
    @Test func aDroppedConnectionIsOpenedAgainAndTheRunGoesOn() async throws {
        let s = try await Self.setup()
        await s.server.setDrop(after: 1)
        var executor = ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit)
        executor.reconnectPause = .zero
        executor.batchSize = 2
        let server = s.server
        let job = try await executor.run(s.job.id, connect: { _ in try await server.connected() },
                                         reconnectAfter: { $0 is LostConnection })
        #expect(await s.server.connects == 2)
        #expect(job.count(.done) == 6 && job.isFinished)
        let byUID = Dictionary(uniqueKeysWithValues: job.items.map { ($0.location!.uid, $0) })
        #expect(byUID[1]?.reason == ServerDeleteExecutor.movedBeforeInterruption)
        #expect(byUID[2]?.reason == ServerDeleteExecutor.movedBeforeInterruption)
        #expect(byUID[3]?.reason == nil && byUID[6]?.reason == nil)
        #expect(await s.server.uids(in: "INBOX").isEmpty)
        #expect(try s.store.load(s.job.id).items.map(\.reason) == job.items.map(\.reason))  // on disk too
        #expect(try ArchiveReader(layout: s.layout).count(MessageFilter(text: "only:archive ")) == 6)
    }

    @Test func aDropBeforeTheMoveIsRetriedAndMovesThenOnce() async throws {
        let s = try await Self.setup()
        await s.server.setDrop(before: 1)
        var executor = ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit)
        executor.reconnectPause = .zero
        let server = s.server
        let job = try await executor.run(s.job.id, connect: { _ in try await server.connected() },
                                         reconnectAfter: { $0 is LostConnection })
        #expect(await s.server.connects == 2 && job.count(.done) == 6)
        #expect(job.items.allSatisfy { $0.reason == nil })  // still there on the re-check: moved by the second try
        #expect(await s.server.moves == 2)  // the first move never happened, the second did
    }

    /// Review: the network may still be away when the connection is opened again.
    @Test func openingItAgainMayFailTooWithinTheBudget() async throws {
        let s = try await Self.setup()
        await s.server.setDrop(after: 1)
        await s.server.setFailConnects([2])
        var executor = ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit)
        executor.reconnectPause = .zero
        let server = s.server
        let job = try await executor.run(s.job.id, connect: { _ in try await server.connected() },
                                         reconnectAfter: { $0 is LostConnection })
        #expect(await s.server.connects == 3 && job.count(.done) == 6)
    }

    /// Review: a long job may drop now and then; only drops without progress use up the budget.
    @Test func dropsWithProgressInBetweenDoNotStopALongJob() async throws {
        let s = try await Self.setup()
        await s.server.setDrop(after: 3)  // each of the three batches drops once
        var executor = ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit)
        executor.reconnectPause = .zero
        executor.batchSize = 2
        let server = s.server
        let job = try await executor.run(s.job.id, connect: { _ in try await server.connected() },
                                         reconnectAfter: { $0 is LostConnection })
        #expect(await s.server.connects == 4 && job.count(.done) == 6)
        #expect(job.items.allSatisfy { $0.reason == ServerDeleteExecutor.movedBeforeInterruption })
    }

    @Test func otherErrorsAndTooManyDropsStillStopTheJob() async throws {
        func executor(_ s: Setup) -> ServerDeleteExecutor {
            var e = ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit)
            e.reconnectPause = .zero
            return e
        }
        let s = try await Self.setup()
        await s.server.setDrop(after: 1)
        let first = executor(s), server = s.server, id = s.job.id
        await #expect(throws: LostConnection.self) {  // not a dropped connection by the caller's rule
            _ = try await first.run(id, connect: { _ in try await server.connected() }, reconnectAfter: { _ in false })
        }
        #expect(await s.server.connects == 1)
        #expect(try s.store.load(s.job.id).count(.claimed) == 6)  // resumable as before

        let t = try await Self.setup()
        await t.server.setDrop(before: 3)
        let second = executor(t), server2 = t.server, id2 = t.job.id
        await #expect(throws: LostConnection.self) {
            _ = try await second.run(id2, connect: { _ in try await server2.connected() }, reconnectAfter: { $0 is LostConnection })
        }
        #expect(await t.server.connects == 3)  // first try + maxReconnects (2)
    }

    /// 2026-11-09, Gmail: inside a batch one answer came back without the header; alone, the same
    /// UID answered in full. Then the bytes decide, not "does not match".
    @Test func aMissingHeaderIsComparedByBytes() async throws {
        let s = try await Self.setup()
        await s.server.setHeaderMissing([1, 3])
        await s.server.replace(uid: 3, in: "INBOX", with: .init(messageID: "<c@t.test>", data: Data("other bytes".utf8), flags: []))
        let job = try await ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit).run(s.job.id) { _ in s.server }
        let byUID = Dictionary(uniqueKeysWithValues: job.items.map { ($0.location!.uid, $0) })
        #expect(byUID[1]?.state == .done)  // same bytes as archived
        #expect(byUID[3]?.state == .failed && byUID[3]?.reason == "Mail auf dem Server stimmt nicht mit dem Archiv überein")
    }

    @Test func batchesCanBeSmallerPerAccount() async throws {
        let s = try await Self.setup()
        var executor = ServerDeleteExecutor(writer: s.writer, store: s.store, audit: s.audit)
        executor.batchSizes = ["imap": 2, "other": 1]
        let job = try await executor.run(s.job.id) { _ in s.server }
        let moves = await s.server.moves
        #expect(job.count(.done) == 6 && moves == 3)
    }
}
