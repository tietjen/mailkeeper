import Foundation
import Testing
@testable import MailKeeperKit
@testable import MailKeeperServer

private func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mailkeeperd-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func config(_ json: String) throws -> ServerConfig {
    try JSONDecoder().decode(ServerConfig.self, from: Data(json.utf8))
}

private let valid = """
{"intervalSeconds": 900, "secretsDirectory": "/run/secrets/mailkeeper", "statusFile": "/data/status.json",
 "people": [{"id": "jan", "archive": "/data/jan", "accounts": [
   {"id": "parasec", "kind": "imap", "username": "jan@example.org", "host": "mail.example.org"},
   {"id": "proton", "kind": "protonBridge", "username": "jan@example.com", "fingerprint": "AB:CD"}]}]}
"""

@Suite("mailkeeperd: Konfiguration")
struct ServerConfigTests {
    @Test func aValidConfigurationMapsToArchiveAccounts() throws {
        let c = try config(valid)
        try c.validate()
        let imap = try c.people[0].accounts[0].accountConfig()
        #expect(imap.kind == .imap && imap.host == "mail.example.org" && imap.port == 993 && imap.security == .tls)
        let bridge = try c.people[0].accounts[1].accountConfig()
        #expect(bridge.host == "127.0.0.1" && bridge.port == 1143 && bridge.policy.mode == .protonBridge)
        #expect(bridge.security == .startTLSPinned(fingerprint: "ab:cd"))  // compared lowercased
    }

    @Test func aBridgeWithoutFingerprintStaysUnconfirmed() throws {
        let spec = ServerConfig.AccountSpec(id: "proton", kind: .protonBridge, username: "a@b.c", host: nil, port: nil,
                                            security: nil, fingerprint: nil, include: nil, exclude: nil)
        #expect(try spec.accountConfig().security == .startTLSPinned(fingerprint: nil))
    }

    @Test func startTLSIsPinnedOnlyWithAFingerprint() throws {
        var spec = ServerConfig.AccountSpec(id: "x", kind: .imap, username: "u", host: "h", port: 143,
                                            security: "startTLS", fingerprint: nil, include: ["INBOX"], exclude: ["Spam"])
        #expect(try spec.accountConfig().security == .startTLS)
        #expect(try spec.accountConfig().policy.include == ["INBOX"] && spec.accountConfig().policy.exclude == ["Spam"])
        spec.fingerprint = "EF"
        #expect(try spec.accountConfig().security == .startTLSPinned(fingerprint: "ef"))
        spec.security = "tls"
        #expect(throws: ConfigError.self) { try spec.accountConfig() }  // a pin would only pretend with TLS
    }

    @Test func mistakesAreRefusedBeforeAnythingRuns() throws {
        let broken = [
            valid.replacingOccurrences(of: "900", with: "30"),
            valid.replacingOccurrences(of: "\"/data/jan\"", with: "\"data/jan\""),
            valid.replacingOccurrences(of: "\"id\": \"jan\"", with: "\"id\": \"Jan!\""),
            valid.replacingOccurrences(of: "\"id\": \"proton\"", with: "\"id\": \"parasec\""),
            valid.replacingOccurrences(of: ", \"host\": \"mail.example.org\"", with: ""),
            """
            {"intervalSeconds": 900, "secretsDirectory": "/s", "statusFile": "/d/s.json", "people": [
              {"id": "a", "archive": "/d/a", "accounts": []}, {"id": "b", "archive": "/d/a/b", "accounts": []}]}
            """,
            """
            {"intervalSeconds": 900, "secretsDirectory": "/s", "statusFile": "/d/s.json", "people": [
              {"id": "a", "archive": "/d/a", "accounts": []}, {"id": "a", "archive": "/d/b", "accounts": []}]}
            """,
        ]
        for json in broken {
            #expect(throws: ConfigError.self, "\(json.prefix(80))") { try config(json).validate() }
        }
    }

    @Test func reconcilingKeepsCreationDateAndUndeclaredAccounts() throws {
        let c = try config(valid)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        var stored = AccountConfig.imap(id: "parasec", username: "alt@example.org", host: "mail.example.org")
        stored.created = old
        let leftover = AccountConfig.imap(id: "frueher", username: "u", host: "h")
        let (accounts, changed) = try reconcile(stored: [stored, leftover], declared: c.people[0].accounts)
        #expect(changed)
        #expect(accounts.map(\.id) == ["parasec", "frueher", "proton"])
        #expect(accounts[0].username == "jan@example.org" && accounts[0].created == old)
        #expect(accounts[1] == leftover)  // no longer fetched, never removed
        let (again, changedAgain) = try reconcile(stored: accounts, declared: c.people[0].accounts)
        #expect(again == accounts && !changedAgain)
    }
}

@Suite("mailkeeperd: Status und Lauf")
struct DaemonTests {
    @Test func statusKeepsTheLastSuccessThroughErrors() throws {
        var status = ServerStatus()
        let t1 = Date(timeIntervalSince1970: 1_000), t2 = Date(timeIntervalSince1970: 2_000)
        status.record("jan/parasec", at: t1, newMessages: 3, error: nil)
        status.record("jan/parasec", at: t2, error: "Verbindung abgelehnt")
        let entry = try #require(status.accounts["jan/parasec"])
        #expect(entry.lastSuccess == t1 && entry.lastAttempt == t2 && entry.newMessages == 3 && entry.error == "Verbindung abgelehnt")

        let url = tempDir().appending(path: "status.json")
        try status.write(to: url)
        #expect(ServerStatus.load(from: url).accounts == status.accounts)
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
    }

    /// A whole run without a mail server: the archive is created, the accounts land in it, the
    /// unreachable server is an error in the status — and a bridge without a confirmed
    /// certificate is not fetched.
    @Test func aRunCreatesTheArchiveAndRecordsWhatFailed() async throws {
        let root = tempDir()
        let secrets = root.appending(path: "secrets")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        let imap = AccountConfig.imap(id: "parasec", username: "jan@example.org", host: "127.0.0.1", port: 9)
        try Data("pw\n".utf8).write(to: secrets.appending(path: FileSecretBackend.fileName(for: CredentialStore.key(for: imap))))
        let c = try config("""
        {"intervalSeconds": 900, "secretsDirectory": "\(secrets.path)", "statusFile": "\(root.path)/status.json",
         "people": [{"id": "jan", "archive": "\(root.path)/jan", "accounts": [
           {"id": "parasec", "kind": "imap", "username": "jan@example.org", "host": "127.0.0.1", "port": 9},
           {"id": "ohne", "kind": "imap", "username": "x@example.org", "host": "127.0.0.1", "port": 9}]}]}
        """)
        try c.validate()
        let lines = LogLines()
        await Daemon(config: c) { lines.add($0) }.runOnce()

        let layout = try ArchiveLayout.open(at: root.appending(path: "jan"), create: false)
        #expect(try AccountStore(layout: layout).load().map(\.id) == ["parasec", "ohne"])
        let status = ServerStatus.load(from: root.appending(path: "status.json"))
        #expect(status.accounts["jan/parasec"]?.error != nil && status.accounts["jan/parasec"]?.lastSuccess == nil)
        // the missing secret is named by the file it should be in, not by the app's keychain
        #expect(status.accounts["jan/ohne"]?.error == "kein Passwort: Secret-Datei x_example.org_127.0.0.1_9 fehlt",
                "\(status.accounts["jan/ohne"]?.error ?? "")")
        #expect(lines.all.count == 2 && lines.all.allSatisfy { $0.hasPrefix("[jan/") })
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
