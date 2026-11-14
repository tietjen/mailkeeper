import Foundation
import MailKeeperKit

/// What a server archives: people, each with an archive and the mailboxes to fetch into it.
/// One JSON file, written where the server is deployed (GitOps), never by the server itself.
/// Strict: an unknown or misspelled field is an error, not silently ignored (review S8).
public struct ServerConfig: Decodable, Sendable, Equatable {
    /// Seconds between two runs over all accounts.
    public var intervalSeconds: Int
    /// Mounted secrets, one file per account (`FileSecretBackend`).
    public var secretsDirectory: String
    /// Last result per account, for probes and people (no mail content).
    public var statusFile: String
    public var people: [Person]
    /// Attachments for Paperless (ADR-0016). Absent: the server only archives.
    public var paperless: PaperlessExport?

    public struct Person: Decodable, Sendable, Equatable {
        public var id: String
        /// Archive folder of this person — one archive per person, never shared.
        public var archive: String
        public var accounts: [AccountSpec]
        /// Where this person's attachments land in Paperless. Absent: archived, not exported.
        public var paperless: PaperlessPerson?

        enum CodingKeys: String, CodingKey, CaseIterable { case id, archive, accounts, paperless }

        public init(from decoder: Decoder) throws {
            try requireKnownKeys(decoder, CodingKeys.self, in: "person")
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            archive = try c.decode(String.self, forKey: .archive)
            accounts = try c.decode([AccountSpec].self, forKey: .accounts)
            paperless = try c.decodeIfPresent(PaperlessPerson.self, forKey: .paperless)
        }
    }

    /// A mailbox as the deployment describes it. Becomes an `AccountConfig` in the person's
    /// archive (`accounts.json`), so `mkctl` and the app see the same account.
    public struct AccountSpec: Decodable, Sendable, Equatable {
        public var id: String
        public var kind: AccountConfig.Kind
        public var username: String
        /// IMAP only; a bridge is always on 127.0.0.1, Gmail on imap.gmail.com.
        public var host: String?
        public var port: Int?
        /// IMAP: "tls" (default) or "startTLS".
        public var security: String?
        /// SHA-256 of the server's leaf certificate, 64 hex digits (colons and case do not
        /// matter) — required for a bridge, optional pin for IMAP with startTLS.
        public var fingerprint: String?
        public var include: [String]?
        public var exclude: [String]?

        enum CodingKeys: String, CodingKey, CaseIterable {
            case id, kind, username, host, port, security, fingerprint, include, exclude
        }

        public init(id: String, kind: AccountConfig.Kind, username: String, host: String? = nil, port: Int? = nil,
                    security: String? = nil, fingerprint: String? = nil, include: [String]? = nil, exclude: [String]? = nil) {
            self.id = id
            self.kind = kind
            self.username = username
            self.host = host
            self.port = port
            self.security = security
            self.fingerprint = fingerprint
            self.include = include
            self.exclude = exclude
        }

        public init(from decoder: Decoder) throws {
            try requireKnownKeys(decoder, CodingKeys.self, in: "account")
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(id: try c.decode(String.self, forKey: .id),
                      kind: try c.decode(AccountConfig.Kind.self, forKey: .kind),
                      username: try c.decode(String.self, forKey: .username),
                      host: try c.decodeIfPresent(String.self, forKey: .host),
                      port: try c.decodeIfPresent(Int.self, forKey: .port),
                      security: try c.decodeIfPresent(String.self, forKey: .security),
                      fingerprint: try c.decodeIfPresent(String.self, forKey: .fingerprint),
                      include: try c.decodeIfPresent([String].self, forKey: .include),
                      exclude: try c.decodeIfPresent([String].self, forKey: .exclude))
        }
    }

    enum CodingKeys: String, CodingKey, CaseIterable { case intervalSeconds, secretsDirectory, statusFile, people, paperless }

    public init(from decoder: Decoder) throws {
        try requireKnownKeys(decoder, CodingKeys.self, in: "configuration")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        intervalSeconds = try c.decode(Int.self, forKey: .intervalSeconds)
        secretsDirectory = try c.decode(String.self, forKey: .secretsDirectory)
        statusFile = try c.decode(String.self, forKey: .statusFile)
        people = try c.decode([Person].self, forKey: .people)
        paperless = try c.decodeIfPresent(PaperlessExport.self, forKey: .paperless)
    }

    public static func load(from url: URL) throws -> ServerConfig {
        let config = try JSONDecoder().decode(ServerConfig.self, from: Data(contentsOf: url))
        try config.validate()
        return config
    }

    public func validate() throws {
        guard intervalSeconds >= 60 else { throw ConfigError("intervalSeconds must be at least 60") }
        guard secretsDirectory.hasPrefix("/"), statusFile.hasPrefix("/") else {
            throw ConfigError("secretsDirectory and statusFile must be absolute paths")
        }
        guard !people.isEmpty else { throw ConfigError("no people configured") }
        var personIDs = Set<String>()
        var archives: [(person: String, path: [String])] = []
        var mailboxes: [String: String] = [:], secretFiles: [String: String] = [:]
        for person in people {
            guard AccountConfig.isValidID(person.id) else { throw ConfigError("invalid person id \"\(person.id)\" (a–z, 0–9, - and _)") }
            guard personIDs.insert(person.id).inserted else { throw ConfigError("person \"\(person.id)\" appears twice") }
            guard person.archive.hasPrefix("/") else { throw ConfigError("\(person.id): archive must be an absolute path") }
            let path = Self.components(person.archive)
            guard !path.isEmpty else { throw ConfigError("\(person.id): the root folder cannot be an archive") }
            archives.append((person.id, path))
            var accountIDs = Set<String>()
            for spec in person.accounts {
                guard AccountConfig.isValidID(spec.id) else { throw ConfigError("\(person.id): invalid account id \"\(spec.id)\"") }
                guard accountIDs.insert(spec.id).inserted else { throw ConfigError("\(person.id): account \"\(spec.id)\" appears twice") }
                let key = CredentialStore.key(for: try spec.accountConfig())
                let here = "\(person.id)/\(spec.id)"
                if let other = mailboxes[key] { throw ConfigError("\(here): the same mailbox as \(other)") }
                mailboxes[key] = here
                let file = FileSecretBackend.fileName(for: key)
                if let other = secretFiles[file] { throw ConfigError("\(here): reads the same secret file as \(other) (\(file))") }
                secretFiles[file] = here
            }
        }
        // Every pair, on whole path components: sorting by text would put "/d/a-b" between
        // "/d/a" and "/d/a/b" and miss the nesting (review S1).
        for (i, a) in archives.enumerated() {
            for b in archives[(i + 1)...] {
                if a.path == b.path { throw ConfigError("\(a.person) and \(b.person) share one archive") }
                if Self.isInside(b.path, a.path) || Self.isInside(a.path, b.path) {
                    throw ConfigError("the archives of \(a.person) and \(b.person) lie inside each other")
                }
            }
        }
        // Paperless: the section and the people's mappings go together.
        if let paperless {
            try paperless.validate()
            guard people.contains(where: { $0.paperless != nil }) else { throw ConfigError("paperless: no person has a paperless mapping") }
            for person in people { try person.paperless?.validate(person: person.id) }
        } else if let person = people.first(where: { $0.paperless != nil }) {
            throw ConfigError("\(person.id): paperless mapping without the paperless section")
        }
        // The status file, the secrets and the ledgers do not belong into anyone's archive.
        for (what, file) in [("statusFile", statusFile), ("secretsDirectory", secretsDirectory)]
            + (paperless.map { [("paperless.ledgerDirectory", $0.ledgerDirectory)] } ?? []) {
            let path = Self.components(file)
            if let a = archives.first(where: { Self.isInside(path, $0.path) || path == $0.path }) {
                throw ConfigError("\(what) lies inside the archive of \(a.person)")
            }
        }
    }

    /// Path components after resolving `..` and symbolic links that already exist.
    static func components(_ path: String) -> [String] {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().pathComponents.filter { $0 != "/" }
    }

    static func isInside(_ inner: [String], _ outer: [String]) -> Bool {
        inner.count > outer.count && Array(inner.prefix(outer.count)) == outer
    }
}

extension ServerConfig.AccountSpec {
    /// The account as the archive stores it. `created` comes from the stored account, if any.
    public func accountConfig(created: Date = Date()) throws -> AccountConfig {
        guard !username.isEmpty else { throw ConfigError("\(id): username is empty") }
        let pin = try fingerprint.map(Self.normalizedFingerprint)
        var config: AccountConfig
        switch kind {
        case .imap:
            guard let host, !host.isEmpty else { throw ConfigError("\(id): an IMAP account needs a host") }
            let mode: AccountConfig.Security
            switch (security ?? "tls").lowercased() {
            case "tls":
                // TLS is checked against the system's CAs; a pin would only suggest otherwise.
                guard pin == nil else { throw ConfigError("\(id): a fingerprint goes with startTLS, not tls") }
                mode = .tls
            case "starttls": mode = pin.map { .startTLSPinned(fingerprint: $0) } ?? .startTLS
            default: throw ConfigError("\(id): security must be \"tls\" or \"startTLS\"")
            }
            config = .imap(id: id, username: username, host: host, port: port ?? 993, security: mode)
        case .gmail:
            try refuse(["host": host, "port": port.map(String.init), "security": security, "fingerprint": fingerprint], for: "a Gmail account")
            config = .gmail(id: id, address: username)
        case .protonBridge:
            // The bridge runs next to the server, on loopback — a host here would be ignored.
            try refuse(["host": host, "security": security], for: "a bridge account")
            config = .protonBridge(id: id, address: username, port: port ?? 1143)
            config.security = .startTLSPinned(fingerprint: pin)
        }
        if let include { config.policy.include = include }
        if let exclude { config.policy.exclude = exclude }
        config.created = created
        return config
    }

    /// 64 hex digits; colons, spaces and case as openssl or a browser print them do not matter.
    static func normalizedFingerprint(_ raw: String) throws -> String {
        let hex = raw.lowercased().filter { !($0 == ":" || $0.isWhitespace) }
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else {
            throw ConfigError("fingerprint must be the certificate's SHA-256 (64 hex digits)")
        }
        return hex
    }

    private func refuse(_ fields: [String: String?], for what: String) throws {
        let set = fields.filter { $0.value != nil }.keys.sorted()
        guard set.isEmpty else { throw ConfigError("\(id): \(set.joined(separator: ", ")) does not apply to \(what)") }
    }
}

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

func requireKnownKeys<K: CodingKey & CaseIterable>(_ decoder: Decoder, _: K.Type, in what: String) throws {
    let known = Set(K.allCases.map(\.stringValue))
    let unknown = try decoder.container(keyedBy: AnyKey.self).allKeys.map(\.stringValue).filter { !known.contains($0) }
    guard unknown.isEmpty else { throw ConfigError("\(what): unknown field \(unknown.sorted().joined(separator: ", "))") }
}

/// The stored accounts after the deployment's declaration: declared ones as declared (keeping
/// when they were first created), the rest untouched — a mailbox dropped from the configuration
/// is no longer fetched, but its account stays, and with it the archive's history.
/// `identityChanged`: declared ids whose mailbox (user, host, port) differs from the stored one.
public func reconcile(stored: [AccountConfig], declared: [ServerConfig.AccountSpec]) throws
    -> (accounts: [AccountConfig], changed: Bool, identityChanged: [String]) {
    var result = stored, identityChanged: [String] = []
    for spec in declared {
        if let i = result.firstIndex(where: { $0.id == spec.id }) {
            let account = try spec.accountConfig(created: result[i].created)
            if CredentialStore.key(for: account) != CredentialStore.key(for: result[i]) { identityChanged.append(spec.id) }
            result[i] = account
        } else {
            result.append(try spec.accountConfig())
        }
    }
    return (result, result != stored, identityChanged)
}
