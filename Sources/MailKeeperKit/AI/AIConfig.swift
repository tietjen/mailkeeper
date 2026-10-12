import Foundation

/// What MailKeeper asks a language model for (ADR-0004). Each task has its own model alias.
public enum AITask: String, Codable, Sendable, CaseIterable {
    /// Everyday language → search query (ADR-0008).
    case search
    /// Category of a mail the heuristics left open.
    case classify
    /// Summary of a mail or thread, on request.
    case summarize
    /// Vectors for semantic search.
    case embed
    /// Connection test.
    case test
}

/// The KI settings of an archive (`<archive>/ai.json`, 0600; the API key lives in the keychain).
/// Local models only (ADR-0004): an OpenAI-compatible endpoint — TJ's homelab LiteLLM — and
/// Apple's on-device model as the fallback. MailKeeper never ships a cloud default.
public struct AIConfig: Codable, Sendable, Equatable {
    public var enabled = false
    /// Base URL of an OpenAI-compatible API, e.g. `http://llm.example.ziti:4000/v1`.
    public var endpoint: URL?
    /// Model alias per task (by `AITask.rawValue`, readable JSON); missing tasks use `fallbackModel`.
    public var models: [String: String] = [:]
    /// Apple's on-device model when the endpoint is not set up or not reachable.
    public var onDevice = true
    /// Seconds a request may take (a little above the gateway's own timeout, so its fallback can work).
    public var timeout: Double = 120

    public static let fallbackModel = "llm-fast"
    public static let fallbackEmbeddingModel = "embedding"

    public init(enabled: Bool = false, endpoint: URL? = nil, models: [AITask: String] = [:], onDevice: Bool = true, timeout: Double = 120) {
        self.enabled = enabled
        self.endpoint = endpoint
        self.models = Dictionary(uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) })
        self.onDevice = onDevice
        self.timeout = timeout
    }

    public func model(for task: AITask) -> String {
        if let m = models[task.rawValue]?.trimmingCharacters(in: .whitespaces), !m.isEmpty { return m }
        return task == .embed ? Self.fallbackEmbeddingModel : Self.fallbackModel
    }

    public mutating func setModel(_ model: String, for task: AITask) {
        let m = model.trimmingCharacters(in: .whitespaces)
        models[task.rawValue] = m.isEmpty ? nil : m
    }

    /// The keychain key of the endpoint's API key (one per host and port).
    public var secretKey: String? {
        guard let endpoint, let host = endpoint.host() else { return nil }
        return "ai:\(host):\(endpoint.port ?? (endpoint.scheme == "https" ? 443 : 80))"
    }

    /// Whether the endpoint stays in the local network: localhost, private addresses, `.local`,
    /// `.lan`, `.internal`, `.home.arpa`, and `.ziti` (OpenZiti overlay). Anything else gets a
    /// warning in the settings — mail would leave the house.
    public static func isLocal(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) else { return false }
        if ["localhost", "::1"].contains(host) { return true }
        if [".local", ".lan", ".internal", ".home.arpa", ".ziti", ".localhost"].contains(where: { host.hasSuffix($0) }) { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (192, 168), (169, 254): return true
            case (172, let b) where (16...31).contains(b): return true
            case (100, let b) where (64...127).contains(b): return true  // CGNAT / overlay networks
            default: return false
            }
        }
        return host.hasPrefix("fd") || host.hasPrefix("fe80:")  // IPv6 ULA / link-local
    }

    /// HTTP is allowed only where App Transport Security lets it through: localhost and `.ziti`
    /// (encrypted by the overlay). Everything else needs HTTPS.
    public static func transportProblem(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host() != nil else {
            return String(localized: "Keine gültige http(s)-Adresse")
        }
        guard scheme == "http" else { return nil }
        let host = url.host()?.lowercased() ?? ""
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".ziti") || host.hasSuffix(".localhost") { return nil }
        return String(localized: "HTTP geht nur für localhost und .ziti-Adressen – sonst bitte HTTPS")
    }
}

/// `<archive>/ai.json`: written atomically, 0600.
public struct AIConfigStore: Sendable {
    public let url: URL

    public init(layout: ArchiveLayout) {
        url = layout.root.appending(path: "ai.json")
    }

    public func load() -> AIConfig {
        guard let data = try? readFile(url.path, limit: 1 << 20),
              let config = try? JSONDecoder().decode(AIConfig.self, from: data) else { return AIConfig() }
        return config
    }

    public func save(_ config: AIConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let staging = url.deletingLastPathComponent().appending(path: ".ai-\(UUID().uuidString).part")
        do { try writeDurably(try encoder.encode(config), to: staging) } catch {
            unlink(staging.path)
            throw error
        }
        guard rename(staging.path, url.path) == 0 else {
            unlink(staging.path)
            throw ArchiveError.io("rename ai.json", path: url.path)
        }
    }
}
