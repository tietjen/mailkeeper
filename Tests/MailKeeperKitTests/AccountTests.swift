import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Accounts")
struct AccountTests {
    @Test func storeRoundTripAndValidation() throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "acc"), create: true)
        let store = AccountStore(layout: layout)
        #expect(try store.load().isEmpty)
        try store.add(.gmail(id: "gmail", address: "probe@example.test"))
        var proton = AccountConfig.protonBridge(id: "proton", address: "jan@example.test")
        try store.add(proton)
        #expect(throws: AccountError.duplicate("gmail")) { try store.add(.gmail(id: "gmail", address: "x@example.test")) }
        #expect(throws: AccountError.invalidID("../x")) { try store.add(.imap(id: "../x", username: "u", host: "h")) }
        proton.security = .startTLSPinned(fingerprint: "ab12")
        proton.policy.include = ["Folders/Test"]
        try store.update(proton)
        let loaded = try store.load()
        #expect(loaded.map(\.id) == ["gmail", "proton"])
        #expect(loaded[1].security == .startTLSPinned(fingerprint: "ab12") && loaded[1].policy.include == ["Folders/Test"])
        #expect(posixMode(store.url) == 0o600)
        try store.remove("gmail")
        #expect(try store.load().map(\.id) == ["proton"])
        #expect(!String(decoding: try Data(contentsOf: store.url), as: UTF8.self).lowercased().contains("password"))
    }

    @Test func presets() {
        let g = AccountConfig.gmail(id: "g", address: "a@gmail.example")
        #expect(g.host == "imap.gmail.com" && g.port == 993 && g.security == .tls && g.policy.mode == .gmail)
        #expect(g.normalizedPassword("abcd efgh ijkl mnop") == "abcdefghijklmnop")
        let p = AccountConfig.protonBridge(id: "p", address: "a@proton.example")
        #expect(p.host == "127.0.0.1" && p.port == 1143 && p.security == .startTLSPinned(fingerprint: nil))
        #expect(p.normalizedPassword("with space") == "with space")  // only Gmail strips spaces
    }

    #if canImport(Security)
    @Test func keychainSaveReadUpdateDelete() throws {
        let store = CredentialStore(service: "de.paranoidsecurity.MailKeeper.tests")
        let account = AccountConfig.imap(id: "t", username: "probe-\(UUID().uuidString)", host: "imap.example.test")
        defer { try? store.delete(for: account) }
        #expect(try store.password(for: account) == nil)
        #expect(try !store.exists(for: account))
        try store.save("erstes", for: account)
        #expect(try store.exists(for: account))
        #expect(try store.password(for: account) == "erstes")
        try store.save("zweites", for: account)
        #expect(try store.password(for: account) == "zweites")
        try store.delete(for: account)
        #expect(try store.password(for: account) == nil)
    }
    #else
    /// Linux brings no store of its own: asking says so instead of answering "no password".
    @Test func withoutAStoreSecretsAreRefused() {
        let store = CredentialStore()
        let account = AccountConfig.imap(id: "t", username: "u", host: "imap.example.test")
        #expect(throws: AccountError.noSecretStore) { try store.save("x", for: account) }
        #expect(throws: AccountError.noSecretStore) { _ = try store.password(for: account) }
        #expect(throws: AccountError.noSecretStore) { _ = try store.exists(for: account) }  // unknown, not "none"
        #expect(throws: AccountError.noSecretStore) { _ = try store.hasCredential(for: account) }
    }
    #endif

    /// The store's own logic over any backend: keys, the OAuth secrets that go with an account.
    @Test func credentialStoreOverABackend() throws {
        let store = CredentialStore(backend: MemorySecrets())
        let account = AccountConfig.imap(id: "t", username: "u", host: "imap.example.test")
        try store.save("erstes", for: account)
        try store.saveRefreshToken("rt", for: account)
        #expect(try store.password(for: account) == "erstes" && store.exists(for: account))
        #expect(try store.secret(key: CredentialStore.key(for: account)) == "erstes")
        #expect(try store.hasRefreshToken(for: account))
        try store.delete(for: account)  // takes the refresh token along
        #expect(try store.password(for: account) == nil && !store.hasRefreshToken(for: account))
    }
}

@Suite("Secrets aus Dateien (mailkeeper-server)")
struct FileSecretTests {
    @Test func namesAreKubernetesSecretKeys() {
        #expect(FileSecretBackend.fileName(for: "jan@example.org@mail.example.org:993") == "jan_example.org_mail.example.org_993")
        #expect(FileSecretBackend.fileName(for: "oauth-refresh:a@b:1") == "oauth-refresh_a_b_1")
        #expect(FileSecretBackend.fileName(for: "ä/../x") == "__.._x")  // one name, no path out of the folder
        #expect(FileSecretBackend.fileName(for: "..") == "_.." && FileSecretBackend.fileName(for: "") == "_")
    }

    @Test func readsTrimsAndRefusesToWrite() throws {
        let dir = tempDir()
        let account = AccountConfig.imap(id: "p", username: "jan@example.org", host: "mail.example.org")
        let file = dir.appending(path: FileSecretBackend.fileName(for: CredentialStore.key(for: account)))
        try Data("geheim \n".utf8).write(to: file)
        let store = CredentialStore(backend: FileSecretBackend(directory: dir))
        #expect(try store.password(for: account) == "geheim ")  // newline off, the space is the password's
        #expect(try store.exists(for: account))
        let other = AccountConfig.imap(id: "q", username: "x@example.org", host: "mail.example.org")
        #expect(try store.password(for: other) == nil && !store.exists(for: other))
        #expect(throws: AccountError.readOnlySecretStore) { try store.save("x", for: other) }
        #expect(throws: AccountError.readOnlySecretStore) { try store.delete(for: account) }
    }

    @Test func aMissingFolderIsAnErrorNotNoPassword() {
        let store = CredentialStore(backend: FileSecretBackend(directory: tempDir().appending(path: "fehlt")))
        let account = AccountConfig.imap(id: "p", username: "u", host: "h")
        #expect(throws: AccountError.noSecretStore) { _ = try store.password(for: account) }
        #expect(throws: AccountError.noSecretStore) { _ = try store.exists(for: account) }
    }
}

final class MemorySecrets: SecretBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    func write(_ secret: Data, key: String, label: String, description: String) throws { lock.withLock { items[key] = secret } }
    func read(key: String) throws -> Data? { lock.withLock { items[key] } }
    func exists(key: String) -> Bool { lock.withLock { items[key] != nil } }
    func delete(key: String) throws { _ = lock.withLock { items.removeValue(forKey: key) } }
}
