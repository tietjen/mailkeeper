import Foundation
import MailKeeperKit

/// What a server archives: people, each with an archive and the mailboxes to fetch into it.
/// One JSON file, written where the server is deployed (GitOps), never by the server itself.
public struct ServerConfig: Decodable, Sendable, Equatable {
    /// Seconds between two runs over all accounts.
    public var intervalSeconds: Int
    /// Mounted secrets, one file per account (`FileSecretBackend`).
    public var secretsDirectory: String
    /// Last result per account, for probes and people (no mail content).
    public var statusFile: String
    public var people: [Person]

    public struct Person: Decodable, Sendable, Equatable {
        public var id: String
        /// Archive folder of this person — one archive per person, never shared.
        public var archive: String
        public var accounts: [AccountSpec]
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
        /// The server certificate's fingerprint — required for a bridge (no trust on first use).
        public var fingerprint: String?
        public var include: [String]?
        public var exclude: [String]?
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
        var personIDs = Set<String>(), archives = Set<String>()
        for person in people {
            guard AccountConfig.isValidID(person.id) else { throw ConfigError("invalid person id \"\(person.id)\" (a–z, 0–9, - and _)") }
            guard personIDs.insert(person.id).inserted else { throw ConfigError("person \"\(person.id)\" appears twice") }
            let archive = URL(fileURLWithPath: person.archive).standardizedFileURL.path
            guard person.archive.hasPrefix("/") else { throw ConfigError("\(person.id): archive must be an absolute path") }
            guard archives.insert(archive).inserted else { throw ConfigError("\(person.id): archive \(archive) is shared with another person") }
            var accountIDs = Set<String>()
            for spec in person.accounts {
                guard AccountConfig.isValidID(spec.id) else { throw ConfigError("\(person.id): invalid account id \"\(spec.id)\"") }
                guard accountIDs.insert(spec.id).inserted else { throw ConfigError("\(person.id): account \"\(spec.id)\" appears twice") }
                _ = try spec.accountConfig()
            }
        }
        // Two archives nested in each other would let one person's archive hold another's.
        let sorted = archives.sorted()
        for (a, b) in zip(sorted, sorted.dropFirst()) where b.hasPrefix(a + "/") {
            throw ConfigError("archive \(b) lies inside \(a)")
        }
    }
}

extension ServerConfig.AccountSpec {
    /// The account as the archive stores it. `created` comes from the stored account, if any.
    public func accountConfig(created: Date = Date()) throws -> AccountConfig {
        guard !username.isEmpty else { throw ConfigError("\(id): username is empty") }
        var config: AccountConfig
        switch kind {
        case .imap:
            guard let host, !host.isEmpty else { throw ConfigError("\(id): an IMAP account needs a host") }
            let mode: AccountConfig.Security
            switch (security ?? "tls").lowercased() {
            case "tls":
                // TLS is checked against the system's CAs; a pin would only suggest otherwise.
                guard fingerprint == nil else { throw ConfigError("\(id): a fingerprint goes with startTLS, not tls") }
                mode = .tls
            case "starttls": mode = fingerprint.map { .startTLSPinned(fingerprint: $0.lowercased()) } ?? .startTLS
            default: throw ConfigError("\(id): security must be \"tls\" or \"startTLS\"")
            }
            config = .imap(id: id, username: username, host: host, port: port ?? 993, security: mode)
        case .gmail:
            config = .gmail(id: id, address: username)
        case .protonBridge:
            config = .protonBridge(id: id, address: username, port: port ?? 1143)
            config.security = .startTLSPinned(fingerprint: fingerprint?.lowercased())
        }
        if let include { config.policy.include = include }
        if let exclude { config.policy.exclude = exclude }
        config.created = created
        return config
    }
}

public struct ConfigError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// The stored accounts after the deployment's declaration: declared ones as declared (keeping
/// when they were first created), the rest untouched — a mailbox dropped from the configuration
/// is no longer fetched, but its account stays, and with it the archive's history.
public func reconcile(stored: [AccountConfig], declared: [ServerConfig.AccountSpec]) throws -> (accounts: [AccountConfig], changed: Bool) {
    var result = stored
    for spec in declared {
        if let i = result.firstIndex(where: { $0.id == spec.id }) {
            result[i] = try spec.accountConfig(created: result[i].created)
        } else {
            result.append(try spec.accountConfig())
        }
    }
    return (result, result != stored)
}
