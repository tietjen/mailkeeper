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
        #expect(c.source == .user && c.category == .spam)
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
        #expect(c.source == .user && c.category == .invoice)  // "Kein Spam", the model's category kept
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
