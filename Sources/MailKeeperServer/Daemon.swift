import Foundation
import MailKeeperIMAP
import MailKeeperKit

/// One run over all people and their accounts — all the server does in Phase 1 of
/// mailkeeper-server. Towards every mail server it only reads: `SyncCoordinator` opens
/// read-only connections whose command allowlist refuses anything that changes (ADR-0002).
///
/// Known limit (ADR-0015): people and accounts run one after the other, without an overall
/// deadline — a first fetch of a big mailbox holds up the next ones for hours. `running` in the
/// status file shows which one is busy.
public struct Daemon: Sendable {
    public let config: ServerConfig
    let secrets: FileSecretBackend
    let credentials: CredentialStore
    let log: @Sendable (String) -> Void

    public init(config: ServerConfig, log: @escaping @Sendable (String) -> Void) {
        self.config = config
        secrets = FileSecretBackend(directory: URL(fileURLWithPath: config.secretsDirectory))
        credentials = CredentialStore(backend: secrets)
        self.log = log
    }

    /// Every declared account once, people one after the other. The status file is written
    /// before and after each account. Returns whether every account got through.
    @discardableResult
    public func runOnce() async -> Bool {
        let statusURL = URL(fileURLWithPath: config.statusFile)
        var status = ServerStatus.load(from: statusURL)
        status.keep(only: Set(config.people.flatMap { person in person.accounts.map { "\(person.id)/\($0.id)" } }),
                    exports: config.paperless == nil ? [] : Set(config.people.filter { $0.paperless != nil }.map(\.id)))
        var clean = true
        for person in config.people {
            do {
                clean = try await run(person, status: &status, statusURL: statusURL) && clean
            } catch {
                // The archive could not be opened, locked or reconciled: nothing of this person ran.
                clean = false
                let now = Date()
                for spec in person.accounts { status.record("\(person.id)/\(spec.id)", at: now, error: Self.clean(error)) }
                log("[\(person.id)] Archiv: \(Self.clean(error))")
                save(status, to: statusURL)
            }
        }
        return clean
    }

    private func run(_ person: ServerConfig.Person, status: inout ServerStatus, statusURL: URL) async throws -> Bool {
        let layout = try ArchiveLayout.open(at: URL(fileURLWithPath: person.archive), create: true)
        // The lock first: accounts.json is changed only by whoever holds it (review S7).
        let writer = try ArchiveWriter(layout: layout)
        let store = AccountStore(layout: layout)
        let (accounts, changed, identityChanged) = try reconcile(stored: try store.load(), declared: person.accounts)
        for id in identityChanged {
            log("[\(person.id)/\(id)] Achtung: anderes Postfach als bisher unter dieser Konto-ID — ab jetzt landet es im selben Ordner des Archivs")
        }
        if changed { try store.save(accounts) }
        var clean = true
        for spec in person.accounts {
            guard let account = accounts.first(where: { $0.id == spec.id }) else { continue }
            clean = await fetch(account, key: "\(person.id)/\(account.id)", writer: writer, status: &status, statusURL: statusURL) && clean
        }
        // After the fetch, over what the archive holds now — also when an account failed: what
        // came in is complete (ADR-0001). Still under the archive's lock.
        if let settings = config.paperless, let mapping = person.paperless {
            clean = export(person.id, settings: settings, mapping: mapping, layout: layout, status: &status, statusURL: statusURL) && clean
        }
        return clean
    }

    private func export(_ person: String, settings: PaperlessExport, mapping: PaperlessPerson, layout: ArchiveLayout,
                        status: inout ServerStatus, statusURL: URL) -> Bool {
        let start = Date()
        let dryRun = PaperlessDryRun(settings: settings, person: mapping, personID: person)
        let ledger = dryRun.ledgerURL.lastPathComponent, mode = settings.mode.rawValue
        status.markExportRunning(person, mode: mode, ledger: ledger, at: start)
        save(status, to: statusURL)
        defer { save(status, to: statusURL) }
        do {
            let counts = try dryRun.run(layout: layout, now: start)
            log(Self.exportSummary(person, counts.pass, totals: counts.totals, seconds: Date().timeIntervalSince(start)))
            status.recordExport(person, mode: mode, ledger: ledger, at: start, counts: counts)
            return true
        } catch {
            log("[\(person)] Paperless-Trockenlauf: Fehler: \(Self.clean(error))")
            status.recordExport(person, mode: mode, ledger: ledger, at: start, error: Self.clean(error))
            return false
        }
    }

    /// Counts only — the ledger holds the details.
    static func exportSummary(_ person: String, _ pass: LedgerCounts, totals: LedgerCounts, seconds: Double) -> String {
        func reasons(_ c: LedgerCounts) -> String {
            let parts = LedgerAttachment.Reason.allCases.compactMap { r in c.skipped[r.rawValue].map { "\(r.rawValue) \($0)" } }
            return parts.isEmpty ? "keine" : parts.joined(separator: ", ")
        }
        var line = String(format: "[%@] Paperless-Trockenlauf: %d Mails neu entschieden · %d Anhänge würden übergeben · ausgelassen: %@",
                          person, pass.messages, pass.upload, reasons(pass))
        if pass.problems > 0 { line += " · \(pass.problems) Mails unlesbar" }
        line += String(format: " · %.1f s — Ledger: %d Mails, %d würden übergeben", seconds, totals.messages, totals.upload)
        return line
    }

    private func fetch(_ account: AccountConfig, key: String, writer: ArchiveWriter,
                       status: inout ServerStatus, statusURL: URL) async -> Bool {
        let start = Date()
        let secretModified = secretFileModified(for: account)
        if let retry = status.waiting(key, now: start, secretModified: secretModified) {
            log("[\(key)] zurückgestellt bis \(retry.formatted(.iso8601)) nach \(status.accounts[key]?.authFailures ?? 0) abgelehnten Anmeldungen (geänderte Secret-Datei beendet das Warten)")
            return false
        }
        status.markRunning(key, at: start)
        save(status, to: statusURL)
        do {
            if case .startTLSPinned(nil) = account.security {
                // No trust on first use: the fingerprint, without a login (review S2).
                let fingerprint = try await SyncCoordinator.certificateFingerprint(for: account)
                log("[\(key)] Zertifikat nicht bestätigt, Fingerabdruck \(fingerprint) — "
                    + "nach Prüfung als \"fingerprint\" in die Konfiguration eintragen; bis dahin kein Abruf")
                status.record(key, at: start, error: "Zertifikat nicht bestätigt")
                save(status, to: statusURL)
                return false
            }
            let report = try await SyncCoordinator.sync(account, writer: writer, credentials: credentials)
            log(Self.summary(key, report, seconds: Date().timeIntervalSince(start)))
            for failure in report.failures { log("[\(key)]   Fehler: \(Self.clean(failure))") }
            status.clearRefusedLogins(key)
            status.record(key, at: start, newMessages: report.newMessages,
                          error: report.failures.isEmpty ? nil : "\(report.failures.count) Postfächer mit Fehler")
            save(status, to: statusURL)
            return report.failures.isEmpty
        } catch {
            let text = describe(error, account: account)
            status.record(key, at: start, error: text)
            if case IMAPError.authentication = error {
                status.recordRefusedLogin(key, at: start, interval: config.intervalSeconds, secretModified: secretModified)
                log("[\(key)] Fehler: \(text) — nächster Versuch frühestens \(status.accounts[key]?.retryAfter?.formatted(.iso8601) ?? "?")")
            } else {
                log("[\(key)] Fehler: \(text)")
            }
            save(status, to: statusURL)
            return false
        }
    }

    /// The app's texts speak of the keychain; on the server the password is a file.
    func describe(_ error: any Error, account: AccountConfig) -> String {
        if case SyncError.noPassword = error {
            let file = FileSecretBackend.fileName(for: CredentialStore.key(for: account))
            let exists = FileManager.default.fileExists(atPath: secrets.directory.appending(path: file).path)
            return "kein Passwort: Secret-Datei \(file) \(exists ? "ist leer" : "fehlt")"
        }
        return Self.clean(error)
    }

    /// When the account's secret file last changed (through the symbolic links of a mounted
    /// Kubernetes secret) — a new password ends a login backoff.
    func secretFileModified(for account: AccountConfig) -> Date? {
        let url = secrets.directory.appending(path: FileSecretBackend.fileName(for: CredentialStore.key(for: account)))
        return (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
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

    /// Error texts may carry what a server said (mailbox names too): one line, no control, bidi
    /// or format characters (`DisplayText.safe`, as everywhere else), bounded.
    static func clean(_ error: any Error) -> String { clean("\(error)") }

    static func clean(_ text: String) -> String {
        let kept = DisplayText.safe(text).unicodeScalars.map { $0.properties.generalCategory == .control ? " " : Character($0) }
        return String(String(kept).prefix(300))
    }
}
