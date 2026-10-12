import Foundation

/// Where cleaning up pays off (6.5a, plan §3): deterministic counts, a query that shows exactly
/// those mails, and a plain reason. Nothing happens from a suggestion itself — deleting goes
/// through the plan sheet with its checks (on the server: grace period, the archive keeps them;
/// in the archive: the trash for 30 days, only what no server holds — ADR-0006).
public struct CleanupSuggestion: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case unreadList, oldNotifications, largeOld, oldSpam }

    public var id: String { kind.rawValue + ":" + query }
    public var kind: Kind
    public var title: String
    public var reason: String
    /// The mails the suggestion is about (search language).
    public var query: String
    public var count: Int
    public var bytes: Int64
    /// Of them, still on a server (MailKeeper fetched them there).
    public var onServer: Int
    /// For a newsletter: the group, to open its detail (unsubscribe lives there).
    public var group: MessageGroup?

    public var archiveOnly: Int { count - onServer }
}

extension ArchiveReader {
    public static let suggestionMinimum = (list: 10, notifications: 20, large: 5, spam: 10)

    public func cleanupSuggestions(now: Date = .now) throws -> [CleanupSuggestion] {
        var out: [CleanupSuggestion] = []
        let place = { (n: Int) in n == 0 ? String(localized: "keine mehr auf einem Server") : String(localized: "\(n) noch auf dem Server") }
        // newsletters nobody reads that still write — by sender: a mail service gives every
        // campaign its own List-Id (one sender came up four times)
        let onServer = Dictionary(try groups(MessageFilter(text: "is:list on:server "), by: .sender).map { ($0.key, $0.count) },
                                  uniquingKeysWith: { a, _ in a })
        let halfYear = now.addingTimeInterval(-182 * 86_400)
        var lists: [CleanupSuggestion] = []
        for g in try groups(MessageFilter(text: "is:list "), by: .sender) where g.count >= Self.suggestionMinimum.list {
            guard Double(g.unread) / Double(g.count) >= 0.9, (g.newest ?? .distantPast) >= halfYear else { continue }
            let share = Int((Double(g.unread) / Double(g.count) * 100).rounded())
            let server = onServer[g.key] ?? 0
            lists.append(CleanupSuggestion(
                kind: .unreadList, title: String(localized: "„\(g.name ?? g.key)“ liest du nicht"),
                reason: String(localized: "\(g.count) Mails, \(share) % ungelesen, die letzte am \(g.newest!.formatted(date: .abbreviated, time: .omitted)); \(place(server)).")
                    + (g.unsubscribe ? " " + String(localized: "Abmelden geht in der Gruppe.") : ""),
                query: g.query + " is:list", count: g.count, bytes: g.bytes, onServer: server, group: g))
        }
        out += lists.sorted { $0.count > $1.count }.prefix(5)
        func bucket(_ kind: CleanupSuggestion.Kind, _ query: String, _ minimum: Int, _ title: String, _ reason: (Int, Int64, Int) -> String) throws {
            let t = try totals(MessageFilter(text: query + " "))
            guard t.count >= minimum else { return }
            let server = try count(MessageFilter(text: query + " on:server "))
            out.append(CleanupSuggestion(kind: kind, title: title, reason: reason(t.count, t.bytes, server), query: query,
                                         count: t.count, bytes: t.bytes, onServer: server))
        }
        try bucket(.oldNotifications, "kategorie:benachrichtigung before:1y", Self.suggestionMinimum.notifications,
                   String(localized: "Alte Benachrichtigungen")) { n, _, server in
            String(localized: "\(n) automatische Benachrichtigungen, älter als ein Jahr; \(place(server)).")
        }
        try bucket(.largeOld, "larger:10M before:1y", Self.suggestionMinimum.large, String(localized: "Große alte Mails")) { n, bytes, server in
            String(localized: "\(n) Mails über 10 MB, älter als ein Jahr – zusammen \(bytes.formatted(.byteCount(style: .file))); \(place(server)). Vom Server löschen kostet nichts, das Archiv behält sie; aus dem Archiv gelöscht sind sie nach 30 Tagen endgültig weg – nur, wenn du die Anhänge nirgends brauchst.")
        }
        try bucket(.oldSpam, "is:junk before:30d (kategorie:spam OR is:phishing)", Self.suggestionMinimum.spam,
                   String(localized: "Bestätigter Spam")) { n, _, server in
            String(localized: "\(n) Mails im Spam-Ordner, älter als 30 Tage, die eine KI oder du als Spam oder Phishing bewertet hat; \(place(server)).")
        }
        return out
    }
}
