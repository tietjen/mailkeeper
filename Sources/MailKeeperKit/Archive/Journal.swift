import Foundation

/// One metadata event. Blobs carry the message bytes; everything a provider knows beyond them
/// (where a message lives, its flags and labels, that it vanished from the server) is recorded
/// here, append-only. The SQLite index is rebuilt from blobs + journal (ADR-0001).
/// Events never contain message content.
public struct JournalEvent: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case account   // an account was registered
        case seen      // a message was observed at a location
        case gone      // a location no longer exists on the server
    }

    public var kind: Kind
    public var time: Double
    public var account: String
    // account
    public var accountKind: String?
    public var accountName: String?
    // location
    public var mailbox: String?
    public var uidValidity: UInt32?
    public var uid: UInt32?
    public var providerID: String?
    public var sha256: String?
    public var internalDate: Double?
    public var flags: [String]?
    public var labels: [String]?

    enum CodingKeys: String, CodingKey {
        case kind = "k", time = "t", account = "a", accountKind = "ak", accountName = "an"
        case mailbox = "mb", uidValidity = "uv", uid = "u", providerID = "pid", sha256 = "sha"
        case internalDate = "id", flags = "f", labels = "l"
    }

    public static func account(_ id: String, kind: String, name: String, time: Double = Date().timeIntervalSince1970) -> JournalEvent {
        JournalEvent(kind: .account, time: time, account: id, accountKind: kind, accountName: name)
    }

    public static func gone(account: String, mailbox: String, uidValidity: UInt32?, uid: UInt32?, providerID: String? = nil,
                            time: Double = Date().timeIntervalSince1970) -> JournalEvent {
        JournalEvent(kind: .gone, time: time, account: account, mailbox: mailbox, uidValidity: uidValidity, uid: uid, providerID: providerID)
    }

    public static func seen(_ loc: LocationInfo, sha256: String, time: Double = Date().timeIntervalSince1970) -> JournalEvent {
        JournalEvent(kind: .seen, time: time, account: loc.account, mailbox: loc.mailbox,
                     uidValidity: loc.uidValidity, uid: loc.uid, providerID: loc.providerID,
                     sha256: sha256, internalDate: loc.internalDate?.timeIntervalSince1970,
                     flags: loc.flags.isEmpty ? nil : loc.flags, labels: loc.labels.isEmpty ? nil : loc.labels)
    }
}

/// Where a message was observed. `uid`/`uidValidity` for IMAP, `providerID` for files
/// (Maildir unique name, mbox offset) or provider ids (X-GM-MSGID).
public struct LocationInfo: Sendable, Equatable {
    public var account: String
    public var mailbox: String
    public var uidValidity: UInt32?
    public var uid: UInt32?
    public var providerID: String?
    public var internalDate: Date?
    public var flags: [String]
    public var labels: [String]

    public init(account: String, mailbox: String, uidValidity: UInt32? = nil, uid: UInt32? = nil,
                providerID: String? = nil, internalDate: Date? = nil, flags: [String] = [], labels: [String] = []) {
        self.account = account
        self.mailbox = mailbox
        self.uidValidity = uidValidity
        self.uid = uid
        self.providerID = providerID
        self.internalDate = internalDate
        self.flags = flags
        self.labels = labels
    }
}

/// Append-only JSONL files `<root>/<account>/<yyyy-mm>.jsonl` (0600).
/// Not thread-safe: owned by the archive writer.
public final class Journal {
    public let root: URL
    private var handles: [String: FileHandle] = [:]
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    init(root: URL) {
        self.root = root
    }

    deinit {
        for h in handles.values { try? h.close() }
    }

    public func append(_ event: JournalEvent) throws {
        var line = try encoder.encode(event)
        line.append(0x0A)
        let handle = try handleFor(account: event.account, time: event.time)
        do { try handle.write(contentsOf: line) } catch {
            throw ArchiveError.io("journal write", path: root.path)
        }
    }

    /// Flushes appended events to disk (call at the end of a batch, before the index commits).
    public func sync() throws {
        for h in handles.values {
            do { try h.synchronize() } catch { throw ArchiveError.io("journal fsync", path: root.path) }
        }
    }

    /// Replays all events of all accounts in file order (files sorted by name = by month).
    public func replay(_ body: (JournalEvent) throws -> Void) throws {
        let fm = FileManager.default
        guard let accounts = try? fm.contentsOfDirectory(atPath: root.path) else { return }
        let decoder = JSONDecoder()
        // Account registrations first, so every location refers to a known account.
        var deferred: [JournalEvent] = []
        for account in accounts.sorted() {
            let dir = root.appending(path: account)
            let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
            for file in files {
                let data = try readFile(dir.appending(path: file).path)
                for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                    // A torn last line after a crash is skipped, not fatal.
                    guard let event = try? decoder.decode(JournalEvent.self, from: Data(line)) else { continue }
                    if event.kind == .account { try body(event) } else { deferred.append(event) }
                }
            }
        }
        for event in deferred { try body(event) }
    }

    private func handleFor(account: String, time: Double) throws -> FileHandle {
        let month = Self.month(time)
        let key = "\(account)/\(month)"
        if let h = handles[key] { return h }
        let dir = root.appending(path: Self.safeComponent(account))
        try makePrivateDirectory(dir)
        let file = dir.appending(path: "\(month).jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            let fd = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            if fd >= 0 { close(fd) }
        }
        guard let h = FileHandle(forWritingAtPath: file.path) else { throw ArchiveError.io("journal open", path: file.path) }
        let end = try h.seekToEnd()
        // A crash can leave a torn last line. Terminate it, or the next event would be glued
        // to the fragment and both would be lost on replay.
        if end > 0, let reader = FileHandle(forReadingAtPath: file.path) {
            defer { try? reader.close() }
            try reader.seek(toOffset: end - 1)
            if try reader.read(upToCount: 1) != Data([0x0A]) { try h.write(contentsOf: Data([0x0A])) }
        }
        handles[key] = h
        return h
    }

    static func safeComponent(_ s: String) -> String {
        let mapped = String(s.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." ? $0 : "_" })
        // "", "." and ".." would write into journal/ itself or above it.
        return mapped.allSatisfy({ $0 == "." }) ? "_" + mapped.replacingOccurrences(of: ".", with: "_") : mapped
    }

    /// "yyyy-MM" in UTC.
    static func month(_ time: Double) -> String {
        var t = time_t(time)
        var tm = tm()
        gmtime_r(&t, &tm)
        return String(format: "%04d-%02d", Int(tm.tm_year) + 1900, Int(tm.tm_mon) + 1)
    }
}
