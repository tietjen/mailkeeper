import Foundation

/// A rule the user accepted (6.5b, ADR-0005: derived suggestions never become rules on their
/// own). A query in the search language and what happens to its mails. A category rule runs by
/// itself (it only labels); a rule that deletes or moves only prepares a plan — ADR-0006.
public struct MailRule: Sendable, Equatable, Identifiable {
    public enum Action: Sendable, Equatable, Hashable {
        case category(MailCategory)
        /// Into the server's trash once a mail is older than `days` (the archive keeps it).
        case serverDelete(days: Int)
        /// Into the account's spam folder.
        case moveToJunk

        public var raw: String {
            switch self {
            case .category(let c): "category:" + c.rawValue
            case .serverDelete(let days): "serverDelete:\(days)"
            case .moveToJunk: "moveToJunk"
            }
        }

        public init?(raw: String) {
            if raw == "moveToJunk" { self = .moveToJunk; return }
            if raw.hasPrefix("category:"), let c = MailCategory(rawValue: String(raw.dropFirst("category:".count))) { self = .category(c); return }
            if raw.hasPrefix("serverDelete:"), let d = Int(raw.dropFirst("serverDelete:".count)), (1...3650).contains(d) { self = .serverDelete(days: d); return }
            return nil
        }

        public var label: String {
            switch self {
            case .category(let c): String(localized: "Art: \(c.label)")
            case .serverDelete(let days): String(localized: "nach \(days) Tagen vom Server löschen")
            case .moveToJunk: String(localized: "in den Spam-Ordner")
            }
        }

        /// Deletes or moves: never by itself, always through the plan sheet.
        public var isDestructive: Bool { if case .category = self { false } else { true } }
    }

    public var id: String
    public var name: String
    public var query: String
    public var action: Action
    public var active: Bool

    init?(_ item: MemoryItem) {
        guard item.kind == .rule, let query = item.content.query, let raw = item.content.action, let action = Action(raw: raw) else { return nil }
        id = item.id
        name = item.content.name ?? query
        self.query = query
        self.action = action
        active = item.active
    }

    /// The mails a destructive rule would act on now (on a server, old enough, not already there).
    public var readyQuery: String? {
        switch action {
        case .category: nil
        case .serverDelete(let days): "(\(query)) before:\(days)d on:server"
        case .moveToJunk: "(\(query)) -is:junk on:server"
        }
    }
}

/// A rule MailKeeper suggests because the user did the same thing again and again.
public struct RuleSuggestion: Sendable, Equatable, Identifiable {
    public var id: String { query + "|" + action.raw }
    public var name: String
    public var query: String
    public var action: MailRule.Action
    /// "3× „Benachrichtigung“ festgelegt", "4× vom Server gelöscht"
    public var evidence: String
    /// Mails the rule would cover today.
    public var matches: Int
}

extension ArchiveReader {
    public func rules(includeRejected: Bool = false) throws -> [MailRule] {
        try memoryItems(includeForgotten: includeRejected).compactMap(MailRule.init)
    }

    /// How many mails a destructive rule would act on now.
    public func ready(_ rule: MailRule) throws -> Int {
        guard let q = rule.readyQuery else { return 0 }
        return try count(MessageFilter(text: q + " "))
    }

    /// Repeated decisions become suggestions (deterministic): the same category given to ≥ 3
    /// mails of a sender (and no other), "Ist Spam" for ≥ 2, deleted on the server ≥ 3 times
    /// (from the audit log: shas → messages → sender). Not where a rule (or a rejected
    /// suggestion) with that query and action exists.
    public func ruleSuggestions(audit: [AuditLog.Entry]) throws -> [RuleSuggestion] {
        let existing = Set(try rules(includeRejected: true).map { $0.query.lowercased() + "|" + $0.action.raw })
        var out: [RuleSuggestion] = []
        func add(_ sender: String, _ name: String?, _ action: MailRule.Action, _ evidence: String) throws {
            let query = "sender:" + QueryParser.quote(sender)
            guard !existing.contains(query.lowercased() + "|" + action.raw), !out.contains(where: { $0.query == query && $0.action == action }) else { return }
            let display = (name?.isEmpty == false ? name! : sender)
            let title: String = switch action {
            case .category(let c): String(localized: "Mails von \(display) immer als „\(c.label)“")
            case .serverDelete(let d): String(localized: "Mails von \(display) nach \(d) Tagen vom Server löschen")
            case .moveToJunk: String(localized: "Mails von \(display) in den Spam-Ordner")
            }
            out.append(RuleSuggestion(name: String(title.prefix(160)), query: query, action: action, evidence: evidence,
                                      matches: try count(MessageFilter(text: query + " "))))
        }
        // the user's categories and spam verdicts, per sender
        var categories: [String: [String: Int]] = [:], spam: [String: Int] = [:], names: [String: String] = [:]
        try db.forEach("""
            SELECT lower(m.from_addr), m.from_name, c.category, c.verdict, c.source FROM messages m JOIN classifications c ON c.message_id = m.id
            WHERE (c.source = 'user' OR c.verdict = 'spam') AND m.trashed IS NULL AND instr(m.from_addr, '@') > 0
            """) { r in
            guard let sender = r.text(0) else { return }
            if let name = r.text(1) { names[sender] = name }
            if r.text(3) == "spam" || (r.text(4) == "user" && r.text(2) == "spam") {
                spam[sender, default: 0] += 1
            } else if r.text(4) == "user", let c = r.text(2) {
                categories[sender, default: [:]][c, default: 0] += 1
            }
        }
        for (sender, counts) in categories.sorted(by: { $0.key < $1.key }) where counts.count == 1 {
            guard let (raw, n) = counts.first, n >= 3, let c = MailCategory(rawValue: raw), c != .spam else { continue }
            try add(sender, names[sender], .category(c), String(localized: "\(n)× „\(c.label)“ festgelegt"))
        }
        for (sender, n) in spam.sorted(by: { $0.key < $1.key }) where n >= 2 {
            try add(sender, names[sender], .moveToJunk, String(localized: "\(n)× als Spam markiert"))
        }
        // deleted on the server, per sender (the audit log names blobs, never senders)
        let deleted = Set(audit.filter { $0.action == .serverDelete && $0.result == .done }.map(\.sha256))
        if !deleted.isEmpty {
            var perSender: [String: Int] = [:]
            let list = Array(deleted)
            for chunk in stride(from: 0, to: list.count, by: 500).map({ Array(list[$0..<min($0 + 500, list.count)]) }) {
                let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try db.forEach("""
                    SELECT DISTINCT mb.message_id, lower(m.from_addr), m.from_name FROM message_blobs mb JOIN messages m ON m.id = mb.message_id
                    WHERE mb.sha256 IN (\(marks)) AND instr(m.from_addr, '@') > 0
                    """, chunk.map { .text($0) }) { r in
                    if let sender = r.text(1) { perSender[sender, default: 0] += 1; if let name = r.text(2) { names[sender] = name } }
                }
            }
            for (sender, n) in perSender.sorted(by: { $0.key < $1.key }) where n >= 3 {
                try add(sender, names[sender], .serverDelete(days: 30), String(localized: "\(n)× vom Server gelöscht"))
            }
        }
        return out.sorted { $0.matches > $1.matches }
    }
}
