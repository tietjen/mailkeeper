import Foundation
import Testing
@testable import MailKeeperKit

/// An IMAP account in memory for restores: mailboxes with roles, messages with flags and labels.
actor FakeRestoreServer: ServerRestoreActions {
    struct Box {
        var validity: UInt32
        var uses: Set<SpecialUse> = []
        var messages: [UInt32: RemoteMessage] = [:]
    }
    var boxes: [String: Box]
    let gmail: Bool
    var selected: String?
    var appends = 0
    var labelCalls: [(UInt32, [String])] = []
    /// Proton: the bridge rebuilds headers, the Message-ID stays.
    var rewrite: (@Sendable (Data) -> Data)?
    /// No APPENDUID (no UIDPLUS).
    var reportsUID = true
    /// The message is stored, then the connection dies (outcome unknown to the client).
    var dropAfterAppend: (@Sendable (Data) -> Bool)?
    var refuse: String?
    /// One refusal before the bytes go out: the connection is gone until the next connect.
    var refuseOnceBeforeData = false
    var refuseAlwaysBeforeData = false
    var dead = false
    var connects = 0
    /// Proton: uploads arrive as read.
    var marksSeen = false
    var flagCalls: [(UInt32, [String], [String])] = []

    init(boxes: [String: Box], gmail: Bool = false) {
        self.boxes = boxes
        self.gmail = gmail
    }

    func setRewrite(_ f: @escaping @Sendable (Data) -> Data) { rewrite = f }
    func setReportsUID(_ b: Bool) { reportsUID = b }
    func setDropAfterAppend(_ f: (@Sendable (Data) -> Bool)?) { dropAfterAppend = f }
    func setRefuse(_ s: String?) { refuse = s }
    func setRefuseOnceBeforeData() { refuseOnceBeforeData = true }
    func setRefuseAlwaysBeforeData() { refuseAlwaysBeforeData = true }
    func addBox(_ name: String) { boxes[name] = Box(validity: 99) }
    func dropRoles() { for k in boxes.keys { boxes[k]!.uses = [] } }
    func setMarksSeen() { marksSeen = true }
    /// What `connect` hands out: this server, alive again.
    func connected() -> FakeRestoreServer {
        connects += 1
        dead = false
        return self
    }
    private func alive() throws { if dead { throw CancellationError() } }
    func put(_ data: Data, uid: UInt32, in box: String) { boxes[box]?.messages[uid] = RemoteMessage(uid: uid, data: data) }
    func messages(in box: String) -> [RemoteMessage] { boxes[box]?.messages.values.sorted { $0.uid < $1.uid } ?? [] }

    func capabilities() async -> SourceCapabilities { SourceCapabilities(gmail: gmail) }
    func mailboxes() async throws -> [RemoteMailbox] {
        try alive()
        return boxes.map { RemoteMailbox(name: $0.key, specialUse: $0.value.uses) }
    }
    func selectForChange(_ mailbox: String) async throws -> UInt32 {
        try alive()
        selected = mailbox
        return boxes[mailbox]!.validity
    }
    func search(messageID: String) async throws -> [UInt32] {
        try alive()
        return boxes[selected!]!.messages.values.filter { m in
            MIMEParser.parse(m.data).messageID.map { $0.contains(messageID) } ?? false
        }.map(\.uid).sorted()
    }
    func append(_ data: Data, to mailbox: String, flags: [String], internalDate: Date?) async throws -> AppendedMessage? {
        try alive()
        if let refuse { throw ServerRefusal(refuse) }
        if refuseOnceBeforeData || refuseAlwaysBeforeData {
            refuseOnceBeforeData = false
            dead = true
            throw ServerRefusal("vor dem Senden abgelehnt", connectionClosed: true)
        }
        appends += 1
        let uid = (boxes[mailbox]!.messages.keys.max() ?? 0) + 1
        boxes[mailbox]!.messages[uid] = RemoteMessage(uid: uid, flags: flags + (marksSeen && !flags.contains("\\Seen") ? ["\\Seen"] : []),
                                                      internalDate: internalDate ?? Date(), data: rewrite?(data) ?? data)
        if dropAfterAppend?(data) == true { throw CancellationError() }
        return reportsUID ? AppendedMessage(uidValidity: boxes[mailbox]!.validity, uid: uid) : nil
    }
    func addLabels(_ labels: [String], uid: UInt32) async throws {
        labelCalls.append((uid, labels))
        boxes[selected!]!.messages[uid]!.labels += labels
    }
    func correctFlags(add: [String], remove: [String], uid: UInt32) async throws {
        flagCalls.append((uid, add, remove))
        var flags = boxes[selected!]!.messages[uid]!.flags.filter { !remove.contains($0) }
        flags += add
        boxes[selected!]!.messages[uid]!.flags = flags
    }
    func fetch(_ uids: [UInt32]) async throws -> [RemoteMessage] {
        uids.compactMap { boxes[selected!]!.messages[$0] }
    }
    func close() async {}
}

@Suite("Restoring to the server (ADR-0006 §5)")
struct RestoreTests {
    static let all = "[Gmail]/All Mail"
    static let arrival = Date(timeIntervalSince1970: 1_552_554_000)  // 14.3.2019

    struct Setup {
        let layout: ArchiveLayout
        let writer: ArchiveWriter
        let reader: ArchiveReader
        let imap: FakeRestoreServer
        let gm: FakeRestoreServer
        let store: ActionStore
        let audit: AuditLog
        let accounts: [AccountConfig]
    }

    /// A gone from INBOX (flags \Seen \Deleted), B still there, C moved on the server (INBOX gone,
    /// Archiv present), D imported only, E gone from Gmail with labels, F gone without Message-ID,
    /// G gone but already back on the server (put there by hand).
    static func setup() async throws -> Setup {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "rs"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "imap", kind: "imap", name: "I"))
        try await writer.register(AccountInfo(id: "gm", kind: "gmail", name: "G"))
        let m = { (id: String, s: String) in sampleMessage(id: "<\(id)@t.test>", subject: s) }
        let f = eml("From: n@t.test\nSubject: F no id\nDate: Thu, 14 Mar 2019 10:00:00 +0100\n\nohne id")
        let inbox = { (uid: UInt32, flags: [String]) in
            LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 7, uid: uid, internalDate: arrival, flags: flags)
        }
        _ = try await writer.ingest([
            (m("a", "A"), inbox(1, ["\\Seen", "\\Deleted", "$Forwarded"])),
            (m("b", "B"), inbox(2, [])),
            (m("c", "C"), inbox(3, [])),
            (m("c", "C"), LocationInfo(account: "imap", mailbox: "Archiv", uidValidity: 8, uid: 1)),
            (m("d", "D"), LocationInfo(account: "import", mailbox: "Import")),
            (m("e", "E"), LocationInfo(account: "gm", mailbox: all, uidValidity: 3, uid: 5, internalDate: arrival,
                                       labels: ["Work", "\\Inbox", "\\Trash", "Ünïcode"])),
            (f, inbox(6, ["\\Answered"])),
            (m("g", "G"), inbox(7, [])),
        ])
        _ = try await writer.markGone(account: "imap", mailbox: "INBOX", uidValidity: 7, uids: [1, 3, 6, 7])
        _ = try await writer.markGone(account: "gm", mailbox: all, uidValidity: 3, uids: [5])
        let imap = FakeRestoreServer(boxes: ["INBOX": .init(validity: 7), "Archiv": .init(validity: 8),
                                             "Trash": .init(validity: 9, uses: [.trash])])
        await imap.put(m("g", "G"), uid: 40, in: "INBOX")
        let gm = FakeRestoreServer(boxes: [all: .init(validity: 3, uses: [.all]), "Work": .init(validity: 4)], gmail: true)
        return Setup(layout: layout, writer: writer, reader: try ArchiveReader(layout: layout), imap: imap, gm: gm,
                     store: ActionStore(layout: layout), audit: AuditLog(url: tempDir().appending(path: "audit.jsonl")),
                     accounts: [AccountConfig.imap(id: "imap", username: "u", host: "mail.example.test"),
                                AccountConfig.gmail(id: "gm", address: "g@gmail.test")])
    }

    func run(_ s: Setup, _ job: ActionJob) async throws -> ActionJob {
        try await run(s, job, accounts: s.accounts)
    }

    func run(_ s: Setup, _ job: ActionJob, accounts: [AccountConfig]) async throws -> ActionJob {
        try s.store.create(job)
        let imap = s.imap, gm = s.gm
        return try await RestoreExecutor(writer: s.writer, store: s.store, audit: s.audit).run(job.id, accounts: accounts) { id in
            id == "gm" ? await gm.connected() : await imap.connected()
        }
    }

    func subject(_ s: Setup, _ item: ActionItem) throws -> String? {
        try s.reader.summaries(try s.reader.messageIDs(MessageFilter(text: "msgid:\(item.messageID ?? "-") "))).first?.subject
    }

    @Test func planGoesBackWhereItWasAndOnlyWhereItIsMissing() async throws {
        let s = try await Self.setup()
        let (job, summary) = try s.reader.planRestore(MessageFilter(), title: "alle", accounts: s.accounts, options: RestoreOptions())
        let bySubject = Dictionary(grouping: job.items) { item in
            item.messageID == nil ? "F" : (try? subject(s, item)) ?? "?"
        }
        #expect(bySubject["A"]?.first?.state == .planned)
        #expect(bySubject["A"]?.first?.target == RestoreTarget(account: "imap", mailbox: "INBOX", flags: ["\\Seen"], internalDate: Self.arrival))
        #expect(bySubject["B"]?.first?.reason == ArchiveReader.restoreStillOnServer)
        #expect(bySubject["C"]?.first?.reason == ArchiveReader.restoreStillOnServer)  // moved, not gone: no duplicate
        #expect(bySubject["D"]?.first?.reason == ArchiveReader.restoreNoOrigin)
        #expect(bySubject["E"]?.first?.target?.labels == ["Work", "\\Inbox", "Ünïcode"])
        #expect(bySubject["F"]?.first?.target?.flags == ["\\Answered"])
        #expect(summary.perAccount == ["imap › INBOX": 3, "gm › \(Self.all)": 1])
        #expect(summary.archiveOnly == 5)  // all but B and C
    }

    @Test func chosenMailboxTakesImportsAndRespectsTheSyncSelection() async throws {
        let s = try await Self.setup()
        let d = try s.reader.messageIDs(MessageFilter(text: "subject:D "))
        var (job, _) = try s.reader.planRestore(MessageFilter(ids: d), title: "D", accounts: s.accounts,
                                                options: RestoreOptions(destination: .mailbox(account: "imap", mailbox: "Archiv"), keepDate: false))
        #expect(job.items.map(\.state) == [.planned])
        #expect(job.items[0].target == RestoreTarget(account: "imap", mailbox: "Archiv"))
        let c = try s.reader.messageIDs(MessageFilter(text: "subject:C "))
        (job, _) = try s.reader.planRestore(MessageFilter(ids: c), title: "C", accounts: s.accounts,
                                            options: RestoreOptions(destination: .mailbox(account: "imap", mailbox: "Archiv")))
        #expect(job.items[0].reason == ArchiveReader.restoreAlreadyThere)
        var limited = s.accounts[0]
        limited.policy = SyncPolicy(mode: .standard, include: ["INBOX"])
        (job, _) = try s.reader.planRestore(MessageFilter(ids: d), title: "D", accounts: [limited],
                                            options: RestoreOptions(destination: .mailbox(account: "imap", mailbox: "Archiv")))
        #expect(job.items[0].reason == ArchiveReader.restoreNotSynced)
        (job, _) = try s.reader.planRestore(MessageFilter(ids: d), title: "D", accounts: [],
                                            options: RestoreOptions(destination: .mailbox(account: "imap", mailbox: "Archiv")))
        #expect(job.items[0].reason == "Konto ist hier nicht eingerichtet")
    }

    @Test func restoreAppendsChecksAndTheArchiveSeesItOnTheServerAgain() async throws {
        let s = try await Self.setup()
        let (planned, _) = try s.reader.planRestore(MessageFilter(), title: "alle", accounts: s.accounts, options: RestoreOptions())
        let job = try await run(s, planned)
        let done = job.items.filter { $0.state == .done }
        #expect(done.count == 4, "\(job.reasons)")  // A, E, F, G
        #expect(job.items.first { $0.messageID == "<g@t.test>" }?.reason == "lag bereits dort")
        let imapAppends = await s.imap.appends, gmAppends = await s.gm.appends
        #expect(imapAppends == 2 && gmAppends == 1)  // A, F; E — not G
        let a = try #require(await s.imap.messages(in: "INBOX").first { MIMEParser.parse($0.data).messageID == "<a@t.test>" })
        #expect(a.flags == ["\\Seen"] && a.internalDate == Self.arrival)
        #expect(await s.gm.labelCalls.first?.1 == ["Work", "\\Inbox"])  // Ünïcode no longer exists: never created
        #expect(job.items.first { $0.messageID == "<e@t.test>" }?.reason == "Labels gibt es nicht mehr: Ünïcode")
        #expect(job.notes.contains { $0.reason == "lag bereits dort" })
        // the archive knows the new locations, journalled: they survive a rebuild
        let onServer = { try Set(s.reader.summaries(try s.reader.messageIDs(MessageFilter(text: "on:server "))).compactMap(\.subject)) }
        #expect(try onServer() == ["A", "B", "C", "E", "F no id", "G"])
        _ = try await s.writer.rebuildIndex()
        #expect(try onServer() == ["A", "B", "C", "E", "F no id", "G"])
        #expect(s.audit.entries().filter { $0.action == .restore }.count == job.items.count - job.count(.skipped))
        // planned again: nothing left to do
        let (again, _) = try s.reader.planRestore(MessageFilter(), title: "alle", accounts: s.accounts, options: RestoreOptions())
        #expect(again.count(.planned) == 0)
    }

    @Test func protonRewritesHeadersAndItStillCounts() async throws {
        let s = try await Self.setup()
        await s.imap.setRewrite { data in Data("X-Pm-Origin: import\r\n".utf8) + data }
        let a = try s.reader.messageIDs(MessageFilter(text: "subject:A "))
        let (planned, _) = try s.reader.planRestore(MessageFilter(ids: a), title: "A", accounts: s.accounts, options: RestoreOptions())
        let job = try await run(s, planned)
        #expect(job.items.map(\.state) == [.done])
        #expect(try s.reader.count(MessageFilter()) == 7)  // the rewritten copy is the same message
        #expect(try s.reader.count(MessageFilter(text: "subject:A on:server ")) == 1)
    }

    /// The connection dies right after the server stored the message: on resume the item is
    /// claimed — found by its Message-ID (done, one copy) or, without one, failed with a hint.
    @Test(arguments: [true, false]) func interruptedAfterTheAppendNothingLandsTwice(withMessageID: Bool) async throws {
        let s = try await Self.setup()
        let ids = try s.reader.messageIDs(MessageFilter(text: "subject:A OR subject:F "))
        let (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "A F", accounts: s.accounts, options: RestoreOptions())
        await s.imap.setDropAfterAppend { data in (MIMEParser.parse(data).messageID == nil) != withMessageID }
        try s.store.create(planned)
        let executor = RestoreExecutor(writer: s.writer, store: s.store, audit: s.audit)
        let imap = s.imap, accounts = s.accounts
        await #expect(throws: CancellationError.self) { _ = try await executor.run(planned.id, accounts: accounts) { _ in await imap.connected() } }
        let claimed = try #require(try s.store.load(planned.id).items.first { $0.state == .claimed })
        #expect((claimed.messageID != nil) == withMessageID)
        await imap.setDropAfterAppend(nil)
        let job = try await executor.run(planned.id, accounts: accounts) { _ in await imap.connected() }
        #expect(job.isFinished)
        let resumed = try #require(job.items.first { $0.id == claimed.id })
        let inbox = await imap.messages(in: "INBOX").map { MIMEParser.parse($0.data).messageID }
        if withMessageID {
            #expect(resumed.state == .done && resumed.reason == "lag bereits dort")
            #expect(inbox.filter { $0 == "<a@t.test>" }.count == 1)
        } else {
            #expect(resumed.state == .failed && resumed.reason?.hasPrefix("Ausgang unbekannt") == true)
            #expect(inbox.filter { $0 == nil }.count == 1)  // the first upload only, never a second
        }
    }

    @Test func runningChecksTheCurrentSyncSelection() async throws {
        let s = try await Self.setup()
        let (planned, _) = try s.reader.planRestore(MessageFilter(), title: "alle", accounts: s.accounts, options: RestoreOptions())
        // since planning the account was narrowed (or the queue file was edited): nothing goes to
        // INBOX; and the Gmail account is no longer set up here at all
        var narrowed = s.accounts[0]
        narrowed.policy = SyncPolicy(mode: .standard, include: ["Archiv"])
        let job = try await run(s, planned, accounts: [narrowed])
        let ran = job.items.filter { $0.state != .skipped }
        #expect(ran.filter { $0.target?.account == "imap" }.allSatisfy { $0.state == .failed && $0.reason == ArchiveReader.restoreNotSynced })
        #expect(ran.first { $0.target?.account == "gm" }?.reason == "Konto ist hier nicht eingerichtet")
        let appends = await s.imap.appends + s.gm.appends
        #expect(appends == 0)
    }

    @Test func aRefusalBeforeSendingCostsTheConnectionNotTheJob() async throws {
        let s = try await Self.setup()
        let ids = try s.reader.messageIDs(MessageFilter(text: "subject:A OR subject:F "))
        let (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "A F", accounts: s.accounts, options: RestoreOptions())
        await s.imap.setRefuseOnceBeforeData()
        let job = try await run(s, planned)
        #expect(job.items.map(\.state) == [.failed, .done])
        #expect(job.items[0].reason == "vom Server abgelehnt: vor dem Senden abgelehnt")
        #expect(await s.imap.connects == 2)  // reconnected for the rest
    }

    @Test func flagsTheServerChangedOnTheWayInGoBack() async throws {
        let s = try await Self.setup()
        await s.imap.setMarksSeen()  // like Proton
        let ids = try s.reader.messageIDs(MessageFilter(text: "subject:F OR subject:G "))
        let (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "F G", accounts: s.accounts, options: RestoreOptions())
        let job = try await run(s, planned)
        #expect(job.count(.done) == 2)
        let f = try #require(await s.imap.messages(in: "INBOX").first { MIMEParser.parse($0.data).messageID == nil })
        #expect(f.flags == ["\\Answered"])
        let calls = await s.imap.flagCalls
        #expect(calls.count == 1 && calls[0].2 == ["\\Seen"])  // only the upload; G (already there) untouched
        let fID = try #require(try s.reader.messageIDs(MessageFilter(text: "subject:F ")).first)
        let detail = try #require(try s.reader.detail(fID))
        #expect(detail.locations.first { $0.isOnServer }?.flags == ["\\Answered"])
    }

    @Test func aReusedMessageIDIsNotTheMessage() async throws {
        let s = try await Self.setup()
        await s.imap.put(sampleMessage(id: "<a@t.test>", subject: "Something else", from: "x@other.test"), uid: 50, in: "INBOX")
        let ids = try s.reader.messageIDs(MessageFilter(text: "subject:A "))
        let (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "A", accounts: s.accounts, options: RestoreOptions())
        let job = try await run(s, planned)
        #expect(job.items.map(\.state) == [.done] && job.items[0].reason == nil)
        #expect(await s.imap.appends == 1)
    }

    @Test func refusalsMissingMailboxesAndDamagedCopiesFailOneByOne() async throws {
        let s = try await Self.setup()
        let ids = try s.reader.messageIDs(MessageFilter(text: "subject:A OR subject:E OR subject:D "))
        var (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "x", accounts: s.accounts,
                                                    options: RestoreOptions(destination: .mailbox(account: "imap", mailbox: "Weg")))
        var job = try await run(s, planned)
        #expect(Set(job.items.map(\.reason)) == ["Ordner gibt es auf dem Server nicht – MailKeeper legt keine Ordner an"])
        (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "x", accounts: s.accounts,
                                                options: RestoreOptions(destination: .mailbox(account: "imap", mailbox: "Trash")))
        job = try await run(s, planned)
        #expect(Set(job.items.map(\.reason)) == ["Ziel ist Papierkorb oder Spam"])
        (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "x", accounts: s.accounts,
                                                options: RestoreOptions(destination: .mailbox(account: "imap", mailbox: "Archiv")))
        let d = try #require(planned.items.first { $0.messageID == "<d@t.test>" })
        try Data("tampered".utf8).write(to: s.layout.blobs.url(for: d.sha256))
        await s.imap.setRefuse("[OVERQUOTA] voll")
        job = try await run(s, planned)
        #expect(job.items.first { $0.messageID == "<d@t.test>" }?.reason == "Archivkopie beschädigt")
        #expect(job.items.first { $0.messageID == "<a@t.test>" }?.reason == "vom Server abgelehnt: [OVERQUOTA] voll")
        #expect(await s.imap.appends == 0)
    }

    @Test func withoutAppendUIDTheMessageIsFoundByItsMessageID() async throws {
        let s = try await Self.setup()
        await s.imap.setReportsUID(false)
        let ids = try s.reader.messageIDs(MessageFilter(text: "subject:A OR subject:F "))
        let (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "A F", accounts: s.accounts, options: RestoreOptions())
        let job = try await run(s, planned)
        #expect(job.items.first { $0.messageID == "<a@t.test>" }.map { $0.state == .done && $0.reason == nil } == true)
        #expect(job.items.first { $0.messageID == nil }?.reason == "hochgeladen; der Ort erscheint beim nächsten Abruf")
    }

    @Test func withoutAppendUIDFlagsAndLabelsStayAsTheServerStoredThem() async throws {
        let s = try await Self.setup()
        await s.gm.setReportsUID(false)
        await s.gm.setMarksSeen()
        let ids = try s.reader.messageIDs(MessageFilter(text: "subject:E "))
        let (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "E", accounts: s.accounts, options: RestoreOptions())
        let job = try await run(s, planned)  // no abort: nothing is changed on a message not known as our upload
        #expect(job.items.map(\.state) == [.done])
        #expect(job.items[0].reason == "Labels nicht gesetzt: der Server meldet keine UID (kein UIDPLUS); "
                + "Status weicht ab und bleibt so: der Server meldet keine UID (kein UIDPLUS)")
        let flagCalls = await s.gm.flagCalls.count, labelCalls = await s.gm.labelCalls.count
        #expect(flagCalls == 0 && labelCalls == 0)
    }

    @Test func aFullMailboxIsNotHammered() async throws {
        let s = try await Self.setup()
        let ids = try s.reader.messageIDs(MessageFilter())
        let (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "x", accounts: s.accounts,
                                                    options: RestoreOptions(destination: .mailbox(account: "imap", mailbox: "Archiv")))
        await s.imap.setRefuseAlwaysBeforeData()
        let job = try await run(s, planned)
        let failed = job.items.filter { $0.state == .failed }
        #expect(failed.filter { $0.reason?.hasPrefix("nicht versucht") == true }.count == failed.count - 3)
        #expect(await s.imap.connects == 3)  // first connect + two reconnects, then it stops trying
    }

    @Test func noRolesNoUploadIntoSomethingCalledTrash() async throws {
        let s = try await Self.setup()
        await s.imap.addBox("Papierkorb")
        await s.imap.dropRoles()
        let ids = try s.reader.messageIDs(MessageFilter(text: "subject:D "))
        let (planned, _) = try s.reader.planRestore(MessageFilter(ids: ids), title: "D", accounts: s.accounts,
                                                    options: RestoreOptions(destination: .mailbox(account: "imap", mailbox: "Papierkorb")))
        let job = try await run(s, planned)
        #expect(job.items.map(\.reason) == ["Ziel ist Papierkorb oder Spam"])
        #expect(await s.imap.appends == 0)
    }

    @Test func onlyClientFlagsAndHarmlessLabelsGoBack() {
        #expect(RestoreTarget.restorableFlags(["\\SEEN", "\\Deleted", "\\Recent", "$Junk", "\\flagged", "\\Seen"]) == ["\\Seen", "\\Flagged"])
        #expect(RestoreTarget.restorableLabels(["\\Inbox", "\\Sent", "\\Trash", "\\Spam", "\\Important", "Steuer/2019", ""])
                == ["\\Inbox", "\\Important", "Steuer/2019"])
    }
}
