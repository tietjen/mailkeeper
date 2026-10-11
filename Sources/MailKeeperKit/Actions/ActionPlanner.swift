import Foundation

/// Totals a plan sheet shows before anything runs.
public struct ActionPlanSummary: Sendable, Equatable {
    /// Messages the filter selected.
    public var messages: Int
    /// Of those, messages without a server location MailKeeper knows (nothing to delete there).
    public var archiveOnly: Int
    /// Items that will run, per account.
    public var perAccount: [String: Int]
}

extension ArchiveReader {
    /// Plans "delete on the server" for the messages of `filter` (ADR-0006 §2): one item per
    /// server location (fetched over IMAP, still present at the last fetch). Items whose
    /// preconditions fail are planned as skipped, with the reason:
    /// - the account is not set up here (no connection to act with);
    /// - the date is unknown, or newer than the grace period (default 30 days);
    /// - the message is flagged on the server.
    /// The blob is verified and the Message-ID re-checked on the server when the item runs.
    public func planServerDelete(_ filter: MessageFilter, title: String, accounts: [AccountConfig],
                                 graceDays: Int = 30, now: Date = Date()) throws -> (ActionJob, ActionPlanSummary) {
        let (whereClause, params) = try Self.whereClause(filter)
        let configured = Set(accounts.map(\.id))
        let cutoff = now.addingTimeInterval(-Double(graceDays) * 86_400)
        var items: [ActionItem] = []
        var withLocation: Set<Int64> = []
        try db.forEach("""
            SELECT l.message_id, l.account_id, l.mailbox, l.uid_validity, l.uid, l.sha256, l.flags,
                   coalesce(l.internal_date, m.date), m.message_id, coalesce(b.size, m.size)
            FROM locations l JOIN messages m ON m.id = l.message_id LEFT JOIN blobs b ON b.sha256 = l.sha256
            WHERE \(QuerySQL.serverLocation) AND l.uid_validity IS NOT NULL
              AND l.message_id IN (SELECT m.id FROM messages m\(whereClause))
            ORDER BY coalesce(l.internal_date, m.date), l.id
            """, params) { row in
            withLocation.insert(row.int(0))
            let location = ServerLocation(account: row.text(1) ?? "", mailbox: row.text(2) ?? "",
                                          uidValidity: UInt32(truncatingIfNeeded: row.int(3)),
                                          uid: UInt32(truncatingIfNeeded: row.int(4)))
            let date = row.optionalDouble(7).map(Date.init(timeIntervalSince1970:))
            let flags = (row.text(6) ?? "").lowercased().split(separator: " ")
            var item = ActionItem(id: items.count, sha256: row.text(5) ?? "", messageID: row.text(8),
                                  size: Int(row.int(9)), date: date, location: location)
            if !configured.contains(location.account) {
                item.state = .skipped
                item.reason = String(localized: "Konto ist hier nicht eingerichtet")
            } else if date == nil {
                item.state = .skipped
                item.reason = String(localized: "Datum unbekannt")
            } else if let date, date > cutoff {
                item.state = .skipped
                item.reason = String(localized: "jünger als \(graceDays) Tage (Schonfrist)")
            } else if flags.contains("\\flagged") {
                item.state = .skipped
                item.reason = String(localized: "markiert")
            }
            items.append(item)
        }
        let total = try count(filter)
        var perAccount: [String: Int] = [:]
        for item in items where item.state == .planned { perAccount[item.location?.account ?? "", default: 0] += 1 }
        let job = ActionJob(kind: .serverDelete, title: title, query: filter.text, graceDays: graceDays, items: items)
        return (job, ActionPlanSummary(messages: total, archiveOnly: total - withLocation.count, perAccount: perAccount))
    }
}
