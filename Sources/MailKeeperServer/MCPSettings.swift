import Foundation
import MailKeeperKit

/// mailkeeper-mcp (ADR-0017): the archive as an MCP connector. Lives in the server configuration
/// so people and archives are named once; `mailkeeperd` validates it and ignores it.
public struct MCPSettings: Decodable, Sendable, Equatable {
    /// The MCP listener — loopback only (`127.0.0.1:8000`): reachable through the Ziti sidecar,
    /// never through a cluster address, which would bypass the dial policy.
    public var listen: String
    /// `GET /healthz` for the kubelet, which cannot reach loopback (`0.0.0.0:8080`).
    public var health: String
    /// `Host` headers accepted (DNS rebinding), e.g. `mcp.mail.ziti:8727`.
    public var allowedHosts: [String]
    /// The register id the broker's assertion must name.
    public var audience: String
    /// The broker's keys (`…/.well-known/jwks.json`).
    public var jwksURL: String
    /// LLDAP user (the assertion's `user`) → person id. A user missing here is refused.
    public var users: [String: String]
    /// The direct path's bearer token (one line), and whom it acts as.
    public var directTokenFile: String
    public var directPerson: String
    /// Which day a mail belongs to for `date_from`/`date_to` (IANA name). The process must run in
    /// it (TZ), since the search language counts days in the process' zone.
    public var timeZone: String
    /// `summarize_correspondence`: LiteLLM only. Absent: the tool refuses with `ai_unavailable`.
    public var ai: AI?

    public struct AI: Decodable, Sendable, Equatable {
        /// OpenAI-compatible base URL, e.g. `http://litellm.litellm:4000/v1`.
        public var url: String
        public var model: String
        public var keyFile: String?
        public var timeoutSeconds: Int

        enum CodingKeys: String, CodingKey, CaseIterable { case url, model, keyFile, timeoutSeconds }

        public init(url: String, model: String, keyFile: String? = nil, timeoutSeconds: Int = 180) {
            self.url = url
            self.model = model
            self.keyFile = keyFile
            self.timeoutSeconds = timeoutSeconds
        }

        public init(from decoder: Decoder) throws {
            try requireKnownKeys(decoder, CodingKeys.self, in: "mcp.ai")
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(url: try c.decode(String.self, forKey: .url), model: try c.decode(String.self, forKey: .model),
                      keyFile: try c.decodeIfPresent(String.self, forKey: .keyFile),
                      timeoutSeconds: try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 180)
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case listen, health, allowedHosts, audience, jwksURL, users, directTokenFile, directPerson, timeZone, ai
    }

    public init(listen: String = "127.0.0.1:8000", health: String = "0.0.0.0:8080", allowedHosts: [String], audience: String,
                jwksURL: String, users: [String: String], directTokenFile: String, directPerson: String,
                timeZone: String, ai: AI? = nil) {
        self.listen = listen
        self.health = health
        self.allowedHosts = allowedHosts
        self.audience = audience
        self.jwksURL = jwksURL
        self.users = users
        self.directTokenFile = directTokenFile
        self.directPerson = directPerson
        self.timeZone = timeZone
        self.ai = ai
    }

    public init(from decoder: Decoder) throws {
        try requireKnownKeys(decoder, CodingKeys.self, in: "mcp")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(listen: try c.decode(String.self, forKey: .listen), health: try c.decode(String.self, forKey: .health),
                  allowedHosts: try c.decode([String].self, forKey: .allowedHosts),
                  audience: try c.decode(String.self, forKey: .audience), jwksURL: try c.decode(String.self, forKey: .jwksURL),
                  users: try c.decode([String: String].self, forKey: .users),
                  directTokenFile: try c.decode(String.self, forKey: .directTokenFile),
                  directPerson: try c.decode(String.self, forKey: .directPerson),
                  timeZone: try c.decode(String.self, forKey: .timeZone), ai: try c.decodeIfPresent(AI.self, forKey: .ai))
    }

    /// `host:port` or `[v6]:port`.
    public static func hostPort(_ text: String) -> (host: String, port: Int)? {
        let host: Substring, rest: Substring
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            host = text[text.index(after: text.startIndex)..<close]
            rest = text[text.index(after: close)...]
            guard rest.hasPrefix(":") else { return nil }
        } else {
            guard let colon = text.lastIndex(of: ":") else { return nil }
            host = text[..<colon]
            rest = text[colon...]
        }
        guard !host.isEmpty, let port = Int(rest.dropFirst()), (1...65535).contains(port) else { return nil }
        return (String(host), port)
    }

    func validate(people: [String]) throws {
        guard let listen = Self.hostPort(listen) else { throw ConfigError("mcp: listen must be host:port") }
        guard ["127.0.0.1", "::1"].contains(listen.host) else {
            throw ConfigError("mcp: listen must be loopback (127.0.0.1 or [::1]) — the Ziti sidecar is the only way in")
        }
        guard let health = Self.hostPort(health) else { throw ConfigError("mcp: health must be host:port") }
        // 0.0.0.0 includes loopback: the same port would collide
        guard health.port != listen.port else { throw ConfigError("mcp: health and listen need different ports") }
        guard !allowedHosts.isEmpty, allowedHosts.allSatisfy({ Self.hostPort($0) != nil && !$0.contains(where: \.isWhitespace) }) else {
            throw ConfigError("mcp: allowedHosts must list host:port names, e.g. mcp.mail.ziti:8727")
        }
        guard audience.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else {
            throw ConfigError("mcp: audience must be the register id (lower case)")
        }
        guard let jwks = URL(string: jwksURL), ["http", "https"].contains(jwks.scheme ?? ""), jwks.host() != nil else {
            throw ConfigError("mcp: jwksURL must be an http(s) URL")
        }
        guard !users.isEmpty else { throw ConfigError("mcp: users is empty — nobody could use the broker path") }
        for (user, person) in users {
            guard user.range(of: #"^[A-Za-z0-9._-]{1,64}$"#, options: .regularExpression) != nil else {
                throw ConfigError("mcp: user \"\(user)\" is no LLDAP name")
            }
            guard people.contains(person) else { throw ConfigError("mcp: user \(user) maps to \"\(person)\", who has no archive here") }
        }
        guard people.contains(directPerson) else { throw ConfigError("mcp: directPerson \"\(directPerson)\" has no archive here") }
        guard directTokenFile.hasPrefix("/") else { throw ConfigError("mcp: directTokenFile must be an absolute path") }
        guard TimeZone(identifier: timeZone) != nil else { throw ConfigError("mcp: unknown timeZone \"\(timeZone)\"") }
        if let ai {
            guard let url = URL(string: ai.url), ["http", "https"].contains(url.scheme ?? ""), url.host() != nil else {
                throw ConfigError("mcp.ai: url must be an http(s) URL")
            }
            guard !ai.model.trimmingCharacters(in: .whitespaces).isEmpty else { throw ConfigError("mcp.ai: model is empty") }
            if let keyFile = ai.keyFile, !keyFile.hasPrefix("/") { throw ConfigError("mcp.ai: keyFile must be an absolute path") }
            guard (10...600).contains(ai.timeoutSeconds) else { throw ConfigError("mcp.ai: timeoutSeconds must be 10–600") }
        }
    }

    /// Files that must not lie inside an archive.
    var files: [(String, String)] {
        [("mcp.directTokenFile", directTokenFile)] + (ai?.keyFile.map { [("mcp.ai.keyFile", $0)] } ?? [])
    }
}
