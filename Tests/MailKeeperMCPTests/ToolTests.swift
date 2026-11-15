import Foundation
import Testing
@testable import MailKeeperKit
@testable import MailKeeperMCP

@Suite("mailkeeper-mcp: Werkzeuge am Archiv")
struct ToolTests {
    /// The text of an answer — and the standard's envelope checked on the way (v2.2 §10.3).
    func text(_ result: JSONValue, isError: Bool = false) throws -> String {
        let content = try #require(result["content"]?.array?.first?["text"]?.string)
        let structured = try #require(result["structuredContent"])
        #expect(structured["text"]?.string == content)  // byte-equal in both branches
        #expect(structured["data_class"] == "personal" && structured["served_from"] == "source" && structured["stale"] == false)
        #expect(structured["as_of"]?.string?.range(of: #"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$"#, options: .regularExpression) != nil)
        #expect(result["isError"]?.bool == isError)
        return content
    }

    func code(_ result: JSONValue) throws -> String? {
        _ = try text(result, isError: true)
        return result["structuredContent"]?["error"]?["code"]?.string
    }

    @Test func searchFindsBriefsWithStableIDsAndFilters() async throws {
        let (_, archives) = try await twoArchives()
        let server = try testServer(archives: archives)
        let all = try await callTool(server, "search", ["query": "Rechnung"])
        let t = try text(all)
        #expect(t.hasPrefix("2 Treffer") && t.contains("Rechnung 4711") && t.contains("id mid:<a@shop.test>"))
        #expect(!t.contains("Alles muss raus"))  // briefs, never the newsletter
        let card = try #require(all["structuredContent"]?["card"])
        #expect(card["type"] == "result-list")
        let first = try #require(card["items"]?.array?.first)
        #expect(first["data_class"] == "personal" && first["type"] == "mail" && first["deep_link"]?.string?.hasPrefix("mid:") == true)
        #expect(first["id"]?.string?.hasPrefix("mid:") == true && first["date"]?.string?.count == 10)
        // filters: sent, person, dates, attachment
        #expect(try text(try await callTool(server, "search", ["type": "sent"])).contains("Re: Rechnung 4711"))
        #expect(try text(try await callTool(server, "search", ["type": "sent"])).hasPrefix("1 Treffer"))
        #expect(try text(try await callTool(server, "search", ["person": "news@news.test"])).contains("Angebote der Woche"))
        #expect(try text(try await callTool(server, "search", ["date_from": "2026-11-01"])).hasPrefix("2 Treffer"))
        #expect(try text(try await callTool(server, "search", ["date_to": "2026-10-31"])).hasPrefix("1 Treffer"))
        #expect(try text(try await callTool(server, "search", ["type": "attachment"])).hasPrefix("1 Treffer"))
        let page = try text(try await callTool(server, "search", ["limit": 1]))
        #expect(page.hasPrefix("3 Treffer, hier 1–1") && page.contains("Weitere mit offset 1"))
    }

    @Test func limitsAndUnknownArgumentsAreRefusedNotCut() async throws {
        let (_, archives) = try await twoArchives()
        let server = try testServer(archives: archives)
        let tooMany = try await callTool(server, "search", ["limit": 51])
        #expect(try code(tooMany) == "limit_exceeded" && tooMany["structuredContent"]?["error"]?["limit"] == 50)
        #expect(try code(try await callTool(server, "search", ["query": .string(String(repeating: "x", count: 501))])) == "limit_exceeded")
        #expect(try code(try await callTool(server, "search", ["querry": "Rechnung"])) == "invalid")
        #expect(try code(try await callTool(server, "search", ["date_from": "2026-02-30"])) == "invalid")
        #expect(try code(try await callTool(server, "search", ["type": "spam"])) == "invalid")
        #expect(try code(try await callTool(server, "fetch", ["id": "mid:<a@shop.test>", "max_tokens": 100])) == "limit_exceeded")
        #expect(try code(try await callTool(server, "mail_thread", [:])) == "invalid")
    }

    @Test func fetchReadsOneMailWithinItsBudget() async throws {
        let (_, archives) = try await twoArchives()
        let server = try testServer(archives: archives)
        let t = try text(try await callTool(server, "fetch", ["id": "mid:<a@shop.test>"]))
        #expect(t.contains("Betreff: Rechnung 4711") && t.contains("Von: Shop <rechnung@shop.test>"))
        #expect(t.contains("Anhänge: Rechnung 4711.pdf") && t.contains("über 42 Euro") && t.contains("Ablage: parasec/INBOX"))
        #expect(t.contains("Datum: 2026-11-03 10:00 (Europe/Berlin)"))
        let card = try #require(try await callTool(server, "fetch", ["id": "mid:<a@shop.test>"])["structuredContent"]?["card"])
        #expect(card["type"] == "document" && card["format"] == "plain" && card["truncated"] == false)
    }

    @Test func anotherPersonsMailIsNotFoundNotForbidden() async throws {
        let (_, archives) = try await twoArchives()
        let server = try testServer(archives: archives)
        // katja's mail, asked for on jan's direct path: the same answer as a mail that does not exist
        let other = try await callTool(server, "fetch", ["id": "mid:<k@example.org>"])
        let none = try await callTool(server, "fetch", ["id": "mid:<nothing@x>"])
        let otherCode = try code(other), noneCode = try code(none)
        #expect(otherCode == "not_found" && noneCode == "not_found")
        #expect(other["structuredContent"]?["error"]?["message"] == none["structuredContent"]?["error"]?["message"])
        #expect(try text(try await callTool(server, "search", ["query": "Befund"])) == "Keine Mail gefunden.")
    }

    @Test func theBrokerPathReadsTheAssertedPersonsArchive() async throws {
        let (_, archives) = try await twoArchives()
        let signer = TestSigner()
        let lines = LockedLines()
        let server = try testServer(archives: archives, signer: signer, lines: lines)
        let meta: JSONValue = ["kastelain": ["run_id": "unsigned-run", "session_id": "s-1",
                                             "assertion": try signer.envelope(TestSigner.body(user: "katja", issued: Date()))]]
        let t = try text(try await callTool(server, "fetch", ["id": "mid:<k@example.org>"], token: nil, meta: meta))
        #expect(t.contains("Befund") && t.contains("Nur für Katja."))
        #expect(lines.all.last == "mcp: fetch path=broker user=katja run=run-test session=s-1 ms=\(lines.all.last!.split(separator: " ")[6].dropFirst(3)) result=ok")
        // the same assertion again: replay; and no identity at all: refused
        #expect(try code(try await callTool(server, "fetch", ["id": "mid:<k@example.org>"], token: nil, meta: meta)) == "replay")
        #expect(try code(try await callTool(server, "search", [:], token: nil)) == "missing_assertion")
        #expect(lines.all.contains { $0.contains("result=replay") } && !lines.all.joined().contains("Befund"))
    }

    @Test func threadsAttachmentsAndCorrespondents() async throws {
        let (_, archives) = try await twoArchives()
        let server = try testServer(archives: archives)
        let thread = try text(try await callTool(server, "mail_thread", ["id": "mid:<b@example.org>"]))
        #expect(thread.contains("2 Mails") && thread.contains("1. 2026-11-03 10:00 · Shop") && thread.contains("Re: Rechnung 4711"))
        #expect(try text(try await callTool(server, "mail_thread", ["query": "Rechnung"])).hasPrefix("Konversation 1: Rechnung 4711"))
        let att = try await callTool(server, "mail_attachments", ["id": "mid:<a@shop.test>"])
        let attText = try text(att)
        #expect(attText.contains("Rechnung 4711.pdf · application/pdf") && attText.contains(sha256Hex(invoicePDF)))
        #expect(try text(try await callTool(server, "mail_attachments", ["id": "mid:<n@news.test>"])) == "Die Mail hat keine Anhänge.")
        let persons = try await callTool(server, "list_persons", [:])
        let personsText = try text(persons)
        #expect(personsText.contains("rechnung@shop.test") && !personsText.contains("jan@example.org"))  // received only
        #expect(persons["structuredContent"]?["card"]?["type"] == "table")
    }

    @Test func summariesGoThroughTheModelOrRefuse() async throws {
        let (_, archives) = try await twoArchives()
        let t = try text(try await callTool(try testServer(archives: archives), "summarize_correspondence", ["person": "rechnung@shop.test"]))
        #expect(t.contains("1 Konversation") && t.contains("Zusammenfassung von 2 Mails.") && t.contains("• 42 Euro"))
        #expect(try code(try await callTool(try testServer(archives: archives, summarizer: nil), "summarize_correspondence", ["person": "x"])) == "ai_unavailable")
        #expect(try code(try await callTool(try testServer(archives: archives, summarizer: FakeSummarizer(fail: true)),
                                            "summarize_correspondence", ["person": "rechnung@shop.test"])) == "ai_unavailable")
    }

    @Test func theReaderBesideTheWriterOnlyReads() async throws {
        let (root, archives) = try await twoArchives()
        let index = root.appending(path: "jan/index.sqlite")
        let before = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        _ = try await callTool(try testServer(archives: archives), "search", ["query": "Rechnung"])
        #expect(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date == before)
        // an index of another schema version is refused, not migrated
        let db = try Database(path: index.path)
        try db.execute("PRAGMA user_version = \(Schema.currentVersion + 1)")
        #expect(throws: ArchiveSchemaMismatch.self) {
            _ = try ArchiveReader(layout: try ArchiveLayout.open(at: root.appending(path: "jan"), create: false), readOnly: true)
        }
        #expect(try code(try await callTool(try testServer(archives: archives), "search", [:])) == "source_unreachable")
    }
}
