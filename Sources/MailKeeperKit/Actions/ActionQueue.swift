import Foundation

/// What a queued job does (ADR-0006: every destructive or bulk action goes through the queue).
public enum ActionKind: String, Codable, Sendable, CaseIterable {
    /// Move the message to the account's Trash on the server; the archive keeps it.
    case serverDelete
    /// Move the message to the archive trash (purged after 30 days).
    case archiveDelete
    /// Append the stored bytes to an account.
    case restore
    /// Write .eml/mbox files.
    case export
    /// "Kein Spam": from the account's spam folder back to its INBOX (5.5).
    case moveToInbox
    /// "Ist Spam": from an ordinary mailbox into the account's spam folder (6.4).
    case moveToJunk
    /// Leaving a newsletter (6.5c): logged, nothing on the mail server changes.
    case unsubscribe
}

/// A location MailKeeper fetched over IMAP: the only kind a server action may touch.
public struct ServerLocation: Codable, Hashable, Sendable {
    public var account: String
    public var mailbox: String
    public var uidValidity: UInt32
    public var uid: UInt32

    public init(account: String, mailbox: String, uidValidity: UInt32, uid: UInt32) {
        self.account = account
        self.mailbox = mailbox
        self.uidValidity = uidValidity
        self.uid = uid
    }
}

/// Where a restore puts a message and what goes along (ADR-0006 §5).
public struct RestoreTarget: Codable, Hashable, Sendable {
    public var account: String
    public var mailbox: String
    /// System flags only (\Seen \Answered \Flagged \Draft): \Deleted never goes back up.
    public var flags: [String]
    /// Gmail labels added after the APPEND (empty for other providers).
    public var labels: [String]
    /// INTERNALDATE for the APPEND; nil = now. Proton ignores it and uses the Date header.
    public var internalDate: Date?

    public init(account: String, mailbox: String, flags: [String] = [], labels: [String] = [], internalDate: Date? = nil) {
        self.account = account
        self.mailbox = mailbox
        self.flags = flags
        self.labels = labels
        self.internalDate = internalDate
    }

    /// The flags a restore carries: the four system flags a client sets, in canonical spelling.
    public static func restorableFlags(_ flags: [String]) -> [String] {
        let canonical = ["\\seen": "\\Seen", "\\answered": "\\Answered", "\\flagged": "\\Flagged", "\\draft": "\\Draft"]
        var out: [String] = []
        for f in flags { if let c = canonical[f.lowercased()], !out.contains(c) { out.append(c) } }
        return out
    }

    /// Gmail labels a restore adds: the user's own plus Inbox, Important and Starred — never
    /// Trash, Spam, Sent or Draft (Gmail manages those itself).
    public static func restorableLabels(_ labels: [String]) -> [String] {
        let system: Set<String> = ["\\inbox", "\\important", "\\starred"]
        return labels.filter { !$0.isEmpty && (!$0.hasPrefix("\\") || system.contains($0.lowercased())) }
    }
}

/// What the plan sheet chose for a restore.
public struct RestoreOptions: Codable, Hashable, Sendable {
    public enum Destination: Codable, Hashable, Sendable {
        /// Back to where it was last seen, in each account it is no longer in.
        case original
        /// One mailbox for all (imported mail has no server origin).
        case mailbox(account: String, mailbox: String)
    }

    public var destination: Destination
    /// The original arrival date (default), or now — then it counts as newly arrived.
    public var keepDate: Bool

    public init(destination: Destination = .original, keepDate: Bool = true) {
        self.destination = destination
        self.keepDate = keepDate
    }
}

/// One message (and, for server actions, one of its locations) in a job.
public struct ActionItem: Codable, Hashable, Sendable, Identifiable {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// Waiting to run.
        case planned
        /// Taken by the executor; after a crash its outcome is unknown and re-checked on resume.
        case claimed
        case done
        case failed
        /// A precondition did not hold (reason says which); never run.
        case skipped
    }

    /// Position in the job, stable for its lifetime.
    public var id: Int
    public var sha256: String
    /// The Message-ID header, re-checked on the server right before acting.
    public var messageID: String?
    public var size: Int
    public var date: Date?
    public var location: ServerLocation?
    /// The message's archive identity (archive actions; stable across index rebuilds).
    public var identity: String?
    /// Restore: where it goes.
    public var target: RestoreTarget?
    public var state: State
    /// Why it was skipped or failed — shown to the user.
    public var reason: String?

    public init(id: Int, sha256: String, messageID: String?, size: Int, date: Date?, location: ServerLocation?,
                identity: String? = nil, target: RestoreTarget? = nil, state: State = .planned, reason: String? = nil) {
        self.identity = identity
        self.target = target
        self.id = id
        self.sha256 = sha256
        self.messageID = messageID
        self.size = size
        self.date = date
        self.location = location
        self.state = state
        self.reason = reason
    }
}

public struct ActionJob: Codable, Sendable, Identifiable {
    public var id: UUID
    public var kind: ActionKind
    /// "Absender news@example.com auf dem Server löschen"
    public var title: String
    /// The search it was planned from (ADR-0008), for the record.
    public var query: String?
    public var graceDays: Int?
    /// Restore: what the plan sheet chose (for replanning and the record).
    public var restore: RestoreOptions?
    public var created: Date
    public var items: [ActionItem]
    public var cancelled = false

    public init(id: UUID = UUID(), kind: ActionKind, title: String, query: String?, graceDays: Int?,
                restore: RestoreOptions? = nil, created: Date = Date(), items: [ActionItem]) {
        self.restore = restore
        self.id = id
        self.kind = kind
        self.title = title
        self.query = query
        self.graceDays = graceDays
        self.created = created
        self.items = items
    }

    public var open: [ActionItem] { items.filter { $0.state == .planned || $0.state == .claimed } }
    public var isFinished: Bool { cancelled || open.isEmpty }

    public func count(_ state: ActionItem.State) -> Int { items.reduce(0) { $1.state == state ? $0 + 1 : $0 } }

    /// Size of what would run (planned and claimed items).
    public var openBytes: Int64 { open.reduce(Int64(0)) { $0 + Int64($1.size) } }

    /// Skip and failure reasons with counts, most common first.
    public var reasons: [(reason: String, count: Int)] {
        Self.tally(items.filter { $0.state == .skipped || $0.state == .failed }.map { $0.reason ?? "—" })
    }

    /// Remarks on items that were done ("lag bereits dort", labels that no longer exist).
    public var notes: [(reason: String, count: Int)] {
        Self.tally(items.filter { $0.state == .done }.compactMap(\.reason))
    }

    private static func tally(_ reasons: [String]) -> [(reason: String, count: Int)] {
        var counts: [String: Int] = [:]
        for r in reasons { counts[r, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { ($0.key, $0.value) }
    }
}

/// `<archive>/queue/<job>.jsonl` (0600): the job as its first line, then one line per state
/// change — appended and synced, never rewritten, so a crash loses at most the line being
/// written and resuming replays the rest. A file whose first line cannot be read is moved to
/// `queue/broken/` (kept, not used).
public struct ActionStore: Sendable {
    public let directory: URL

    public init(layout: ArchiveLayout) {
        directory = layout.root.appending(path: "queue", directoryHint: .isDirectory)
    }

    private struct Line: Codable {
        enum Kind: String, Codable { case job, state, cancel }
        var type: Kind
        var job: ActionJob?
        var item: Int?
        var state: ActionItem.State?
        var reason: String?
        var time: Double
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private func file(_ id: UUID) -> URL { directory.appending(path: "\(id.uuidString).jsonl") }

    public func create(_ job: ActionJob) throws {
        try makePrivateDirectory(directory)
        try append(Line(type: .job, job: job, time: Date().timeIntervalSince1970), to: file(job.id), create: true)
    }

    public func record(job: UUID, item: Int, state: ActionItem.State, reason: String? = nil) throws {
        try append(Line(type: .state, item: item, state: state, reason: reason, time: Date().timeIntervalSince1970),
                   to: file(job), create: false)
    }

    /// Stops a job: what is still planned will not run (claimed items are re-checked first).
    public func cancel(job: UUID) throws {
        try append(Line(type: .cancel, time: Date().timeIntervalSince1970), to: file(job), create: false)
    }

    public func remove(_ id: UUID) throws {
        try? FileManager.default.removeItem(at: file(id))
    }

    /// All jobs, newest first, and the files that could not be read (moved aside).
    public func load() -> (jobs: [ActionJob], broken: [URL]) {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { $0.hasSuffix(".jsonl") }
        var jobs: [ActionJob] = []
        var broken: [URL] = []
        for name in names {
            let url = directory.appending(path: name)
            if let job = try? Self.replay(url) {
                jobs.append(job)
            } else {
                let aside = directory.appending(path: "broken", directoryHint: .isDirectory)
                try? makePrivateDirectory(aside)
                let target = aside.appending(path: name)
                if rename(url.path, target.path) == 0 { broken.append(target) }
            }
        }
        return (jobs.sorted { $0.created > $1.created }, broken)
    }

    public func load(_ id: UUID) throws -> ActionJob { try Self.replay(file(id)) }

    static func replay(_ url: URL) throws -> ActionJob {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let lines = try readFile(url.path).split(separator: 0x0A, omittingEmptySubsequences: true)
        guard let first = lines.first, let head = try? decoder.decode(Line.self, from: Data(first)),
              head.type == .job, var job = head.job else { throw ArchiveError.io("unreadable job", path: url.path) }
        for raw in lines.dropFirst() {
            guard let line = try? decoder.decode(Line.self, from: Data(raw)) else { continue }  // torn last line
            switch line.type {
            case .state:
                guard let i = line.item, job.items.indices.contains(i), let state = line.state else { continue }
                job.items[i].state = state
                job.items[i].reason = line.reason
            case .cancel:
                job.cancelled = true
            case .job:
                continue
            }
        }
        return job
    }

    private func append(_ line: Line, to url: URL, create: Bool) throws {
        var data = try Self.encoder.encode(line)
        data.append(0x0A)
        let flags = O_WRONLY | O_APPEND | O_CLOEXEC | (create ? O_CREAT | O_EXCL : 0)
        let fd = open(url.path, flags, 0o600)
        guard fd >= 0 else { throw ArchiveError.io("open: \(String(cString: strerror(errno)))", path: url.path) }
        defer { close(fd) }
        // A torn last line (crash mid-write) is terminated first, or this line would be glued to it.
        if !create, let last = Self.lastByte(url), last != 0x0A { _ = write(fd, [UInt8(0x0A)], 1) }
        try data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ArchiveError.io("write: \(String(cString: strerror(errno)))", path: url.path)
                }
                offset += n
            }
        }
        guard fsync(fd) == 0 else { throw ArchiveError.io("fsync", path: url.path) }
    }

    private static func lastByte(_ url: URL) -> UInt8? {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var byte: UInt8 = 0
        let end = lseek(fd, 0, SEEK_END)
        guard end > 0, lseek(fd, end - 1, SEEK_SET) >= 0, read(fd, &byte, 1) == 1 else { return nil }
        return byte
    }
}

/// `~/Library/Logs/MailKeeper/audit.jsonl` (0600): what MailKeeper did, metadata only — no
/// subject, no sender, no content (ADR-0006).
public struct AuditLog: Sendable {
    public struct Entry: Codable, Sendable, Equatable {
        public var time: Double
        public var job: UUID
        public var action: ActionKind
        public var result: ActionItem.State
        public var account: String?
        public var mailbox: String?
        public var uidValidity: UInt32?
        public var uid: UInt32?
        public var sha256: String
        public var reason: String?
    }

    public let url: URL

    public init(url: URL = AuditLog.defaultURL) {
        self.url = url
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs/MailKeeper/audit.jsonl")
    }

    /// `location`: where a restore put the message (its new UID), for the record.
    public func append(job: ActionJob, item: ActionItem, at location: ServerLocation? = nil) throws {
        let place = location ?? item.location
        let entry = Entry(time: Date().timeIntervalSince1970, job: job.id, action: job.kind, result: item.state,
                          account: place?.account ?? item.target?.account,
                          mailbox: place?.mailbox ?? item.target?.mailbox,
                          uidValidity: place?.uidValidity, uid: place?.uid,
                          sha256: item.sha256, reason: item.reason)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        try makePrivateDirectory(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)  // read: the last byte
        guard fd >= 0 else { throw ArchiveError.io("open: \(String(cString: strerror(errno)))", path: url.path) }
        defer { close(fd) }
        // a torn last line (crash mid-write) is terminated first, or this entry would be glued to it
        let end = lseek(fd, 0, SEEK_END)
        if end > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, end - 1) == 1, last != 0x0A { _ = write(fd, [UInt8(0x0A)], 1) }
        }
        try data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ArchiveError.io("audit write", path: url.path)
                }
                offset += n
            }
        }
        _ = fsync(fd)
    }

    public func entries() -> [Entry] {
        guard let data = try? readFile(url.path) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(Entry.self, from: Data($0)) }
    }
}
