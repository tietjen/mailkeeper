import Foundation
import Security

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

    public var id: String
    public var kind: Kind
    public var displayName: String
    public var username: String
    public var host: String
    public var port: Int
    public var security: Security
    public var policy: SyncPolicy
    public var created: Date

    public init(id: String, kind: Kind, displayName: String, username: String, host: String, port: Int,
                security: Security, policy: SyncPolicy, created: Date = Date()) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.username = username
        self.host = host
        self.port = port
        self.security = security
        self.policy = policy
        self.created = created
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
    case keychain(OSStatus)

    public var description: String {
        switch self {
        case .invalidID(let id): "Ungültige Konto-ID „\(id)“ (erlaubt: a–z, 0–9, - und _)"
        case .duplicate(let id): "Ein Konto „\(id)“ gibt es schon"
        case .unknown(let id): "Kein Konto „\(id)“"
        case .keychain(let s): "Schlüsselbund-Fehler \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "")"
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

/// Account passwords in the login keychain, created by the running program (ADR-0003: the
/// data protection keychain needs a provisioning profile; reading items another program
/// created raises a prompt). Keyed by mailbox identity, so two archives share one entry.
public struct CredentialStore: Sendable {
    public let service: String

    public init(service: String = "de.paranoidsecurity.MailKeeper") {
        self.service = service
    }

    public static func key(for account: AccountConfig) -> String {
        "\(account.username)@\(account.host):\(account.port)"
    }

    private func query(_ account: AccountConfig) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: Self.key(for: account)]
    }

    public func save(_ password: String, for account: AccountConfig) throws {
        let secret = Data(account.normalizedPassword(password).utf8)
        let update = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AccountError.keychain(update) }
        var add = query(account)
        add[kSecValueData as String] = secret
        add[kSecAttrLabel as String] = "MailKeeper – \(account.displayName)"
        add[kSecAttrDescription as String] = "IMAP-Zugang (MailKeeper)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccountError.keychain(status) }
    }

    public func password(for account: AccountConfig) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw AccountError.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether an entry exists — attributes only, so no keychain prompt even for entries
    /// another program created (the ACL guards the secret, not the attributes).
    public func exists(for account: AccountConfig) -> Bool {
        var q = query(account)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    public func delete(for account: AccountConfig) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.keychain(status) }
    }

    // MARK: Other secrets (the KI endpoint's API key)

    private func query(key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    public func saveSecret(_ secret: String, key: String, label: String, description: String) throws {
        let data = Data(secret.utf8)
        let update = SecItemUpdate(query(key: key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw AccountError.keychain(update) }
        var add = query(key: key)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = label
        add[kSecAttrDescription as String] = description
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw AccountError.keychain(status) }
    }

    public func secret(key: String) throws -> String? {
        var q = query(key: key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw AccountError.keychain(status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func secretExists(key: String) -> Bool {
        var q = query(key: key)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    public func deleteSecret(key: String) throws {
        let status = SecItemDelete(query(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AccountError.keychain(status) }
    }
}
