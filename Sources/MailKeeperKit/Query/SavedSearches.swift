import Foundation

/// A named query shown as a smart view in the sidebar (ADR-0008).
public struct SavedSearch: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var query: String
    public var created: Date

    public init(id: UUID = UUID(), name: String, query: String, created: Date = Date()) {
        self.id = id
        self.name = name
        self.query = query
        self.created = created
    }
}

public enum SavedSearchError: Error, CustomStringConvertible, Equatable {
    case emptyName
    case emptyQuery
    case invalidQuery(String)
    case unknown(UUID)

    public var description: String {
        switch self {
        case .emptyName: "Die Ansicht braucht einen Namen."
        case .emptyQuery: "Die Ansicht braucht eine Suche."
        case .invalidQuery(let m): m
        case .unknown: "Diese Ansicht gibt es nicht mehr."
        }
    }
}

/// `<archive>/saved-searches.json` (0600), replaced atomically. Travels with the archive,
/// because the queries name its accounts and folders.
public struct SavedSearchStore: Sendable {
    public let url: URL

    public init(layout: ArchiveLayout) {
        url = layout.root.appending(path: "saved-searches.json")
    }

    public func load() throws -> [SavedSearch] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SavedSearch].self, from: Data(contentsOf: url))
    }

    public func save(_ searches: [SavedSearch]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let staging = url.deletingLastPathComponent().appending(path: ".saved-searches-\(UUID().uuidString).part")
        do { try writeDurably(try encoder.encode(searches), to: staging) } catch {
            unlink(staging.path)  // a full disk must not leave the staging file behind
            throw error
        }
        guard rename(staging.path, url.path) == 0 else {
            unlink(staging.path)
            throw ArchiveError.io("rename saved-searches.json", path: url.path)
        }
    }

    /// Adds or replaces (same id) after validating name and query.
    public func put(_ search: SavedSearch) throws {
        let s = try Self.validated(search)
        var all = try load()
        if let i = all.firstIndex(where: { $0.id == s.id }) { all[i] = s } else { all.append(s) }
        try save(all)
    }

    public func remove(_ id: UUID) throws {
        var all = try load()
        guard all.contains(where: { $0.id == id }) else { throw SavedSearchError.unknown(id) }
        all.removeAll { $0.id == id }
        try save(all)
    }

    /// The current view as one self-contained query: sidebar scope AND search text. The text is
    /// always parenthesised behind a scope — "a ODER b" must not become "(scope a) OR b".
    public static func query(account: String? = nil, mailbox: String? = nil, base: String? = nil, text: String) -> String {
        func value(_ v: String) -> String {
            v.contains(where: { $0.isWhitespace || "()\"".contains($0) }) || v.hasPrefix("-")
                ? "\"" + v.replacingOccurrences(of: "\"", with: "") + "\"" : v
        }
        var scope: [String] = []
        if let account { scope.append("account:" + value(account)) }
        if let mailbox { scope.append("folder:" + value(mailbox)) }
        if let base, !base.trimmingCharacters(in: .whitespaces).isEmpty { scope.append("(\(base))") }
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return scope.joined(separator: " ") }
        return (scope + [scope.isEmpty ? t : "(\(t))"]).joined(separator: " ")
    }

    static func validated(_ search: SavedSearch) throws -> SavedSearch {
        var s = search
        s.name = collapseWhitespace(s.name).trimmingCharacters(in: .whitespaces)
        s.query = s.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.name.isEmpty else { throw SavedSearchError.emptyName }
        guard !s.query.isEmpty else { throw SavedSearchError.emptyQuery }
        do {
            guard try QueryParser.parse(s.query).root != nil else { throw SavedSearchError.emptyQuery }
        } catch let e as QueryError {
            throw SavedSearchError.invalidQuery(e.message)
        }
        return s
    }
}

/// Suggestions for the search field: field names while typing a word, values after a colon.
public enum QueryCompletion {
    public struct Suggestion: Sendable, Equatable {
        public var title: String
        public var detail: String
        /// The whole new search text.
        public var completion: String
    }

    static let fields: [(String, String)] = [
        ("from:", "Absender, Name oder Adresse"), ("to:", "Empfänger (An, Cc)"), ("subject:", "Betreff"),
        ("has:", "attachment · pdf · image · calendar"), ("is:", "unread · read · flagged · answered · list"),
        ("after:", "ab Datum: 2024, 2024-03, 17.3.2024, 30d"), ("before:", "vor Datum"), ("until:", "bis einschließlich"),
        ("date:", "im Zeitraum: 2024-05, heute"), ("larger:", "größer als: 500K, 5M"), ("smaller:", "kleiner als"),
        ("folder:", "Ordner (Archiv/* für Unterordner)"), ("account:", "Konto"), ("label:", "Label"),
        ("list:", "Mailingliste (Teil der List-Id)"), ("sender:", "exakte Absenderadresse"),
        ("domain:", "exakte Absender-Domain"), ("listid:", "exakte List-Id"), ("filename:", "Name eines Anhangs"),
        ("body:", "nur im Text"), ("pdf:", "nur im Text von PDF-Anhängen"), ("only:archive", "nicht mehr auf dem Server"), ("on:server", "noch auf dem Server"),
    ]

    static let values: [String: [(String, String)]] = [
        "has": [("attachment", "mit Anhang"), ("pdf", "mit PDF"), ("image", "mit Bild"), ("calendar", "mit Kalendereintrag")],
        "is": [("unread", "ungelesen"), ("read", "gelesen"), ("flagged", "markiert"), ("answered", "beantwortet"),
               ("list", "Newsletter und Listen")],
        "after": [("30d", "letzte 30 Tage"), ("1y", "letztes Jahr"), ("heute", "heute")],
        "before": [("1y", "älter als ein Jahr"), ("5y", "älter als fünf Jahre")],
        "date": [("heute", "heute"), ("gestern", "gestern")],
        "larger": [("1M", "größer als 1 MB"), ("5M", "größer als 5 MB"), ("20M", "größer als 20 MB")],
        "smaller": [("100K", "kleiner als 100 KB")],
    ]

    public static func suggestions(for text: String, folders: [String] = [], accounts: [String] = [],
                                   labels: [String] = [], limit: Int = 8) -> [Suggestion] {
        if let last = text.last, last.isWhitespace || last == ")" { return [] }
        let start = text.lastIndex(where: { $0.isWhitespace || $0 == "(" }).map(text.index(after:)) ?? text.startIndex
        let head = String(text[..<start])
        var word = String(text[start...])
        var negated = ""
        if word.hasPrefix("-") { negated = "-"; word.removeFirst() }
        guard !word.isEmpty else { return [] }
        var out: [Suggestion] = []
        if let colon = word.firstIndex(of: ":") {
            let key = word[..<colon].lowercased()
            guard let field = QueryParser.Field.aliases[key] else { return [] }
            let typed = String(word[word.index(after: colon)...]).replacingOccurrences(of: "\"", with: "")
            let prefix = head + negated + word[...colon]
            var candidates: [(String, String)] = values[field.rawValue] ?? []
            switch field {
            case .folder: candidates = folders.map { ($0, "Ordner") }
            case .account: candidates = accounts.map { ($0, "Konto") }
            case .label: candidates = labels.map { ($0, "Label") }
            default: break
            }
            for (value, detail) in candidates where typed.isEmpty || value.lowercased().hasPrefix(typed.lowercased()) {
                let v = value.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" }) ? "\"\(value)\"" : value
                out.append(Suggestion(title: word[...colon] + value, detail: detail, completion: prefix + v + " "))
            }
        } else {
            let lower = word.lowercased()
            for (field, detail) in fields where field.hasPrefix(lower) && field != lower {
                out.append(Suggestion(title: field, detail: detail,
                                      completion: head + negated + field + (field.hasSuffix(":") ? "" : " ")))
            }
        }
        return Array(out.prefix(limit))
    }
}
