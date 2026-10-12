import Foundation

/// What the user taught MailKeeper (ADR-0005, Phase 6.1). Typed and attributed: a note or term
/// the user wrote is trusted (`user`), an example from the user's own decision too (`feedback`);
/// anything inferred from mail content (`derived`, from 6.2 on) is not — it may only raise caution.
public enum MemoryKind: String, Codable, Sendable, CaseIterable {
    /// An explicit statement: "Steuerberater ist wichtig".
    case preference
    /// A decision of the user on a mail: its category, or spam / not spam.
    case example
    /// Per sender, domain or list: what its mails usually are and what the user does with them.
    case senderProfile = "sender_profile"
    /// The user's words: "Firma" = the Proton account.
    case vocabulary
    /// A real relationship (ADR-0010 §6): a bank, school, shop — with the domains it really used.
    case relation

    public var label: String {
        switch self {
        case .preference: String(localized: "Notiz")
        case .example: String(localized: "Beispiel")
        case .senderProfile: String(localized: "Absenderprofil")
        case .vocabulary: String(localized: "Begriff")
        case .relation: String(localized: "Beziehung")
        }
    }
}

public enum MemoryProvenance: String, Codable, Sendable {
    case user, feedback, derived

    public var label: String {
        switch self {
        case .user: String(localized: "von dir")
        case .feedback: String(localized: "deine Entscheidung")
        case .derived: String(localized: "abgeleitet")
        }
    }

    public var trusted: Bool { self != .derived }
}

/// The JSON of an item; each kind uses its fields.
public struct MemoryContent: Codable, Sendable, Equatable {
    /// A note's or term's text.
    public var text: String?
    /// An example: the category the user gave, and/or the verdict ("spam", "ham").
    public var category: String?
    public var verdict: String?
    public var sender: String?
    public var domain: String?
    public var list: String?
    public var subject: String?
    /// A relation: its name, the domains it used, and when it began and ended (seconds since 1970).
    public var name: String?
    public var domains: [String]?
    public var since: Double?
    public var until: Double?

    public init(text: String? = nil, category: String? = nil, verdict: String? = nil, sender: String? = nil, domain: String? = nil,
                list: String? = nil, subject: String? = nil, name: String? = nil, domains: [String]? = nil, since: Double? = nil,
                until: Double? = nil) {
        self.name = name
        self.domains = domains
        self.since = since
        self.until = until
        self.text = text
        self.category = category
        self.verdict = verdict
        self.sender = sender
        self.domain = domain
        self.list = list
        self.subject = subject
    }
}

public struct MemoryItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var kind: MemoryKind
    /// "" for all accounts, else an account id.
    public var scope: String
    /// What it is about: "sender:a@b.de", "domain:b.de", "list:x", or "" (in general).
    public var subject: String
    public var content: MemoryContent
    public var provenance: MemoryProvenance
    /// Identities of the messages it came from (never ids: they change with a rebuild).
    public var sources: [String]
    public var weight: Double
    public var created: Date
    public var updated: Date
    public var lastUsed: Date?
    public var active: Bool

    /// One line for lists.
    public var summary: String {
        switch kind {
        case .example:
            let category = content.category.flatMap(MailCategory.init(rawValue:))
            let verdict = content.verdict == "ham" ? String(localized: "kein Spam")
                : content.verdict == "spam" && category != .spam ? String(localized: "Spam") : nil  // "Ist Spam" sets both
            let what = [category?.label, verdict].compactMap { $0 }.joined(separator: ", ")
            return "\(what) – \(content.subject ?? "")"
        case .relation:
            return "\(content.name ?? "") (\((content.domains ?? []).joined(separator: ", ")))"
        default:
            return content.text ?? ""
        }
    }
}

public enum Memory {
    /// The longest note or term the user can store (they go into prompts, 6.2).
    public static let maxText = 500

    /// The example rows for the user's decided messages (`… WHERE <condition on c>` appended):
    /// one per message, id "ex:" + identity — the same in the v11 backfill and after every
    /// decision, so a rebuild reproduces them.
    static let exampleSelect = """
        SELECT 'ex:' || m.identity, 'example', 'sender:' || lower(coalesce(m.from_addr, '')),
               json_object('category', CASE WHEN c.source = 'user' THEN c.category END, 'verdict', c.verdict,
                           'sender', lower(m.from_addr),
                           'domain', CASE WHEN instr(m.from_addr, '@') > 0 THEN lower(substr(m.from_addr, instr(m.from_addr, '@') + 1)) END,
                           'list', m.list_id, 'subject', substr(m.subject, 1, 160)),
               'feedback', m.identity, c.created, c.created
        FROM messages m JOIN classifications c ON c.message_id = m.id
        """

    /// A stable id for a new note.
    public static func newID() -> String { "note:" + UUID().uuidString.lowercased() }

    /// What may be stored as a note's text: trimmed, bounded, without control characters.
    public static func cleanText(_ s: String) -> String {
        let kept = s.unicodeScalars.filter { $0 == "\n" || !CharacterSet.controlCharacters.contains($0) }
        let text = String(String.UnicodeScalarView(kept)).trimmingCharacters(in: .whitespacesAndNewlines)
        return String(text.prefix(maxText))
    }
}

/// The file format of "Exportieren …" / "Importieren …" in the memory view.
public struct MemoryExport: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var kind: String
        public var scope: String
        public var subject: String
        public var provenance: String
        public var content: MemoryContent
        public var updated: Date
    }

    public var format = "mailkeeper-memory"
    public var version = 1
    public var exported: Date
    public var items: [Item]
}

extension ArchiveReader {
    public func memoryItems(includeForgotten: Bool = false) throws -> [MemoryItem] {
        try db.query("""
            SELECT id, kind, scope, subject, content, provenance, sources, weight, created, updated, last_used, active
            FROM memory_items \(includeForgotten ? "" : "WHERE active = 1") ORDER BY updated DESC, id
            """) { r in
            Self.memoryItem(r)
        }.compactMap { $0 }
    }

    public func memoryItem(_ id: String) throws -> MemoryItem? {
        try db.queryOne("""
            SELECT id, kind, scope, subject, content, provenance, sources, weight, created, updated, last_used, active
            FROM memory_items WHERE id = ?
            """, [.text(id)]) { Self.memoryItem($0) } ?? nil
    }

    /// The active items of the user and the user's decisions, as a file (derived ones are
    /// recomputed, examples point to messages — both are exported for reading, imported never).
    public func exportMemory(now: Date = .now) throws -> Data {
        let items = try memoryItems().map {
            MemoryExport.Item(kind: $0.kind.rawValue, scope: $0.scope, subject: $0.subject, provenance: $0.provenance.rawValue,
                              content: $0.content, updated: $0.updated)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(MemoryExport(exported: now, items: items))
    }

    /// Message ids of the given identities (examples name their messages by identity).
    public func messageIDs(identities: [String]) throws -> [String: Int64] {
        var out: [String: Int64] = [:]
        for chunk in stride(from: 0, to: identities.count, by: 500).map({ Array(identities[$0..<min($0 + 500, identities.count)]) }) {
            let marks = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            try db.forEach("SELECT identity, id FROM messages WHERE identity IN (\(marks))", chunk.map { .text($0) }) { r in
                if let identity = r.text(0) { out[identity] = r.int(1) }
            }
        }
        return out
    }

    /// The memory items a suggestion used (6.2, "Warum?"): ids of notes and examples, and
    /// "profile:sender:…" for the sender profile it saw.
    public func suggestionSources(of messageID: Int64) throws -> [String] {
        try db.query("SELECT memory_id FROM suggestion_sources WHERE message_id = ? ORDER BY memory_id", [.int(messageID)]) { $0.text(0) ?? "" }
    }

    static func memoryItem(_ r: Row) -> MemoryItem? {
        guard let kind = r.text(1).flatMap(MemoryKind.init(rawValue:)), let provenance = r.text(5).flatMap(MemoryProvenance.init(rawValue:)) else { return nil }
        let content = r.text(4).flatMap { try? JSONDecoder().decode(MemoryContent.self, from: Data($0.utf8)) } ?? MemoryContent()
        return MemoryItem(id: r.text(0) ?? "", kind: kind, scope: r.text(2) ?? "", subject: r.text(3) ?? "", content: content,
                          provenance: provenance, sources: (r.text(6) ?? "").split(separator: " ").map(String.init),
                          weight: r.optionalDouble(7) ?? 1, created: Date(timeIntervalSince1970: r.optionalDouble(8) ?? 0),
                          updated: Date(timeIntervalSince1970: r.optionalDouble(9) ?? 0),
                          lastUsed: r.optionalDouble(10).map(Date.init(timeIntervalSince1970:)), active: r.bool(11))
    }
}
