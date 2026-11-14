import Foundation

/// The last result per account ("jan/parasec"), written before and after every account. Counts,
/// times and error texts only, never mail content — readable for probes and with `kubectl exec`.
public struct ServerStatus: Codable, Sendable, Equatable {
    public var updated: Date
    public var accounts: [String: AccountStatus]
    /// The Paperless export per person (ADR-0016) — counts only.
    public var exports: [String: ExportStatus]?

    public struct ExportStatus: Codable, Sendable, Equatable {
        /// "dryRun": decided and written down, nothing uploaded.
        public var mode: String
        /// The ledger file of the current settings (the fingerprint is in its name).
        public var ledger: String?
        public var lastAttempt: Date
        public var lastSuccess: Date?
        public var error: String?
        /// A pass is under way (the first one reads every message with attachments).
        public var running: Bool?
        /// Not an error, but worth a look: messages not or not completely read (see the ledger).
        public var warning: String?
        /// The last pass that got through: messages decided anew and what became of their attachments.
        public var pass: LedgerCounts?
        /// Everything in the ledger.
        public var totals: LedgerCounts?
    }

    public struct AccountStatus: Codable, Sendable, Equatable {
        public var lastAttempt: Date
        public var lastSuccess: Date?
        /// New messages in the last successful run.
        public var newMessages: Int
        /// Why the last run did not get through — nil after a clean run.
        public var error: String?
        /// A fetch of this account is under way (a first fetch takes hours).
        public var running: Bool?
        /// Logins the server refused in a row, and when the next try is due — so a wrong or
        /// revoked password is not retried every interval (fail2ban, Gmail). A changed secret
        /// file (`secretModified`) ends the wait at once.
        public var authFailures: Int?
        public var retryAfter: Date?
        public var secretModified: Date?
    }

    public init(updated: Date = Date(), accounts: [String: AccountStatus] = [:]) {
        self.updated = updated
        self.accounts = accounts
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// A missing or unreadable file starts empty: the status is a report, not a source of truth.
    public static func load(from url: URL) -> ServerStatus {
        (try? decoder.decode(ServerStatus.self, from: Data(contentsOf: url))) ?? ServerStatus()
    }

    /// Durably and atomically: a fixed temporary name (nothing left over after a kill), fsync,
    /// rename. 0600 like the rest of the data volume.
    public func write(to url: URL) throws {
        let data = try Self.encoder.encode(self)
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).tmp")
        unlink(tmp.path)
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        let handle = try FileHandle(forWritingTo: tmp)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            unlink(tmp.path)
            throw error
        }
        guard rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    /// Only accounts the configuration still names: one dropped or renamed would otherwise keep
    /// its old `lastSuccess` and make a staleness alert fire for good (review S5).
    mutating func keep(only keys: Set<String>, exports people: Set<String>) {
        accounts = accounts.filter { keys.contains($0.key) }
        exports = exports?.filter { people.contains($0.key) }
        if exports?.isEmpty == true { exports = nil }
    }

    /// Like accounts: an export that failed keeps its last success and its last counts.
    mutating func recordExport(_ person: String, mode: String, ledger: String, at time: Date,
                               counts: (pass: LedgerCounts, totals: LedgerCounts)? = nil, error: String? = nil) {
        var entry = exports?[person] ?? ExportStatus(mode: mode, lastAttempt: time)
        entry.mode = mode
        entry.ledger = ledger
        entry.lastAttempt = time
        entry.running = nil
        entry.error = error
        if let counts, error == nil {
            entry.lastSuccess = time
            entry.pass = counts.pass
            entry.totals = counts.totals
            entry.warning = counts.totals.problems > 0
                ? "\(counts.totals.problems) Mails nicht oder nicht ganz gelesen — im Ledger unter problem" : nil
        }
        exports = (exports ?? [:]).merging([person: entry]) { $1 }
        updated = Date()
    }

    mutating func markExportRunning(_ person: String, mode: String, ledger: String, at time: Date) {
        var entry = exports?[person] ?? ExportStatus(mode: mode, lastAttempt: time)
        entry.mode = mode
        entry.ledger = ledger
        entry.lastAttempt = time
        entry.running = true
        exports = (exports ?? [:]).merging([person: entry]) { $1 }
        updated = Date()
    }

    /// A run that got through sets `lastSuccess`; one with an error keeps the last one, so a
    /// stale `lastSuccess` is what an alert looks at.
    mutating func record(_ key: String, at time: Date, newMessages: Int? = nil, error: String?) {
        var entry = accounts[key] ?? AccountStatus(lastAttempt: time, lastSuccess: nil, newMessages: 0, error: nil)
        entry.lastAttempt = time
        entry.running = nil
        if let newMessages {
            entry.newMessages = newMessages
            if error == nil { entry.lastSuccess = time }
        }
        entry.error = error
        accounts[key] = entry
        updated = Date()
    }

    mutating func markRunning(_ key: String, at time: Date) {
        var entry = accounts[key] ?? AccountStatus(lastAttempt: time, lastSuccess: nil, newMessages: 0, error: nil)
        entry.lastAttempt = time
        entry.running = true
        accounts[key] = entry
        updated = Date()
    }

    /// After a refused login: wait one interval, then twice as long each time, at most 6 hours.
    mutating func recordRefusedLogin(_ key: String, at time: Date, interval: Int, secretModified: Date?) {
        var entry = accounts[key] ?? AccountStatus(lastAttempt: time, lastSuccess: nil, newMessages: 0, error: nil)
        let failures = (entry.authFailures ?? 0) + 1
        entry.authFailures = failures
        entry.retryAfter = time.addingTimeInterval(Self.backoff(failures: failures, interval: interval))
        entry.secretModified = secretModified
        accounts[key] = entry
    }

    mutating func clearRefusedLogins(_ key: String) {
        accounts[key]?.authFailures = nil
        accounts[key]?.retryAfter = nil
        accounts[key]?.secretModified = nil
    }

    static func backoff(failures: Int, interval: Int) -> TimeInterval {
        min(Double(interval) * pow(2, Double(max(failures - 1, 0))), 6 * 3600)
    }

    /// Whether to leave the account alone for now: a refused login is waiting out its time and
    /// the secret file is still the one that was refused.
    func waiting(_ key: String, now: Date, secretModified: Date?) -> Date? {
        guard let entry = accounts[key], let retry = entry.retryAfter, retry > now,
              entry.secretModified == secretModified else { return nil }
        return retry
    }
}
