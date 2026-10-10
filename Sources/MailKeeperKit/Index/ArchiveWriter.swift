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

/// The single writer of an archive: holds the archive lock, the write connection, the blob
/// store and the journal. Order per message: blob durable → index row → journal event.
public actor ArchiveWriter {
    public let layout: ArchiveLayout
    private let lock: ArchiveLock
    private var db: Database
    private let journal: Journal
    private let blobs: BlobStore

    public init(layout: ArchiveLayout) throws {
        self.layout = layout
        lock = try ArchiveLock(layout)
        db = try Database(path: layout.indexURL.path)
        try Schema.migrate(db)
        journal = Journal(root: layout.journalURL)
        blobs = layout.blobs
    }

    // MARK: Accounts

    public func register(_ account: AccountInfo) throws {
        let exists = try db.queryOne("SELECT 1 FROM accounts WHERE id = ?", [.text(account.id)]) { _ in true } ?? false
        guard !exists else { return }
        try insertAccount(account, time: Date().timeIntervalSince1970)
        try journal.append(.account(account.id, kind: account.kind, name: account.name))
        journal.sync()
    }

    private func insertAccount(_ a: AccountInfo, time: Double) throws {
        try db.run("INSERT OR IGNORE INTO accounts(id, kind, display_name, created) VALUES (?, ?, ?, ?)",
                   [.text(a.id), .text(a.kind), .text(a.name), .double(time)])
    }

    // MARK: Ingest

    /// Ingests a batch in one transaction (fast imports). Journal events are synced at the end.
    public func ingest(_ batch: [(data: Data, location: LocationInfo)]) throws -> [IngestResult] {
        let results = try db.transaction {
            try batch.map { try ingestOne($0.data, at: $0.location, journalled: true) }
        }
        journal.sync()
        return results
    }

    public func ingest(_ data: Data, at location: LocationInfo) throws -> IngestResult {
        try ingest([(data, location)])[0]
    }

    private func ingestOne(_ data: Data, at loc: LocationInfo, journalled: Bool, time: Double = Date().timeIntervalSince1970) throws -> IngestResult {
        let sha: String
        if journalled {
            sha = try blobs.put(data).sha256
        } else {
            sha = sha256Hex(data)  // rebuild: blob exists already
        }
        try db.run("INSERT OR IGNORE INTO blobs(sha256, size, added, verified) VALUES (?, ?, ?, ?)",
                   [.text(sha), .int(Int64(data.count)), .double(time), .double(time)])

        if let (locID, msgID) = try existingLocation(loc) {
            try db.run("UPDATE locations SET flags = ?, labels = ?, last_seen = ?, on_server = 1 WHERE id = ?",
                       [.text(loc.flags.joined(separator: " ")), .text(loc.labels.joined(separator: "\u{1F}")), .double(time), .int(locID)])
            return .unchanged(msgID)
        }

        var isNewMessage = false
        var messageRowID = try db.queryOne("SELECT message_id FROM message_blobs WHERE sha256 = ?", [.text(sha)]) { $0.int(0) }
        if messageRowID == nil {
            let parsed = MIMEParser.parse(data)
            let identity = Self.identity(parsed, sha: sha)
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
                  .optional(loc.internalDate?.timeIntervalSince1970), .text(loc.flags.joined(separator: " ")),
                  .text(loc.labels.joined(separator: "\u{1F}")), .double(time), .double(time)])
        if journalled { try journal.append(.seen(loc, sha256: sha, time: time)) }
        return isNewMessage ? .newMessage(msgID) : .newLocation(msgID)
    }

    private func existingLocation(_ loc: LocationInfo) throws -> (Int64, Int64)? {
        if let uid = loc.uid {
            return try db.queryOne("""
                SELECT id, message_id FROM locations
                WHERE account_id = ? AND mailbox = ? AND uid_validity IS ? AND uid = ?
                """, [.text(loc.account), .text(loc.mailbox), .optional(loc.uidValidity.map(Int64.init)), .int(Int64(uid))]) { ($0.int(0), $0.int(1)) }
        }
        if let pid = loc.providerID {
            return try db.queryOne("""
                SELECT id, message_id FROM locations
                WHERE account_id = ? AND mailbox = ? AND uid IS NULL AND provider_id = ?
                """, [.text(loc.account), .text(loc.mailbox), .text(pid)]) { ($0.int(0), $0.int(1)) }
        }
        return nil
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
        return id
    }

    /// Message identity (ADR-0001): the Message-ID, else a hash over sender, date, subject and
    /// the start of the text — stable across header rewrites like Proton's.
    static func identity(_ p: ParsedMessage, sha: String) -> String {
        if let id = p.messageID { return "mid:" + id }
        let basis = [p.from.first?.address ?? "", p.date.map { String(Int($0.timeIntervalSince1970)) } ?? "",
                     p.subject ?? "", String(collapseWhitespace(p.text).prefix(4096))].joined(separator: "\u{1F}")
        return "h:" + sha256Hex(Data(basis.utf8))
    }

    // MARK: Rebuild & verify

    /// Rebuilds the index from journal + blobs into a fresh file, then swaps it in. Every
    /// connection to the old file is closed before the swap; readers must reopen afterwards.
    public func rebuildIndex(progress: (@Sendable (Int) -> Void)? = nil) throws -> Int {
        let fresh = layout.root.appending(path: "index.rebuild.sqlite").path
        let target = layout.indexURL.path
        Self.removeDatabaseFiles(fresh)
        db = try Database(path: fresh)  // releases (closes) the live connection
        var count = 0
        do {
            try Schema.migrate(db)
            try db.execute("BEGIN IMMEDIATE")
            try journal.replay { event in
                switch event.kind {
                case .account:
                    try insertAccount(AccountInfo(id: event.account, kind: event.accountKind ?? "unknown",
                                                  name: event.accountName ?? event.account), time: event.time)
                case .seen:
                    guard let sha = event.sha256, let mailbox = event.mailbox else { return }
                    let data = try blobs.read(sha)
                    let loc = LocationInfo(account: event.account, mailbox: mailbox, uidValidity: event.uidValidity,
                                           uid: event.uid, providerID: event.providerID,
                                           internalDate: event.internalDate.map(Date.init(timeIntervalSince1970:)),
                                           flags: event.flags ?? [], labels: event.labels ?? [])
                    _ = try ingestOne(data, at: loc, journalled: false, time: event.time)
                    count += 1
                    if count % 1000 == 0 {
                        try db.execute("COMMIT; BEGIN IMMEDIATE")
                        progress?(count)
                    }
                case .gone:
                    try db.run("""
                        UPDATE locations SET on_server = 0
                        WHERE account_id = ? AND mailbox = ? AND uid_validity IS ? AND uid IS ? AND provider_id IS ?
                        """, [.text(event.account), .optional(event.mailbox), .optional(event.uidValidity.map(Int64.init)),
                              .optional(event.uid.map(Int64.init)), .optional(event.providerID)])
                }
            }
            try db.execute("COMMIT")
        } catch {
            try? db.execute("ROLLBACK")
            db = try Database(path: target)  // back to the untouched old index
            Self.removeDatabaseFiles(fresh)
            throw error
        }
        db = try Database(path: ":memory:")  // close the fresh file cleanly (checkpoints its WAL)
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: target + suffix) }
        guard rename(fresh, target) == 0 else {
            db = try Database(path: target)
            throw ArchiveError.io("rename index", path: target)
        }
        db = try Database(path: target)
        return count
    }

    static func removeDatabaseFiles(_ path: String) {
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// Re-hashes every blob; returns the shas that do not match their content.
    public func verifyBlobs(progress: (@Sendable (Int) -> Void)? = nil) throws -> [String] {
        let shas = try db.query("SELECT sha256 FROM blobs") { $0.text(0) ?? "" }
        var bad: [String] = []
        for (n, sha) in shas.enumerated() {
            if (try? blobs.verify(sha)) != true { bad.append(sha) }
            if n % 1000 == 0 { progress?(n) }
        }
        let now = Date().timeIntervalSince1970
        try db.transaction {
            for sha in shas where !bad.contains(sha) {
                try db.run("UPDATE blobs SET verified = ? WHERE sha256 = ?", [.double(now), .text(sha)])
            }
        }
        return bad
    }
}
