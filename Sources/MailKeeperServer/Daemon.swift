import Foundation
import MailKeeperIMAP
import MailKeeperKit

/// One run over all people and their accounts — all the server does in Phase 1 of
/// mailkeeper-server. Towards every mail server it only reads: `SyncCoordinator` opens
/// read-only connections whose command allowlist refuses anything that changes (ADR-0002).
public struct Daemon: Sendable {
    public let config: ServerConfig
    let credentials: CredentialStore
    let log: @Sendable (String) -> Void

    public init(config: ServerConfig, log: @escaping @Sendable (String) -> Void) {
        self.config = config
        credentials = CredentialStore(backend: FileSecretBackend(directory: URL(fileURLWithPath: config.secretsDirectory)))
        self.log = log
    }

    /// Every declared account once, people one after the other. The status file is written after
    /// each account, so it is current even while a long first fetch runs.
    public func runOnce() async {
        let statusURL = URL(fileURLWithPath: config.statusFile)
        var status = ServerStatus.load(from: statusURL)
        for person in config.people {
            do {
                try await run(person, status: &status, statusURL: statusURL)
            } catch {
                // The archive could not be opened, reconciled or locked: nothing of this person ran.
                let now = Date()
                for spec in person.accounts { status.record("\(person.id)/\(spec.id)", at: now, error: Self.clean(error)) }
                log("[\(person.id)] Archiv: \(Self.clean(error))")
                save(status, to: statusURL)
            }
        }
    }

    private func run(_ person: ServerConfig.Person, status: inout ServerStatus, statusURL: URL) async throws {
        let layout = try ArchiveLayout.open(at: URL(fileURLWithPath: person.archive), create: true)
        let store = AccountStore(layout: layout)
        let (accounts, changed) = try reconcile(stored: try store.load(), declared: person.accounts)
        if changed { try store.save(accounts) }
        let writer = try ArchiveWriter(layout: layout)  // holds the archive's lock until this person is done
        for spec in person.accounts {
            guard let account = accounts.first(where: { $0.id == spec.id }) else { continue }
            let key = "\(person.id)/\(account.id)"
            let start = Date()
            do {
                if case .startTLSPinned(nil) = account.security {
                    try await reportCertificate(of: account, key: key)
                    status.record(key, at: start, error: "Zertifikat nicht bestätigt")
                } else {
                    let report = try await SyncCoordinator.sync(account, writer: writer, credentials: credentials)
                    log(Self.summary(key, report, seconds: Date().timeIntervalSince(start)))
                    for failure in report.failures { log("[\(key)]   Fehler: \(Self.clean(failure))") }
                    status.record(key, at: start, newMessages: report.newMessages,
                                  error: report.failures.isEmpty ? nil : "\(report.failures.count) Postfächer mit Fehler")
                }
            } catch {
                let text = Self.describe(error, account: account)
                log("[\(key)] Fehler: \(text)")
                status.record(key, at: start, error: text)
            }
            save(status, to: statusURL)
        }
    }

    /// A bridge account without a confirmed certificate is not fetched (no trust on first use).
    /// Its fingerprint goes to the log, so whoever deploys can compare it and put it into the
    /// configuration. The connection stays on loopback: a bridge is always 127.0.0.1.
    private func reportCertificate(of account: AccountConfig, key: String) async throws {
        let credential = try await SyncCoordinator.credential(for: account, credentials: credentials)
        let check = try await SyncCoordinator.check(account, credential: credential)
        log("[\(key)] Zertifikat nicht bestätigt, Fingerabdruck \(check.certificateFingerprint ?? "unbekannt") — "
            + "nach Prüfung als \"fingerprint\" in die Konfiguration eintragen; bis dahin kein Abruf")
    }

    /// The app's texts speak of the keychain; on the server the password is a file.
    static func describe(_ error: any Error, account: AccountConfig) -> String {
        if case SyncError.noPassword = error {
            return "kein Passwort: Secret-Datei \(FileSecretBackend.fileName(for: CredentialStore.key(for: account))) fehlt"
        }
        return clean(error)
    }

    private func save(_ status: ServerStatus, to url: URL) {
        do { try status.write(to: url) } catch { log("Status: \(Self.clean(error))") }
    }

    static func summary(_ key: String, _ r: SyncReport, seconds: Double) -> String {
        var line = String(format: "[%@] %d Postfächer · %d neu (%@) · %d weitere Ablageorte · %d Flag-Änderungen · %d nicht mehr auf dem Server · %.1f s",
                          key, r.mailboxes, r.newMessages, bytes(r.bytes), r.newLocations, r.flagChanges, r.gone, seconds)
        if r.back > 0 { line += " · \(r.back) wieder auf dem Server" }
        return line
    }

    static func bytes(_ n: Int64) -> String {
        n < 1 << 20 ? String(format: "%.0f KB", Double(n) / 1024) : String(format: "%.1f MB", Double(n) / 1_048_576)
    }

    /// Error texts may carry what a server said: one line, no control characters, bounded.
    static func clean(_ error: any Error) -> String { clean("\(error)") }

    static func clean(_ text: String) -> String {
        let kept = text.unicodeScalars.map { $0.properties.generalCategory == .control ? " " : Character($0) }
        return String(String(kept).prefix(300))
    }
}

extension ServerStatus {
    /// A run that got through sets `lastSuccess`; one with an error keeps the last one, so a
    /// stale `lastSuccess` is what an alert looks at.
    mutating func record(_ key: String, at time: Date, newMessages: Int? = nil, error: String?) {
        var entry = accounts[key] ?? AccountStatus(lastAttempt: time, lastSuccess: nil, newMessages: 0, error: nil)
        entry.lastAttempt = time
        if let newMessages {
            entry.newMessages = newMessages
            if error == nil { entry.lastSuccess = time }
        }
        entry.error = error
        accounts[key] = entry
        updated = Date()
    }
}
