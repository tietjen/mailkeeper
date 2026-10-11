import Foundation

public enum IngestResult: Sendable, Equatable {
    /// A message not seen before was added.
    case newMessage(Int64)
    /// A known message was found at a new location (another folder/account, or new bytes).
    case newLocation(Int64)
    /// The location was already known; flags/labels/last-seen were refreshed.
    case unchanged(Int64)

    public var messageID: Int64 {
        switch self { case .newMessage(let id), .newLocation(let id), .unchanged(let id): id }
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
    public let layout: ArchiveLayout
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
        switch mode {
        case .live: sha = try blobs.put(data).sha256
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
            let parsed = MIMEParser.parse(data)
            let identity = try resolveIdentity(parsed, sha: sha)
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
        guard base.hasPrefix("mid:"),
              let (from, subject) = try db.queryOne("SELECT from_addr, subject FROM messages WHERE identity = ?",
                                                    [.text(base)], { ($0.text(0), $0.text(1)) })
        else { return base }
        if Self.sameMessage(from: from, subject: subject, as: p) { return base }
        return base + "|" + Self.fallbackIdentity(p, sha: sha)
    }

    static func sameMessage(from: String?, subject: String?, as p: ParsedMessage) -> Bool {
        let norm = { (s: String?) in collapseWhitespace((s ?? "").lowercased()) }
        return norm(from) == norm(p.from.first?.address) && norm(subject) == norm(p.subject)
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
    public func knownUIDs(account: String, mailbox: String, uidValidity: UInt32) throws -> Set<UInt32> {
        Set(try db.query("SELECT uid FROM locations WHERE account_id = ? AND mailbox = ? AND uid_validity = ? AND uid IS NOT NULL",
                         [.text(account), .text(mailbox), .int(Int64(uidValidity))]) { UInt32(truncatingIfNeeded: $0.int(0)) })
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
