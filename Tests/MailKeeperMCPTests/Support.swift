import Foundation
import Testing
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
@testable import MailKeeperKit
@testable import MailKeeperAI
@testable import MailKeeperMCP

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mailkeeper-mcp-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The shared assertion fixture from tj/kastelain (copied from wiki-mcp's testdata, unchanged).
func fixture() throws -> JSONValue {
    let url = try #require(Bundle.module.url(forResource: "assertion_fixture", withExtension: "json", subdirectory: "Fixtures"))
    return try JSONValue.parse(Data(contentsOf: url))
}

struct StaticKeys: KeySource {
    var set: [String: Data]
    func keys(refresh: Bool) async throws -> [String: Data] { set }
}

/// Signs assertion bodies with a key of its own — for the cases the fixture does not cover.
struct TestSigner {
    let key = Curve25519.Signing.PrivateKey()
    let kid = "test-kid"
    var keys: StaticKeys { StaticKeys(set: [kid: key.publicKey.rawRepresentation]) }

    func envelope(_ body: JSONValue, alg: String = "EdDSA", kid: String? = nil) throws -> JSONValue {
        let sig = try key.signature(for: body.serialized(canonical: true))
        let b64 = Data(sig).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return ["kid": .string(kid ?? self.kid), "alg": .string(alg), "body": body, "sig": .string(b64)]
    }

    static func body(user: String = "jan", audience: String = "mail", issued: Date, lifetime: TimeInterval = 60,
                     nonce: String = UUID().uuidString) -> JSONValue {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return ["user": .string(user), "groups": ["familie"], "auth_strength": "strong_auth", "run_id": "run-test",
                "issued_at": .string(f.string(from: issued)), "expires_at": .string(f.string(from: issued.addingTimeInterval(lifetime))),
                "audience": .string(audience), "nonce": .string(nonce)]
    }
}

/// A multipart mail: text body and attachments (name, type, bytes).
func mail(id: String, from: String, to: String = "Jan <jan@example.org>", subject: String, date: String, body: String,
          extraHeaders: [String] = [], parts: [(name: String, type: String, data: Data)] = []) -> Data {
    var s = "From: \(from)\r\nTo: \(to)\r\nSubject: \(subject)\r\nDate: \(date)\r\nMessage-ID: \(id)\r\n"
    for h in extraHeaders { s += h + "\r\n" }
    s += "MIME-Version: 1.0\r\nContent-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n"
    s += "--b1\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n"
    for p in parts {
        s += "--b1\r\nContent-Type: \(p.type); name=\"\(p.name)\"\r\nContent-Transfer-Encoding: base64\r\n"
        s += "Content-Disposition: attachment; filename=\"\(p.name)\"\r\n\r\n\(p.data.base64EncodedString(options: .lineLength76Characters))\r\n"
    }
    s += "--b1--\r\n"
    return Data(s.utf8)
}

let invoicePDF = Data("%PDF-1.4 Rechnung 4711 über 42 Euro".utf8) + Data(repeating: 0x41, count: 2_000)

/// Two people: jan with an invoice, his reply (sent) and a newsletter; katja with one mail.
func twoArchives() async throws -> (root: URL, archives: [String: URL]) {
    let root = tempDir()
    let inbox = LocationInfo(account: "parasec", mailbox: "INBOX")
    let jan = try ArchiveLayout.open(at: root.appending(path: "jan"), create: true)
    _ = try await ArchiveWriter(layout: jan).ingest([
        (mail(id: "<a@shop.test>", from: "Shop <rechnung@shop.test>", subject: "Rechnung 4711", date: "Tue, 03 Nov 2026 10:00:00 +0100",
              body: "Sehr geehrter Herr Tietjen,\n\nanbei Ihre Rechnung über 42 Euro.\n\nZahlbar bis zum 30. November.\n\nViele Grüße",
              parts: [("Rechnung 4711.pdf", "application/pdf", invoicePDF)]), inbox),
        (mail(id: "<b@example.org>", from: "Jan <jan@example.org>", to: "Shop <rechnung@shop.test>", subject: "Re: Rechnung 4711",
              date: "Wed, 04 Nov 2026 09:00:00 +0100", body: "Danke, ist bezahlt.",
              extraHeaders: ["In-Reply-To: <a@shop.test>", "References: <a@shop.test>"]), LocationInfo(account: "parasec", mailbox: "Sent")),
        (mail(id: "<n@news.test>", from: "News <news@news.test>", subject: "Angebote der Woche", date: "Thu, 01 Oct 2026 08:00:00 +0200",
              body: "Alles muss raus."), inbox),
    ])
    let katja = try ArchiveLayout.open(at: root.appending(path: "katja"), create: true)
    _ = try await ArchiveWriter(layout: katja).ingest(
        mail(id: "<k@example.org>", from: "Ärztin <praxis@example.org>", to: "katja@example.org", subject: "Befund",
             date: "Thu, 05 Nov 2026 11:00:00 +0100", body: "Nur für Katja."), at: inbox)
    return (root, ["jan": root.appending(path: "jan"), "katja": root.appending(path: "katja")])
}

struct FakeSummarizer: ConversationSummarizer {
    var fail = false
    func summarize(_ messages: [SummaryMessage], total: Int, flagged: Bool) async throws -> MailSummary {
        if fail { throw AIError.timeout(1) }
        return MailSummary(summary: "Zusammenfassung von \(messages.count) Mails.", points: ["42 Euro"], todo: [], caution: nil,
                           covered: messages.count, total: total, path: .endpoint, model: "fake", seconds: 0.1)
    }
}

let directToken = String(repeating: "t", count: 40)

func testServer(archives: [String: URL], summarizer: (any ConversationSummarizer)? = FakeSummarizer(), signer: TestSigner = TestSigner(),
                lines: LockedLines = LockedLines(), now: @escaping @Sendable () -> Date = Date.init) throws -> MCPServer {
    let identity = try IdentityResolver(verifier: AssertionVerifier(audience: "mail", keys: signer.keys, now: now),
                                        users: ["jan": "jan", "katja": "katja"], directToken: directToken, directPerson: "jan")
    return MCPServer(identity: identity, archives: ArchiveAccess(archives: archives), summarizer: summarizer,
                     timeZone: TimeZone(identifier: "Europe/Berlin")!, allowedHosts: ["mcp.mail.ziti:8727"], log: { lines.append($0) }, now: now)
}

/// One JSON-RPC request through the server's HTTP entry; returns the decoded answer.
func rpc(_ server: MCPServer, _ method: String, _ params: JSONValue = [:], token: String? = directToken,
         host: String = "mcp.mail.ziti:8727") async throws -> (status: Int, body: JSONValue?) {
    var headers = ["host": host, "content-type": "application/json"]
    if let token { headers["authorization"] = "Bearer \(token)" }
    let request: JSONValue = ["jsonrpc": "2.0", "id": 1, "method": .string(method), "params": params]
    let response = await server.handle(HTTPRequest(method: "POST", path: "/mcp", headers: headers, body: request.serialized()))
    let isJSON = response.headers.contains { $0.0 == "Content-Type" && $0.1.hasPrefix("application/json") }
    return (response.status, isJSON ? try JSONValue.parse(response.body) : nil)
}

func callTool(_ server: MCPServer, _ name: String, _ args: JSONValue = [:], token: String? = directToken,
              meta: JSONValue? = nil) async throws -> JSONValue {
    var params: [String: JSONValue] = ["name": .string(name), "arguments": args]
    if let meta { params["_meta"] = meta }
    let (status, body) = try await rpc(server, "tools/call", .object(params), token: token)
    guard status == 200, let result = body?["result"] else { throw JSONError("no result: \(status) \(body?.text ?? "")") }
    return result
}

final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}
