import Foundation

public enum IngestResult: Sendable, Equatable {
    /// A message not seen before was added.
    case newMessage(Int64)
    /// A known message was found at a new location (another folder/account, or new bytes).
    case newLocation(Int64)
    /// The location was already known; flags/labels/last-seen were refreshed.
    case unchanged(Int64)
    /// The message was deleted from the archive for good (tombstone): nothing was stored.
    case tombstoned

    public var messageID: Int64 {
        switch self {
        case .newMessage(let id), .newLocation(let id), .unchanged(let id): id
        case .tombstoned: -1
        }
    }
}

public struct AccountInfo: Sendable, Equatable {
    public var id: String
    public var kind: String
    public var name: String

    public init(id: String, kind: String, name: String) {
        self.id = id
        self.kind = kind
        self.name = name
    }
}

/// Outcome of an index rebuild. Missing or damaged blobs do not stop a rebuild; they are listed.
public struct RebuildReport: Sendable, Equatable {
    public var locations = 0
    public var missingBlobs: [String] = []
    public var damagedBlobs: [String] = []
    public var skippedEvents = 0
}

/// The single writer of an archive: holds the archive lock, the write connection, the blob
/// store and the journal. Order per message (ADR-0001, blobs + journal are the truth):
/// blob durable → journal event → journal fsync → index commit.
public actor ArchiveWriter {
    public nonisolated let layout: ArchiveLayout
    private let lock: ArchiveLock
    private var db: Database
    private let journal: Journal
    private let blobs: BlobStore

    public init(layout: ArchiveLayout) throws {
        self.layout = layout
        lock = try ArchiveLock(layout)
        layout.removeTemporaryFiles()  // only the lock holder may touch staging files
        db = try Database(path: layout.indexURL.path)
        try Schema.migrate(db)
        journal = Journal(root: layout.journalURL)
        blobs = layout.blobs
    }

    // MARK: Accounts

    public func register(_ account: AccountInfo) throws {
        let exists = try db.queryOne("SELECT 1 FROM accounts WHERE id = ? AND kind != 'unknown'", [.text(account.id)]) { _ in true } ?? false
        guard !exists else { return }
        try journal.append(.account(account.id, kind: account.kind, name: account.name))
        try journal.sync()
        try upsertAccount(account, time: Date().timeIntervalSince1970)
    }

    /// Inserts an account or upgrades a placeholder created for a location without account event.
    private func upsertAccount(_ a: AccountInfo, time: Double) throws {
        try db.run("""
            INSERT INTO accounts(id, kind, display_name, created) VALUES (?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, display_name = excluded.display_name
            WHERE accounts.kind = 'unknown'
            """, [.text(a.id), .text(a.kind), .text(a.name), .double(time)])
    }

    // MARK: Ingest

    private enum Mode {
        case live
        case replay(sha256: String, intact: Bool)
    }

    /// Ingests a batch in one transaction (fast imports). The journal is fsync'ed before the
    /// index commits, so a crash can leave journal events without index rows (a rebuild adds
    /// them) but never index rows without journal events.
    public func ingest(_ batch: [(data: Data, location: LocationInfo)]) throws -> [IngestResult] {
        let now = Date().timeIntervalSince1970
        return try db.transaction {
            let results = try batch.map { try ingestOne($0.data, at: $0.location, mode: .live, time: now) }
            try journal.sync()
            return results
        }
    }

    public func ingest(_ data: Data, at location: LocationInfo) throws -> IngestResult {
        try ingest([(data, location)])[0]
    }

    private struct ExistingLocation {
        var id: Int64
        var messageID: Int64
        var sha256: String
        var flags: String
        var labels: String
    }

    private func ingestOne(_ data: Data, at loc: LocationInfo, mode: Mode, time: Double) throws -> IngestResult {
        let sha: String
        var intact = true
        var early: (parsed: ParsedMessage, identity: String)?
        switch mode {
        case .live:
            // A message deleted for good comes back neither by sync nor by re-import: check the
            // tombstones before anything is stored (bytes, then - for unknown bytes - identity).
            let candidate = sha256Hex(data)
            if try isTombstoned("sha:" + candidate) { return .tombstoned }
            if try db.queryOne("SELECT 1 FROM message_blobs WHERE sha256 = ?", [.text(candidate)], { _ in true }) == nil {
                let parsed = MIMEParser.parse(data)
                let identity = try resolveIdentity(parsed, sha: candidate)
                if try isTombstoned("id:" + identity) { return .tombstoned }
                early = (parsed, identity)
            }
            sha = try blobs.put(data).sha256
        case .replay(let s, let ok): sha = s; intact = ok
        }
        try db.run("INSERT OR IGNORE INTO blobs(sha256, size, added, verified) VALUES (?, ?, ?, ?)",
                   [.text(sha), .int(Int64(data.count)), .double(time), intact ? .double(time) : .null])
        // Foreign key target; a rebuild may meet a location whose account event was lost.
        try db.run("INSERT OR IGNORE INTO accounts(id, kind, display_name, created) VALUES (?, 'unknown', ?, ?)",
                   [.text(loc.account), .text(loc.account), .double(time)])

        let flags = loc.flags.joined(separator: " ")
        let labels = loc.labels.joined(separator: "\u{1F}")
        if let existing = try existingLocation(loc) {
            if existing.sha256 == sha {
                if existing.flags != flags || existing.labels != labels {
                    if case .live = mode { try journal.append(.seen(loc, sha256: sha, time: time)) }
                    try db.run("UPDATE locations SET flags = ?, labels = ? WHERE id = ?",
                               [.text(flags), .text(labels), .int(existing.id)])
                }
                try db.run("UPDATE locations SET last_seen = ?, on_server = 1 WHERE id = ?", [.double(time), .int(existing.id)])
                return .unchanged(existing.messageID)
            }
            // Different bytes at a known location (rewritten Maildir file): the newer content wins.
            try db.run("DELETE FROM locations WHERE id = ?", [.int(existing.id)])
        }

        if case .live = mode { try journal.append(.seen(loc, sha256: sha, time: time)) }

        var isNewMessage = false
        var messageRowID = try db.queryOne("SELECT message_id FROM message_blobs WHERE sha256 = ?", [.text(sha)]) { $0.int(0) }
        if messageRowID == nil {
            let parsed = early?.parsed ?? MIMEParser.parse(data)
            let identity = try early?.identity ?? resolveIdentity(parsed, sha: sha)
            messageRowID = try db.queryOne("SELECT id FROM messages WHERE identity = ?", [.text(identity)]) { $0.int(0) }
            if messageRowID == nil {
                messageRowID = try insertMessage(parsed, identity: identity, sha: sha, size: data.count, time: time)
                isNewMessage = true
            }
            try db.run("INSERT OR IGNORE INTO message_blobs(message_id, sha256) VALUES (?, ?)", [.int(messageRowID!), .text(sha)])
        }
        let msgID = messageRowID!
        try db.run("""
            INSERT INTO locations(message_id, sha256, account_id, mailbox, uid_validity, uid, provider_id,
                                  internal_date, flags, labels, on_server, first_seen, last_seen)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
            """, [.int(msgID), .text(sha), .text(loc.account), .text(loc.mailbox),
                  .optional(loc.uidValidity.map(Int64.init)), .optional(loc.uid.map(Int64.init)), .optional(loc.providerID),
                  .optional(loc.internalDate?.timeIntervalSince1970), .text(flags), .text(labels), .double(time), .double(time)])
        // In the trash means on no server (TJ). A trashed message showing up on a server again
        // (moved back there by the user) is live again: out of the trash, journalled.
        if case .live = mode, loc.uid != nil,
           let identity = try db.queryOne("SELECT identity FROM messages WHERE id = ? AND trashed IS NOT NULL", [.int(msgID)], { $0.text(0) }) ?? nil {
            try journal.append(.trash(.untrashed, identity: identity, time: time))
            try applyTrash(.untrashed, identity: identity, time: time)
        }
        return isNewMessage ? .newMessage(msgID) : .newLocation(msgID)
    }

    private func existingLocation(_ loc: LocationInfo) throws -> ExistingLocation? {
        let map = { (r: Row) in
            ExistingLocation(id: r.int(0), messageID: r.int(1), sha256: r.text(2) ?? "", flags: r.text(3) ?? "", labels: r.text(4) ?? "")
        }
        if let uid = loc.uid {
            return try db.queryOne("""
                SELECT id, message_id, sha256, flags, labels FROM locations
                WHERE account_id = ? AND mailbox = ? AND uid_validity IS ? AND uid = ?
                """, [.text(loc.account), .text(loc.mailbox), .optional(loc.uidValidity.map(Int64.init)), .int(Int64(uid))], map)
        }
        if let pid = loc.providerID {
            return try db.queryOne("""
                SELECT id, message_id, sha256, flags, labels FROM locations
                WHERE account_id = ? AND mailbox = ? AND uid IS NULL AND provider_id = ?
                """, [.text(loc.account), .text(loc.mailbox), .text(pid)], map)
        }
        return nil
    }

    /// A shared Message-ID only merges messages that also agree on sender and subject.
    /// Otherwise a reused or forged Message-ID would hide a different mail behind the first one.
    private func resolveIdentity(_ p: ParsedMessage, sha: String) throws -> String {
        let base = Self.identity(p, sha: sha)
        guard base.hasPrefix("mid:") else { return base }
        if let (from, subject) = try db.queryOne("SELECT from_addr, subject FROM messages WHERE identity = ?",
                                                 [.text(base)], { ($0.text(0), $0.text(1)) }) {
            if Self.sameMessage(from: from, subject: subject, as: p) { return base }
            return base + "|" + Self.fallbackIdentity(p, sha: sha)
        }
        // Purged before: the tombstone remembers who sent it and decides as the row would have —
        // a different message reusing the Message-ID is not swallowed by it.
        if let who = try db.queryOne("SELECT who FROM tombstones WHERE key = ?", [.text("id:" + base)], { $0.text(0) }) ?? nil,
           who != Self.senderSubjectKey(from: p.from.first?.address, subject: p.subject) {
            return base + "|" + Self.fallbackIdentity(p, sha: sha)
        }
        return base
    }

    static func sameMessage(from: String?, subject: String?, as p: ParsedMessage) -> Bool {
        let norm = { (s: String?) in collapseWhitespace((s ?? "").lowercased()) }
        return norm(from) == norm(p.from.first?.address) && norm(subject) == norm(p.subject)
    }

    /// What `sameMessage` compares, as a hash: kept in a tombstone instead of sender and subject.
    static func senderSubjectKey(from: String?, subject: String?) -> String {
        let norm = { (s: String?) in collapseWhitespace((s ?? "").lowercased()) }
        return sha256Hex(Data((norm(from) + "\u{1F}" + norm(subject)).utf8))
    }

    private func insertMessage(_ p: ParsedMessage, identity: String, sha: String, size: Int, time: Double) throws -> Int64 {
        let from = p.from.first
        try db.run("""
            INSERT INTO messages(identity, message_id, subject, from_name, from_addr, to_addrs, cc_addrs, date,
                                 in_reply_to, refs, list_id, list_unsubscribe, precedence, auto_submitted,
                                 attachment_count, size, primary_blob, snippet, first_seen)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, [.text(identity), .optional(p.messageID), .optional(p.subject), .optional(from?.name), .optional(from?.address),
                  .text(p.to.map(\.address).joined(separator: ", ")), .text(p.cc.map(\.address).joined(separator: ", ")),
                  .optional(p.date?.timeIntervalSince1970), .optional(p.inReplyTo), .text(p.references.joined(separator: " ")),
                  .optional(p.listID), .bool(p.hasListUnsubscribe), .optional(p.precedence), .optional(p.autoSubmitted),
                  .int(Int64(p.attachments.filter { !$0.isInline }.count)), .int(Int64(size)), .text(sha),
                  .text(SearchText.snippet(p.text)), .double(time)])
        let id = db.lastInsertRowID
        for a in p.attachments {
            try db.run("INSERT INTO attachments(message_id, filename, mime_type, size, content_id, is_inline) VALUES (?, ?, ?, ?, ?, ?)",
                       [.int(id), .optional(a.filename), .text(a.mimeType), .int(Int64(a.size)), .optional(a.contentID), .bool(a.isInline)])
        }
        let people = { (list: [MailAddress]) in list.map { [$0.name, $0.address].compactMap { $0 }.joined(separator: " ") }.joined(separator: " ") }
        try db.run("INSERT INTO messages_fts(rowid, subject, from_text, to_text, body, attachments) VALUES (?, ?, ?, ?, ?, ?)",
                   [.int(id), .text(SearchText.normalize(p.subject ?? "")), .text(SearchText.normalize(people(p.from))),
                    .text(SearchText.normalize(people(p.to + p.cc))), .text(SearchText.normalize(p.text)),
                    .text(SearchText.normalize(p.attachments.compactMap(\.filename).joined(separator: " ")))])
        try Threads.link(db, id: id, messageID: p.messageID,
                         references: Threads.references(inReplyTo: p.inReplyTo, references: p.references, own: p.messageID))
        return id
    }

    /// Message identity (ADR-0001): the Message-ID, else a hash over sender, date, subject and
    /// the start of the text — stable across header rewrites like Proton's.
    static func identity(_ p: ParsedMessage, sha: String) -> String {
        if let id = p.messageID { return "mid:" + id }
        return fallbackIdentity(p, sha: sha)
    }

    static func fallbackIdentity(_ p: ParsedMessage, sha: String) -> String {
        let parts = [p.from.first?.address ?? "", p.date.map { String(Int($0.timeIntervalSince1970)) } ?? "",
                     p.subject ?? "", String(collapseWhitespace(p.text).prefix(4096))]
        // Nothing to identify it by (empty or headerless junk): only identical bytes are the same.
        if parts.allSatisfy(\.isEmpty) { return "sha:" + sha }
        return "h:" + sha256Hex(Data(parts.joined(separator: "\u{1F}").utf8))
    }

    // MARK: Rebuild & verify

    /// Rebuilds the index from journal + blobs into a fresh file, then swaps it in. The fresh
    /// file is built without WAL, so nothing is left behind at the swap. Missing or damaged
    /// blobs are reported, not fatal. Readers notice the replaced file and reopen
    /// (`ArchiveReader` checks the inode).
    // MARK: Attachment text (ADR-0009)

    /// Messages with a PDF attachment and no final result yet (failures of an older extractor
    /// version count as pending), newest first.
    public func pendingAttachmentText(limit: Int, version: Int) throws -> [(id: Int64, sha256: String)] {
        try db.query("SELECT m.id, m.primary_blob FROM messages m WHERE \(AttachmentIndexer.pendingCondition) ORDER BY m.date DESC NULLS LAST, m.id DESC LIMIT ?",
                     [.int(Int64(version)), .int(Int64(limit))]) { ($0.int(0), $0.text(1) ?? "") }
    }

    public func pendingAttachmentTextCount(version: Int) throws -> Int {
        Int(try db.queryOne("SELECT count(*) FROM messages m WHERE \(AttachmentIndexer.pendingCondition)",
                            [.int(Int64(version))]) { $0.int(0) } ?? 0)
    }

    /// Stores the outcome for a message and replaces its searchable text.
    public func setAttachmentText(messageID: Int64, _ result: AttachmentText, version: Int) throws {
        try db.transaction {
            try db.run("DELETE FROM attachment_text_fts WHERE rowid = ?", [.int(messageID)])
            if !result.text.isEmpty {
                try db.run("INSERT INTO attachment_text_fts(rowid, text) VALUES (?, ?)",
                           [.int(messageID), .text(SearchText.normalize(result.text))])
            }
            try db.run("""
                INSERT OR REPLACE INTO attachment_text(message_id, status, chars, detail, extracted, version)
                VALUES (?, ?, ?, ?, ?, ?)
                """, [.int(messageID), .text(result.status.rawValue), .int(Int64(result.text.count)),
                      .optional(result.detail.map { String($0.prefix(500)) }), .double(Date().timeIntervalSince1970),
                      .int(Int64(version))])
        }
    }

    public func rebuildIndex(progress: (@Sendable (Int) -> Void)? = nil) throws -> RebuildReport {
        let fresh = layout.root.appending(path: "index.rebuild.sqlite").path
        let target = layout.indexURL.path
        Self.removeDatabaseFiles(fresh)
        db = try Database(path: fresh, wal: false)  // releases (closes) the live connection
        var report = RebuildReport()
        var missing = Set<String>(), damaged = Set<String>()
        var archiveEvents: [JournalEvent] = []  // trash/purge refer to messages: applied after all seen events
        do {
            try Schema.migrate(db)
            try db.execute("BEGIN IMMEDIATE")
            try journal.replay { event in
                switch event.kind {
                case .account:
                    try upsertAccount(AccountInfo(id: event.account, kind: event.accountKind ?? "unknown",
                                                  name: event.accountName ?? event.account), time: event.time)
                case .seen:
                    guard let sha = event.sha256, BlobStore.isValidSHA(sha), let mailbox = event.mailbox else {
                        report.skippedEvents += 1
                        return
                    }
                    guard let data = try? blobs.read(sha) else {
                        missing.insert(sha)
                        return
                    }
                    let intact = sha256Hex(data) == sha
                    if !intact { damaged.insert(sha) }
                    let loc = LocationInfo(account: event.account, mailbox: mailbox, uidValidity: event.uidValidity,
                                           uid: event.uid, providerID: event.providerID,
                                           internalDate: event.internalDate.map(Date.init(timeIntervalSince1970:)),
                                           flags: event.flags ?? [], labels: event.labels ?? [])
                    do {
                        _ = try ingestOne(data, at: loc, mode: .replay(sha256: sha, intact: intact), time: event.time)
                        report.locations += 1
                    } catch {
                        report.skippedEvents += 1
                    }
                    if report.locations % 1000 == 0 {
                        try db.execute("COMMIT; BEGIN IMMEDIATE")
                        progress?(report.locations)
                    }
                case .gone:
                    try markGoneRow(event)
                case .trashed, .untrashed, .purged:
                    archiveEvents.append(event)
                }
            }
            // by time; equal times keep their journal order
            let ordered = archiveEvents.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
            for event in ordered {
                guard let identity = event.identity else { report.skippedEvents += 1; continue }
                if event.kind == .purged {
                    try applyPurge(identity: identity, shas: event.shas ?? [], locations: event.locations ?? [], who: event.who,
                                   time: event.time)
                    missing.subtract(event.shas ?? [])  // deleted on purpose, not lost
                } else {
                    try applyTrash(event.kind, identity: identity, time: event.time)
                }
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            db = try Database(path: target)  // back to the untouched old index
            Self.removeDatabaseFiles(fresh)
            throw error
        }
        db = try Database(path: ":memory:")  // close the fresh file (rollback journal: no -wal/-shm)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: target + suffix) }
        guard rename(fresh, target) == 0 else {
            db = try Database(path: target)
            throw ArchiveError.io("rename index", path: target)
        }
        Self.removeDatabaseFiles(fresh)
        db = try Database(path: target)  // back to WAL
        report.missingBlobs = missing.sorted()
        report.damagedBlobs = damaged.sorted()
        return report
    }

    /// IMAP locations are identified by UID (they may also carry a provider id such as
    /// X-GM-MSGID); file locations by provider id.
    private func markGoneRow(_ event: JournalEvent) throws {
        if let uid = event.uid {
            try db.run("""
                UPDATE locations SET on_server = 0
                WHERE account_id = ? AND mailbox = ? AND uid_validity IS ? AND uid = ?
                """, [.text(event.account), .optional(event.mailbox), .optional(event.uidValidity.map(Int64.init)), .int(Int64(uid))])
        } else if let pid = event.providerID {
            try db.run("UPDATE locations SET on_server = 0 WHERE account_id = ? AND mailbox = ? AND uid IS NULL AND provider_id = ?",
                       [.text(event.account), .optional(event.mailbox), .text(pid)])
        }
    }

    // MARK: Sync support

    public struct MailboxState: Sendable, Equatable {
        /// UIDVALIDITY values the archive has locations for.
        public var validities: Set<UInt32>
        public var modSeqValidity: UInt32?
        public var highestModSeq: UInt64?
    }

    public func mailboxState(account: String, mailbox: String) throws -> MailboxState {
        let validities = try db.query("""
            SELECT DISTINCT uid_validity FROM locations
            WHERE account_id = ? AND mailbox = ? AND uid_validity IS NOT NULL AND on_server = 1
            """, [.text(account), .text(mailbox)]) { UInt32(truncatingIfNeeded: $0.int(0)) }
        let state = try db.queryOne("SELECT uid_validity, highest_modseq FROM sync_state WHERE account_id = ? AND mailbox = ?",
                                    [.text(account), .text(mailbox)]) { row in
            (UInt32(truncatingIfNeeded: row.int(0)), row.optionalInt(1).map { UInt64(bitPattern: $0) })
        }
        return MailboxState(validities: Set(validities), modSeqValidity: state?.0, highestModSeq: state?.1)
    }

    /// IMAP mailboxes of an account that still have locations on the server.
    public func activeMailboxes(account: String) throws -> [String] {
        try db.query("SELECT DISTINCT mailbox FROM locations WHERE account_id = ? AND on_server = 1 AND uid IS NOT NULL",
                     [.text(account)]) { $0.text(0) ?? "" }
    }

    /// Every UID ever seen in this mailbox/validity (also those gone since — UIDs are never reused).
    /// UIDs the archive has - or deleted for good (tombstones): sync fetches neither.
    public func knownUIDs(account: String, mailbox: String, uidValidity: UInt32) throws -> Set<UInt32> {
        let params: [SQLValue] = [.text(account), .text(mailbox), .int(Int64(uidValidity))]
        return Set(try db.query("""
            SELECT uid FROM locations WHERE account_id = ? AND mailbox = ? AND uid_validity = ? AND uid IS NOT NULL
            UNION SELECT uid FROM tombstone_locations WHERE account_id = ? AND mailbox = ? AND uid_validity = ?
            """, params + params) { UInt32(truncatingIfNeeded: $0.int(0)) })
    }

    // MARK: Archive trash (Phase 4.3, ADR-0006 4)

    private func isTombstoned(_ key: String) throws -> Bool {
        try db.queryOne("SELECT 1 FROM tombstones WHERE key = ?", [.text(key)]) { _ in true } ?? false
    }

    /// Moves messages to the archive trash (hidden from every view, purged after the grace time).
    /// In the trash means on no server: a message with a live server location stays (checked
    /// here, at the moment it happens — a plan may be older than the last sync).
    @discardableResult
    public func trash(_ identities: [String], time: Double = Date().timeIntervalSince1970) throws -> Int {
        try trashDetailed(identities, time: time).newlyTrashed
    }

    public struct TrashOutcome: Sendable, Equatable {
        public var trashed: Set<String> = []
        /// Still on a server: left alone.
        public var onServer: Set<String> = []
        /// No such message (any more) in this archive.
        public var missing: Set<String> = []
        /// Of `trashed`, those that were not in the trash before.
        public var newlyTrashed = 0
    }

    public func trashDetailed(_ identities: [String], time: Double = Date().timeIntervalSince1970) throws -> TrashOutcome {
        var outcome = TrashOutcome()
        var changing: [String] = []
        for identity in identities {
            let state = try db.queryOne("""
                SELECT trashed IS NOT NULL,
                       EXISTS (SELECT 1 FROM locations l WHERE l.message_id = m.id AND l.on_server = 1 AND l.uid IS NOT NULL)
                FROM messages m WHERE identity = ?
                """, [.text(identity)]) { ($0.bool(0), $0.bool(1)) }
            switch state {
            case nil: outcome.missing.insert(identity)
            case (_, true)?: outcome.onServer.insert(identity)
            case (true, false)?: outcome.trashed.insert(identity)  // already there: idempotent
            case (false, false)?: changing.append(identity); outcome.trashed.insert(identity)
            }
        }
        try setTrashed(changing, time: time, kind: .trashed)
        outcome.newlyTrashed = changing.count
        return outcome
    }

    @discardableResult
    public func untrash(_ identities: [String]) throws -> Int {
        let live = try identities.filter {
            try db.queryOne("SELECT 1 FROM messages WHERE identity = ? AND trashed IS NOT NULL", [.text($0)], { _ in true }) != nil
        }
        try setTrashed(live, time: Date().timeIntervalSince1970, kind: .untrashed)
        return live.count
    }

    /// Journal first (synced), then the index - like ingest.
    private func setTrashed(_ changing: [String], time: Double, kind: JournalEvent.Kind) throws {
        guard !changing.isEmpty else { return }
        for identity in changing { try journal.append(.trash(kind, identity: identity, time: time)) }
        try journal.sync()
        try db.transaction {
            for identity in changing { try applyTrash(kind, identity: identity, time: time) }
        }
    }

    private func applyTrash(_ kind: JournalEvent.Kind, identity: String, time: Double) throws {
        try db.run("UPDATE messages SET trashed = ? WHERE identity = ?",
                   [kind == .trashed ? .double(time) : .null, .text(identity)])
    }

    public struct PurgeReport: Sendable, Equatable {
        public var messages = 0
        public var blobs = 0
        public var bytes: Int64 = 0
        /// In the trash but back on a server: taken out of the trash instead of purged.
        public var backOnServer = 0
    }

    /// Deletes messages from the archive for good: rows, search text, blobs no longer referenced.
    /// Tombstones (identity, bytes, IMAP locations) keep sync and import from bringing them back.
    /// Only what is in the archive trash — whatever the caller passes (review 4.7: a stale list
    /// must not purge live mail); a trashed message that is on a server again leaves the trash.
    public func purge(_ identities: [String], time: Double = Date().timeIntervalSince1970) throws -> PurgeReport {
        var report = PurgeReport()
        var candidates: Set<String> = []
        var plans: [(identity: String, shas: [String], tombs: [JournalEvent.Tombstone], who: String?)] = []
        var backOnServer: [String] = []
        for identity in identities {
            guard let (id, live, from, subject) = try db.queryOne("""
                SELECT id, EXISTS (SELECT 1 FROM locations l WHERE l.message_id = m.id AND l.on_server = 1 AND l.uid IS NOT NULL),
                       from_addr, subject
                FROM messages m WHERE identity = ? AND trashed IS NOT NULL
                """, [.text(identity)], { ($0.int(0), $0.bool(1), $0.text(2), $0.text(3)) }) else { continue }
            if live { backOnServer.append(identity); continue }
            let shas = try db.query("SELECT sha256 FROM message_blobs WHERE message_id = ? UNION SELECT sha256 FROM locations WHERE message_id = ?",
                                    [.int(id), .int(id)]) { $0.text(0) ?? "" }
            let tombs = try db.query("""
                SELECT account_id, mailbox, uid_validity, uid FROM locations
                WHERE message_id = ? AND uid IS NOT NULL AND uid_validity IS NOT NULL
                """, [.int(id)]) {
                JournalEvent.Tombstone(account: $0.text(0) ?? "", mailbox: $0.text(1) ?? "",
                                       uidValidity: UInt32(truncatingIfNeeded: $0.int(2)), uid: UInt32(truncatingIfNeeded: $0.int(3)))
            }
            plans.append((identity, shas, tombs, identity.hasPrefix("mid:") ? Self.senderSubjectKey(from: from, subject: subject) : nil))
        }
        if !backOnServer.isEmpty {
            try setTrashed(backOnServer, time: time, kind: .untrashed)
            report.backOnServer = backOnServer.count
        }
        guard !plans.isEmpty else { return report }
        for p in plans { try journal.append(.purged(identity: p.identity, shas: p.shas, locations: p.tombs, who: p.who, time: time)) }
        try journal.sync()
        try db.transaction {
            for p in plans {
                try applyPurge(identity: p.identity, shas: p.shas, locations: p.tombs, who: p.who, time: time)
                candidates.formUnion(p.shas)
                report.messages += 1
            }
        }
        // Blob files after the index commit, and only if nothing refers to them any more.
        for sha in candidates where BlobStore.isValidSHA(sha) {
            let used = try db.queryOne("SELECT 1 FROM message_blobs WHERE sha256 = ? UNION SELECT 1 FROM locations WHERE sha256 = ?",
                                       [.text(sha), .text(sha)]) { _ in true } ?? false
            guard !used else { continue }
            let size = try db.queryOne("SELECT size FROM blobs WHERE sha256 = ?", [.text(sha)]) { $0.int(0) } ?? 0
            try db.run("DELETE FROM blobs WHERE sha256 = ?", [.text(sha)])
            if unlink(blobs.url(for: sha).path) == 0 {
                report.blobs += 1
                report.bytes += size
            }
        }
        return report
    }

    private func applyPurge(identity: String, shas: [String], locations: [JournalEvent.Tombstone], who: String?, time: Double) throws {
        if let id = try db.queryOne("SELECT id FROM messages WHERE identity = ?", [.text(identity)], { $0.int(0) }) {
            try db.run("DELETE FROM messages_fts WHERE rowid = ?", [.int(id)])
            try db.run("DELETE FROM attachment_text_fts WHERE rowid = ?", [.int(id)])
            try db.run("DELETE FROM messages WHERE id = ?", [.int(id)])  // cascades locations, attachments, refs, text
        }
        try db.run("INSERT OR REPLACE INTO tombstones(key, purged, who) VALUES (?, ?, ?)", [.text("id:" + identity), .double(time), .optional(who)])
        for sha in shas { try db.run("INSERT OR REPLACE INTO tombstones(key, purged) VALUES (?, ?)", [.text("sha:" + sha), .double(time)]) }
        for t in locations {
            try db.run("INSERT OR IGNORE INTO tombstone_locations(account_id, mailbox, uid_validity, uid) VALUES (?, ?, ?, ?)",
                       [.text(t.account), .text(t.mailbox), .int(Int64(t.uidValidity)), .int(Int64(t.uid))])
        }
    }

    /// Purges what has been in the trash for longer than `days` (ADR-0006: 30).
    public func purgeExpired(days: Int = 30, now: Date = Date()) throws -> PurgeReport {
        let cutoff = now.timeIntervalSince1970 - Double(days) * 86_400
        let expired = try db.query("SELECT identity FROM messages WHERE trashed IS NOT NULL AND trashed < ?",
                                   [.double(cutoff)]) { $0.text(0) ?? "" }
        return try purge(expired, time: now.timeIntervalSince1970)
    }

    public func onServerUIDs(account: String, mailbox: String, uidValidity: UInt32) throws -> Set<UInt32> {
        Set(try db.query("""
            SELECT uid FROM locations
            WHERE account_id = ? AND mailbox = ? AND uid_validity = ? AND uid IS NOT NULL AND on_server = 1
            """, [.text(account), .text(mailbox), .int(Int64(uidValidity))]) { UInt32(truncatingIfNeeded: $0.int(0)) })
    }

    /// Applies server-side flag/label changes to known locations; journals only real changes.
    /// Returns the number of changed locations.
    public func updateFlags(account: String, mailbox: String, uidValidity: UInt32, _ updates: [RemoteFlags]) throws -> Int {
        guard !updates.isEmpty else { return 0 }
        let now = Date().timeIntervalSince1970
        return try db.transaction {
            var changed = 0
            for u in updates {
                guard let row = try db.queryOne("""
                    SELECT id, sha256, flags, labels, provider_id, internal_date FROM locations
                    WHERE account_id = ? AND mailbox = ? AND uid_validity = ? AND uid = ?
                    """, [.text(account), .text(mailbox), .int(Int64(uidValidity)), .int(Int64(u.uid))], { r in
                        (id: r.int(0), sha: r.text(1) ?? "", flags: r.text(2) ?? "", labels: r.text(3) ?? "",
                         pid: r.text(4), idate: r.optionalDouble(5))
                    }) else { continue }
                let flags = u.flags.joined(separator: " "), labels = u.labels.joined(separator: "\u{1F}")
                guard flags != row.flags || labels != row.labels else { continue }
                let loc = LocationInfo(account: account, mailbox: mailbox, uidValidity: uidValidity, uid: u.uid, providerID: row.pid,
                                       internalDate: row.idate.map(Date.init(timeIntervalSince1970:)), flags: u.flags, labels: u.labels)
                try journal.append(.seen(loc, sha256: row.sha, time: now))
                try db.run("UPDATE locations SET flags = ?, labels = ?, last_seen = ? WHERE id = ?",
                           [.text(flags), .text(labels), .double(now), .int(row.id)])
                changed += 1
            }
            try journal.sync()
            return changed
        }
    }

    /// Marks locations as gone from the server (`uids == nil`: all of that UIDVALIDITY).
    /// The messages stay in the archive. Returns the number of locations newly marked.
    public func markGone(account: String, mailbox: String, uidValidity: UInt32, uids: Set<UInt32>?) throws -> Int {
        let now = Date().timeIntervalSince1970
        return try db.transaction {
            let current = try db.query("""
                SELECT uid FROM locations
                WHERE account_id = ? AND mailbox = ? AND uid_validity = ? AND uid IS NOT NULL AND on_server = 1
                """, [.text(account), .text(mailbox), .int(Int64(uidValidity))]) { UInt32(truncatingIfNeeded: $0.int(0)) }
            let targets = uids.map { set in current.filter(set.contains) } ?? current
            for uid in targets {
                let event = JournalEvent.gone(account: account, mailbox: mailbox, uidValidity: uidValidity, uid: uid, time: now)
                try journal.append(event)
                try markGoneRow(event)
            }
            try journal.sync()
            return targets.count
        }
    }

    // MARK: Categories (Phase 5.4)

    /// Runs the rules over messages that have no category row yet (or one from older rules), one
    /// batch per call; returns how many it looked at (0 = done). Model answers are kept.
    public func classifyHeuristically(batch: Int = 2_000) throws -> Int {
        let rows = try db.query("""
            SELECT m.id, m.from_addr, m.subject, m.list_id, m.list_unsubscribe, m.precedence, m.auto_submitted,
                   EXISTS (SELECT 1 FROM attachments a WHERE a.message_id = m.id AND a.is_inline = 0
                           AND (a.mime_type = 'application/pdf' OR a.filename LIKE '%.pdf'))
            FROM messages m LEFT JOIN classifications c ON c.message_id = m.id
            WHERE c.message_id IS NULL OR (c.source = 'heuristic' AND c.version < ?)
            LIMIT ?
            """, [.int(Int64(Heuristics.version)), .int(Int64(batch))]) { r in
            (r.int(0), HeuristicFeatures(from: r.text(1), subject: r.text(2), listID: r.text(3), listUnsubscribe: r.bool(4),
                                         precedence: r.text(5), autoSubmitted: r.text(6), hasPDF: r.bool(7)))
        }
        guard !rows.isEmpty else { return 0 }
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for (id, features) in rows {
                let result = Heuristics.classify(features)
                try db.run("""
                    INSERT OR REPLACE INTO classifications(message_id, category, source, rule, model, reason, version, created)
                    VALUES (?, ?, 'heuristic', ?, NULL, NULL, ?, ?)
                    """, [.int(id), .optional(result?.category.rawValue), .optional(result?.rule),
                          .int(Int64(Heuristics.version)), .double(now)])
            }
        }
        return rows.count
    }

    /// A model's answer for one message (reason already display-safe and bounded by the caller).
    public func setClassification(messageID: Int64, category: MailCategory, source: ClassificationSource, model: String?, reason: String?) throws {
        try db.run("""
            INSERT OR REPLACE INTO classifications(message_id, category, source, rule, model, reason, version, created)
            SELECT id, ?, ?, NULL, ?, ?, 0, ? FROM messages WHERE id = ?
            """, [.text(category.rawValue), .text(source.rawValue), .optional(model), .optional(reason),
                  .double(Date().timeIntervalSince1970), .int(messageID)])
    }

    /// Locations marked gone that the server lists again (a mailbox missing from one LIST, a
    /// language switch back on Gmail): on the server again, journalled as `seen` with what was
    /// known — and out of the archive trash, which means "on no server".
    public func markPresent(account: String, mailbox: String, uidValidity: UInt32, uids: Set<UInt32>) throws -> Int {
        guard !uids.isEmpty else { return 0 }
        let now = Date().timeIntervalSince1970
        let rows = try db.query("""
            SELECT l.id, l.uid, l.sha256, l.provider_id, l.internal_date, l.flags, l.labels, m.identity, m.trashed IS NOT NULL
            FROM locations l JOIN messages m ON m.id = l.message_id
            WHERE l.account_id = ? AND l.mailbox = ? AND l.uid_validity = ? AND l.uid IS NOT NULL AND l.on_server = 0
            """, [.text(account), .text(mailbox), .int(Int64(uidValidity))]) { r in
            (id: r.int(0), uid: UInt32(truncatingIfNeeded: r.int(1)), sha: r.text(2) ?? "", pid: r.text(3),
             date: r.optionalDouble(4), flags: r.text(5) ?? "", labels: r.text(6) ?? "", identity: r.text(7) ?? "", trashed: r.bool(8))
        }.filter { uids.contains($0.uid) }
        guard !rows.isEmpty else { return 0 }
        try db.transaction {
            for r in rows {
                let loc = LocationInfo(account: account, mailbox: mailbox, uidValidity: uidValidity, uid: r.uid, providerID: r.pid,
                                       internalDate: r.date.map(Date.init(timeIntervalSince1970:)),
                                       flags: r.flags.split(separator: " ").map(String.init),
                                       labels: r.labels.split(separator: "\u{1F}").map(String.init))
                try journal.append(.seen(loc, sha256: r.sha, time: now))
                try db.run("UPDATE locations SET on_server = 1, last_seen = ? WHERE id = ?", [.double(now), .int(r.id)])
                if r.trashed {
                    try journal.append(.trash(.untrashed, identity: r.identity, time: now))
                    try applyTrash(.untrashed, identity: r.identity, time: now)
                }
            }
            try journal.sync()
        }
        return rows.count
    }

    public func setSyncState(account: String, mailbox: String, uidValidity: UInt32, highestModSeq: UInt64?) throws {
        try db.run("""
            INSERT INTO sync_state(account_id, mailbox, uid_validity, highest_modseq, last_sync) VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(account_id, mailbox) DO UPDATE SET uid_validity = excluded.uid_validity,
                highest_modseq = excluded.highest_modseq, last_sync = excluded.last_sync
            """, [.text(account), .text(mailbox), .int(Int64(uidValidity)),
                  .optional(highestModSeq.map { Int64(bitPattern: $0) }), .double(Date().timeIntervalSince1970)])
    }

    static func removeDatabaseFiles(_ path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// Re-hashes every blob; returns the shas that do not match their content and marks them
    /// unverified in the index.
    public func verifyBlobs(progress: (@Sendable (Int) -> Void)? = nil) throws -> [String] {
        let shas = try db.query("SELECT sha256 FROM blobs") { $0.text(0) ?? "" }
        var bad = Set<String>()
        for (n, sha) in shas.enumerated() {
            if (try? blobs.verify(sha)) != true { bad.insert(sha) }
            if n % 1000 == 0 { progress?(n) }
        }
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for sha in shas {
                try db.run("UPDATE blobs SET verified = ? WHERE sha256 = ?", [bad.contains(sha) ? .null : .double(now), .text(sha)])
            }
        }
        return bad.sorted()
    }
}
