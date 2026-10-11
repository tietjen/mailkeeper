import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Export (4.6)")
struct ExportTests {
    /// Three messages: one with "From " and ">From " lines in its body, one without subject, two
    /// with the same subject and date (file name clash).
    static func archive() async throws -> (ArchiveLayout, ArchiveReader) {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "ex"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest([
            (sampleMessage(id: "<f@t.test>", subject: "Tricky", body: "From here on\n>From quoted\nok"), LocationInfo(account: "x", mailbox: "INBOX")),
            (eml("From: a@t.test\nDate: Thu, 14 Mar 2019 10:00:00 +0100\nMessage-ID: <n@t.test>\n\nkein Betreff"), LocationInfo(account: "x", mailbox: "INBOX")),
            (sampleMessage(id: "<s1@t.test>", subject: "Same/Name: ok"), LocationInfo(account: "x", mailbox: "INBOX")),
            (sampleMessage(id: "<s2@t.test>", subject: "Same/Name: ok", body: "zwei\n"), LocationInfo(account: "x", mailbox: "INBOX")),
        ])
        return (layout, try ArchiveReader(layout: layout))
    }

    @Test func emlFilesAreTheExactBytesAndNeverOverwrite() async throws {
        let (layout, reader) = try await Self.archive()
        let items = try reader.exportItems(MessageFilter())
        let dir = tempDir()
        try Data("schon da".utf8).write(to: dir.appending(path: ExportTests.firstName(items)))
        let report = try await ArchiveExporter(blobs: layout.blobs).export(items, format: .eml, to: dir)
        #expect(report.exported == 4 && report.problems.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(files.count == 5)  // the existing file stays, ours gets " (2)"
        #expect(files.allSatisfy { !$0.contains("/") && !$0.contains(":") })
        #expect(try String(contentsOf: dir.appending(path: ExportTests.firstName(items)), encoding: .utf8) == "schon da")
        let written = try files.filter { $0.hasSuffix(".eml") }.map { try Data(contentsOf: dir.appending(path: $0)) }
        #expect(Set(written.map(sha256Hex)).isSuperset(of: Set(items.map(\.sha256))))
        let attributes = try FileManager.default.attributesOfItem(atPath: dir.appending(path: files.first { $0.contains("ohne Betreff") }!).path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
        #expect((attributes[.modificationDate] as? Date) == items.first { $0.subject == nil }?.date)
        // and back in: EML import yields the same bytes
        try FileManager.default.removeItem(at: dir.appending(path: ExportTests.firstName(items)))
        let back = try ArchiveLayout.open(at: tempDir().appending(path: "back"), create: true)
        let writer = try ArchiveWriter(layout: back)
        _ = try await EMLImporter(root: dir, account: "files").run(writer: writer)
        #expect(Set(try ArchiveReader(layout: back).exportItems(MessageFilter()).map(\.sha256)) == Set(items.map(\.sha256)))
    }

    static func firstName(_ items: [ExportItem]) -> String {
        ArchiveExporter.fileName(items.first { $0.subject == "Same/Name: ok" }!)
    }

    @Test func mboxRoundTripsThroughTheImporterByteForByte() async throws {
        let (layout, reader) = try await Self.archive()
        let items = try reader.exportItems(MessageFilter())
        let file = tempDir().appending(path: "out.mbox")
        let report = try await ArchiveExporter(blobs: layout.blobs).export(items, format: .mbox, to: file)
        #expect(report.exported == 4)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.hasPrefix("From MAILER-DAEMON "))
        let bytes = try Data(contentsOf: file)  // String.contains sees "\r\n" as one character
        #expect(bytes.range(of: Data("\n>From here on".utf8)) != nil && bytes.range(of: Data("\n>>From quoted".utf8)) != nil)
        let back = try ArchiveLayout.open(at: tempDir().appending(path: "back"), create: true)
        _ = try await MboxImporter(file: file, account: "mbox").run(writer: try ArchiveWriter(layout: back))
        #expect(Set(try ArchiveReader(layout: back).exportItems(MessageFilter()).map(\.sha256)) == Set(items.map(\.sha256)))
    }

    @Test func damagedCopiesAreReportedNotWritten() async throws {
        let (layout, reader) = try await Self.archive()
        let items = try reader.exportItems(MessageFilter())
        try Data("tampered".utf8).write(to: layout.blobs.url(for: items[0].sha256))
        try FileManager.default.removeItem(at: layout.blobs.url(for: items[1].sha256))
        let dir = tempDir()
        let report = try await ArchiveExporter(blobs: layout.blobs).export(items, format: .eml, to: dir)
        #expect(report.exported == 2)
        #expect(report.problems == ["Archivkopie beschädigt": 1, "Archivkopie fehlt": 1])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
    }

    @Test func aStoppedMboxExportLeavesNoHalfFile() async throws {
        let (layout, reader) = try await Self.archive()
        let items = try reader.exportItems(MessageFilter())
        let file = tempDir().appending(path: "out.mbox")
        await #expect(throws: CancellationError.self) {
            _ = try await ArchiveExporter(blobs: layout.blobs).export(items, format: .mbox, to: file) { done, _ in
                if done < items.count { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func separatorAndEscaping() {
        #expect(ArchiveExporter.separatorLine(Date(timeIntervalSince1970: 1_552_554_000)) == "From MAILER-DAEMON Thu Mar 14 09:00:00 2019\n")
        #expect(ArchiveExporter.separatorLine(Date(timeIntervalSince1970: 1_551_690_000)) == "From MAILER-DAEMON Mon Mar  4 09:00:00 2019\n")
        let raw = Data("From x\r\n>From y\r\nok From z\r\nFromage\r\n".utf8)
        let escaped = ArchiveExporter.escapeFromLines(raw)
        #expect(String(decoding: escaped, as: UTF8.self) == ">From x\r\n>>From y\r\nok From z\r\nFromage\r\n")
        #expect(MboxImporter.unescapeFromLines(escaped) == raw)
    }

    @Test func fileNamesAreSortableAndSafe() {
        let item = ExportItem(sha256: "x", size: 1, date: nil, subject: "Rechnung\u{202E}fdp.exe / März: 2019.pdf")
        let name = ArchiveExporter.fileName(item)
        #expect(name.hasPrefix("0000-00-00 0000 ") && name.hasSuffix(".eml"))
        #expect(!name.contains("/") && !name.contains(":") && !name.unicodeScalars.contains("\u{202E}"))
    }
}
