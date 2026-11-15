import Foundation

/// A message as a connector names it (ADR-0017): by its archive identity, which survives an
/// index rebuild — row ids do not.
public struct ConnectorBrief: Sendable, Equatable {
    public var row: Int64
    public var identity: String
    public var messageID: String?
    public var subject: String?
    public var fromName: String?
    public var fromAddress: String?
    /// Recipients as stored (comma separated).
    public var to: String?
    public var date: Date?
    public var attachmentCount: Int
    public var snippet: String?
    /// Messages in its conversation (1 = on its own).
    public var threadCount: Int
}

extension ArchiveReader {
    /// The row of a message that is not in the archive trash, by its archive identity.
    public func rowID(identity: String) throws -> Int64? {
        try self.db.queryOne("SELECT id FROM messages WHERE identity = ? AND trashed IS NULL", [.text(identity)]) { $0.int(0) }
    }

    /// Briefs for rows, in the order of `ids`; rows that are gone are left out.
    public func connectorBriefs(_ ids: [Int64]) throws -> [ConnectorBrief] {
        guard !ids.isEmpty else { return [] }
        let db = try self.db
        var byID: [Int64: ConnectorBrief] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.forEach("""
                SELECT id, identity, message_id, subject, from_name, from_addr, to_addrs, date, attachment_count, snippet,
                       (SELECT count(*) FROM messages t WHERE t.thread_id = m.thread_id AND t.trashed IS NULL)
                FROM messages m WHERE id IN (\(marks)) AND trashed IS NULL
                """, chunk.map { .int($0) }) { row in
                byID[row.int(0)] = ConnectorBrief(
                    row: row.int(0), identity: row.text(1) ?? "", messageID: row.text(2), subject: row.text(3),
                    fromName: row.text(4), fromAddress: row.text(5), to: row.text(6),
                    date: row.optionalDouble(7).map(Date.init(timeIntervalSince1970:)),
                    attachmentCount: Int(row.int(8)), snippet: row.text(9), threadCount: max(1, Int(row.int(10))))
            }
        }
        return ids.compactMap { byID[$0] }
    }

    /// The conversation key of each row (rows of one conversation share it). Thread ids are
    /// rebuilt with the index, so this is only for grouping within one answer.
    public func conversationKeys(_ ids: [Int64]) throws -> [Int64: Int64] {
        guard !ids.isEmpty else { return [:] }
        let db = try self.db
        var out: [Int64: Int64] = [:]
        for chunk in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.forEach("SELECT id, coalesce(thread_id, -id) FROM messages WHERE id IN (\(marks))", chunk.map { .int($0) }) { row in
                out[row.int(0)] = row.int(1)
            }
        }
        return out
    }
}
