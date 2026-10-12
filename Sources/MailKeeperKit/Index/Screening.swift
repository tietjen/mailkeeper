import Foundation

/// One new mail the inbox screening looked at (6.4): the deterministic warning it carries, and
/// whether a model should look at it too.
public struct ScreeningCandidate: Sendable, Equatable {
    public var id: Int64
    /// "lookalike" or "serverfail" — stored, so "Verdächtig" shows it without a model.
    public var warning: String?
    public var needsModel: Bool
}

extension ArchiveReader {
    /// New mail outside the spam, sent and trash mailboxes that the screening has not looked at
    /// (or, with `again`, has looked at but no model has): newest first. A model is asked only
    /// where it matters — a warning of the register or the own server, a first contact at a
    /// public address, mail the rules left open, and invoices, orders and notifications that do
    /// not come from a confirmed relation with a passing check of the own server.
    public func screeningCandidates(since: Date, limit: Int, again: Bool = false) throws -> [ScreeningCandidate] {
        let relations = try self.relations()
        let servers = try ownAuthServers()
        let publics = try publicAddresses()
        let ordinary = "NOT \(QuerySQL.junkLocation) AND NOT \(QuerySQL.sentLocation) AND NOT \(QuerySQL.trashLocation)"
        let rows = try db.query("""
            SELECT m.id, c.category FROM messages m JOIN classifications c ON c.message_id = m.id
            WHERE m.trashed IS NULL AND m.date >= ? AND c.source IN ('heuristic', 'similar') AND c.verdict IS NULL
              AND \(again ? "1" : "c.screened IS NULL")
              AND m.id IN (SELECT l.message_id FROM locations l WHERE \(ordinary))
              AND m.id NOT IN (SELECT l.message_id FROM locations l WHERE \(QuerySQL.junkLocation) OR \(QuerySQL.sentLocation))
            ORDER BY m.date DESC LIMIT ?
            """, [.double(since.timeIntervalSince1970), .int(Int64(limit))]) { ($0.int(0), $0.text(1).flatMap(MailCategory.init(rawValue:))) }
        let phishingProne: Set<MailCategory> = [.invoice, .orderShipping, .notification, .accountSecurity]
        return try rows.map { id, category in
            let check = try relationCheck(of: id, relations: relations, servers: servers, publicAddresses: publics)
            var warning: String?
            if check.lookAlike != nil { warning = "lookalike" } else if case .failed = check.server { warning = "serverfail" }
            let trusted: Bool = { if case .passed = check.server { return check.known != nil && !(check.known?.ended ?? false) }; return false }()
            let needsModel = warning != nil || check.firstContactAt != nil || category == nil
                || (category.map(phishingProne.contains) ?? false && !trusted)
            return ScreeningCandidate(id: id, warning: warning, needsModel: needsModel)
        }
    }
}
