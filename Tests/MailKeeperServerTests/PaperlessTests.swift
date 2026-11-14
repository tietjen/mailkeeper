import Foundation
import Testing
@testable import MailKeeperKit
@testable import MailKeeperServer

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mailkeeperd-paperless-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A multipart message: a text or HTML body and attachments (name, type, bytes, disposition, cid).
private func mail(id: String, from: String = "Shop <rechnung@shop.test>", subject: String = "Ihre Rechnung",
                  date: String = "Mon, 03 Nov 2026 10:00:00 +0100", extraHeaders: [String] = [], html: String? = nil,
                  parts: [(name: String?, type: String, data: Data, disposition: String?, cid: String?)]) -> Data {
    var s = "From: \(from)\r\nTo: jan@example.org\r\nSubject: \(subject)\r\nDate: \(date)\r\nMessage-ID: \(id)\r\n"
    for h in extraHeaders { s += h + "\r\n" }
    s += "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n"
    if let html {
        s += "--b1\r\nContent-Type: multipart/related; boundary=\"b2\"\r\n\r\n--b2\r\nContent-Type: text/html; charset=utf-8\r\n\r\n\(html)\r\n"
        for p in parts where p.cid != nil {
            s += "--b2\r\nContent-Type: \(p.type)\r\nContent-Transfer-Encoding: base64\r\nContent-ID: <\(p.cid!)>\r\n"
            if let d = p.disposition { s += "Content-Disposition: \(d)\(p.name.map { "; filename=\"\($0)\"" } ?? "")\r\n" }
            s += "\r\n\(p.data.base64EncodedString(options: .lineLength76Characters))\r\n"
        }
        s += "--b2--\r\n"
    } else {
        s += "--b1\r\nContent-Type: text/plain; charset=utf-8\r\n\r\nAnbei.\r\n"
    }
    for p in parts where p.cid == nil {
        s += "--b1\r\nContent-Type: \(p.type)\(p.name.map { "; name=\"\($0)\"" } ?? "")\r\nContent-Transfer-Encoding: base64\r\n"
        if let d = p.disposition { s += "Content-Disposition: \(d)\(p.name.map { "; filename=\"\($0)\"" } ?? "")\r\n" }
        s += "\r\n\(p.data.base64EncodedString(options: .lineLength76Characters))\r\n"
    }
    s += "--b1--\r\n"
    return Data(s.utf8)
}

private func bytes(_ n: Int, seed: UInt8) -> Data { Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) }) }

private let settings = PaperlessExport(ledgerDirectory: "/unused", rule: "-is:list -is:junk", timeZone: "Europe/Berlin",
                                       extensions: ["pdf", "docx", "png", "jpg", "xlsx"], minBytes: 10_000)
private let jan = PaperlessPerson(owner: "admin", tags: ["jan", "mail"], storagePath: "privat")
private let inbox = LocationInfo(account: "parasec", mailbox: "INBOX")

@Suite("mailkeeperd: Paperless-Trockenlauf")
struct PaperlessDryRunTests {
    static let invoice = bytes(20_000, seed: 1)

    /// Five mails: an invoice with every kind of attachment, a newsletter with a PDF, the same
    /// invoice again (forwarded), a mail Jan sent, and an old one in a nested folder.
    static func archive() async throws -> (ArchiveLayout, URL) {
        let root = tempDir()
        let layout = try ArchiveLayout.open(at: root.appending(path: "jan"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest([
            (mail(id: "<a@shop.test>", html: "<p>Hallo <img src=\"cid:logo1\"></p>", parts: [
                ("Rechnung 4711.pdf", "application/pdf", invoice, "attachment", nil),
                ("logo.png", "image/png", bytes(30_000, seed: 2), "inline", "logo1"),   // shown by the HTML
                ("icon.png", "image/png", bytes(900, seed: 3), "attachment", nil),      // too small
                ("daten.zip", "application/zip", bytes(15_000, seed: 4), "attachment", nil),
                ("login.html", "text/html", bytes(12_000, seed: 5), "attachment", nil),
                ("makro.docm", "application/vnd.ms-word.document.macroEnabled.12", bytes(12_000, seed: 6), "attachment", nil),
                ("leer.pdf", "application/pdf", Data(), "attachment", nil),
            ]), inbox),
            (mail(id: "<n@news.test>", from: "News <news@news.test>", subject: "Newsletter",
                  extraHeaders: ["List-Unsubscribe: <mailto:off@news.test>"],
                  parts: [("Angebote.pdf", "application/pdf", bytes(25_000, seed: 7), "attachment", nil)]), inbox),
            (mail(id: "<f@example.org>", from: "Katja <katja@example.org>", subject: "Fwd: Ihre Rechnung",
                  date: "Tue, 04 Nov 2026 00:30:00 +0100",
                  parts: [("rechnung.PDF", "application/pdf", invoice, nil, nil)]), inbox),   // no disposition, upper case
            (mail(id: "<s@example.org>", from: "Jan <jan@example.org>", subject: "Vertrag", date: "Wed, 05 Nov 2026 00:30:00 +0100",
                  parts: [("Vertrag.docx", "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                           bytes(40_000, seed: 8), "attachment", nil)]), LocationInfo(account: "parasec", mailbox: "Sent")),
            (mail(id: "<old@shop.test>", date: "Wed, 01 Jan 2020 10:00:00 +0100",
                  parts: [("Alt.pdf", "application/pdf", bytes(11_000, seed: 9), "attachment", nil)]),
             LocationInfo(account: "parasec", mailbox: "Archiv/2020")),
        ])
        return (layout, root.appending(path: "ledger"))
    }

    static func records(_ url: URL) throws -> [LedgerRecord] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { try decoder.decode(LedgerRecord.self, from: Data($0.utf8)) }
    }

    func dryRun(_ ledger: URL, _ change: (inout PaperlessExport) -> Void = { _ in }) -> PaperlessDryRun {
        var s = settings
        s.ledgerDirectory = ledger.path
        change(&s)
        return PaperlessDryRun(settings: s, person: jan, personID: "jan")
    }

    @Test func everyAttachmentIsDecidedWithItsReason() async throws {
        let (layout, ledger) = try await Self.archive()
        let run = dryRun(ledger)
        let (pass, totals) = try run.run(layout: layout)
        #expect(pass == totals && pass.messages == 5 && pass.problems == 0)
        #expect(run.ledgerURL.lastPathComponent == "jan-\(settings.fingerprint(for: jan)).jsonl")
        let records = try Self.records(run.ledgerURL)
        func decisions(_ id: String) -> [String: String] {
            let r = records.first { $0.messageId == id }!
            return Dictionary(uniqueKeysWithValues: r.attachments.map { ($0.filename, $0.reason?.rawValue ?? "upload") })
        }
        #expect(decisions("<a@shop.test>") == ["Rechnung 4711.pdf": "upload", "logo.png": "inline", "icon.png": "small",
                                               "daten.zip": "type", "login.html": "risky", "makro.docm": "risky", "leer.pdf": "empty"])
        #expect(decisions("<n@news.test>") == ["Angebote.pdf": "rule"])          // newsletter: is:list
        #expect(decisions("<f@example.org>") == ["rechnung.PDF": "duplicate"])  // same bytes as the invoice
        #expect(decisions("<s@example.org>") == ["Vertrag.docx": "upload"])
        #expect(decisions("<old@shop.test>") == ["Alt.pdf": "upload"])
        #expect(pass.upload == 3 && pass.skipped == ["inline": 1, "small": 1, "type": 1, "risky": 2, "empty": 1, "rule": 1, "duplicate": 1])

        let invoice = records.first { $0.messageId == "<a@shop.test>" }!.attachments.first { $0.decision == .upload }!
        #expect(invoice.sha256 == sha256Hex(Self.invoice) && invoice.size == 20_000 && invoice.disposition == "attachment")
        #expect(invoice.paperless == PaperlessDocument(title: "Rechnung 4711", created: "2026-11-03", owner: "admin", tags: ["jan", "mail"],
                                                       storagePath: "privat", correspondent: "rechnung@shop.test",
                                                       sourceMail: "mid:a@shop.test"))
        let sent = records.first { $0.messageId == "<s@example.org>" }!
        #expect(sent.sent && sent.places == ["parasec/Sent"] && sent.attachments[0].paperless?.correspondent == nil)
        #expect(sent.attachments[0].paperless?.created == "2026-11-05")  // 23:30 UTC the day before: the configured zone decides
        #expect(records.first { $0.messageId == "<old@shop.test>" }!.places == ["parasec/Archiv/2020"])
        #expect(records.first { $0.messageId == "<n@news.test>" }!.rule == false)
        #expect(records.allSatisfy { $0.settings == settings.fingerprint(for: jan) && $0.v == 1 })
        // the order the archive saw them in: the invoice before its forwarded copy
        #expect(records.firstIndex { $0.messageId == "<a@shop.test>" }! < records.firstIndex { $0.messageId == "<f@example.org>" }!)
        let attributes = try FileManager.default.attributesOfItem(atPath: run.ledgerURL.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)
    }

    @Test func theArchiveIsOnlyRead() async throws {
        let (layout, ledger) = try await Self.archive()
        func snapshot() throws -> [String: Date] {
            var out: [String: Date] = [:]
            for dir in [layout.blobsURL, layout.root.appending(path: "journal")] {
                let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])!
                for case let url as URL in walker {
                    out[url.path] = try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                }
            }
            return out
        }
        let before = try snapshot()
        _ = try dryRun(ledger).run(layout: layout)
        #expect(try snapshot() == before && !before.isEmpty)
    }

    @Test func aSecondPassDecidesNothingAgain() async throws {
        let (layout, ledger) = try await Self.archive()
        let run = dryRun(ledger)
        let first = try run.run(layout: layout)
        let again = try run.run(layout: layout)
        #expect(again.pass == LedgerCounts() && again.totals == first.totals)
        // a new mail with the invoice: a duplicate of what went before, across passes
        _ = try await ArchiveWriter(layout: layout).ingest(mail(id: "<g@shop.test>", parts: [("R.pdf", "application/pdf", Self.invoice, "attachment", nil)]),
                                                           at: inbox)
        let third = try run.run(layout: layout)
        #expect(third.pass.messages == 1 && third.pass.skipped == ["duplicate": 1] && third.totals.messages == 6)
    }

    @Test func otherSettingsStartANewLedgerAndDecideEverythingAgain() async throws {
        let (layout, ledger) = try await Self.archive()
        let first = dryRun(ledger)
        _ = try first.run(layout: layout)
        let lower = dryRun(ledger) { $0.minBytes = 500 }
        #expect(lower.ledgerURL != first.ledgerURL)
        let (pass, _) = try lower.run(layout: layout)
        #expect(pass.messages == 5 && pass.skipped["small"] == nil && pass.upload == 4)  // icon.png goes now
        #expect(try Self.records(first.ledgerURL).count == 5)  // the old ledger stays as it was
        // the extension order is no setting
        #expect(dryRun(ledger) { $0.extensions.reverse() }.ledgerURL == first.ledgerURL)
    }

    @Test func sinceGoesByArrivalNotByTheSendersDate() async throws {
        let (layout, ledger) = try await Self.archive()
        var arrived = inbox
        arrived.uid = 7
        arrived.uidValidity = 1
        arrived.internalDate = Date(timeIntervalSince1970: 1_793_700_000)  // 2026-11-03
        _ = try await ArchiveWriter(layout: layout).ingest(mail(id: "<w@shop.test>", date: "Thu, 01 Jan 1970 00:00:00 +0000",
                                                                parts: [("W.pdf", "application/pdf", bytes(12_000, seed: 10), "attachment", nil)]), at: arrived)
        let run = dryRun(ledger) { $0.since = "2026-11-01" }
        let (pass, _) = try run.run(layout: layout)
        #expect(pass.messages == 5)
        let ids = Set(try Self.records(run.ledgerURL).compactMap(\.messageId))
        #expect(!ids.contains("<old@shop.test>") && ids.contains("<w@shop.test>"))
    }

    @Test func aTornLastLineIsDecidedAgainAndAnyOtherBadLineStops() async throws {
        let (layout, ledger) = try await Self.archive()
        let run = dryRun(ledger)
        let first = try run.run(layout: layout)
        var data = try Data(contentsOf: run.ledgerURL)
        data.removeLast(40)  // a kill in the middle of the last line
        try data.write(to: run.ledgerURL)
        let again = try run.run(layout: layout)
        #expect(again.pass.messages == 1 && again.totals == first.totals)
        #expect(try Self.records(run.ledgerURL).count == 5)

        try Data("{\"v\":1,\"sett".utf8).write(to: run.ledgerURL)  // only a torn first line
        #expect(try run.run(layout: layout).pass.messages == 5)

        var lines = try String(contentsOf: run.ledgerURL, encoding: .utf8).split(separator: "\n").map(String.init)
        lines[1] = "{kaputt"
        try (lines.joined(separator: "\n") + "\n").write(to: run.ledgerURL, atomically: true, encoding: .utf8)
        #expect(throws: LedgerError.self) { try run.run(layout: layout) }
        lines[1] = lines[0].replacingOccurrences(of: "\"v\":1", with: "\"v\":2")
        try (lines.joined(separator: "\n") + "\n").write(to: run.ledgerURL, atomically: true, encoding: .utf8)
        #expect(throws: LedgerError.self) { try run.run(layout: layout) }  // a newer version is not read as this one
        try FileManager.default.removeItem(at: run.ledgerURL)
        try FileManager.default.createSymbolicLink(at: run.ledgerURL, withDestinationURL: ledger.appending(path: "elsewhere"))
        #expect(throws: LedgerError.self) { try run.run(layout: layout) }  // never through a symbolic link
    }

    @Test func missingAndDamagedCopiesAreTriedAgainAndWrittenDownOnce() async throws {
        let (layout, ledger) = try await Self.archive()
        let reader = try ArchiveReader(layout: layout)
        let all = try reader.attachmentMessages(rule: nil, since: nil)
        let old = all.first { $0.messageID == "<old@shop.test>" }!, sent = all.first { $0.messageID == "<s@example.org>" }!
        let oldBytes = try layout.blobs.read(old.primaryBlob)
        try Data("kaputt".utf8).write(to: layout.blobs.url(for: old.primaryBlob))
        try FileManager.default.removeItem(at: layout.blobs.url(for: sent.primaryBlob))
        let run = dryRun(ledger)
        let first = try run.run(layout: layout)
        #expect(first.pass.problems == 2 && first.pass.messages == 3 && first.totals.problems == 2)
        let problems = try Self.records(run.ledgerURL).filter { $0.problem != nil }
        #expect(Set(problems.compactMap(\.problem)) == [.damaged, .missing] && problems.allSatisfy(\.attachments.isEmpty))
        let again = try run.run(layout: layout)
        #expect(again.pass.problems == 2 && again.totals.problems == 2)
        #expect(try Self.records(run.ledgerURL).count == 5)  // not written down again
        try oldBytes.write(to: layout.blobs.url(for: old.primaryBlob))  // repaired, e.g. from the backup
        let repaired = try run.run(layout: layout)
        #expect(repaired.pass.messages == 1 && repaired.pass.upload == 1 && repaired.totals.problems == 1)
    }

    @Test(.enabled(if: getuid() != 0, "root reads a file without permissions"))
    func aCopyThatCannotBeReadNowEndsThePass() async throws {
        let (layout, ledger) = try await Self.archive()
        let old = try ArchiveReader(layout: layout).attachmentMessages(rule: nil, since: nil).first { $0.messageID == "<old@shop.test>" }!
        let path = layout.blobs.url(for: old.primaryBlob).path
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int ?? 0o600
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
        let run = dryRun(ledger)
        #expect(throws: (any Error).self) { try run.run(layout: layout) }  // nothing decided on an error of the moment
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
        #expect(try run.run(layout: layout).totals.messages == 5)
        #expect(try Self.records(run.ledgerURL).allSatisfy { $0.problem == nil })
    }

    @Test func aTooLargeMessageIsNotReadButDecided() async throws {
        let (layout, ledger) = try await Self.archive()
        _ = try await ArchiveWriter(layout: layout).ingest(mail(id: "<big@shop.test>", parts: [("Scan.pdf", "application/pdf", bytes(1_200_000, seed: 11), "attachment", nil)]),
                                                           at: inbox)
        let run = dryRun(ledger) { $0.maxMessageBytes = 1 << 20 }
        let first = try run.run(layout: layout)
        #expect(first.pass.messages == 6 && first.pass.problems == 1)
        #expect(try Self.records(run.ledgerURL).first { $0.messageId == "<big@shop.test>" }?.problem == .tooLarge)
        #expect(try run.run(layout: layout).pass == LedgerCounts())  // decided: its size will not change
    }

    @Test func theDaemonRunsTheDryRunAfterTheFetchAndReportsCounts() async throws {
        let (layout, ledger) = try await Self.archive()
        let root = layout.root.deletingLastPathComponent()
        let json = """
        {"intervalSeconds": 900, "secretsDirectory": "\(root.appending(path: "secrets").path)", "statusFile": "\(root.appending(path: "status.json").path)",
         "paperless": {"mode": "dryRun", "ledgerDirectory": "\(ledger.path)", "rule": "-is:list", "timeZone": "Europe/Berlin",
                       "extensions": ["pdf", "docx"], "minBytes": 10000},
         "people": [{"id": "jan", "archive": "\(layout.root.path)", "accounts": [],
                     "paperless": {"owner": "admin", "tags": ["jan", "mail"], "storagePath": "privat"}}]}
        """
        try FileManager.default.createDirectory(at: root.appending(path: "secrets"), withIntermediateDirectories: true)
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        try config.validate()
        let lines = LockedLines()
        let clean = await Daemon(config: config, log: { lines.append($0) }).runOnce()
        #expect(clean)
        let status = ServerStatus.load(from: URL(fileURLWithPath: config.statusFile))
        let export = try #require(status.exports?["jan"])
        #expect(export.mode == "dryRun" && export.error == nil && export.warning == nil && export.running == nil)
        #expect(export.lastSuccess != nil && export.totals?.upload == 3 && export.ledger?.hasPrefix("jan-") == true)
        #expect(lines.all.contains { $0.contains("Paperless-Trockenlauf: 5 Mails neu entschieden · 3 Anhänge würden übergeben") })
        #expect(!lines.all.joined().contains("Rechnung"))  // counts only, no subjects or file names in the log
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

@Suite("mailkeeperd: Paperless-Konfiguration")
struct PaperlessConfigTests {
    static func config(paperless: String?, person: String? = #"{"owner": "admin", "tags": ["jan", "mail"]}"#) -> String {
        """
        {"intervalSeconds": 900, "secretsDirectory": "/run/secrets/mailkeeper", "statusFile": "/data/status.json",
         \(paperless.map { "\"paperless\": \($0)," } ?? "")
         "people": [{"id": "jan", "archive": "/data/jan", "accounts": []\(person.map { ", \"paperless\": \($0)" } ?? "")}]}
        """
    }

    static let section = #"{"mode": "dryRun", "ledgerDirectory": "/data/export", "rule": "-is:list -is:junk", "since": "2026-10-01", "timeZone": "Europe/Berlin", "extensions": ["pdf", "docx"], "minBytes": 10000}"#

    func load(_ json: String) throws -> ServerConfig {
        let c = try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
        try c.validate()
        return c
    }

    @Test func aValidSectionLoads() throws {
        let c = try load(Self.config(paperless: Self.section))
        #expect(c.paperless?.mode == .dryRun && c.paperless?.extensions == ["pdf", "docx"] && c.people[0].paperless?.owner == "admin")
        #expect(c.paperless?.maxMessageBytes == 64 << 20)
        #expect(try c.paperless?.sinceDate() == Date(timeIntervalSince1970: 1_790_805_600))  // midnight in Berlin (CEST)
        #expect(try load(Self.config(paperless: nil, person: nil)).paperless == nil)  // Phase 1 configurations stay valid
        for rule in ["-is:list -is:junk", "-from:news@x.test -domain:werbung.test", "folder:INBOX OR folder:Archive", "-subject:\"newsletter\"", "-(is:list OR is:junk)"] {
            #expect(PaperlessExport.ruleProblem(rule) == nil, "\(rule)")
        }
    }

    @Test func mistakesAreRefusedBeforeAnythingRuns() throws {
        func refused(_ section: String?, person: String? = #"{"owner": "admin", "tags": ["jan"]}"#, _ why: Comment) {
            #expect(throws: (any Error).self, why) { try load(Self.config(paperless: section, person: person)) }
        }
        func with(_ change: String, _ value: String) -> String {
            Self.section.replacingOccurrences(of: change, with: value)
        }
        refused(with(#""mode": "dryRun""#, #""mode": "upload""#), "upload is not built")
        refused(with(#""extensions": ["pdf", "docx"]"#, #""extensions": ["pdf", "html"]"#), "web pages never go by rule")
        refused(with(#""extensions": ["pdf", "docx"]"#, #""extensions": [".pdf"]"#), "no dot")
        refused(with(#""extensions": ["pdf", "docx"]"#, #""extensions": ["PDF"]"#), "lower case")
        refused(with(#""extensions": ["pdf", "docx"]"#, #""extensions": []"#), "nothing to hand over")
        refused(with(#""extensions": ["pdf", "docx"]"#, #""extensions": ["pdf", "pdf"]"#), "twice")
        refused(with(#""since": "2026-10-01""#, #""since": "2026-02-30""#), "no such day")
        refused(with(#""since": "2026-10-01""#, #""since": "1.10.2026""#), "format")
        refused(with(#""timeZone": "Europe/Berlin""#, #""timeZone": "Mars/Olympus""#), "unknown zone")
        refused(with(#", "timeZone": "Europe/Berlin""#, ""), "the zone is required, not the container's TZ")
        refused(with(#""minBytes": 10000"#, #""minBytes": -1"#), "negative")
        refused(with(#""minBytes": 10000"#, #""minBytes": 10000, "maxMessageBytes": 1000"#), "below 1 MiB")
        refused(with(#""ledgerDirectory": "/data/export""#, #""ledgerDirectory": "/data/jan/export""#), "inside the archive")
        refused(with(#""ledgerDirectory": "/data/export""#, #""ledgerDirectory": "data/export""#), "relative")
        refused(with(#""minBytes": 10000"#, #""minBytes": 10000, "url": "http://x""#), "unknown field")
        // a typo in the rule must not widen it (review S1)
        for (rule, why) in [("larger:abc", "invalid value"), ("-is:list -iss:junk", "misspelt field = plain text"),
                            ("-", "punctuation alone"), ("", "empty"), ("   ", "blank"), ("- is:list", "lone minus"),
                            ("rechnung", "plain text"), ("-is:phishing", "no classification on the server"),
                            ("kategorie:rechnung", "no classification"), ("pdf:kündigung", "no PDF text on the server"),
                            ("-is:list \"werbung\"", "quoted plain text"), ("after:2026-10-01", "dates go into since"),
                            ("-before:30d", "relative dates")] {
            refused(with(#""rule": "-is:list -is:junk""#, "\"rule\": \"\(rule.replacingOccurrences(of: "\"", with: "\\\""))\""), "\(why): \(rule)")
        }
        refused(Self.section, person: nil, "a section nobody uses")
        refused(nil, "a mapping without section")
        refused(Self.section, person: #"{"owner": "", "tags": ["jan"]}"#, "no owner")
        refused(Self.section, person: #"{"owner": "admin", "tags": []}"#, "no tags")
        refused(Self.section, person: #"{"owner": "admin", "tags": ["jan", "jan"]}"#, "tag twice")
        refused(Self.section, person: #"{"owner": "admin", "tags": ["jan"], "korrespondent": "x"}"#, "unknown person field")
    }

    @Test func theLocalesCalendarDoesNotMatter() throws {
        let p = PaperlessExport(ledgerDirectory: "/x", since: "2026-11-01", timeZone: "UTC", extensions: ["pdf"], minBytes: 0)
        #expect(try p.calendar().identifier == .gregorian)
        #expect(try p.sinceDate() == Date(timeIntervalSince1970: 1_793_491_200))  // 2026-11-01T00:00Z
    }
}
