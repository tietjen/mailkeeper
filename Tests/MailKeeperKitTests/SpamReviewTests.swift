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
    func moveOutOfJunk(_ uids: [UInt32], to destination: String) async throws {
        if let refuse { throw ServerRefusal(refuse) }
        guard boxes[destination] != nil else { throw ServerRefusal("kein Ordner \(destination)") }
        moves += 1
        for uid in uids {
            guard let d = boxes[selected!]!.messages.removeValue(forKey: uid) else { continue }
            let next = (boxes[destination]!.messages.keys.max() ?? 0) + 1
            boxes[destination]!.messages[next] = d
        }
    }
    func junkMailbox() async throws -> String? {
        boxes.first { $0.value.uses.contains(.junk) }?.key ?? boxes.keys.first { RemoteMailbox.looksLikeJunk($0) }
    }
    func moveToJunk(_ uids: [UInt32]) async throws {
        if let refuse { throw ServerRefusal(refuse) }
        guard let junk = try await junkMailbox() else { throw ServerRefusal("kein Spam-Ordner") }
        moves += 1
        for uid in uids {
            guard let d = boxes[selected!]!.messages.removeValue(forKey: uid) else { continue }
            let next = (boxes[junk]!.messages.keys.max() ?? 0) + 1
            boxes[junk]!.messages[next] = d
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
        // 6.8: the rescued mail is no longer "is:junk" — its Spam row is gone — and leaves the review
        #expect(try r.count(MessageFilter(text: "is:junk ", ids: [legit])) == 0)
        #expect(try r.junkReview().total == 2)  // the lottery mail on the server, the imported one
    }

    @Test("6.8: back where it lay — a folder before the filter took it, INBOX before an 'Ist Spam'; a target that is gone or no ordinary folder falls back to INBOX")
    func backWhereItLay() async throws {
        let (layout, writer, r) = try await Self.archive()
        // the invoice lay in "Projekte" before the server's filter moved it to Spam
        _ = try await writer.ingest([(sampleMessage(id: "<legit@t.test>", subject: "Ihre Rechnung", from: "billing@stadtwerke.example"),
                                      LocationInfo(account: "imap", mailbox: "Projekte", uidValidity: 3, uid: 4))])
        _ = try await writer.markGone(account: "imap", mailbox: "Projekte", uidValidity: 3, uids: [4])
        let legit = try #require(try r.messageIDs(MessageFilter(text: "subject:rechnung ")).first)
        let lotto = try #require(try r.messageIDs(MessageFilter(text: "subject:gewinn ")).first)
        let accounts = [AccountConfig.imap(id: "imap", username: "u", host: "mail.example.test")]
        var (job, summary) = try r.planRescue(MessageFilter(ids: [legit, lotto]), title: "x", accounts: accounts)
        #expect(job.items.first { $0.identity?.contains("legit") == true }?.target?.mailbox == "Projekte")
        #expect(job.items.first { $0.identity?.contains("junk") == true }?.target?.mailbox == "INBOX")  // never elsewhere: INBOX
        #expect(summary.perAccount == ["imap › Projekte": 1, "imap › INBOX": 1])
        // an edited queue file may not send it to Sent: INBOX instead, and the result says so
        job.items[job.items.firstIndex { $0.identity?.contains("junk") == true }!].target = RestoreTarget(account: "imap", mailbox: "Sent")
        let server = FakeRescueServer(["INBOX": .init(validity: 7), "Spam": .init(validity: 5, uses: [.junk]), "Projekte": .init(validity: 3),
                                       "Sent": .init(validity: 8, uses: [.sent])])
        await server.put(sampleMessage(id: "<legit@t.test>", subject: "Ihre Rechnung", from: "billing@stadtwerke.example"), uid: 1, in: "Spam")
        await server.put(sampleMessage(id: "<junk@t.test>", subject: "Gewinn!", from: "win@lotto.example"), uid: 2, in: "Spam")
        let store = ActionStore(layout: layout)
        try store.create(job)
        var config = accounts[0]
        config.policy = SyncPolicy(mode: .standard)
        let done = try await RescueExecutor(writer: writer, store: store, audit: AuditLog(url: tempDir().appending(path: "a.jsonl")))
            .run(job.id, accounts: [config]) { _ in server }
        #expect(done.items.allSatisfy { $0.state == .done }, "\(done.reasons)")
        let projekte = await server.ids(in: "Projekte"), inbox = await server.ids(in: "INBOX")
        #expect(projekte == ["<legit@t.test>"] && inbox == ["<junk@t.test>"])
        #expect(await server.ids(in: "Sent").isEmpty)
        let junkItem = try #require(done.items.first { $0.identity?.contains("junk") == true })
        #expect(junkItem.reason?.contains("„Sent“ gibt es nicht mehr oder ist kein gewöhnlicher Ordner") == true)
        #expect(done.items.first { $0.identity?.contains("legit") == true }?.reason?.hasPrefix("aus „Spam“ → Projekte") == true)
        #expect(try r.detail(legit)?.locations.contains { $0.mailbox == "Projekte" && $0.isOnServer } == true)  // synced: recorded
    }

    @Test("6.8: 'is:fehlalarm' is what the review counts as 'laut KI kein Spam'; 'Kein Spam' ends a model's spam category")
    func falsePositivesAndTheEndOfASpamCategory() async throws {
        let (_, writer, r) = try await Self.archive()
        let legit = try #require(try r.messageIDs(MessageFilter(text: "subject:rechnung ")).first)
        let lotto = try #require(try r.messageIDs(MessageFilter(text: "subject:gewinn ")).first)
        let imported = try #require(try r.messageIDs(MessageFilter(text: "subject:importiert ")).first)
        try await writer.setClassification(messageID: legit, category: .invoice, source: .endpoint, model: "m", reason: "Rechnung")
        try await writer.setClassification(messageID: lotto, category: .spam, source: .endpoint, model: "m", reason: "Gewinnspiel")
        try await writer.setClassification(messageID: imported, category: .newsletter, source: .endpoint, model: "m", reason: "x", phishing: .suspicious)
        #expect(try r.messageIDs(MessageFilter(text: "is:fehlalarm ")) == [legit])  // phishing is no false positive
        #expect(try r.junkReview().notSpam == 1)
        #expect(try r.count(MessageFilter(text: "-is:fehlalarm is:junk ")) == 2)  // negation takes all of it
        try await writer.confirmNotSpam(identity: try #require(try r.identities(of: [lotto]).first))
        let c = try #require(try r.classification(of: lotto))
        #expect(c.category == nil && c.source == .heuristic && c.verdict == "ham")
        #expect(try r.heuristicPendingCount() >= 1)  // the rules look at it again
        #expect(try r.count(MessageFilter(text: "kategorie:spam ", ids: [lotto])) == 0)
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
        #expect(done.items[0].reason == "aus „Spam“ → INBOX · im Posteingang; diesen Ordner ruft MailKeeper für das Konto nicht ab")
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


@Suite("Spam & Phishing im Posteingang (6.4)")
struct InboxSpamTests {
    static let accounts = [AccountConfig.imap(id: "imap", username: "u", host: "mail.example.test")]

    @Test func istSpamMovesFromTheInboxToTheSpamFolderAndTheArchiveKnows() async throws {
        let (layout, writer, r) = try await SpamReviewTests.archive()
        _ = try await writer.ingest([
            (sampleMessage(id: "<sent@t.test>", subject: "Gesendet", from: "me@own.test"), LocationInfo(account: "imap", mailbox: "Sent", uidValidity: 8, uid: 1)),
        ])
        let server = FakeRescueServer(["INBOX": .init(validity: 7), "Spam": .init(validity: 5, uses: [.junk]), "Sent": .init(validity: 8, uses: [.sent])])
        await server.put(sampleMessage(id: "<inbox@t.test>", subject: "Hallo"), uid: 1, in: "INBOX")
        let hello = try #require(try r.messageIDs(MessageFilter(text: "subject:hallo ")).first)
        let sent = try #require(try r.messageIDs(MessageFilter(text: "subject:gesendet ")).first)
        let spam = try #require(try r.messageIDs(MessageFilter(text: "subject:gewinn ")).first)
        let imported = try #require(try r.messageIDs(MessageFilter(text: "subject:importiert ")).first)
        let (job, summary) = try r.planMarkSpam(MessageFilter(ids: [hello, sent, spam, imported]), title: "x", accounts: Self.accounts)
        #expect(job.kind == .moveToJunk && job.items.map(\.location?.mailbox) == ["INBOX"])  // never from Sent, Spam or an import
        #expect(summary.archiveOnly == 3)

        var config = Self.accounts[0]
        config.policy = SyncPolicy(mode: .standard, includeJunk: true)  // the spam folder is fetched: its location is recorded
        let store = ActionStore(layout: layout)
        try store.create(job)
        let done = try await RescueExecutor(writer: writer, store: store, audit: AuditLog(url: tempDir().appending(path: "a.jsonl")))
            .run(job.id, accounts: [config]) { _ in server }
        #expect(done.items.map(\.state) == [.done], "\(done.reasons)")
        let inbox = await server.ids(in: "INBOX"), junk = await server.ids(in: "Spam")
        #expect(inbox.isEmpty && junk == ["<inbox@t.test>"])
        let detail = try #require(try r.detail(hello))
        #expect(detail.locations.first { $0.mailbox == "Spam" }?.isOnServer == true && detail.locations.first { $0.mailbox == "INBOX" }?.isOnServer == false)
        let c = try #require(try r.classification(of: hello))
        #expect(c.source == .user && c.category == .spam && c.verdict == "spam")
        #expect(try r.count(MessageFilter(text: "is:junk ", ids: [hello])) == 1)
    }

    @Test("Review 6.7 S7: a server that marks only Junk keeps the name veto for Sent (an edited queue file)")
    func partialRolesKeepTheNameVeto() async throws {
        let (layout, writer, r) = try await SpamReviewTests.archive()
        let hello = try #require(try r.messageIDs(MessageFilter(text: "subject:hallo ")).first)
        let server = FakeRescueServer(["INBOX": .init(validity: 7), "Spam": .init(validity: 5, uses: [.junk]), "Sent": .init(validity: 8)])
        await server.put(sampleMessage(id: "<inbox@t.test>", subject: "Hallo"), uid: 1, in: "Sent")
        var (job, _) = try r.planMarkSpam(MessageFilter(ids: [hello]), title: "x", accounts: Self.accounts)
        job.items[0].location?.mailbox = "Sent"  // as if the queue file had been edited
        let store = ActionStore(layout: layout)
        try store.create(job)
        let done = try await RescueExecutor(writer: writer, store: store, audit: AuditLog(url: tempDir().appending(path: "a.jsonl")))
            .run(job.id, accounts: Self.accounts) { _ in server }
        #expect(done.items.map(\.state) == [.failed] && done.items.first?.reason == "aus diesem Ordner verschiebt MailKeeper nichts in den Spam-Ordner")
        #expect(await server.moves == 0)
    }

    @Test("Review 6.7 B1: new mail gets its rules before the screening looks for candidates")
    func newMailIsScreenedInTheSameSync() async throws {
        let (_, writer, r) = try await RelationTests.archive()
        let day = Calendar.current.component(.day, from: .now), year = Calendar.current.component(.year, from: .now)
        _ = try await writer.ingest([(RelationTests.mail("fresh", from: "info@musterbank-service.example", subject: "Konto",
                                                         auth: "mail.own.test; dmarc=pass", date: "\(day) \(Self.month()) \(year)"),
                                      LocationInfo(account: "x", mailbox: "INBOX", providerID: "fresh"))])
        let fresh = try #require(try r.messageIDs(MessageFilter(text: "msgid:fresh@t.test ")).first)
        let since = Date.now.addingTimeInterval(-14 * 86_400)
        #expect(!(try r.screeningCandidates(since: since, limit: 50).contains { $0.id == fresh }))  // no classification row yet
        try await writer.prepareForScreening()
        #expect(try r.screeningCandidates(since: since, limit: 50).contains { $0.id == fresh })
    }

    @Test func aRefusalOrAMissingSpamFolderFailsOnlyItsItems() async throws {
        let (layout, writer, r) = try await SpamReviewTests.archive()
        let hello = try #require(try r.messageIDs(MessageFilter(text: "subject:hallo ")).first)
        for (boxes, refuse, reason) in [
            (["INBOX": FakeRescueServer.Box(validity: 7)], nil as String?, "Kein Spam-Ordner auf dem Server"),
            (["INBOX": FakeRescueServer.Box(validity: 7), "Spam": .init(validity: 5, uses: [.junk])], "NO quota", "vom Server abgelehnt: NO quota"),
        ] {
            let server = FakeRescueServer(boxes)
            await server.put(sampleMessage(id: "<inbox@t.test>", subject: "Hallo"), uid: 1, in: "INBOX")
            if let refuse { await server.setRefuse(refuse) }
            let (job, _) = try r.planMarkSpam(MessageFilter(ids: [hello]), title: "x", accounts: Self.accounts)
            let store = ActionStore(layout: layout)
            try store.create(job)
            let done = try await RescueExecutor(writer: writer, store: store, audit: AuditLog(url: tempDir().appending(path: "a.jsonl")))
                .run(job.id, accounts: Self.accounts) { _ in server }
            #expect(done.items.map(\.state) == [.failed] && done.items.first?.reason == reason, "\(done.reasons)")
            #expect(try r.classification(of: hello)?.source != .user)  // nothing moved: no verdict either
        }
    }

    @Test func theScreeningAsksTheModelOnlyWhereItMatters() async throws {
        let (_, writer, r) = try await RelationTests.archive()
        try await writer.saveRelation(name: "Sparkasse", domains: ["sparkasse.example"], since: nil, until: nil)
        let recent = { (id: String, from: String, subject: String, auth: String) in
            (RelationTests.mail(id, from: from, subject: subject, auth: auth, date: "\(Calendar.current.component(.day, from: .now)) \(Self.month()) \(Calendar.current.component(.year, from: .now))"),
             LocationInfo(account: "x", mailbox: "INBOX", providerID: id))
        }
        _ = try await writer.ingest([
            recent("n1", "Sparkasse <info@sparkasse.example>", "Kontoauszug", "mail.own.test; dmarc=pass header.from=sparkasse.example"),
            recent("n2", "Sparkasse <info@sparkasse-kundenportal.example>", "Konto gesperrt", "mail.own.test; dmarc=pass"),
            recent("n3", "news@shop.example", "Sale", "mail.own.test; dmarc=pass"),
        ])
        _ = try await writer.classifyHeuristically()
        let id = { (key: String) in try #require(try r.messageIDs(MessageFilter(text: "msgid:\(key)@t.test ")).first) }
        try await writer.setClassification(messageID: try id("n1"), category: .invoice, source: .heuristic, model: nil, reason: nil)
        try await writer.setClassification(messageID: try id("n3"), category: .newsletter, source: .heuristic, model: nil, reason: nil)
        let candidates = try r.screeningCandidates(since: Date.now.addingTimeInterval(-2 * 86_400), limit: 20)
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })
        #expect(byID[try id("n1")]?.needsModel == false)  // a known relation's invoice, the own server's check passed
        let lure = try id("n2")
        #expect(byID[lure]?.needsModel == true && byID[lure]?.warning == "lookalike")
        #expect(byID[try id("n3")]?.needsModel == false)  // a newsletter
        #expect(candidates.count == 3)  // older mail and mail in Sent are not screened

        // a stopped run: warnings stored, the model's candidates still open for the next run
        try await writer.setScreened(candidates.filter { !$0.needsModel })
        try await writer.setScreened(candidates.filter(\.needsModel), markScreened: false)
        #expect(try r.screeningCandidates(since: Date.now.addingTimeInterval(-2 * 86_400), limit: 20).map(\.id) == [lure])
        #expect(try r.messageIDs(MessageFilter(text: "is:verdächtig ")) == [lure])
        try await writer.setScreened(candidates)
        #expect(try r.screeningCandidates(since: Date.now.addingTimeInterval(-2 * 86_400), limit: 20).isEmpty)
        #expect(try r.screeningCandidates(since: Date.now.addingTimeInterval(-2 * 86_400), limit: 20, again: true).count == 3)
        #expect(try r.messageIDs(MessageFilter(text: "is:verdächtig ")) == [try id("n2")])  // the warning alone shows it
        try await writer.confirmNotSpam(identity: try #require(try r.identities(of: [try id("n2")]).first))
        #expect(try r.messageIDs(MessageFilter(text: "is:verdächtig ")).isEmpty)  // "kein Spam" ends it
    }

    static func month() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM"
        return f.string(from: .now)
    }
}
