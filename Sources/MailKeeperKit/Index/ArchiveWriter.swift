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
        try setHeaderFields(id, p.headers)
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
                case .trashed, .untrashed, .purged, .classified, .memory:
                    archiveEvents.append(event)
                }
            }
            // by time; equal times keep their journal order
            let ordered = archiveEvents.enumerated().sorted { ($0.element.time, $0.offset) < ($1.element.time, $1.offset) }.map(\.element)
            for event in ordered {
                if event.kind == .memory {
                    if let record = event.memory { try applyMemory(record, time: event.time) } else { report.skippedEvents += 1 }
                    continue
                }
                guard let identity = event.identity else { report.skippedEvents += 1; continue }
                if event.kind == .purged {
                    try applyPurge(identity: identity, shas: event.shas ?? [], locations: event.locations ?? [], who: event.who,
                                   time: event.time)
                    missing.subtract(event.shas ?? [])  // deleted on purpose, not lost
                } else if event.kind == .classified {
                    try applyUserDecision(identity: identity, category: event.category, verdict: event.verdict, time: event.time)
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

    /// What LIST said about the account's mailboxes (only those with a role are kept).
    public func setMailboxRoles(account: String, _ boxes: [RemoteMailbox]) throws {
        try db.transaction {
            try db.run("DELETE FROM mailbox_roles WHERE account_id = ?", [.text(account)])
            for box in boxes where !box.specialUse.isEmpty {
                try db.run("INSERT OR REPLACE INTO mailbox_roles(account_id, mailbox, roles) VALUES (?, ?, ?)",
                           [.text(account), .text(box.name), .text(" " + box.specialUse.map(\.rawValue).sorted().joined(separator: " ") + " ")])
            }
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
            WHERE c.message_id IS NULL OR (c.source IN ('heuristic', 'similar') AND c.version < ?)
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
                // an upsert: the user's verdict and a phishing assessment stay
                try db.run("""
                    INSERT INTO classifications(message_id, category, source, rule, model, reason, version, created)
                    VALUES (?, ?, 'heuristic', ?, NULL, NULL, ?, ?)
                    ON CONFLICT(message_id) DO UPDATE SET category = excluded.category, source = 'heuristic', rule = excluded.rule,
                        model = NULL, reason = NULL, version = excluded.version, created = excluded.created
                    """, [.int(id), .optional(result?.category.rawValue), .optional(result?.rule),
                          .int(Int64(Heuristics.version)), .double(now)])
            }
        }
        return rows.count
    }

    /// A model's answer for one message (texts already display-safe and bounded by the caller),
    /// with its phishing assessment (5.6). Never over a category the user gave; the user's
    /// verdict stays.
    public func setClassification(messageID: Int64, category: MailCategory, source: ClassificationSource, model: String?, reason: String?,
                                  phishing: PhishingLevel? = nil, phishingReason: String? = nil, sources: [String] = []) throws {
        try db.run("""
            INSERT INTO classifications(message_id, category, source, rule, model, reason, version, created, phishing, phishing_reason)
            SELECT id, ?, ?, NULL, ?, ?, 0, ?, ?, ? FROM messages
            WHERE id = ? AND id NOT IN (SELECT message_id FROM classifications WHERE source = 'user')
            ON CONFLICT(message_id) DO UPDATE SET
                -- a user's rule keeps its category (6.5b); the model's phishing view still counts
                category = CASE WHEN classifications.source = 'user-rule' THEN classifications.category ELSE excluded.category END,
                source = CASE WHEN classifications.source = 'user-rule' THEN 'user-rule' ELSE excluded.source END,
                rule = CASE WHEN classifications.source = 'user-rule' THEN classifications.rule ELSE NULL END,
                model = CASE WHEN classifications.source = 'user-rule' THEN classifications.model ELSE excluded.model END,
                reason = CASE WHEN classifications.source = 'user-rule' THEN classifications.reason ELSE excluded.reason END,
                version = 0, created = excluded.created,
                phishing = CASE WHEN classifications.verdict = 'ham' THEN NULL ELSE excluded.phishing END,
                phishing_reason = CASE WHEN classifications.verdict = 'ham' THEN NULL ELSE excluded.phishing_reason END
            """, [.text(category.rawValue), .text(source.rawValue), .optional(model), .optional(reason),
                  .double(Date().timeIntervalSince1970), .optional(phishing?.rawValue), .optional(phishingReason), .int(messageID)])
        guard db.changes > 0 else { return }  // the user's category: nothing written, nothing to explain
        // what the model was shown from the memory (6.2, "Warum?"); used items get their last use
        let now = Date().timeIntervalSince1970
        try db.run("DELETE FROM suggestion_sources WHERE message_id = ?", [.int(messageID)])
        for id in Set(sources) {
            try db.run("INSERT OR IGNORE INTO suggestion_sources(message_id, memory_id) VALUES (?, ?)", [.int(messageID), .text(id)])
            try db.run("UPDATE memory_items SET last_used = ? WHERE id = ?", [.double(now), .text(id)])
        }
    }

    /// "Ist Spam": category spam, the user's — journalled, survives a rebuild, no model overrides it.
    public func setUserClassification(identity: String, category: MailCategory?) throws {
        let time = Date().timeIntervalSince1970
        try journal.append(.classified(identity: identity, category: category?.rawValue, verdict: category == .spam ? "spam" : nil, time: time))
        try journal.sync()
        try applyUserDecision(identity: identity, category: category?.rawValue, verdict: category == .spam ? "spam" : nil, time: time)
    }

    /// "Kein Spam": only the verdict — the category stays the model's (and may be asked again);
    /// journalled.
    public func confirmNotSpam(identity: String) throws {
        let time = Date().timeIntervalSince1970
        try journal.append(.classified(identity: identity, category: nil, verdict: "ham", time: time))
        try journal.sync()
        try applyUserDecision(identity: identity, category: nil, verdict: "ham", time: time)
    }

    /// A `classified` event: with a category the user set the category (source user); a verdict
    /// alone ("ham") only marks the verdict.
    private func applyUserDecision(identity: String, category: String?, verdict: String?, time: Double) throws {
        defer { try? refreshExample(identity: identity, time: time) }  // the decision is an example (6.1)
        if let category {
            // "Art ändern" (6.1): another category than spam keeps a "kein Spam", and ends a "Spam"
            try db.run("""
                INSERT INTO classifications(message_id, category, source, rule, model, reason, version, created, verdict)
                SELECT id, ?, 'user', NULL, NULL, NULL, 0, ?, ? FROM messages WHERE identity = ?
                ON CONFLICT(message_id) DO UPDATE SET category = excluded.category, source = 'user', rule = NULL, model = NULL,
                    reason = NULL, created = excluded.created,
                    verdict = CASE WHEN excluded.verdict IS NOT NULL THEN excluded.verdict
                                   WHEN classifications.verdict = 'spam' THEN NULL ELSE classifications.verdict END
                """, [.text(category), .double(time), .optional(verdict), .text(identity)])
        } else {
            try db.run("""
                INSERT INTO classifications(message_id, category, source, rule, model, reason, version, created, verdict)
                SELECT id, NULL, 'heuristic', NULL, NULL, NULL, 0, ?, ? FROM messages WHERE identity = ?
                ON CONFLICT(message_id) DO UPDATE SET verdict = excluded.verdict,
                    -- "kein Spam" is the user's word on phishing too: a model's flag goes (review 5.9 C6)
                    phishing = CASE WHEN excluded.verdict = 'ham' THEN NULL ELSE classifications.phishing END,
                    phishing_reason = CASE WHEN excluded.verdict = 'ham' THEN NULL ELSE classifications.phishing_reason END,
                    -- a "Spam" category ends with "kein Spam", whoever gave it (6.8: a model's stayed and
                    -- kept "kategorie:spam" true); the rules look at the mail again
                    category = CASE WHEN classifications.category = 'spam' AND (excluded.verdict = 'ham' OR classifications.source = 'user')
                                    THEN NULL ELSE classifications.category END,
                    version = CASE WHEN classifications.category = 'spam' AND (excluded.verdict = 'ham' OR classifications.source = 'user')
                                   THEN 0 ELSE classifications.version END,
                    source = CASE WHEN classifications.category = 'spam' AND (excluded.verdict = 'ham' OR classifications.source = 'user')
                                  THEN 'heuristic' ELSE classifications.source END,
                    model = CASE WHEN classifications.category = 'spam' AND (excluded.verdict = 'ham' OR classifications.source = 'user')
                                 THEN NULL ELSE classifications.model END,
                    reason = CASE WHEN classifications.category = 'spam' AND (excluded.verdict = 'ham' OR classifications.source = 'user')
                                  THEN NULL ELSE classifications.reason END,
                    rule = CASE WHEN classifications.category = 'spam' AND (excluded.verdict = 'ham' OR classifications.source = 'user')
                                THEN NULL ELSE classifications.rule END
                """, [.double(time), .optional(verdict), .text(identity)])
        }
    }

    // MARK: Embeddings and similar mails (5.7)

    func setEmbeddingRows(_ rows: [(id: Int64, vector: Data)], model: String) throws {
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for row in rows {
                try db.run("""
                    INSERT OR REPLACE INTO embeddings(message_id, model, dim, vector, created)
                    SELECT id, ?, ?, ?, ? FROM messages WHERE id = ?
                    """, [.text(model), .int(Int64(row.vector.count / 2)), .blob(row.vector), .double(now), .int(row.id)])
            }
        }
    }

    /// A category taken from similar mails: only where the rules left it open and neither a
    /// model nor the user decided. A model answer replaces it; so does a rule change (the row
    /// keeps the rules' version, and `classifyHeuristically` looks at it again); a newer vote
    /// (`SimilarVote.ruleTag` in `rule`) decides it again.
    public func setSimilarClassification(_ items: [(id: Int64, category: MailCategory, reason: String)]) throws {
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for item in items {
                try db.run("""
                    UPDATE classifications SET category = ?, source = 'similar', reason = ?, rule = ?, model = NULL, created = ?
                    WHERE message_id = ? AND category IS NULL AND verdict IS NULL AND source = 'heuristic'
                    """, [.text(item.category.rawValue), .text(item.reason), .text(SimilarVote.ruleTag), .double(now), .int(item.id)])
            }
        }
    }

    /// Rows of an older vote go back to open, to be decided again under the current one.
    public func reopenStaleSimilar() throws -> Int {
        try db.run("""
            UPDATE classifications SET category = NULL, source = 'heuristic', reason = NULL, rule = NULL
            WHERE source = 'similar' AND coalesce(rule, '') != ?
            """, [.text(SimilarVote.ruleTag)])
        return db.changes
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

// MARK: - Memory (6.1, ADR-0005) — here for the private journal and database

extension ArchiveWriter {
    /// A note or term of the user (new, or changed when `id` names one): journalled, so it
    /// survives a rebuild. Returns its id.
    @discardableResult
    public func saveNote(id: String? = nil, kind: MemoryKind, text: String, subject: String = "", scope: String = "") throws -> String {
        guard kind == .preference || kind == .vocabulary else { throw ArchiveError.invalid("Nur Notizen und Begriffe lassen sich schreiben") }
        let clean = Memory.cleanText(text)
        guard !clean.isEmpty else { throw ArchiveError.invalid("Leere Notiz") }
        let record = JournalEvent.MemoryRecord(id: id ?? Memory.newID(), kind: kind.rawValue, scope: scope,
                                               subject: Memory.cleanText(subject), text: clean, active: true)
        let time = Date().timeIntervalSince1970
        try journal.append(.memory(record, time: time))
        try journal.sync()
        try applyMemory(record, time: time)
        return record.id
    }

    /// "Vergessen": the item is no longer used and no longer shown — journalled (also for an
    /// example: the decision on the mail stays, only its use as an example ends).
    public func forgetMemory(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let time = Date().timeIntervalSince1970
        for id in ids { try journal.append(.memory(JournalEvent.MemoryRecord(id: id, active: false), time: time)) }
        try journal.sync()
        try db.transaction {
            for id in ids { try applyMemory(JournalEvent.MemoryRecord(id: id, active: false), time: time) }
        }
    }

    /// Notes and terms from an export file; examples and derived items are not imported (they
    /// belong to the messages and the history of the archive they came from). Returns the count.
    public func importMemory(_ data: Data) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard data.count < 4 << 20, let file = try? decoder.decode(MemoryExport.self, from: data), file.format == "mailkeeper-memory" else {
            throw ArchiveError.invalid("Keine MailKeeper-Gedächtnisdatei")
        }
        let reader = try ArchiveReader(layout: layout)
        let existing = Set(try reader.memoryItems().compactMap { item in
            item.provenance == .user ? "\(item.kind.rawValue)|\(item.subject)|\(item.content.text ?? "")" : nil
        })
        // rules and relations too, checked like the user's own (review 6 R7): what the export wrote
        var rules = Set(try reader.rules().map { $0.query.lowercased() + "|" + $0.action.raw })
        var claimed = Set(try reader.relations().flatMap(\.domains))
        var added = 0
        for item in file.items.prefix(2_000) {
            guard let kind = MemoryKind(rawValue: item.kind) else { continue }
            do {
                switch kind {
                case .preference, .vocabulary:
                    guard let text = item.content.text, !Memory.cleanText(text).isEmpty,
                          !existing.contains("\(kind.rawValue)|\(Memory.cleanText(item.subject))|\(Memory.cleanText(text))") else { continue }
                    try saveNote(kind: kind, text: text, subject: item.subject, scope: item.scope)
                case .rule:
                    guard let query = item.content.query, let action = item.content.action.flatMap(MailRule.Action.init(raw:)),
                          rules.insert(query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|" + action.raw).inserted else { continue }
                    try saveRule(name: item.content.name ?? query, query: query, action: action)
                case .relation:
                    // a domain belongs to one relation: one already claimed keeps the whole entry out
                    guard let name = item.content.name, let domains = item.content.domains.map(Relations.normalize), !domains.isEmpty,
                          claimed.isDisjoint(with: domains) else { continue }
                    try saveRelation(name: name, domains: domains, since: item.content.since.map(Date.init(timeIntervalSince1970:)),
                                     until: item.content.until.map(Date.init(timeIntervalSince1970:)))
                    claimed.formUnion(domains)
                default:
                    continue
                }
                added += 1
            } catch ArchiveError.invalid {
                continue  // an entry the checks refuse (no valid search, no name): the others still come
            }
        }
        return added
    }

    /// A `memory` event, live or in a rebuild.
    func applyMemory(_ record: JournalEvent.MemoryRecord, time: Double) throws {
        if !record.active, record.content == nil {
            try db.run("UPDATE memory_items SET active = 0, updated = ? WHERE id = ?", [.double(time), .text(record.id)])
            return
        }
        guard let kind = record.kind else { return }
        let body: MemoryContent
        if let content = record.content { body = content } else if let text = record.text { body = MemoryContent(text: text) } else { return }
        let content = String(decoding: try JSONEncoder().encode(body), as: UTF8.self)
        // a rejected suggestion is stored inactive: it keeps its domains from being suggested again
        try db.run("""
            INSERT INTO memory_items(id, kind, scope, subject, content, provenance, sources, created, updated, active)
            VALUES (?, ?, ?, ?, ?, 'user', '', ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET kind = excluded.kind, scope = excluded.scope, subject = excluded.subject,
                content = excluded.content, updated = excluded.updated, active = excluded.active
            """, [.text(record.id), .text(kind), .text(record.scope ?? ""), .text(record.subject ?? ""), .text(content),
                  .double(time), .double(time), .bool(record.active)])
    }

    /// A relationship the user confirmed, edited or ended (ADR-0010 §6) — journalled. Domains are
    /// registrable domains, lowercased; the name is bounded. Returns its id.
    @discardableResult
    public func saveRelation(id: String? = nil, name: String, domains: [String], since: Date?, until: Date?) throws -> String {
        let record = try Self.relationRecord(id: id, name: name, domains: domains, since: since, until: until, active: true)
        let time = Date().timeIntervalSince1970
        try journal.append(.memory(record, time: time))
        try journal.sync()
        try applyMemory(record, time: time)
        return record.id
    }

    /// "Ablehnen": these domains are not suggested again (journalled, an inactive relation).
    public func rejectRelation(name: String, domains: [String]) throws {
        let record = try Self.relationRecord(id: nil, name: name, domains: domains, since: nil, until: nil, active: false)
        let time = Date().timeIntervalSince1970
        try journal.append(.memory(record, time: time))
        try journal.sync()
        try applyMemory(record, time: time)
    }

    static func relationRecord(id: String?, name: String, domains: [String], since: Date?, until: Date?, active: Bool) throws -> JournalEvent.MemoryRecord {
        let clean = Memory.cleanText(name).replacingOccurrences(of: "\n", with: " ")
        let list = Relations.normalize(domains)
        guard !clean.isEmpty else { throw ArchiveError.invalid("Die Beziehung braucht einen Namen") }
        guard !list.isEmpty else { throw ArchiveError.invalid("Die Beziehung braucht mindestens eine Domain, z. B. sparkasse.de") }
        var content = MemoryContent(name: String(clean.prefix(120)), domains: list,
                                    since: since?.timeIntervalSince1970, until: until?.timeIntervalSince1970)
        content.rejected = active ? nil : true  // "Ablehnen", not "Vergessen" (review 6 S3)
        return JournalEvent.MemoryRecord(id: id ?? "rel:" + UUID().uuidString.lowercased(), kind: MemoryKind.relation.rawValue, scope: "",
                                         subject: "domain:" + list[0], active: active, content: content)
    }

    /// The example of a decided message, after each decision (live and in a rebuild): a new
    /// decision is new feedback, so a forgotten example comes back with it.
    func refreshExample(identity: String, time: Double) throws {
        try db.run("""
            INSERT INTO memory_items(id, kind, subject, content, provenance, sources, created, updated)
            \(Memory.exampleSelect) WHERE m.identity = ? AND (c.source = 'user' OR c.verdict IS NOT NULL)
            ON CONFLICT(id) DO UPDATE SET subject = excluded.subject, content = excluded.content, updated = ?, active = 1
            """, [.text(identity), .double(time)])
    }
}

// MARK: - Header fields for the relationship register (6.3)

extension ArchiveWriter {
    /// Version of what `setHeaderFields` extracts; a higher one re-reads every header.
    public static let headerFieldsVersion = 1

    func setHeaderFields(_ id: Int64, _ headers: HeaderList) throws {
        let auth = AuthResults.parse(headers["Authentication-Results"])
        try db.run("""
            UPDATE messages SET auth_server = ?, auth_dkim = ?, auth_spf = ?, auth_dmarc = ?, auth_from = ?, delivered_to = ?, headers_v = ?
            WHERE id = ?
            """, [.optional(auth?.server), .optional(auth?.dkim), .optional(auth?.spf), .optional(auth?.dmarc), .optional(auth?.fromDomain),
                  .optional(DeliveredTo.address(headers)), .int(Int64(Self.headerFieldsVersion)), .int(id)])
    }

    /// Older messages: reads only the header of the primary blob, `batch` at a time. Returns how
    /// many it looked at (0 = done).
    public func indexHeaderFields(batch: Int = 500) throws -> Int {
        let rows = try db.query("SELECT id, primary_blob FROM messages WHERE headers_v IS NULL OR headers_v < ? LIMIT ?",
                                [.int(Int64(Self.headerFieldsVersion)), .int(Int64(batch))]) { ($0.int(0), $0.text(1) ?? "") }
        guard !rows.isEmpty else { return 0 }
        try db.transaction {
            for (id, sha) in rows {
                let head = (try? blobs.readHead(sha)) ?? Data()
                try setHeaderFields(id, HeaderParser.parse(head).0)
            }
        }
        return rows.count
    }
}

// MARK: - Inbox screening (6.4)

extension ArchiveWriter {
    /// Marks messages as looked at by the screening, with the register's or the own server's
    /// warning (derived data, not journalled).
    /// After the register changed (a relation confirmed, extended, ended, forgotten): the warnings
    /// of screened mails are computed again — a domain added to a relation is no look-alike any
    /// more, a new relation can make another mail one (review 6 S1). Returns how many changed.
    @discardableResult
    public func refreshWarnings() throws -> Int {
        let reader = try ArchiveReader(layout: layout)
        let relations = try reader.relations(), servers = try reader.ownAuthServers()
        // the warnings that show (and those of the last year that could show): not every mail
        // ever screened — that grows with each sync (review 6.7 S3)
        let rows = try db.query("""
            SELECT c.message_id, c.warning FROM classifications c JOIN messages m ON m.id = c.message_id
            WHERE c.warning IS NOT NULL OR (c.screened IS NOT NULL AND m.date >= ?)
            """, [.double(Date().addingTimeInterval(-365 * 86_400).timeIntervalSince1970)]) { ($0.int(0), $0.text(1)) }
        var updates: [(Int64, String?)] = []
        for (n, (id, old)) in rows.enumerated() {
            if n % 256 == 0, Task.isCancelled { throw CancellationError() }  // a sync is waiting for the writer
            // no public addresses: the warning does not depend on first contact, which costs a
            // sender profile per mail (review 6 R2)
            let check = try reader.relationCheck(of: id, relations: relations, servers: servers, publicAddresses: [])
            var warning: String?
            if check.lookAlike != nil { warning = "lookalike" } else if case .failed = check.server { warning = "serverfail" }
            if warning != old { updates.append((id, warning)) }
        }
        try db.transaction {
            for (id, warning) in updates { try db.run("UPDATE classifications SET warning = ? WHERE message_id = ?", [.optional(warning), .int(id)]) }
        }
        return updates.count
    }

    /// `markScreened: false` stores only the warning (a model's candidate is marked after its answer).
    public func setScreened(_ items: [ScreeningCandidate], markScreened: Bool = true) throws {
        guard !items.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for item in items {
                if markScreened {
                    try db.run("UPDATE classifications SET screened = ?, warning = ? WHERE message_id = ?",
                               [.double(now), .optional(item.warning), .int(item.id)])
                } else {
                    try db.run("UPDATE classifications SET warning = ? WHERE message_id = ?", [.optional(item.warning), .int(item.id)])
                }
            }
        }
    }
}

// MARK: - Rules (6.5b)

extension ArchiveWriter {
    /// A rule the user accepted or wrote: journalled. The query must be valid search language and
    /// not empty (a rule over everything is no rule). Returns its id.
    @discardableResult
    public func saveRule(id: String? = nil, name: String, query: String, action: MailRule.Action) throws -> String {
        let record = try Self.ruleRecord(id: id, name: name, query: query, action: action, active: true)
        let time = Date().timeIntervalSince1970
        try journal.append(.memory(record, time: time))
        try journal.sync()
        try applyMemory(record, time: time)
        return record.id
    }

    /// "Ablehnen": this suggestion does not come again (an inactive rule, journalled).
    public func rejectRule(name: String, query: String, action: MailRule.Action) throws {
        let record = try Self.ruleRecord(id: nil, name: name, query: query, action: action, active: false)
        let time = Date().timeIntervalSince1970
        try journal.append(.memory(record, time: time))
        try journal.sync()
        try applyMemory(record, time: time)
    }

    static func ruleRecord(id: String?, name: String, query: String, action: MailRule.Action, active: Bool) throws -> JournalEvent.MemoryRecord {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (try? QueryParser.parse(q + " ").root) != nil else { throw ArchiveError.invalid("Die Regel braucht eine gültige, nicht leere Suche, z. B. sender:news@shop.de") }
        let clean = Memory.cleanText(name).replacingOccurrences(of: "\n", with: " ")
        var content = MemoryContent(name: String((clean.isEmpty ? q : clean).prefix(160)), query: String(q.prefix(600)), action: action.raw)
        content.rejected = active ? nil : true  // "Ablehnen", not "Löschen": only that keeps it from coming back (review 6 R3)
        return JournalEvent.MemoryRecord(id: id ?? "rule:" + UUID().uuidString.lowercased(), kind: MemoryKind.rule.rawValue, scope: "",
                                         subject: "rule", active: active, content: content)
    }

    /// Before the screening of new mail (6.4): the rules and the user's category rules first —
    /// the candidates are mails with a classification row, which only the rules give a new mail
    /// (review 6.7 B1: otherwise each sync screened the mail of the sync before).
    public func prepareForScreening() throws {
        while try classifyHeuristically() > 0 {}
        _ = try applyCategoryRules()
    }

    /// Category rules label their mails (derived, re-applied after a rebuild): over the rules'
    /// own categories, similarity and models, never over the user's decision on a single mail.
    /// Mails of a rule that is gone or changed go back to the rules. Returns how many changed.
    @discardableResult
    public func applyCategoryRules() throws -> Int {
        let reader = try ArchiveReader(layout: layout)
        let rules = try reader.rules().filter { if case .category = $0.action { $0.active } else { false } }
        var changed = 0
        try db.transaction {
            // stale: a rule forgotten, or its query no longer matches
            let ids = rules.map(\.id)
            let marks = ids.isEmpty ? "''" : Array(repeating: "?", count: ids.count).joined(separator: ",")
            try db.run("""
                UPDATE classifications SET category = NULL, source = 'heuristic', rule = NULL, reason = NULL, version = 0
                WHERE source = 'user-rule' AND coalesce(rule, '') NOT IN (\(marks))
                """, ids.map { .text($0) })
            changed += db.changes
            for rule in rules {
                guard case .category(let category) = rule.action else { continue }
                // a query the parser no longer takes stops only its own rule, not the pass after it
                // (review 6 R5); its labels stay until it is fixed or forgotten
                guard let ids = try? reader.messageIDs(MessageFilter(text: "(\(rule.query)) ")),
                      let json = String(data: try JSONEncoder().encode(ids), encoding: .utf8) else { continue }
                // set-based, one statement each (review 6 R5): no longer matching → back to the rules
                try db.run("""
                    UPDATE classifications SET category = NULL, source = 'heuristic', rule = NULL, reason = NULL, version = 0
                    WHERE source = 'user-rule' AND rule = ? AND message_id NOT IN (SELECT value FROM json_each(?))
                    """, [.text(rule.id), .text(json)])
                changed += db.changes
                try db.run("""
                    UPDATE classifications SET category = ?, source = 'user-rule', rule = ?, reason = ?, model = NULL
                    WHERE message_id IN (SELECT value FROM json_each(?)) AND source != 'user'
                      AND NOT (source = 'user-rule' AND rule = ? AND category = ?)
                      AND NOT (? = 'spam' AND coalesce(verdict, '') = 'ham')  -- a rule never calls spam what the user called no spam (6.8)
                    """, [.text(category.rawValue), .text(rule.id), .text(rule.name), .text(json), .text(rule.id), .text(category.rawValue),
                          .text(category.rawValue)])
                changed += db.changes
            }
        }
        return changed
    }
}
