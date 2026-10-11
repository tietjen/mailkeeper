import Foundation

public struct MailboxSummary: Sendable, Hashable {
    public var account: String
    public var name: String
    public var count: Int
}

public struct AccountSummary: Sendable, Hashable {
    public var id: String
    public var kind: String
    public var name: String
    public var messageCount: Int
    public var mailboxes: [MailboxSummary]
}

public struct MessageSummary: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var date: Date?
    public var fromName: String?
    public var fromAddress: String?
    public var subject: String?
    public var size: Int
    public var attachmentCount: Int
    public var snippet: String?
    /// Messages in this message's conversation (1 = on its own).
    public var threadCount: Int = 1

    public var fromDisplay: String { fromName ?? fromAddress ?? "" }
}

public struct MessageLocation: Sendable, Hashable {
    public var account: String
    public var mailbox: String
    public var uid: UInt32?
    public var flags: [String]
    public var labels: [String]
    public var internalDate: Date?
    public var onServer: Bool
    public var sha256: String
}

public struct MessageDetail: Sendable {
    public var summary: MessageSummary
    public var messageID: String?
    public var listID: String?
    public var primaryBlob: String
    public var locations: [MessageLocation]
}

public struct ArchiveStats: Sendable, Equatable {
    public var accounts: Int
    /// Messages outside the archive trash.
    public var messages: Int
    public var locations: Int
    public var blobs: Int
    public var blobBytes: Int64
    /// Messages in the archive trash.
    public var trashed = 0
}

/// Cleanup view: messages grouped by sender address, sender domain or mailing list.
public enum GroupMode: String, Sendable, CaseIterable {
    case sender, domain, list
}

public struct MessageGroup: Sendable, Hashable, Identifiable {
    public var mode: GroupMode
    /// Address, domain or List-Id (lowercased).
    public var key: String
    /// A sender name seen in the group.
    public var name: String?
    public var count: Int
    public var bytes: Int64
    public var newest: Date?
    public var oldest: Date?
    /// Messages without \Seen in any location.
    public var unread: Int
    /// Some message offers List-Unsubscribe.
    public var unsubscribe: Bool

    public var id: String { mode.rawValue + ":" + key }

    /// Exactly this group's messages (ADR-0008: sender:, domain:, listid: are exact).
    public var query: String {
        let field = switch mode {
        case .sender: "sender"
        case .domain: "domain"
        case .list: "listid"
        }
        // groups() leaves out keys with a quote; "@" first would be stripped from a bare domain
        let quoted = key.hasPrefix("@") || key.contains(where: { $0.isWhitespace || "()".contains($0) })
        return "\(field):" + (quoted ? "\"\(key)\"" : key)
    }
}

public enum MessageSort: String, Sendable, CaseIterable {
    case date, from, subject, size
}

public struct MessageFilter: Sendable, Equatable {
    public var account: String?
    public var mailbox: String?
    /// Query text (ADR-0008), e.g. `from:amazon has:pdf after:2024`.
    public var text: String?
    /// A saved search's query; combined with `text` by AND, each parsed on its own.
    public var base: String?
    /// Further queries AND-ed on (a cleanup group's exact query, an overview bucket).
    public var also: [String] = []
    /// Messages in the archive trash are hidden unless asked for (the trash view).
    public var trash: TrashScope = .exclude
    /// Exactly these messages (a selection in the list), AND-ed with the rest.
    public var ids: [Int64]?

    public enum TrashScope: Sendable, Equatable { case exclude, only }
    /// Reference time for relative dates ("30d").
    public var now: Date

    public init(account: String? = nil, mailbox: String? = nil, text: String? = nil, base: String? = nil,
                also: [String] = [], trash: TrashScope = .exclude, ids: [Int64]? = nil, now: Date = Date()) {
        self.ids = ids
        self.account = account
        self.mailbox = mailbox
        self.text = text
        self.base = base
        self.also = also
        self.trash = trash
        self.now = now
    }
}

/// Read side of the index for the UI and the CLI. One connection; confine to one thread
/// (the main actor in the app). WAL lets it read while the writer imports.
public final class ArchiveReader {
    public let layout: ArchiveLayout
    private var connection: Database
    private var inode: UInt64

    /// Whether opening would migrate the index first — possibly slow (v3 links every message
    /// into conversations). The app then runs `migrate` in the background before creating a
    /// reader on the main actor.
    public static func needsMigration(_ layout: ArchiveLayout) -> Bool {
        guard let db = try? Database(path: layout.indexURL.path, readOnly: true),
              let version = try? db.queryOne("PRAGMA user_version", [], { $0.int(0) }) else { return false }
        return version < Int64(Schema.currentVersion)
    }

    /// Migrates the index on a connection of its own; waits up to a minute for a writer
    /// (mkctl) that holds the lock instead of failing after the usual 5 s.
    public static func migrate(_ layout: ArchiveLayout) throws {
        let db = try Database(path: layout.indexURL.path)
        db.setBusyTimeout(milliseconds: 60_000)
        try Schema.migrate(db)
    }

    public init(layout: ArchiveLayout) throws {
        self.layout = layout
        connection = try Database(path: layout.indexURL.path)
        try Schema.migrate(connection)  // a fresh archive may not have been written yet
        inode = Self.inode(layout.indexURL.path)
    }

    /// The live connection; reopened when an index rebuild replaced the file underneath
    /// (an old connection would answer every query with SQLITE_IOERR).
    var db: Database {
        get throws {
            let now = Self.inode(layout.indexURL.path)
            if now != 0, now != inode {
                connection = try Database(path: layout.indexURL.path)
                inode = now
            }
            return connection
        }
    }

    private static func inode(_ path: String) -> UInt64 {
        var st = stat()
        return stat(path, &st) == 0 ? UInt64(st.st_ino) : 0
    }

    public func accounts() throws -> [AccountSummary] {
        let db = try self.db
        let boxes = try db.query("""
            SELECT account_id, mailbox, count(DISTINCT message_id) FROM locations
            WHERE message_id NOT IN (SELECT id FROM messages WHERE trashed IS NOT NULL)
            GROUP BY account_id, mailbox ORDER BY account_id, mailbox COLLATE NOCASE
            """) { MailboxSummary(account: $0.text(0) ?? "", name: $0.text(1) ?? "", count: Int($0.int(2))) }
        return try db.query("""
            SELECT a.id, a.kind, a.display_name,
                   (SELECT count(DISTINCT message_id) FROM locations l WHERE l.account_id = a.id
                    AND l.message_id NOT IN (SELECT id FROM messages WHERE trashed IS NOT NULL))
            FROM accounts a ORDER BY a.display_name COLLATE NOCASE
            """) { row in
            let id = row.text(0) ?? ""
            return AccountSummary(id: id, kind: row.text(1) ?? "", name: row.text(2) ?? id,
                                  messageCount: Int(row.int(3)), mailboxes: boxes.filter { $0.account == id })
        }
    }

    /// Ordered message ids for a filter (8 bytes per row; the list view pages rows by id).
    public func messageIDs(_ filter: MessageFilter, sort: MessageSort = .date, ascending: Bool = false) throws -> [Int64] {
        let (whereClause, params) = try Self.whereClause(filter)
        var sql = "SELECT m.id FROM messages m" + whereClause
        let dir = ascending ? "ASC" : "DESC"
        switch sort {
        case .date: sql += " ORDER BY m.date \(dir) NULLS LAST, m.id \(dir)"
        case .from: sql += " ORDER BY coalesce(m.from_name, m.from_addr) COLLATE NOCASE \(dir), m.date DESC"
        case .subject: sql += " ORDER BY m.subject COLLATE NOCASE \(dir), m.date DESC"
        case .size: sql += " ORDER BY m.size \(dir), m.id"
        }
        return try self.db.query(sql, params) { $0.int(0) }
    }

    /// `EXPLAIN QUERY PLAN` of the list query (tests guard against correlated subqueries).
    func queryPlan(_ filter: MessageFilter) throws -> [String] {
        let (whereClause, params) = try Self.whereClause(filter)
        return try self.db.query("EXPLAIN QUERY PLAN SELECT m.id FROM messages m" + whereClause + " ORDER BY m.date DESC",
                                 params) { $0.text(3) ?? "" }
    }

    /// Archive identities of message rows (stable keys for trash and purge).
    public func identities(of ids: [Int64]) throws -> [String] {
        guard !ids.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: ids.count).joined(separator: ",")
        return try self.db.query("SELECT identity FROM messages WHERE id IN (\(marks))", ids.map { .int($0) }) { $0.text(0) ?? "" }
    }

    /// Identities of everything in the archive trash.
    public func trashedIdentities() throws -> [String] {
        try self.db.query("SELECT identity FROM messages WHERE trashed IS NOT NULL") { $0.text(0) ?? "" }
    }

    /// Number of messages matching a filter (sidebar badges of saved searches).
    public func count(_ filter: MessageFilter) throws -> Int {
        let (whereClause, params) = try Self.whereClause(filter)
        return Int(try self.db.queryOne("SELECT count(*) FROM messages m" + whereClause, params) { $0.int(0) } ?? 0)
    }

    /// Groups of the messages matching `filter`, largest first. Keys come from the same
    /// expressions the exact query fields use, so a group and its `query` agree.
    public func groups(_ filter: MessageFilter, by mode: GroupMode, limit: Int = 2_000) throws -> [MessageGroup] {
        let (whereClause, params) = try Self.whereClause(filter)
        // Same expressions and folding as the exact query fields (QuerySQL), so group and drill-down agree.
        let key = switch mode {
        case .sender: "mk_lower(m.from_addr)"
        case .domain: "CASE WHEN instr(m.from_addr, '@') > 0 THEN mk_lower(substr(m.from_addr, instr(m.from_addr, '@') + 1)) END"
        case .list: "m.list_id"
        }
        // A list is named by its newest message's sender (newsletters name themselves there; the
        // List-Id is often a machine id) — a window function, only where it is needed. A sender
        // practically always uses one name; a domain has many senders, so none.
        let name = switch mode {
        case .sender: "max(name)"
        case .domain: "NULL"
        case .list: "max(name)"
        }
        let nameColumn = mode == .list
            ? "first_value(m.from_name) OVER (PARTITION BY \(key) ORDER BY m.date DESC NULLS LAST, m.id DESC)"
            : "m.from_name"
        let sql = """
            SELECT k, \(name), count(*), sum(size), max(date), min(date), sum(unread), max(unsub) FROM (
                SELECT \(key) AS k, m.size AS size, m.date AS date, m.list_unsubscribe AS unsub,
                       \(nameColumn) AS name,
                       seen.message_id IS NULL AS unread
                FROM messages m
                LEFT JOIN (SELECT DISTINCT message_id FROM locations
                           WHERE instr(' ' || lower(flags) || ' ', ' \\seen ') > 0) seen ON seen.message_id = m.id
                \(whereClause)
            ) WHERE k IS NOT NULL AND k != '' AND instr(k, '"') = 0  -- a quote cannot be expressed in a query value
            GROUP BY k ORDER BY count(*) DESC, k LIMIT ?
            """
        return try self.db.query(sql, params + [.int(Int64(limit))]) { row in
            MessageGroup(mode: mode, key: row.text(0) ?? "", name: row.text(1), count: Int(row.int(2)), bytes: row.int(3),
                         newest: row.optionalDouble(4).map(Date.init(timeIntervalSince1970:)),
                         oldest: row.optionalDouble(5).map(Date.init(timeIntervalSince1970:)),
                         unread: Int(row.int(6)), unsubscribe: row.bool(7))
        }
    }

    /// Distinct labels across all locations (Gmail labels, Takeout), for completion.
    public func labels() throws -> [String] {
        var out: Set<String> = []
        try self.db.forEach("SELECT DISTINCT labels FROM locations WHERE labels != ''") { row in
            for l in (row.text(0) ?? "").split(separator: "\u{1F}") { out.insert(String(l)) }
        }
        return out.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func whereClause(_ filter: MessageFilter) throws -> (String, [SQLValue]) {
        var conditions: [String] = [filter.trash == .only ? "m.trashed IS NOT NULL" : "m.trashed IS NULL"]
        var params: [SQLValue] = []
        if let ids = filter.ids {
            conditions.append(ids.isEmpty ? "0" : "m.id IN (" + Array(repeating: "?", count: ids.count).joined(separator: ",") + ")")
            params += ids.map { .int($0) }
        }
        // Uncorrelated IN, evaluated once. A correlated EXISTS let SQLite pick the (account,
        // mailbox) index per message: 60 s for a 39k INBOX (43k × 39k rows).
        if let account = filter.account {
            var c = "m.id IN (SELECT l.message_id FROM locations l WHERE l.account_id = ?"
            params.append(.text(account))
            if let mailbox = filter.mailbox {
                c += " AND l.mailbox = ?"
                params.append(.text(mailbox))
            }
            conditions.append(c + ")")
        }
        // ADR-0008 query language; an invalid query throws QueryError instead of widening.
        for text in [filter.base, filter.text].compactMap({ $0 }) + filter.also {
            guard let root = try QueryParser.parse(text, now: filter.now).root else { continue }
            var compiled = QuerySQL()
            conditions.append(compiled.condition(root))
            params += compiled.params
        }
        return (conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND "), params)
    }

    /// Rows for a page of ids, returned in the order of `ids`.
    public func summaries(_ ids: [Int64]) throws -> [MessageSummary] {
        guard !ids.isEmpty else { return [] }
        let db = try self.db
        var byID: [Int64: MessageSummary] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.forEach("""
                SELECT id, date, from_name, from_addr, subject, size, attachment_count, snippet,
                       (SELECT count(*) FROM messages t WHERE t.thread_id = m.thread_id AND t.trashed IS NULL)
                FROM messages m WHERE id IN (\(placeholders))
                """, chunk.map { .int($0) }) { row in
                byID[row.int(0)] = Self.summary(row)
            }
        }
        return ids.compactMap { byID[$0] }
    }

    public func detail(_ id: Int64) throws -> MessageDetail? {
        let db = try self.db
        guard let (summary, mid, list, blob) = try db.queryOne("""
            SELECT id, date, from_name, from_addr, subject, size, attachment_count, snippet,
                   (SELECT count(*) FROM messages t WHERE t.thread_id = m.thread_id AND t.trashed IS NULL), message_id, list_id, primary_blob
            FROM messages m WHERE id = ?
            """, [.int(id)], { row in (Self.summary(row), row.text(9), row.text(10), row.text(11) ?? "") }) else { return nil }
        let locations = try db.query("""
            SELECT account_id, mailbox, uid, flags, labels, internal_date, on_server, sha256
            FROM locations WHERE message_id = ? ORDER BY account_id, mailbox
            """, [.int(id)]) { row in
            MessageLocation(account: row.text(0) ?? "", mailbox: row.text(1) ?? "",
                            uid: row.optionalInt(2).map { UInt32(truncatingIfNeeded: $0) },
                            flags: (row.text(3) ?? "").split(separator: " ").map(String.init),
                            labels: (row.text(4) ?? "").split(separator: "\u{1F}").map(String.init),
                            internalDate: row.optionalDouble(5).map(Date.init(timeIntervalSince1970:)),
                            onServer: row.bool(6), sha256: row.text(7) ?? "")
        }
        return MessageDetail(summary: summary, messageID: mid, listID: list, primaryBlob: blob, locations: locations)
    }

    /// Parses the stored message for the reader.
    public func parsedMessage(_ id: Int64) throws -> ParsedMessage? {
        guard let d = try detail(id) else { return nil }
        return MIMEParser.parse(try layout.blobs.read(d.primaryBlob))
    }

    public func stats() throws -> ArchiveStats {
        try self.db.queryOne("""
            SELECT (SELECT count(*) FROM accounts), (SELECT count(*) FROM messages WHERE trashed IS NULL),
                   (SELECT count(*) FROM locations), (SELECT count(*) FROM blobs), (SELECT coalesce(sum(size), 0) FROM blobs),
                   (SELECT count(*) FROM messages WHERE trashed IS NOT NULL)
            """) { ArchiveStats(accounts: Int($0.int(0)), messages: Int($0.int(1)), locations: Int($0.int(2)),
                                blobs: Int($0.int(3)), blobBytes: $0.int(4), trashed: Int($0.int(5))) }
            ?? ArchiveStats(accounts: 0, messages: 0, locations: 0, blobs: 0, blobBytes: 0)
    }

    private static func summary(_ row: Row) -> MessageSummary {
        MessageSummary(id: row.int(0), date: row.optionalDouble(1).map(Date.init(timeIntervalSince1970:)),
                       fromName: row.text(2), fromAddress: row.text(3), subject: row.text(4),
                       size: Int(row.int(5)), attachmentCount: Int(row.int(6)), snippet: row.text(7),
                       threadCount: max(1, Int(row.int(8))))
    }

    /// Progress of making PDF attachments searchable (ADR-0009); `pending` counts what the
    /// queue of `version` would still do — the same condition the writer uses.
    public func attachmentTextStats(version: Int = AttachmentIndexer.version) throws -> AttachmentTextStats {
        let db = try self.db
        var stats = AttachmentTextStats()
        stats.withPDF = Int(try db.queryOne("""
            SELECT count(DISTINCT message_id) FROM attachments
            WHERE is_inline = 0 AND (mime_type = 'application/pdf' OR filename LIKE '%.pdf')
              AND message_id NOT IN (SELECT id FROM messages WHERE trashed IS NOT NULL)
            """) { $0.int(0) } ?? 0)
        try db.forEach("SELECT status, count(*) FROM attachment_text GROUP BY status") { row in
            if let s = AttachmentText.Status(rawValue: row.text(0) ?? "") { stats.byStatus[s] = Int(row.int(1)) }
        }
        stats.pending = Int(try db.queryOne("SELECT count(*) FROM messages m WHERE \(AttachmentIndexer.pendingCondition)",
                                            [.int(Int64(version))]) { $0.int(0) } ?? 0)
        return stats
    }

    // MARK: Conversations

    /// The conversation of a message, oldest first (just the message when it stands alone).
    public func thread(of id: Int64, limit: Int = 500) throws -> [MessageSummary] {
        let ids = try self.db.query("""
            SELECT t.id FROM messages m JOIN messages t ON t.thread_id = m.thread_id
            WHERE m.id = ? AND (t.trashed IS NULL OR t.id = m.id) ORDER BY t.date NULLS FIRST, t.id LIMIT ?
            """, [.int(id), .int(Int64(limit))]) { $0.int(0) }
        return try summaries(ids.isEmpty ? [id] : ids)
    }

    /// `thread:<Message-ID>` for the conversation of a message — named by a member's
    /// Message-ID, which survives a rebuild (thread ids do not). nil without any Message-ID.
    public func threadQuery(of id: Int64) throws -> String? {
        let messageID: String?? = try self.db.queryOne("""
            SELECT t.message_id FROM messages m JOIN messages t ON t.thread_id = m.thread_id
            WHERE m.id = ? AND t.message_id IS NOT NULL ORDER BY t.id = m.id DESC, t.date LIMIT 1
            """, [.int(id)]) { $0.text(0) }
        return (messageID ?? nil).map { "thread:\($0)" }
    }
}
