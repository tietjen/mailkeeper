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

    @Test func keychainSaveReadUpdateDelete() throws {
        let store = CredentialStore(service: "de.paranoidsecurity.MailKeeper.tests")
        let account = AccountConfig.imap(id: "t", username: "probe-\(UUID().uuidString)", host: "imap.example.test")
        defer { try? store.delete(for: account) }
        #expect(try store.password(for: account) == nil)
        try store.save("erstes", for: account)
        #expect(try store.password(for: account) == "erstes")
        try store.save("zweites", for: account)
        #expect(try store.password(for: account) == "zweites")
        try store.delete(for: account)
        #expect(try store.password(for: account) == nil)
    }
}
