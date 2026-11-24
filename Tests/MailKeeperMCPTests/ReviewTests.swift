import Foundation
import Testing
@testable import MailKeeperKit
@testable import MailKeeperAI
@testable import MailKeeperMCP

/// What the review of the first version asked to be pinned down.
@Suite("mailkeeper-mcp: Grenzen aus dem Review")
struct ReviewTests {
    func text(_ result: JSONValue) -> String { result["content"]?.array?.first?["text"]?.string ?? "" }
    func code(_ result: JSONValue) -> String? { result["structuredContent"]?["error"]?["code"]?.string }

    @Test func trashedMailIsInvisibleEverywhere() async throws {
        let (_, archives) = try await twoArchives()
        let writer = try ArchiveWriter(layout: try ArchiveLayout.open(at: archives["jan"]!, create: false))
        #expect(try await writer.trash(["mid:<a@shop.test>"]) == 1)
        let server = try testServer(archives: archives)
        #expect(!text(try await callTool(server, "search", ["query": "Rechnung"])).contains("mid:<a@shop.test>"))
        for (tool, args) in [("fetch", ["id": "mid:<a@shop.test>"] as JSONValue), ("mail_thread", ["id": "mid:<a@shop.test>"]),
                             ("mail_attachments", ["id": "mid:<a@shop.test>"])] {
            #expect(code(try await callTool(server, tool, args)) == "not_found", "\(tool)")
        }
        let thread = text(try await callTool(server, "mail_thread", ["id": "mid:<b@example.org>"]))
        #expect(thread.contains("1 Mails") && !thread.contains("1. 2026-11-03"))
    }

    @Test func readingLeavesTheArchiveFoldersAlone() async throws {
        let (root, archives) = try await twoArchives()
        let jan = root.appending(path: "jan")
        try FileManager.default.removeItem(at: jan.appending(path: "tmp"))
        chmod(jan.path, 0o750)
        _ = try await callTool(try testServer(archives: archives), "search", ["query": "Rechnung"])
        #expect(!FileManager.default.fileExists(atPath: jan.appending(path: "tmp").path))  // not created
        #expect((try FileManager.default.attributesOfItem(atPath: jan.path)[.posixPermissions] as? Int) == 0o750)  // not tightened
    }

    @Test func aQueryCannotLiftTheOtherFilters() async throws {
        let (_, archives) = try await twoArchives()
        let server = try testServer(archives: archives)
        // as one text this would be `(Angebote) OR (Rechnung) after:…` = Angebote OR (Rechnung AND after)
        let result = try await callTool(server, "search", ["query": "Angebote) OR (Rechnung", "date_from": "2026-11-01"])
        #expect(code(result) == "invalid" || !text(result).contains("Angebote der Woche"))
        let fair = text(try await callTool(server, "search", ["query": "Angebote OR Rechnung", "date_from": "2026-11-01"]))
        #expect(fair.hasPrefix("2 Treffer") && !fair.contains("Angebote der Woche"))
    }

    @Test func aWebPageIsTurnedAway() async throws {
        let (_, archives) = try await twoArchives()
        let server = try testServer(archives: archives)
        let headers = ["host": "mcp.mail.ziti:8727", "origin": "https://evil.example", "authorization": "Bearer \(directToken)"]
        let ping: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": "ping"]
        #expect(await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: ping.serialized())).status == 403)
    }

    @Test func summariesEndAtTheirDeadline() async throws {
        let (_, archives) = try await twoArchives()
        let slow = try testServer(archives: archives, summarizer: FakeSummarizer(delay: .seconds(300)), summaryDeadline: .milliseconds(200))
        // the bound below (50 s on CI) stays far below the 300 s a missing deadline would take
        let started = ContinuousClock.now
        let result = try await callTool(slow, "summarize_correspondence", ["person": "rechnung@shop.test"])
        #expect(code(result) == "ai_unavailable" && ContinuousClock.now - started < TimeBudget.linear(.seconds(5)))
        #expect(text(result).contains("in time"))
    }

    @Test func modelFailuresAreCategoriesNotServerText() {
        let kind = MailTools.kind(AIError.server(500, "Prompt war: Ihre Rechnung über 42 Euro …"))
        #expect(kind == "Modell meldet Fehler 500" && !kind.contains("Rechnung"))
        #expect(MailTools.kind(AIError.connection("litellm.internal:4000 refused")) == "Modell nicht erreichbar")
    }

    @Test func theModelGateHoldsItsLimitAndLetsCancelledWaitersGo() async throws {
        let gate = ModelGate(limit: 2)
        actor Peak { var now = 0, max = 0; func up() { now += 1; max = Swift.max(max, now) }; func down() { now -= 1 } }
        let peak = Peak()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try? await gate.acquire()
                    await peak.up()
                    try? await Task.sleep(for: .milliseconds(20))
                    await peak.down()
                    await gate.release()
                }
            }
        }
        #expect(await peak.max == 2)
        // a waiter that is cancelled leaves the queue; the slot is not lost
        try await gate.acquire(); try await gate.acquire()
        let waiter = Task { try await gate.acquire() }
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        await #expect(throws: CancellationError.self) { try await waiter.value }
        await gate.release()
        try await gate.acquire()  // the freed slot is there
    }

    @Test func listPersonsPagesAndSaysWhenThereIsMore() async throws {
        let (_, archives) = try await twoArchives()
        let server = try testServer(archives: archives)
        let first = try await callTool(server, "list_persons", ["limit": 1])
        #expect(text(first).contains("Weitere mit offset 1") && first["structuredContent"]?["card"]?["truncated"] == true)
        let second = text(try await callTool(server, "list_persons", ["limit": 1, "offset": 1]))
        #expect(second.hasPrefix("Korrespondenten 2–2") && !second.contains("Weitere"))
    }

    @Test func documentCardsAreCappedByBytes() {
        let (cut, wasCut) = utf8Prefix(String(repeating: "ü", count: 40), maxBytes: 11)
        #expect(cut == String(repeating: "ü", count: 5) && wasCut)  // 2 bytes each, never half a character
        #expect(utf8Prefix("abc", maxBytes: 3) == ("abc", false))
    }

    @Test func theJWKSIsNotHammeredWhenItFails() async throws {
        actor Calls { var n = 0; func next() { n += 1 } }
        let calls = Calls()
        let failing = JWKSKeySource(url: URL(string: "http://gateway/jwks")!) { _ in await calls.next(); throw URLError(.cannotConnectToHost) }
        for _ in 0..<5 { _ = try? await failing.keys(refresh: true) }
        #expect(await calls.n == 1)
        let jwks = Data(#"{"keys":[{"kty":"OKP","crv":"Ed25519","kid":"a","x":"Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc"}]}"#.utf8)
        let empty = Data(#"{"keys":[]}"#.utf8)
        actor Answers { var list: [Data]; init(_ l: [Data]) { list = l }; func next() -> Data { list.count > 1 ? list.removeFirst() : list[0] } }
        let answers = Answers([jwks, empty])
        let source = JWKSKeySource(url: URL(string: "http://gateway/jwks")!, minInterval: .milliseconds(10), maxAge: .seconds(1)) { _ in
            await answers.next()
        }
        #expect(try await source.keys(refresh: false).keys.sorted() == ["a"])
        try await Task.sleep(for: .milliseconds(20))
        #expect(try await source.keys(refresh: true).keys.sorted() == ["a"])  // an empty set does not replace a good one
        try await Task.sleep(for: .milliseconds(1_100))
        await #expect(throws: (any Error).self) { try await source.keys(refresh: false) }  // stale and the refetch is empty: fail-closed
    }

    @Test func aNonceInAnotherNormalFormIsAReplay() async throws {
        let s = TestSigner()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let v = AssertionVerifier(audience: "mail", keys: s.keys, now: { now })
        _ = try await v.verify(try s.envelope(TestSigner.body(issued: now, nonce: "aK1")))
        await #expect(throws: Refusal("replay", "nonce has already been redeemed")) {
            try await v.verify(try s.envelope(TestSigner.body(issued: now, nonce: "a\u{212A}1")))  // KELVIN SIGN, NFC → K
        }
    }
}
