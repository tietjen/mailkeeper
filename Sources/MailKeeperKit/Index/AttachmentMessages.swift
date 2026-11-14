import Foundation

/// A message with attachments as an attachment export sees it (mailkeeper-server, ADR-0016): who
/// sent it and when, where it lies, and whether the export's rule matches it. The attachments
/// themselves come from parsing the primary blob — the index knows names and types, not bytes.
public struct AttachmentMessage: Sendable, Equatable {
    /// Stable across index rebuilds (journal identity) — unlike the row id.
    public var identity: String
    public var messageID: String?
    public var subject: String?
    public var fromName: String?
    public var fromAddress: String?
    /// The `Date:` header — what the sender wrote.
    public var date: Date?
    public var firstSeen: Date
    public var primaryBlob: String
    /// Bytes of the stored message, to decide before reading it.
    public var size: Int
    /// "account/mailbox" for every place the archive found it, sorted. Account ids hold no "/",
    /// so the first one separates account and mailbox.
    public var places: [String]
    /// The rule (a query, ADR-0008) matches this message; without a rule every message does.
    public var matchesRule: Bool
    /// Sent by the archive's owner (`is:sent`: it lies in a sent folder).
    public var sent: Bool
}

extension ArchiveReader {
    /// Messages the index lists with attachments, in the order the archive first saw them —
    /// so of two messages carrying the same file, the earlier one comes first. Messages in the
    /// archive trash are left out. `since` compares with when the mail arrived (the earliest
    /// INTERNALDATE of its places; else its `Date:` header, else when the archive first saw it),
    /// as a mail server's SINCE does — a sender's wrong `Date:` does not hide a mail.
    ///
    /// The rule is query text exactly as in the search field (same text, same result, wherever
    /// it runs); an invalid one throws instead of matching everything.
    public func attachmentMessages(rule: String?, since: Date?, now: Date = Date()) throws -> [AttachmentMessage] {
        let rule = rule?.trimmingCharacters(in: .whitespacesAndNewlines)
        let matching: Set<Int64>? = try rule.flatMap { $0.isEmpty ? nil : Set(try messageIDs(MessageFilter(text: $0, now: now))) }
        let sent = Set(try messageIDs(MessageFilter(text: "is:sent", now: now)))
        let sinceValue: SQLValue = since.map { .double($0.timeIntervalSince1970) } ?? .null
        let decoder = JSONDecoder()
        return try db.query("""
            SELECT m.id, m.identity, m.message_id, m.subject, m.from_name, m.from_addr, m.date, m.first_seen, m.primary_blob,
                   coalesce(b.size, m.size),
                   (SELECT json_group_array(json_array(l.account_id, l.mailbox)) FROM locations l WHERE l.message_id = m.id)
            FROM messages m LEFT JOIN blobs b ON b.sha256 = m.primary_blob
            WHERE m.attachment_count > 0 AND m.trashed IS NULL
              AND (?1 IS NULL OR coalesce((SELECT min(l.internal_date) FROM locations l WHERE l.message_id = m.id),
                                          m.date, m.first_seen) >= ?1)
            ORDER BY m.first_seen, m.id
            """, [sinceValue]) { row in
            let pairs = (try? decoder.decode([[String]].self, from: Data((row.text(10) ?? "[]").utf8))) ?? []
            let places = Set(pairs.compactMap { $0.count == 2 ? $0[0] + "/" + $0[1] : nil }).sorted()
            return AttachmentMessage(identity: row.text(1) ?? "", messageID: row.text(2), subject: row.text(3),
                                     fromName: row.text(4), fromAddress: row.text(5),
                                     date: row.optionalDouble(6).map(Date.init(timeIntervalSince1970:)),
                                     firstSeen: Date(timeIntervalSince1970: row.double(7)), primaryBlob: row.text(8) ?? "",
                                     size: Int(row.int(9)), places: places,
                                     matchesRule: matching?.contains(row.int(0)) ?? true, sent: sent.contains(row.int(0)))
        }
    }
}
