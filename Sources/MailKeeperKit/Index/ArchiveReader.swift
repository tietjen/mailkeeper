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
    public var messages: Int
    public var locations: Int
    public var blobs: Int
    public var blobBytes: Int64
}

public enum MessageSort: String, Sendable, CaseIterable {
    case date, from, subject, size
}

public struct MessageFilter: Sendable, Equatable {
    public var account: String?
    public var mailbox: String?
    public var text: String?

    public init(account: String? = nil, mailbox: String? = nil, text: String? = nil) {
        self.account = account
        self.mailbox = mailbox
        self.text = text
    }
}

/// Read side of the index for the UI and the CLI. One connection; confine to one thread
/// (the main actor in the app). WAL lets it read while the writer imports.
public final class ArchiveReader {
    public let layout: ArchiveLayout
    private var connection: Database
    private var inode: UInt64

    public init(layout: ArchiveLayout) throws {
        self.layout = layout
        connection = try Database(path: layout.indexURL.path)
        try Schema.migrate(connection)  // a fresh archive may not have been written yet
        inode = Self.inode(layout.indexURL.path)
    }

    /// The live connection; reopened when an index rebuild replaced the file underneath
    /// (an old connection would answer every query with SQLITE_IOERR).
    private var db: Database {
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
            GROUP BY account_id, mailbox ORDER BY account_id, mailbox COLLATE NOCASE
            """) { MailboxSummary(account: $0.text(0) ?? "", name: $0.text(1) ?? "", count: Int($0.int(2))) }
        return try db.query("""
            SELECT a.id, a.kind, a.display_name,
                   (SELECT count(DISTINCT message_id) FROM locations l WHERE l.account_id = a.id)
            FROM accounts a ORDER BY a.display_name COLLATE NOCASE
            """) { row in
            let id = row.text(0) ?? ""
            return AccountSummary(id: id, kind: row.text(1) ?? "", name: row.text(2) ?? id,
                                  messageCount: Int(row.int(3)), mailboxes: boxes.filter { $0.account == id })
        }
    }

    /// Ordered message ids for a filter (8 bytes per row; the list view pages rows by id).
    public func messageIDs(_ filter: MessageFilter, sort: MessageSort = .date, ascending: Bool = false) throws -> [Int64] {
        var sql = "SELECT m.id FROM messages m"
        var conditions: [String] = []
        var params: [SQLValue] = []
        if let account = filter.account {
            var c = "EXISTS (SELECT 1 FROM locations l WHERE l.message_id = m.id AND l.account_id = ?"
            params.append(.text(account))
            if let mailbox = filter.mailbox {
                c += " AND l.mailbox = ?"
                params.append(.text(mailbox))
            }
            conditions.append(c + ")")
        }
        if let text = filter.text, let match = SearchText.ftsQuery(text) {
            conditions.append("m.id IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ?)")
            params.append(.text(match))
        }
        if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
        let dir = ascending ? "ASC" : "DESC"
        switch sort {
        case .date: sql += " ORDER BY m.date \(dir) NULLS LAST, m.id \(dir)"
        case .from: sql += " ORDER BY coalesce(m.from_name, m.from_addr) COLLATE NOCASE \(dir), m.date DESC"
        case .subject: sql += " ORDER BY m.subject COLLATE NOCASE \(dir), m.date DESC"
        case .size: sql += " ORDER BY m.size \(dir), m.id"
        }
        return try self.db.query(sql, params) { $0.int(0) }
    }

    /// Rows for a page of ids, returned in the order of `ids`.
    public func summaries(_ ids: [Int64]) throws -> [MessageSummary] {
        guard !ids.isEmpty else { return [] }
        let db = try self.db
        var byID: [Int64: MessageSummary] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.forEach("""
                SELECT id, date, from_name, from_addr, subject, size, attachment_count, snippet
                FROM messages WHERE id IN (\(placeholders))
                """, chunk.map { .int($0) }) { row in
                byID[row.int(0)] = Self.summary(row)
            }
        }
        return ids.compactMap { byID[$0] }
    }

    public func detail(_ id: Int64) throws -> MessageDetail? {
        let db = try self.db
        guard let (summary, mid, list, blob) = try db.queryOne("""
            SELECT id, date, from_name, from_addr, subject, size, attachment_count, snippet, message_id, list_id, primary_blob
            FROM messages WHERE id = ?
            """, [.int(id)], { row in (Self.summary(row), row.text(8), row.text(9), row.text(10) ?? "") }) else { return nil }
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
            SELECT (SELECT count(*) FROM accounts), (SELECT count(*) FROM messages), (SELECT count(*) FROM locations),
                   (SELECT count(*) FROM blobs), (SELECT coalesce(sum(size), 0) FROM blobs)
            """) { ArchiveStats(accounts: Int($0.int(0)), messages: Int($0.int(1)), locations: Int($0.int(2)),
                                blobs: Int($0.int(3)), blobBytes: $0.int(4)) }
            ?? ArchiveStats(accounts: 0, messages: 0, locations: 0, blobs: 0, blobBytes: 0)
    }

    private static func summary(_ row: Row) -> MessageSummary {
        MessageSummary(id: row.int(0), date: row.optionalDouble(1).map(Date.init(timeIntervalSince1970:)),
                       fromName: row.text(2), fromAddress: row.text(3), subject: row.text(4),
                       size: Int(row.int(5)), attachmentCount: Int(row.int(6)), snippet: row.text(7))
    }
}
