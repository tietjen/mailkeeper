import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Archive trash and tombstones (ADR-0006 §4)")
struct ArchiveTrashTests {
    static func archive() async throws -> (ArchiveLayout, ArchiveWriter, ArchiveReader) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "tr"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "imap", kind: "imap", name: "I"))
        try await writer.register(AccountInfo(id: "backup", kind: "maildir", name: "B"))
        _ = try await writer.ingest([
            (sampleMessage(id: "<a@t.test>", subject: "A"), LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 9, uid: 1)),
            (sampleMessage(id: "<a@t.test>", subject: "A"), LocationInfo(account: "backup", mailbox: "INBOX", providerID: "a")),
            (sampleMessage(id: "<b@t.test>", subject: "B"), LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 9, uid: 2)),
            (sampleMessage(id: "<c@t.test>", subject: "C"), LocationInfo(account: "backup", mailbox: "INBOX", providerID: "c")),
        ])
        return (layout, writer, try ArchiveReader(layout: layout))
    }

    /// A and B leave the IMAP server (deleted there): only then may they go to the archive trash.
    static func offServer(_ writer: ArchiveWriter) async throws {
        _ = try await writer.markGone(account: "imap", mailbox: "INBOX", uidValidity: 9, uids: [1, 2])
    }

    static func identity(_ r: ArchiveReader, _ subject: String) throws -> String {
        try #require(try r.db.queryOne("SELECT identity FROM messages WHERE subject = ?", [.text(subject)]) { $0.text(0) } ?? nil)
    }

    static func subjects(_ r: ArchiveReader, _ filter: MessageFilter = MessageFilter()) throws -> Set<String> {
        Set(try r.summaries(try r.messageIDs(filter)).compactMap(\.subject))
    }

    /// Review 4.7 B1: purge takes only what is in the trash, whatever list the caller passes.
    @Test func purgeTakesOnlyWhatIsInTheTrash() async throws {
        let (_, writer, r) = try await Self.archive()
        let report = try await writer.purge([try Self.identity(r, "A"), try Self.identity(r, "C")])
        #expect(report.messages == 0 && report.blobs == 0)
        #expect(try Self.subjects(r) == ["A", "B", "C"])
        #expect(try await writer.knownUIDs(account: "imap", mailbox: "INBOX", uidValidity: 9) == [1, 2])  // no tombstones
    }

    /// Review 4.7 S1: in the trash means on no server — checked when it happens.
    @Test func mailOnAServerDoesNotGoToTheTrash() async throws {
        let (layout, writer, r) = try await Self.archive()
        let (b, c) = (try Self.identity(r, "B"), try Self.identity(r, "C"))
        let outcome = try await writer.trashDetailed([b, c, "mid:<gibt-es-nicht@t.test>"])
        #expect(outcome.onServer == [b] && outcome.trashed == [c] && outcome.missing == ["mid:<gibt-es-nicht@t.test>"])
        // a plan made while C was archive-only, run after C showed up on a server again
        try await writer.untrash([c])
        let (job, _) = try r.planArchiveDelete(MessageFilter(text: "subject:C "), title: "C")
        #expect(job.count(.planned) == 1)
        _ = try await writer.ingest(sampleMessage(id: "<c@t.test>", subject: "C"),
                                    at: LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 9, uid: 3))
        let store = ActionStore(layout: layout)
        try store.create(job)
        let done = try await ArchiveDeleteExecutor(writer: writer, store: store, audit: AuditLog(url: tempDir().appending(path: "a.jsonl"))).run(job.id)
        #expect(done.items.map(\.state) == [.skipped] && done.items[0].reason == ArchiveReader.stillOnServer)
        #expect(try r.stats().trashed == 0)
    }

    /// Review 4.7 S2: a purged message's tombstone does not swallow a different message that
    /// reuses its Message-ID — but still keeps the purged one out. Journalled: same after a rebuild.
    @Test func aReusedMessageIDAfterAPurgeIsNotSwallowed() async throws {
        let (_, writer, r) = try await Self.archive()
        try await Self.offServer(writer)
        let a = try Self.identity(r, "A")
        try await writer.trash([a])
        #expect(try await writer.purge([a]).messages == 1)
        _ = try await writer.rebuildIndex()
        let other = sampleMessage(id: "<a@t.test>", subject: "Ganz etwas anderes", from: "x@other.test")
        guard case .newMessage = try await writer.ingest(other, at: LocationInfo(account: "backup", mailbox: "Neu", providerID: "o")) else {
            Issue.record("a different message with a reused Message-ID was swallowed")
            return
        }
        let again = sampleMessage(id: "<a@t.test>", subject: "A", body: "andere Bytes derselben Mail")
        #expect(try await writer.ingest(again, at: LocationInfo(account: "backup", mailbox: "Neu", providerID: "a2")) == .tombstoned)
        #expect(try Self.subjects(r) == ["B", "C", "Ganz etwas anderes"])
    }

    @Test func trashHidesAndRestores() async throws {
        let (_, writer, r) = try await Self.archive()
        try await Self.offServer(writer)
        #expect(try await writer.trash([try Self.identity(r, "B")]) == 1)
        #expect(try await writer.trash([try Self.identity(r, "B")]) == 0)  // already there
        #expect(try Self.subjects(r) == ["A", "C"])
        #expect(try Self.subjects(r, MessageFilter(trash: .only)) == ["B"])
        #expect(try r.stats().messages == 2 && r.stats().trashed == 1)
        #expect(try r.accounts().first { $0.id == "imap" }?.messageCount == 1)
        #expect(try await writer.untrash([try Self.identity(r, "B")]) == 1)
        #expect(try Self.subjects(r) == ["A", "B", "C"] && r.stats().trashed == 0)
    }

    @Test func purgeDeletesForGoodAndNothingBringsItBack() async throws {
        let (layout, writer, r) = try await Self.archive()
        try await Self.offServer(writer)
        let a = try Self.identity(r, "A")
        let blob = try #require(try r.detail(try r.messageIDs(MessageFilter(text: "subject:A ")).first!)?.primaryBlob)
        try await writer.trash([a])
        let report = try await writer.purge([a])
        #expect(report.messages == 1 && report.blobs == 1 && report.bytes > 0)
        #expect(!FileManager.default.fileExists(atPath: layout.blobs.url(for: blob).path))
        #expect(try Self.subjects(r) == ["B", "C"] && r.stats().trashed == 0)
        // sync: the purged UID counts as known, so it is not fetched again
        #expect(try await writer.knownUIDs(account: "imap", mailbox: "INBOX", uidValidity: 9) == [1, 2])
        // the same bytes (re-import) and other bytes of the same message (re-fetch) stay out
        #expect(try await writer.ingest(sampleMessage(id: "<a@t.test>", subject: "A"),
                                        at: LocationInfo(account: "backup", mailbox: "Other", providerID: "x")) == .tombstoned)
        let variant = sampleMessage(id: "<a@t.test>", subject: "A", body: "andere Bytes")
        #expect(try await writer.ingest(variant, at: LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 9, uid: 77)) == .tombstoned)
        #expect(!FileManager.default.fileExists(atPath: layout.blobs.url(for: sha256Hex(variant)).path))
        #expect(try r.stats().messages == 2)
        // an index rebuild neither resurrects it nor reports its blob as lost
        let rebuilt = try await writer.rebuildIndex()
        #expect(rebuilt.missingBlobs.isEmpty)
        #expect(try Self.subjects(r) == ["B", "C"])
        #expect(try await writer.ingest(variant, at: LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 9, uid: 78)) == .tombstoned)
    }

    @Test func trashSurvivesARebuildAndExpiresAfterThirtyDays() async throws {
        let (_, writer, r) = try await Self.archive()
        try await Self.offServer(writer)
        let now = Date()
        try await writer.trash([try Self.identity(r, "B")], time: now.addingTimeInterval(-31 * 86_400).timeIntervalSince1970)
        try await writer.trash([try Self.identity(r, "C")], time: now.addingTimeInterval(-5 * 86_400).timeIntervalSince1970)
        _ = try await writer.rebuildIndex()
        #expect(try Self.subjects(r, MessageFilter(trash: .only)) == ["B", "C"])
        let purged = try await writer.purgeExpired(days: 30, now: now)
        #expect(purged.messages == 1)
        #expect(try Self.subjects(r, MessageFilter(trash: .only)) == ["C"] && Self.subjects(r) == ["A"])
    }

    @Test func planAndRunAnArchiveDelete() async throws {
        let (layout, writer, r) = try await Self.archive()
        let (job, summary) = try r.planArchiveDelete(MessageFilter(text: "subject:A OR subject:C "), title: "A und C")
        #expect(job.items.count == 2 && job.items.allSatisfy { $0.identity != nil })
        #expect(summary.messages == 2 && summary.archiveOnly == 1)
        // A is still on the IMAP server: in the trash means on no server (TJ) — skipped, with the way out
        let a = try #require(job.items.first { $0.state == .skipped })
        #expect(a.reason == ArchiveReader.stillOnServer && job.count(.planned) == 1)
        let store = ActionStore(layout: layout)
        try store.create(job)
        let audit = AuditLog(url: tempDir().appending(path: "audit.jsonl"))
        let done = try await ArchiveDeleteExecutor(writer: writer, store: store, audit: audit).run(job.id)
        #expect(done.count(.done) == 1 && audit.entries().count == 1)
        #expect(try Self.subjects(r) == ["A", "B"] && Self.subjects(r, MessageFilter(trash: .only)) == ["C"])
        #expect(try store.load(job.id).isFinished)
    }

    @Test("Exactly one place: server and archive, archive only, or trash")
    func placeIsShownAndKeptConsistent() async throws {
        let (_, writer, r) = try await Self.archive()
        let id = { (s: String) in try #require(try r.messageIDs(MessageFilter(text: "subject:\(s) ", trash: .exclude)).first) }
        #expect(try r.detail(try id("A"))?.place == .serverAndArchive)
        #expect(try r.detail(try id("C"))?.place == .archiveOnly)
        let c = try id("C")
        let trashedAt = Date().addingTimeInterval(-2 * 86_400)
        try await writer.trash([try Self.identity(r, "C")], time: trashedAt.timeIntervalSince1970)
        let detail = try #require(try r.detail(c))
        #expect(detail.place == .trash)
        #expect(abs(detail.purgeDate(days: 30)!.timeIntervalSince(trashedAt) - 30 * 86_400) < 1)
        #expect(detail.purgeDate(days: 7).map { abs($0.timeIntervalSince(trashedAt) - 7 * 86_400) < 1 } == true)
        #expect(detail.purgeDate(days: nil) == nil)  // only by hand: no date
        // back on a server (moved there by the user): out of the trash, also after a rebuild
        _ = try await writer.ingest(sampleMessage(id: "<c@t.test>", subject: "C"),
                                    at: LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 9, uid: 50))
        #expect(try r.detail(c)?.place == .serverAndArchive)
        _ = try await writer.rebuildIndex()
        #expect(try Self.subjects(r, MessageFilter(trash: .only)).isEmpty && Self.subjects(r).contains("C"))
    }
}
