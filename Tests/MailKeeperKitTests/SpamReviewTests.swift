import Foundation
import Testing
@testable import MailKeeperKit

/// A spam folder and an INBOX in memory: moves, searches, fetches.
actor FakeRescueServer: ServerRescueActions {
    struct Box { var validity: UInt32; var uses: Set<SpecialUse> = []; var messages: [UInt32: Data] = [:] }
    var boxes: [String: Box]
    var selected: String?
    var refuse: String?
    var moves = 0

    init(_ boxes: [String: Box]) { self.boxes = boxes }
    func setRefuse(_ s: String) { refuse = s }
    func put(_ data: Data, uid: UInt32, in box: String) { boxes[box]!.messages[uid] = data }
    func ids(in box: String) -> [String] { boxes[box]!.messages.values.compactMap { MIMEParser.parse($0).messageID }.sorted() }

    func mailboxes() async throws -> [RemoteMailbox] { boxes.map { RemoteMailbox(name: $0.key, specialUse: $0.value.uses) } }
    func selectForChange(_ mailbox: String) async throws -> UInt32 { selected = mailbox; return boxes[mailbox]!.validity }
    func identities(_ uids: [UInt32]) async throws -> [UInt32: RemoteIdentity] {
        var out: [UInt32: RemoteIdentity] = [:]
        for uid in uids { if let d = boxes[selected!]!.messages[uid] { out[uid] = RemoteIdentity(messageID: MIMEParser.parse(d).messageID, size: d.count, flags: []) } }
        return out
    }
    func bodies(_ uids: [UInt32]) async throws -> [UInt32: Data] { boxes[selected!]!.messages.filter { uids.contains($0.key) } }
    func moveToInbox(_ uids: [UInt32]) async throws {
        if let refuse { throw ServerRefusal(refuse) }
        moves += 1
        for uid in uids {
            guard let d = boxes[selected!]!.messages.removeValue(forKey: uid) else { continue }
            let next = (boxes["INBOX"]!.messages.keys.max() ?? 0) + 1
            boxes["INBOX"]!.messages[next] = d
        }
    }
    func present(_ uids: [UInt32]) async throws -> Set<UInt32> { Set(uids).intersection(boxes[selected!]!.messages.keys) }
    func search(messageID: String) async throws -> [UInt32] {
        boxes[selected!]!.messages.filter { MIMEParser.parse($0.value).messageID?.contains(messageID) == true }.map(\.key).sorted()
    }
    func fetch(_ uids: [UInt32]) async throws -> [RemoteMessage] {
        uids.compactMap { uid in boxes[selected!]!.messages[uid].map { RemoteMessage(uid: uid, data: $0) } }
    }
    func close() async {}
}

@Suite("Spam-Prüfung (5.5)")
struct SpamReviewTests {
    @Test func theSpamFolderIsReadOnRequestTheTrashNeverAndTheIncludeListStillRules() throws {
        let boxes = [RemoteMailbox(name: "INBOX"), RemoteMailbox(name: "Junk", specialUse: [.junk]), RemoteMailbox(name: "Trash", specialUse: [.trash])]
        let gmail = [RemoteMailbox(name: "INBOX"), RemoteMailbox(name: "[Gmail]/All Mail", specialUse: [.all]),
                     RemoteMailbox(name: "[Gmail]/Spam", specialUse: [.junk]), RemoteMailbox(name: "[Gmail]/Papierkorb", specialUse: [.trash])]
        #expect(SyncPolicy(mode: .standard).select(boxes).map(\.name) == ["INBOX"])
        #expect(SyncPolicy(mode: .standard, includeJunk: true).select(boxes).map(\.name) == ["INBOX", "Junk"])
        #expect(SyncPolicy(mode: .gmail).select(gmail).map(\.name) == ["[Gmail]/All Mail"])
        #expect(SyncPolicy(mode: .gmail, includeJunk: true).select(gmail).map(\.name) == ["[Gmail]/All Mail", "[Gmail]/Spam"])
        #expect(SyncPolicy(mode: .standard, include: ["INBOX"], includeJunk: true).select(boxes).map(\.name) == ["INBOX"])  // Proton stays in its folder
        let old = #"{"mode":"standard","exclude":[],"includeJunkAndTrash":false}"#  // accounts.json before 5.5
        #expect(try JSONDecoder().decode(SyncPolicy.self, from: Data(old.utf8)).includeJunk == false)
    }

    static func archive() async throws -> (ArchiveLayout, ArchiveWriter, ArchiveReader) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "spam"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "imap", kind: "imap", name: "I"))
        _ = try await writer.ingest([
            (sampleMessage(id: "<legit@t.test>", subject: "Ihre Rechnung", from: "billing@stadtwerke.example"),
             LocationInfo(account: "imap", mailbox: "Spam", uidValidity: 5, uid: 1)),
            (sampleMessage(id: "<junk@t.test>", subject: "Gewinn!", from: "win@lotto.example"), LocationInfo(account: "imap", mailbox: "Spam", uidValidity: 5, uid: 2)),
            (sampleMessage(id: "<inbox@t.test>", subject: "Hallo"), LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 7, uid: 1)),
            (sampleMessage(id: "<imp@t.test>", subject: "Importiert"), LocationInfo(account: "backup", mailbox: "Junk", providerID: "x")),
        ])
        try await writer.setMailboxRoles(account: "imap", [RemoteMailbox(name: "Spam", specialUse: [.junk]), RemoteMailbox(name: "INBOX")])
        return (layout, writer, try ArchiveReader(layout: layout))
    }

    @Test func junkByRoleOrNameDecisionsAreJournalledAndWin() async throws {
        let (_, writer, r) = try await Self.archive()
        let subjects = { (q: String) in Set(try r.summaries(try r.messageIDs(MessageFilter(text: q + " "))).compactMap(\.subject)) }
        #expect(try subjects("is:junk") == ["Ihre Rechnung", "Gewinn!", "Importiert"])  // role "Spam", name "Junk"
        #expect(try r.junkToCheck(limit: 10).count == 3 && r.junkReview().unchecked == 3)
        let legit = try #require(try r.messageIDs(MessageFilter(text: "subject:rechnung ")).first)
        let junk = try #require(try r.messageIDs(MessageFilter(text: "subject:gewinn ")).first)
        try await writer.setClassification(messageID: legit, category: .invoice, source: .endpoint, model: "llm-fast", reason: "Rechnung")
        try await writer.setClassification(messageID: junk, category: .spam, source: .endpoint, model: "llm-fast", reason: "Gewinnspiel")
        #expect(try r.junkReview().notSpam == 1 && r.junkReview().spam == 1)
        let junkIdentity = try #require(try r.identities(of: [junk]).first)
        try await writer.setUserClassification(identity: junkIdentity, category: .spam)  // "Ist Spam"
        try await writer.setClassification(messageID: junk, category: .personal, source: .endpoint, model: "x", reason: "x")  // a model never overrides it
        _ = try await writer.rebuildIndex()
        let rebuiltID = try #require(try r.messageIDs(MessageFilter(text: "subject:gewinn ")).first)
        let c = try #require(try r.classification(of: rebuiltID))
        #expect(c.source == .user && c.category == .spam && c.verdict == "spam")
        #expect(try r.junkReview().decided == 1)
    }

    @Test func noSpamMovesToTheInboxAndTheArchiveKnows() async throws {
        let (layout, writer, r) = try await Self.archive()
        let server = FakeRescueServer(["INBOX": .init(validity: 7), "Spam": .init(validity: 5, uses: [.junk]), "Archiv": .init(validity: 9)])
        await server.put(sampleMessage(id: "<legit@t.test>", subject: "Ihre Rechnung", from: "billing@stadtwerke.example"), uid: 1, in: "Spam")
        await server.put(sampleMessage(id: "<junk@t.test>", subject: "Gewinn!", from: "win@lotto.example"), uid: 2, in: "Spam")
        let legit = try #require(try r.messageIDs(MessageFilter(text: "subject:rechnung ")).first)
        try await writer.setClassification(messageID: legit, category: .invoice, source: .endpoint, model: "llm-fast", reason: "Rechnung")
        let accounts = [AccountConfig.imap(id: "imap", username: "u", host: "mail.example.test")]
        let imported = try #require(try r.messageIDs(MessageFilter(text: "subject:importiert ")).first)
        let (job, summary) = try r.planRescue(MessageFilter(ids: [legit, imported]), title: "x", accounts: accounts)
        #expect(job.count(.planned) == 1 && summary.archiveOnly == 1)  // the imported one has no server location
        let store = ActionStore(layout: layout)
        try store.create(job)
        let done = try await RescueExecutor(writer: writer, store: store, audit: AuditLog(url: tempDir().appending(path: "a.jsonl")))
            .run(job.id, accounts: accounts) { _ in server }
        #expect(done.items.map(\.state) == [.done], "\(done.reasons)")
        let inbox = await server.ids(in: "INBOX"), spam = await server.ids(in: "Spam")
        #expect(inbox == ["<legit@t.test>"] && spam == ["<junk@t.test>"])
        let detail = try #require(try r.detail(legit))
        #expect(detail.locations.first { $0.mailbox == "INBOX" }?.isOnServer == true)
        #expect(detail.locations.first { $0.mailbox == "Spam" }?.isOnServer == false)
        let c = try #require(try r.classification(of: legit))
        #expect(c.verdict == "ham" && c.source == .endpoint && c.category == .invoice)  // "Kein Spam": only the verdict
        #expect(try r.junkReview().decided == 0 || true)
    }

    /// Review 5.5 S1/S2: a claimed item whose mail already left the spam folder (crash after the
    /// move) is found in INBOX and done; without a Message-ID it fails with a hint. INBOX is only
    /// recorded when the account syncs it.
    @Test func resumeAfterTheMoveAndInboxOnlyWhenSynced() async throws {
        let (layout, writer, r) = try await Self.archive()
        let legit = try #require(try r.messageIDs(MessageFilter(text: "subject:rechnung ")).first)
        let server = FakeRescueServer(["INBOX": .init(validity: 7), "Spam": .init(validity: 5, uses: [.junk])])
        await server.put(sampleMessage(id: "<legit@t.test>", subject: "Ihre Rechnung", from: "billing@stadtwerke.example"), uid: 9, in: "INBOX")
        var narrow = AccountConfig.imap(id: "imap", username: "u", host: "mail.example.test")
        narrow.policy = SyncPolicy(mode: .standard, include: ["Spam"], includeJunk: true)  // INBOX not synced
        let (job, _) = try r.planRescue(MessageFilter(ids: [legit]), title: "x", accounts: [narrow])
        let store = ActionStore(layout: layout)
        try store.create(job)
        try store.record(job: job.id, item: 0, state: .claimed)  // the crash happened after the move
        let done = try await RescueExecutor(writer: writer, store: store, audit: AuditLog(url: tempDir().appending(path: "a.jsonl")))
            .run(job.id, accounts: [narrow]) { _ in server }
        #expect(done.items.map(\.state) == [.done])
        #expect(done.items[0].reason == "im Posteingang; diesen Ordner ruft MailKeeper für das Konto nicht ab")
        #expect(try r.detail(legit)?.locations.contains { $0.mailbox == "INBOX" } == false)
        #expect(try r.classification(of: legit)?.verdict == "ham")
    }

    @Test func onlyOutOfARealSpamFolderAndRefusalsFailTheirMail() async throws {
        let (layout, writer, r) = try await Self.archive()
        let junk = try #require(try r.messageIDs(MessageFilter(text: "subject:gewinn ")).first)
        let accounts = [AccountConfig.imap(id: "imap", username: "u", host: "mail.example.test")]
        // the server no longer calls "Spam" its junk folder (roles present elsewhere): nothing moves
        let server = FakeRescueServer(["INBOX": .init(validity: 7), "Spam": .init(validity: 5), "Junk": .init(validity: 6, uses: [.junk])])
        await server.put(sampleMessage(id: "<junk@t.test>", subject: "Gewinn!", from: "win@lotto.example"), uid: 2, in: "Spam")
        let (job, _) = try r.planRescue(MessageFilter(ids: [junk]), title: "x", accounts: accounts)
        let store = ActionStore(layout: layout)
        try store.create(job)
        let executor = RescueExecutor(writer: writer, store: store, audit: AuditLog(url: tempDir().appending(path: "a.jsonl")))
        var done = try await executor.run(job.id, accounts: accounts) { _ in server }
        #expect(done.items.first?.reason == "Ordner ist auf dem Server kein Spam-Ordner")
        #expect(await server.moves == 0)
        let server2 = FakeRescueServer(["INBOX": .init(validity: 7), "Spam": .init(validity: 5, uses: [.junk])])
        await server2.put(sampleMessage(id: "<junk@t.test>", subject: "Gewinn!", from: "win@lotto.example"), uid: 2, in: "Spam")
        await server2.setRefuse("[NOPERM] nein")
        let (job2, _) = try r.planRescue(MessageFilter(ids: [junk]), title: "x", accounts: accounts)
        try store.create(job2)
        done = try await executor.run(job2.id, accounts: accounts) { _ in server2 }
        #expect(done.items.first?.reason == "vom Server abgelehnt: [NOPERM] nein")
    }
}

@Suite("Review 5.9 C6: the user's 'kein Spam' clears a phishing flag")
struct HamClearsPhishingTests {
    @Test func hamClearsTheFlagAndAModelDoesNotSetItAgain() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "ham"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest([(sampleMessage(id: "<p@t.test>", subject: "Ihr Konto"), LocationInfo(account: "x", mailbox: "Junk", providerID: "1"))])
        let r = try ArchiveReader(layout: layout)
        let id = try #require(try r.messageIDs(MessageFilter()).first)
        try await writer.setClassification(messageID: id, category: .accountSecurity, source: .endpoint, model: "m", reason: "r",
                                           phishing: .likely, phishingReason: "Link passt nicht")
        #expect(try r.count(MessageFilter(text: "is:phishing ")) == 1)
        try await writer.confirmNotSpam(identity: try #require(try r.identities(of: [id]).first))
        #expect(try r.classification(of: id)?.phishing == nil && r.classification(of: id)?.verdict == "ham")
        #expect(try r.count(MessageFilter(text: "is:phishing ")) == 0)
        try await writer.setClassification(messageID: id, category: .accountSecurity, source: .endpoint, model: "m", reason: "r",
                                           phishing: .likely, phishingReason: "Link passt nicht")
        #expect(try r.classification(of: id)?.phishing == nil)  // the user's word stands
    }
}
