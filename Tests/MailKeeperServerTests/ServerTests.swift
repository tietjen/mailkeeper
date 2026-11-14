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

private let pin = String(repeating: "ab", count: 32)
private let pinWithColons = (0..<32).map { _ in "AB" }.joined(separator: ":")

private let valid = """
{"intervalSeconds": 900, "secretsDirectory": "/run/secrets/mailkeeper", "statusFile": "/data/status.json",
 "people": [{"id": "jan", "archive": "/data/jan", "accounts": [
   {"id": "parasec", "kind": "imap", "username": "jan@example.org", "host": "mail.example.org"},
   {"id": "proton", "kind": "protonBridge", "username": "jan@example.com", "fingerprint": "\(pinWithColons)"}]}]}
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
        #expect(bridge.security == .startTLSPinned(fingerprint: pin))  // colons and case as openssl prints them
    }

    @Test func aBridgeWithoutFingerprintStaysUnconfirmed() throws {
        let spec = ServerConfig.AccountSpec(id: "proton", kind: .protonBridge, username: "a@b.c")
        #expect(try spec.accountConfig().security == .startTLSPinned(fingerprint: nil))
    }

    @Test func fingerprintsAreSHA256OrRefused() throws {
        for bad in ["", "AB:CD", String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            let spec = ServerConfig.AccountSpec(id: "p", kind: .protonBridge, username: "a@b.c", fingerprint: bad)
            #expect(throws: ConfigError.self, "\(bad)") { try spec.accountConfig() }  // "" must not mean "pinned to nothing"
        }
    }

    @Test func startTLSIsPinnedOnlyWithAFingerprint() throws {
        var spec = ServerConfig.AccountSpec(id: "x", kind: .imap, username: "u", host: "h", port: 143,
                                            security: "startTLS", include: ["INBOX"], exclude: ["Spam"])
        #expect(try spec.accountConfig().security == .startTLS)
        #expect(try spec.accountConfig().policy.include == ["INBOX"] && spec.accountConfig().policy.exclude == ["Spam"])
        spec.fingerprint = pin.uppercased()
        #expect(try spec.accountConfig().security == .startTLSPinned(fingerprint: pin))
        spec.security = "tls"
        #expect(throws: ConfigError.self) { try spec.accountConfig() }  // a pin would only pretend with TLS
    }

    @Test func fieldsThatDoNotApplyAreRefused() {
        let cases = [
            ServerConfig.AccountSpec(id: "p", kind: .protonBridge, username: "a@b.c", host: "bridge.mail.svc"),
            ServerConfig.AccountSpec(id: "p", kind: .protonBridge, username: "a@b.c", security: "tls"),
            ServerConfig.AccountSpec(id: "g", kind: .gmail, username: "a@gmail.com", port: 993),
            ServerConfig.AccountSpec(id: "g", kind: .gmail, username: "a@gmail.com", host: "imap.gmail.com"),
        ]
        for spec in cases { #expect(throws: ConfigError.self, "\(spec)") { try spec.accountConfig() } }
    }

    @Test func mistakesAreRefusedBeforeAnythingRuns() throws {
        let people = { (a: String, b: String) in
            """
            {"intervalSeconds": 900, "secretsDirectory": "/s", "statusFile": "/st/status.json", "people": [
              {"id": "a", "archive": "\(a)", "accounts": []}, {"id": "b", "archive": "\(b)", "accounts": []},
              {"id": "c", "archive": "/d/a-b", "accounts": []}]}
            """
        }
        let broken = [
            valid.replacingOccurrences(of: "900", with: "30"),
            valid.replacingOccurrences(of: "\"/data/jan\"", with: "\"data/jan\""),
            valid.replacingOccurrences(of: "\"/data/jan\"", with: "\"/\""),
            valid.replacingOccurrences(of: "\"/data/status.json\"", with: "\"/data/jan/status.json\""),
            valid.replacingOccurrences(of: "\"/run/secrets/mailkeeper\"", with: "\"/data/jan/secrets\""),
            valid.replacingOccurrences(of: "\"id\": \"jan\"", with: "\"id\": \"Jan!\""),
            valid.replacingOccurrences(of: "\"id\": \"proton\"", with: "\"id\": \"parasec\""),
            valid.replacingOccurrences(of: ", \"host\": \"mail.example.org\"", with: ""),
            people("/d/a", "/d/a/b"),  // "/d/a-b" sorts between them (review S1)
            people("/d/a", "/d/a"),
            people("/d/a/", "/d/a/./x"),
            """
            {"intervalSeconds": 900, "secretsDirectory": "/s", "statusFile": "/st/s.json", "people": [
              {"id": "a", "archive": "/d/a", "accounts": [{"id": "x", "kind": "imap", "username": "u", "host": "h"}]},
              {"id": "b", "archive": "/d/b", "accounts": [{"id": "y", "kind": "imap", "username": "u", "host": "h"}]}]}
            """,
        ]
        for json in broken {
            #expect(throws: ConfigError.self, "\(json.prefix(140))") { try config(json).validate() }
        }
    }

    @Test func unknownFieldsAreRefusedNotIgnored() {
        let typos = [
            valid.replacingOccurrences(of: "\"fingerprint\"", with: "\"fingerprnt\""),
            valid.replacingOccurrences(of: "\"host\"", with: "\"hostname\""),
            valid.replacingOccurrences(of: "\"intervalSeconds\"", with: "\"interval\": 1, \"intervalSeconds\""),
            valid.replacingOccurrences(of: "\"archive\"", with: "\"excludes\": [], \"archive\""),
        ]
        for json in typos {
            #expect(throws: ConfigError.self, "\(json.prefix(120))") { try config(json) }
        }
    }

    @Test func reconcilingKeepsCreationDateAndUndeclaredAccounts() throws {
        let c = try config(valid)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        var stored = AccountConfig.imap(id: "parasec", username: "alt@example.org", host: "mail.example.org")
        stored.created = old
        let leftover = AccountConfig.imap(id: "frueher", username: "u", host: "h")
        let (accounts, changed, identityChanged) = try reconcile(stored: [stored, leftover], declared: c.people[0].accounts)
        #expect(changed && identityChanged == ["parasec"])  // another mailbox under the same id
        #expect(accounts.map(\.id) == ["parasec", "frueher", "proton"])
        #expect(accounts[0].username == "jan@example.org" && accounts[0].created == old)
        #expect(accounts[1] == leftover)  // no longer fetched, never removed
        let (again, changedAgain, identityAgain) = try reconcile(stored: accounts, declared: c.people[0].accounts)
        #expect(again == accounts && !changedAgain && identityAgain.isEmpty)
    }
}

@Suite("mailkeeperd: Status und Lauf")
struct DaemonTests {
    @Test func statusKeepsTheLastSuccessThroughErrors() throws {
        var status = ServerStatus()
        let t1 = Date(timeIntervalSince1970: 1_000), t2 = Date(timeIntervalSince1970: 2_000)
        status.record("jan/parasec", at: t1, newMessages: 3, error: nil)
        status.markRunning("jan/parasec", at: t2)
        #expect(status.accounts["jan/parasec"]?.running == true)
        status.record("jan/parasec", at: t2, error: "Verbindung abgelehnt")
        let entry = try #require(status.accounts["jan/parasec"])
        #expect(entry.lastSuccess == t1 && entry.lastAttempt == t2 && entry.newMessages == 3 && entry.error == "Verbindung abgelehnt")
        #expect(entry.running == nil)

        let url = tempDir().appending(path: "status.json")
        try status.write(to: url)
        #expect(ServerStatus.load(from: url).accounts == status.accounts)
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["status.json"])
    }

    @Test func accountsNoLongerConfiguredLeaveTheStatus() {
        var status = ServerStatus()
        status.record("jan/parasec", at: Date(), newMessages: 1, error: nil)
        status.record("jan/frueher", at: Date(timeIntervalSince1970: 0), newMessages: 1, error: nil)
        status.keep(only: ["jan/parasec"], exports: [])
        #expect(Array(status.accounts.keys) == ["jan/parasec"])
    }

    @Test func refusedLoginsBackOffUntilTheSecretChanges() {
        var status = ServerStatus()
        let now = Date(timeIntervalSince1970: 10_000), secret = Date(timeIntervalSince1970: 5_000)
        status.recordRefusedLogin("jan/parasec", at: now, interval: 900, secretModified: secret)
        #expect(status.waiting("jan/parasec", now: now.addingTimeInterval(899), secretModified: secret) != nil)
        #expect(status.waiting("jan/parasec", now: now.addingTimeInterval(901), secretModified: secret) == nil)
        #expect(status.waiting("jan/parasec", now: now, secretModified: Date()) == nil)  // a new password: try at once
        for _ in 0..<20 { status.recordRefusedLogin("jan/parasec", at: now, interval: 900, secretModified: secret) }
        #expect(status.accounts["jan/parasec"]?.retryAfter == now.addingTimeInterval(6 * 3600))  // capped
        #expect(ServerStatus.backoff(failures: 2, interval: 900) == 1800)
        status.clearRefusedLogins("jan/parasec")
        #expect(status.waiting("jan/parasec", now: now, secretModified: secret) == nil)
    }

    @Test func serverTextIsOneSafeLine() {
        #expect(Daemon.clean("Postfach \u{202E}gnuhcer\nZeile\u{7}") == "Postfach gnuhcer Zeile")
        #expect(Daemon.clean(String(repeating: "x", count: 500)).count == 300)
    }

    /// A whole run without a mail server: the archive is created, the accounts land in it, the
    /// unreachable server and the missing or empty secret are errors in the status, and the run
    /// says it did not get through.
    @Test func aRunCreatesTheArchiveAndRecordsWhatFailed() async throws {
        let root = tempDir()
        let secrets = root.appending(path: "secrets")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        let imap = AccountConfig.imap(id: "parasec", username: "jan@example.org", host: "127.0.0.1", port: 9)
        try Data("pw\n".utf8).write(to: secrets.appending(path: FileSecretBackend.fileName(for: CredentialStore.key(for: imap))))
        let empty = AccountConfig.imap(id: "leer", username: "e@example.org", host: "127.0.0.1", port: 9)
        try Data("\n".utf8).write(to: secrets.appending(path: FileSecretBackend.fileName(for: CredentialStore.key(for: empty))))
        let c = try config("""
        {"intervalSeconds": 900, "secretsDirectory": "\(secrets.path)", "statusFile": "\(root.path)/status.json",
         "people": [{"id": "jan", "archive": "\(root.path)/jan", "accounts": [
           {"id": "parasec", "kind": "imap", "username": "jan@example.org", "host": "127.0.0.1", "port": 9},
           {"id": "ohne", "kind": "imap", "username": "x@example.org", "host": "127.0.0.1", "port": 9},
           {"id": "leer", "kind": "imap", "username": "e@example.org", "host": "127.0.0.1", "port": 9},
           {"id": "proton", "kind": "protonBridge", "username": "j@example.com", "port": 9}]}]}
        """)
        try c.validate()
        let lines = LogLines()
        let clean = await Daemon(config: c) { lines.add($0) }.runOnce()

        #expect(!clean)
        let layout = try ArchiveLayout.open(at: root.appending(path: "jan"), create: false)
        #expect(try AccountStore(layout: layout).load().map(\.id) == ["parasec", "ohne", "leer", "proton"])
        let status = ServerStatus.load(from: root.appending(path: "status.json"))
        #expect(status.accounts["jan/parasec"]?.error != nil && status.accounts["jan/parasec"]?.lastSuccess == nil)
        #expect(status.accounts["jan/ohne"]?.error == "kein Passwort: Secret-Datei x_example.org_127.0.0.1_9 fehlt")
        #expect(status.accounts["jan/leer"]?.error == "kein Passwort: Secret-Datei e_example.org_127.0.0.1_9 ist leer")
        // the bridge without fingerprint only asks for the certificate — here nothing listens
        #expect(status.accounts["jan/proton"]?.error?.contains("Verbindung") == true, "\(status.accounts["jan/proton"]?.error ?? "")")
        #expect(status.accounts.values.allSatisfy { $0.running == nil })
        #expect(lines.all.count == 4 && lines.all.allSatisfy { $0.hasPrefix("[jan/") })
    }

    /// While someone else holds the archive's lock (mkctl through kubectl exec), nothing of this
    /// person runs — and accounts.json stays as it was (review S7).
    @Test func aHeldLockLeavesTheArchiveAlone() async throws {
        let root = tempDir()
        let c = try config("""
        {"intervalSeconds": 900, "secretsDirectory": "\(root.path)/secrets", "statusFile": "\(root.path)/status.json",
         "people": [{"id": "jan", "archive": "\(root.path)/jan", "accounts": [
           {"id": "parasec", "kind": "imap", "username": "jan@example.org", "host": "127.0.0.1", "port": 9}]}]}
        """)
        let layout = try ArchiveLayout.open(at: root.appending(path: "jan"), create: true)
        let lock = try ArchiveLock(layout)
        let lines = LogLines()
        let clean = await Daemon(config: c) { lines.add($0) }.runOnce()
        withExtendedLifetime(lock) {}
        #expect(!clean)
        #expect(try AccountStore(layout: layout).load().isEmpty)
        #expect(ServerStatus.load(from: root.appending(path: "status.json")).accounts["jan/parasec"]?.error != nil)
    }
}

final class LogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}
