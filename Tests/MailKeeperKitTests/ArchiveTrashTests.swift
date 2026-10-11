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

    static func identity(_ r: ArchiveReader, _ subject: String) throws -> String {
        try #require(try r.db.queryOne("SELECT identity FROM messages WHERE subject = ?", [.text(subject)]) { $0.text(0) } ?? nil)
    }

    static func subjects(_ r: ArchiveReader, _ filter: MessageFilter = MessageFilter()) throws -> Set<String> {
        Set(try r.summaries(try r.messageIDs(filter)).compactMap(\.subject))
    }

    @Test func trashHidesAndRestores() async throws {
        let (_, writer, r) = try await Self.archive()
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
        #expect(abs(detail.purgeDate()!.timeIntervalSince(trashedAt) - 30 * 86_400) < 1)
        // back on a server (moved there by the user): out of the trash, also after a rebuild
        _ = try await writer.ingest(sampleMessage(id: "<c@t.test>", subject: "C"),
                                    at: LocationInfo(account: "imap", mailbox: "INBOX", uidValidity: 9, uid: 50))
        #expect(try r.detail(c)?.place == .serverAndArchive)
        _ = try await writer.rebuildIndex()
        #expect(try Self.subjects(r, MessageFilter(trash: .only)).isEmpty && Self.subjects(r).contains("C"))
    }
}
