import Foundation
import Testing
@testable import MailKeeperKit

/// Stands in for the XPC service: the "PDF" bytes say what should happen.
struct FakeExtractor: AttachmentTextExtractor {
    struct Crash: Error {}
    func extractText(pdf: Data) async throws -> AttachmentText {
        let s = String(decoding: pdf, as: UTF8.self)
        if s.hasPrefix("PDF:") { return AttachmentText(status: .ok, text: String(s.dropFirst(4))) }
        if s == "LOCKED" { return AttachmentText(status: .encrypted) }
        if s == "SCAN" { return AttachmentText(status: .empty) }
        throw Crash()
    }
}

private func mail(_ id: String, subject: String, body: String, pdfs: [(name: String, type: String, content: String)]) -> Data {
    var parts = "--b\nContent-Type: text/plain; charset=utf-8\n\n\(body)\n"
    for p in pdfs {
        parts += "--b\nContent-Type: \(p.type)\nContent-Disposition: attachment; filename=\(p.name)\n"
        parts += "Content-Transfer-Encoding: base64\n\n\(Data(p.content.utf8).base64EncodedString())\n"
    }
    return eml("""
    From: a@example.test
    Subject: \(subject)
    Date: Thu, 14 Mar 2024 10:00:00 +0100
    Message-ID: \(id)
    Content-Type: multipart/mixed; boundary=b

    \(parts)--b--
    """)
}

@Suite("Attachment text (ADR-0009)")
struct AttachmentIndexTests {
    static func archive() async throws -> (ArchiveLayout, ArchiveWriter) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "ai"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "a", kind: "imap", name: "A"))
        let mails = [
            mail("<p1@t.test>", subject: "P1", body: "Danke für Ihre Bestellung", pdfs: [("r.pdf", "application/pdf", "PDF:Telekom Rechnung 2024")]),
            mail("<p2@t.test>", subject: "P2", body: "Anbei", pdfs: [("v.pdf", "application/pdf", "PDF:Mietvertrag Wohnung"),
                                                                    ("s.pdf", "application/pdf", "SCAN")]),
            mail("<p3@t.test>", subject: "P3", body: "kaputt", pdfs: [("x.pdf", "application/pdf", "BOOM")]),
            mail("<p4@t.test>", subject: "P4", body: "gesperrt", pdfs: [("g.pdf", "application/pdf", "LOCKED")]),
            mail("<p5@t.test>", subject: "P5", body: "Telekom ohne Anhang", pdfs: []),
            mail("<p6@t.test>", subject: "P6", body: "Hallo", pdfs: [("Kuendigung.PDF", "application/octet-stream", "PDF:Kündigung Fitnessstudio")]),
            mail("<p7@t.test>", subject: "P7", body: "Scan", pdfs: [("scan.pdf", "application/pdf", "SCAN")]),
        ]
        _ = try await writer.ingest(mails.enumerated().map { ($1, LocationInfo(account: "a", mailbox: "INBOX", providerID: "\($0)")) })
        return (layout, writer)
    }

    static func subjects(_ r: ArchiveReader, _ q: String) throws -> Set<String> {
        Set(try r.summaries(try r.messageIDs(MessageFilter(text: q + " "))).compactMap(\.subject))
    }

    @Test func queueRecordsEveryOutcomeAndMakesTextSearchable() async throws {
        let (layout, writer) = try await Self.archive()
        let r = try ArchiveReader(layout: layout)
        #expect(try Self.subjects(r, "telekom") == ["P5"])  // before: only the body of P5
        let run = try await AttachmentIndexer(writer: writer, extractor: FakeExtractor()).run()
        #expect(run.total == 6 && run.done == 6 && run.searchable == 3 && run.failed == 1)
        let stats = try r.attachmentTextStats()
        #expect(stats.withPDF == 6 && stats.pending == 0)
        #expect(stats.byStatus == [.ok: 3, .failed: 1, .encrypted: 1, .empty: 1])
        // S3: a newer extractor retries failed and empty (not encrypted) — the app's gate sees it
        #expect(try r.attachmentTextStats(version: AttachmentIndexer.version + 1).pending == 2)
        let cases: [(String, Set<String>)] = [
            ("telekom", ["P1", "P5"]), ("bestellung 2024", ["P1"]),   // body word AND pdf word
            ("pdf:bestellung", []), ("pdf:mietvertrag", ["P2"]), ("kündigung", ["P6"]), ("kuendigung", ["P6"]),
            ("telekom OR mietvertrag", ["P1", "P2", "P5"]), ("-telekom has:pdf", ["P2", "P3", "P4", "P6", "P7"]),
            ("pdf:telekom -subject:P1", []), ("fitness*", ["P6"]),
        ]
        for (q, expected) in cases { #expect(try Self.subjects(r, q) == expected, "\(q)") }
        // nothing left; a newer extractor retries failures only; a rebuild queues everything again
        #expect(try await AttachmentIndexer(writer: writer, extractor: FakeExtractor()).run().total == 0)
        #expect(try await writer.pendingAttachmentTextCount(version: AttachmentIndexer.version + 1) == 2)
        _ = try await writer.rebuildIndex()
        #expect(try await writer.pendingAttachmentTextCount(version: AttachmentIndexer.version) == 6)
    }

    /// Import and sync cancel the queue mid-extraction: that must not record a failure.
    @Test func cancellationRecordsNothingAndResumesLater() async throws {
        struct SlowExtractor: AttachmentTextExtractor {
            func extractText(pdf: Data) async throws -> AttachmentText {
                try await Task.sleep(for: .seconds(30))  // throws CancellationError when cancelled
                return AttachmentText(status: .ok, text: "late")
            }
        }
        let (layout, writer) = try await Self.archive()
        let task = Task { try await AttachmentIndexer(writer: writer, extractor: SlowExtractor()).run() }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try ArchiveReader(layout: layout).attachmentTextStats().done == 0)
        #expect(try await AttachmentIndexer(writer: writer, extractor: FakeExtractor()).run().done == 6)
    }

    /// S4: a service that cannot run at all must not mark every PDF as failed.
    @Test func unavailableServiceRecordsNothing() async throws {
        struct Missing: AttachmentTextExtractor {
            func extractText(pdf: Data) async throws -> AttachmentText { throw AttachmentTextUnavailable("no service") }
        }
        let (layout, writer) = try await Self.archive()
        await #expect(throws: AttachmentTextUnavailable.self) {
            _ = try await AttachmentIndexer(writer: writer, extractor: Missing()).run()
        }
        let stats = try ArchiveReader(layout: layout).attachmentTextStats()
        #expect(stats.done == 0 && stats.pending == 6)
    }

    @Test func reindexingReplacesText() async throws {
        let (layout, writer) = try await Self.archive()
        let r = try ArchiveReader(layout: layout)
        let id = try #require(try r.messageIDs(MessageFilter(text: "subject:P1 ")).first)
        try await writer.setAttachmentText(messageID: id, AttachmentText(status: .ok, text: "alpha"), version: 1)
        try await writer.setAttachmentText(messageID: id, AttachmentText(status: .ok, text: "beta"), version: 1)
        #expect(try Self.subjects(r, "pdf:alpha").isEmpty && Self.subjects(r, "pdf:beta") == ["P1"])
        #expect(try r.queryPlan(MessageFilter(text: "telekom pdf:x")).contains { $0.contains("LIST SUBQUERY") })
    }
}
