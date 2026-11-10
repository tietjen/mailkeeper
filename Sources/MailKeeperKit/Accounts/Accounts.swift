import Foundation
#if canImport(Security)
import Security
#endif

/// A mail account the archive syncs from. Stored in `<archive>/accounts.json` — never a
/// password (that lives in the keychain, see `CredentialStore`).
public struct AccountConfig: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case imap, gmail, protonBridge
    }

    public enum Security: Codable, Sendable, Equatable {
        case tls
        case startTLS
        /// Local bridge with a self-signed certificate: leaf pinned (nil until confirmed).
        case startTLSPinned(fingerprint: String?)
    }

    /// How the account signs in. Absent (the only form before 7.1) means a password.
    public struct OAuth: Codable, Sendable, Equatable {
        public enum Provider: String, Codable, Sendable { case google }
        public var provider: Provider
        /// The Google Cloud client of whoever set the account up; nil uses the one MailKeeper
        /// ships with, if a build ever has one (ADR-0012). The client secret, where the provider
        /// wants one, lives in the keychain beside the refresh token.
        public var clientID: String?

        /// A pasted client id often carries a space or a newline; stored raw it would break
        /// every later refresh with `invalid_client`, and signing in again would store it again
        /// (review 7.1 S1). Empty means: the client the app ships with.
        public init(provider: Provider = .google, clientID: String?) {
            self.provider = provider
            let trimmed = clientID?.trimmingCharacters(in: .whitespacesAndNewlines)
            self.clientID = (trimmed?.isEmpty ?? true) ? nil : trimmed
        }

        public init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            self.init(provider: try box.decode(Provider.self, forKey: .provider),
                      clientID: try box.decodeIfPresent(String.self, forKey: .clientID))
        }
    }

    public var id: String
    public var kind: Kind
    public var displayName: String
    public var username: String
    public var host: String
    public var port: Int
    public var security: Security
    public var policy: SyncPolicy
    public var created: Date
    /// Set = sign in with the provider instead of a password (7.1).
    public var oauth: OAuth?

    public init(id: String, kind: Kind, displayName: String, username: String, host: String, port: Int,
                security: Security, policy: SyncPolicy, created: Date = Date(), oauth: OAuth? = nil) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.username = username
        self.host = host
        self.port = port
        self.security = security
        self.policy = policy
        self.created = created
        self.oauth = oauth
    }

    /// Presets: Gmail (All Mail + labels, app password), Proton Mail Bridge (local, pinned
    /// certificate, folders), generic IMAPS.
    public static func gmail(id: String, address: String) -> AccountConfig {
        AccountConfig(id: id, kind: .gmail, displayName: address, username: address, host: "imap.gmail.com", port: 993,
                      security: .tls, policy: SyncPolicy(mode: .gmail))
    }

    public static func protonBridge(id: String, address: String, port: Int = 1143) -> AccountConfig {
        AccountConfig(id: id, kind: .protonBridge, displayName: address, username: address, host: "127.0.0.1", port: port,
                      security: .startTLSPinned(fingerprint: nil), policy: SyncPolicy(mode: .protonBridge))
    }

    public static func imap(id: String, username: String, host: String, port: Int = 993,
                            security: Security = .tls) -> AccountConfig {
        AccountConfig(id: id, kind: .imap, displayName: username, username: username, host: host, port: port,
                      security: security, policy: SyncPolicy(mode: .standard))
    }

    public var info: AccountInfo { AccountInfo(id: id, kind: kind.rawValue, name: displayName) }

    /// Account ids name journal folders and appear in commands: lowercase letters, digits, - and _.
    public static func isValidID(_ id: String) -> Bool {
        (1...40).contains(id.count) && id.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }

    /// Google shows app passwords as "abcd efgh ijkl mnop"; IMAP wants them without spaces.
    public func normalizedPassword(_ password: String) -> String {
        kind == .gmail ? password.filter { !$0.isWhitespace } : password
    }
}

public enum AccountError: Error, CustomStringConvertible, Equatable {
    case invalidID(String)
    case duplicate(String)
    case unknown(String)
    /// An `OSStatus` from the keychain (macOS).
    case keychain(Int32)
    /// No place for secrets is set up (Linux, until the server brings its own store).
    case noSecretStore

    public var description: String {
        switch self {
        case .invalidID(let id): String(localized: "Ungültige Konto-ID „\(id)“ (erlaubt: a–z, 0–9, - und _)")
        case .duplicate(let id): String(localized: "Ein Konto „\(id)“ gibt es schon")
        case .unknown(let id): String(localized: "Kein Konto „\(id)“")
        case .keychain(let s):
            #if canImport(Security)
            String(localized: "Schlüsselbund-Fehler \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "")")
            #else
            "keychain error \(s)"
            #endif
        case .noSecretStore: "no secret store is set up on this system"
        }
    }
}

/// `<archive>/accounts.json` (0600), replaced atomically.
public struct AccountStore: Sendable {
    public let url: URL

    public init(layout: ArchiveLayout) {
        url = layout.root.appending(path: "accounts.json")
    }

    public func load() throws -> [AccountConfig] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([AccountConfig].self, from: Data(contentsOf: url))
    }

    public func save(_ accounts: [AccountConfig]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let staging = url.deletingLastPathComponent().appending(path: ".accounts-\(UUID().uuidString).part")
        do { try writeDurably(try encoder.encode(accounts), to: staging) } catch {
            unlink(staging.path)
            throw error
        }
        guard rename(staging.path, url.path) == 0 else {
            unlink(staging.path)
            throw ArchiveError.io("rename accounts.json", path: url.path)
        }
    }

    public func add(_ account: AccountConfig) throws {
        guard AccountConfig.isValidID(account.id) else { throw AccountError.invalidID(account.id) }
        var all = try load()
        guard !all.contains(where: { $0.id == account.id }) else { throw AccountError.duplicate(account.id) }
        all.append(account)
        try save(all)
    }

    public func update(_ account: AccountConfig) throws {
        var all = try load()
        guard let i = all.firstIndex(where: { $0.id == account.id }) else { throw AccountError.unknown(account.id) }
        all[i] = account
        try save(all)
    }

    /// Removes the configuration only; the archived mail stays.
    public func remove(_ id: String) throws {
        var all = try load()
        guard all.contains(where: { $0.id == id }) else { throw AccountError.unknown(id) }
        all.removeAll { $0.id == id }
        try save(all)
    }
}

/// Where `CredentialStore` keeps its secrets: four operations on a string key.
public protocol SecretBackend: Sendable {
    func write(_ secret: Data, key: String, label: String, description: String) throws
    func read(key: String) throws -> Data?
    /// Without reading the secret itself (the keychain asks no question for that). Throws when it
    /// cannot tell — "unknown" must not read as "none" (a revoke would follow, 7.1 B1).
    func exists(key: String) throws -> Bool
    func delete(key: String) throws
}

/// Account passwords, refresh tokens and API keys, keyed by mailbox identity, so two archives
/// share one entry. On macOS in the login keychain; on Linux there is no store unless one is
/// passed in — the server brings its own (mailkeeper-server, Phase 1).
public struct CredentialStore: Sendable {
    public let service: String
    let backend: any SecretBackend

    public init(service: String = "de.paranoidsecurity.MailKeeper") {
        self.service = service
        #if canImport(Security)
        backend = KeychainBackend(service: service)
        #else
        backend = NoSecretBackend()
        #endif
    }

    public init(service: String = "de.paranoidsecurity.MailKeeper", backend: any SecretBackend) {
        self.service = service
        self.backend = backend
    }

    public static func key(for account: AccountConfig) -> String {
        "\(account.username)@\(account.host):\(account.port)"
    }

    public func save(_ password: String, for account: AccountConfig) throws {
        try backend.write(Data(account.normalizedPassword(password).utf8), key: Self.key(for: account),
                          label: "MailKeeper – \(account.displayName)", description: "IMAP-Zugang (MailKeeper)")
    }

    public func password(for account: AccountConfig) throws -> String? {
        try secret(key: Self.key(for: account))
    }

    /// Whether an entry exists — attributes only, so no keychain prompt even for entries
    /// another program created (the ACL guards the secret, not the attributes).
    public func exists(for account: AccountConfig) throws -> Bool {
        try secretExists(key: Self.key(for: account))
    }

    public func delete(for account: AccountConfig) throws {
        try deleteSecret(key: Self.key(for: account))
        try deleteSecret(key: Self.refreshTokenKey(for: account))
        try deleteSecret(key: Self.clientSecretKey(for: account))
    }

    // MARK: Sign-in with a provider (7.1): the refresh token takes the password's place

    public static func refreshTokenKey(for account: AccountConfig) -> String { "oauth-refresh:" + key(for: account) }
    public static func clientSecretKey(for account: AccountConfig) -> String { "oauth-client-secret:" + key(for: account) }

    public func saveRefreshToken(_ token: String, for account: AccountConfig) throws {
        try saveSecret(token, key: Self.refreshTokenKey(for: account),
                       label: "MailKeeper – \(account.displayName)", description: "Google-Anmeldung (MailKeeper)")
    }

    public func refreshToken(for account: AccountConfig) throws -> String? {
        try secret(key: Self.refreshTokenKey(for: account))
    }

    public func saveClientSecret(_ secret: String, for account: AccountConfig) throws {
        try saveSecret(secret.trimmingCharacters(in: .whitespacesAndNewlines), key: Self.clientSecretKey(for: account),
                       label: "MailKeeper – \(account.displayName)", description: "Google-Client-Secret (MailKeeper)")
    }

    public func clientSecret(for account: AccountConfig) throws -> String? {
        try secret(key: Self.clientSecretKey(for: account))
    }

    /// Whether a sign-in for this mailbox is stored — asked before a discarded token is handed
    /// back to Google: a revoke takes the whole grant, so one must not be sent while a good
    /// sign-in is in the keychain (Nachprüfung 7.1 B1).
    public func hasRefreshToken(for account: AccountConfig) throws -> Bool {
        try secretExists(key: Self.refreshTokenKey(for: account))
    }

    /// Whether the account can sign in at all: a password, or a refresh token for an OAuth account.
    public func hasCredential(for account: AccountConfig) throws -> Bool {
        try account.oauth == nil ? exists(for: account) : secretExists(key: Self.refreshTokenKey(for: account))
    }

    // MARK: Other secrets (the KI endpoint's API key)

    public func saveSecret(_ secret: String, key: String, label: String, description: String) throws {
        try backend.write(Data(secret.utf8), key: key, label: label, description: description)
    }

    public func secret(key: String) throws -> String? {
        try backend.read(key: key).map { String(decoding: $0, as: UTF8.self) }
    }

    public func secretExists(key: String) throws -> Bool {
        try backend.exists(key: key)
    }

    public func deleteSecret(key: String) throws {
        try backend.delete(key: key)
    }
}

#if canImport(Security)
/// The login keychain, items created by the running program (ADR-0003: the data protection
/// keychain needs a provisioning profile; reading items another program created raises a prompt).
struct KeychainBackend: SecretBackend {
    let service: String

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func write(_ secret: Data, key: String, label: String, description: String) throws {
        let update = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AccountError.keychain(update) }
        var add = query(key)
        add[kSecValueData as String] = secret
        add[kSecAttrLabel as String] = label
        add[kSecAttrDescription as String] = description
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccountError.keychain(status) }
    }

    func read(key: String) throws -> Data? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw AccountError.keychain(status) }
        return data
    }

    func exists(key: String) throws -> Bool {
        var q = query(key)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    func delete(key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.keychain(status) }
    }
}
#endif

/// No store set up: nothing is kept, and asking for a secret says so instead of answering
/// "none" — a sync must not run as if the account had no password.
struct NoSecretBackend: SecretBackend {
    func write(_ secret: Data, key: String, label: String, description: String) throws { throw AccountError.noSecretStore }
    func read(key: String) throws -> Data? { throw AccountError.noSecretStore }
    func exists(key: String) throws -> Bool { throw AccountError.noSecretStore }
    func delete(key: String) throws {}
}
