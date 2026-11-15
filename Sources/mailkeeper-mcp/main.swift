#if canImport(Glibc)
// Before Foundation: Glibc's `stdout` is a mutable global that Swift 6 refuses otherwise.
@preconcurrency import Glibc
#endif
import Foundation
import MailKeeperKit
import MailKeeperAI
import MailKeeperServer
import MailKeeperMCP

// mailkeeper-mcp — the archive as an MCP connector (ADR-0017). Read-only sidecar next to
// mailkeeperd: one archive per person, each person reads only their own, identity per path
// (Kastelain's signed assertion, or the direct token of TJ's devices).

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mailkeeper-mcp: \(message)\n".utf8))
    exit(2)
}

var configPath = "/etc/mailkeeper/config.json"
var checkOnly = false
var args = CommandLine.arguments.dropFirst()
while let arg = args.popFirst() {
    switch arg {
    case "--config":
        guard let path = args.popFirst() else { fail("--config needs a file") }
        configPath = path
    case "--check-config": checkOnly = true
    default:
        print("usage: mailkeeper-mcp [--config <file>] [--check-config]")
        exit(arg == "--help" || arg == "-h" ? 0 : 2)
    }
}

let config: ServerConfig
do { config = try ServerConfig.load(from: URL(fileURLWithPath: configPath)) } catch { fail("\(configPath): \(error)") }
guard let settings = config.mcp else { fail("\(configPath): no mcp section") }

/// One line, without a trailing newline; empty or unreadable is an error.
func secret(_ path: String, _ what: String) -> String {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
        fail("\(what): \(path) is missing or empty")
    }
    return text
}

if checkOnly {
    print("Konfiguration in Ordnung: \(config.people.count) Personen, \(settings.users.count) Broker-Nutzer, direkt als \(settings.directPerson)"
          + (settings.ai == nil ? ", ohne KI" : ", KI \(settings.ai!.model)"))
    exit(0)
}

// The search language counts days in the process' zone: it must be the configured one.
guard TimeZone.current.identifier == settings.timeZone else {
    fail("the process runs in \(TimeZone.current.identifier), mcp.timeZone is \(settings.timeZone) — set TZ=\(settings.timeZone)")
}
guard let zone = TimeZone(identifier: settings.timeZone),
      let listen = MCPSettings.hostPort(settings.listen), let health = MCPSettings.hostPort(settings.health),
      let jwks = URL(string: settings.jwksURL) else { fail("mcp: unreadable addresses") }

let identity: IdentityResolver
do {
    identity = try IdentityResolver(verifier: AssertionVerifier(audience: settings.audience, keys: JWKSKeySource(url: jwks)),
                                    users: settings.users, directToken: secret(settings.directTokenFile, "direct token"),
                                    directPerson: settings.directPerson)
} catch { fail("\(error)") }

var summarizer: (any ConversationSummarizer)?
if let ai = settings.ai, let url = URL(string: ai.url) {
    let key = ai.keyFile.map { secret($0, "AI key") }
    let aiConfig = AIConfig(enabled: true, endpoint: url, models: [.summarize: ai.model], onDevice: false, timeout: Double(ai.timeoutSeconds))
    // metadata only (task, model, seconds, outcome) — never prompt or answer
    let callLog = AICallLog(url: URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "mailkeeper-mcp/ai.jsonl"))
    summarizer = MailSummarizer(router: AIRouter(config: aiConfig, apiKey: key, log: callLog))
}

let archives = ArchiveAccess(archives: Dictionary(uniqueKeysWithValues: config.people.map { ($0.id, URL(fileURLWithPath: $0.archive)) }))
let server = MCPServer(identity: identity, archives: archives, summarizer: summarizer, timeZone: zone,
                       allowedHosts: settings.allowedHosts, log: log)

/// `/healthz`: the MCP listener is bound and every archive opens; cached for 10 s.
actor Health {
    var mcpBound = false
    var last: (at: ContinuousClock.Instant, ok: Bool)?
    func bound() { mcpBound = true }
    func check(_ archives: ArchiveAccess) async -> Bool {
        if let last, ContinuousClock.now - last.at < .seconds(10) { return last.ok }
        let ok = mcpBound ? await archives.healthy() : false
        last = (.now, ok)
        return ok
    }
}
let healthState = Health()

signal(SIGTERM) { _ in exit(0) }
signal(SIGINT) { _ in exit(0) }

log("mailkeeper-mcp \(MCPServer.version): \(config.people.count) Archive, Broker-Audience \(settings.audience), "
    + "direkt als \(settings.directPerson), \(settings.ai == nil ? "ohne KI" : "KI \(settings.ai!.model)"), lauscht auf \(settings.listen)")

do {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            try await HTTPServer.run(host: listen.host, port: listen.port, bound: { _ in Task { await healthState.bound() } }) { request in
                await server.handle(request)
            }
        }
        group.addTask {
            try await HTTPServer.run(host: health.host, port: health.port, maxBody: 0) { request in
                guard request.method == "GET", request.path == "/healthz" else { return .text(404, "not found") }
                return await healthState.check(archives) ? .text(200, "ok") : .text(503, "archive or listener not ready")
            }
        }
        try await group.next()
        group.cancelAll()
    }
} catch {
    fail("\(error)")
}
