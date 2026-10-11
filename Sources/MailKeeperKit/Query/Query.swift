import Foundation

/// A parsed search query (ADR-0008). `QuerySQL` turns it into a condition on the index.
public indirect enum QueryNode: Sendable, Equatable {
    case and([QueryNode])
    case or([QueryNode])
    case not(QueryNode)
    case predicate(QueryPredicate)
}

public enum QueryPredicate: Sendable, Equatable {
    /// `any`: message or attachment text; `pdf`: attachment text only (ADR-0009).
    public enum TextField: String, Sendable { case any, subject, from, to, body, filename, pdf }
    public enum Attachment: String, Sendable { case any, pdf, image, calendar }
    public enum Flag: String, Sendable { case unread, read, flagged, answered }

    /// Words or a phrase in the full-text index; `prefix`: the last word matches as prefix.
    case text(TextField, String, prefix: Bool)
    /// Exact sender address, case-insensitive.
    case sender(String)
    /// Exact sender domain (the part after @), case-insensitive; no subdomains.
    case domain(String)
    case has(Attachment)
    case larger(Int64)
    case smaller(Int64)
    /// `date >= start`
    case dateFrom(Date)
    /// `date < end`
    case dateBefore(Date)
    case account(String)
    case folder(String, prefix: Bool)
    case label(String)
    /// List-Id contains the text.
    case list(String)
    /// List-Id equals the text.
    case listID(String)
    case isList
    /// The message's category (Phase 5.4); nil = left open by the rules, no model answer yet.
    case category(MailCategory?)
    /// Sent mail: a location in a sent mailbox, or Gmail's \Sent label.
    case isSent
    /// A location in a spam/junk mailbox (by the server's role or its usual name).
    case inJunk
    case flag(Flag)
    case onServer
    case archiveOnly
    case messageID(String)
    /// The conversation containing the message with this Message-ID.
    case thread(String)
}

public struct QueryError: Error, Equatable, CustomStringConvertible, Sendable {
    public var message: String
    public var description: String { message }

    init(_ message: String) {
        self.message = message
    }
}

/// A top-level term for display: what it means and where it stands in the text.
public struct QueryChip: Sendable, Equatable {
    public var label: String
    public var range: Range<String.Index>
    /// The term's source text, to check that `range` still points at it after edits.
    public var text: String
}

public struct Query: Sendable, Equatable {
    /// nil: no condition (everything matches).
    public var root: QueryNode?
    public var chips: [QueryChip]
}

public enum QueryParser {
    public static let maxLength = 4_096
    public static let maxTerms = 64
    public static let maxDepth = 16

    /// Parses query text. `now` and `calendar` resolve dates ("2024-03", "30d") to instants.
    public static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) throws(QueryError) -> Query {
        guard text.count <= maxLength else { throw QueryError("Die Suche ist zu lang (höchstens \(maxLength) Zeichen).") }
        var tokens = tokenize(text)
        if let last = tokens.indices.last, case .term(_, _, quoted: false) = tokens[last].kind,
           tokens[last].range.upperBound == text.endIndex {
            tokens[last].livePrefix = true  // still typing this word
        }
        var parser = Parser(tokens: tokens, text: text, now: now, calendar: calendar)
        let query = try parser.parseTop()
        return query
    }

    // MARK: Tokens

    enum Field: String, CaseIterable {
        case from, to, subject, body, filename, pdf, sender, has, larger, smaller
        case after, before, until, date, account, folder, label, list, listid, domain, `is`, on, only, msgid, thread, category

        static let aliases: [String: Field] = {
            var map = Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0) })
            let extra: [String: Field] = [
                "von": .from, "an": .to, "cc": .to, "betreff": .subject, "text": .body, "anhang": .filename,
                "datei": .filename, "absender": .sender, "hat": .has, "größer": .larger, "groesser": .larger,
                "kleiner": .smaller, "ab": .after, "since": .after, "seit": .after, "vor": .before, "bis": .until,
                "datum": .date, "konto": .account, "in": .folder, "ordner": .folder, "liste": .list, "ist": .is,
                "auf": .on, "nur": .only, "message-id": .msgid, "konversation": .thread, "anhangtext": .pdf,
                "kategorie": .category, "art": .category,
            ]
            map.merge(extra) { a, _ in a }
            return map
        }()
    }

    struct Token {
        enum Kind: Equatable {
            case lparen, rparen, or, not
            case term(Field?, String, quoted: Bool)
        }
        var kind: Kind
        var range: Range<String.Index>
        var livePrefix = false
    }

    static func tokenize(_ s: String) -> [Token] {
        var tokens: [Token] = []
        var i = s.startIndex
        func isDelimiter(_ c: Character) -> Bool { c.isWhitespace || c == "(" || c == ")" || c == "\"" }
        /// From an opening quote to the closing one (or the end while still typing).
        func quoted(at start: String.Index) -> (String, String.Index) {
            let contentStart = s.index(after: start)
            var j = contentStart
            while j < s.endIndex, s[j] != "\"" { j = s.index(after: j) }
            let value = String(s[contentStart..<j])
            return (value, j < s.endIndex ? s.index(after: j) : j)
        }
        while i < s.endIndex {
            let c = s[i]
            let next = s.index(after: i)
            if c.isWhitespace { i = next; continue }
            switch c {
            case "(":
                tokens.append(Token(kind: .lparen, range: i..<next)); i = next; continue
            case ")":
                tokens.append(Token(kind: .rparen, range: i..<next)); i = next; continue
            case "-" where next < s.endIndex && !s[next].isWhitespace && s[next] != ")":
                tokens.append(Token(kind: .not, range: i..<next)); i = next; continue
            case "\"":
                let (value, end) = quoted(at: i)
                tokens.append(Token(kind: .term(nil, value, quoted: true), range: i..<end)); i = end; continue
            default: break
            }
            var j = i
            while j < s.endIndex, !isDelimiter(s[j]) { j = s.index(after: j) }
            let word = s[i..<j]
            if let colon = word.firstIndex(of: ":"), let field = Field.aliases[word[..<colon].lowercased()] {
                let valueStart = s.index(after: colon)
                if valueStart == j, j < s.endIndex, s[j] == "\"" {
                    let (value, end) = quoted(at: j)
                    tokens.append(Token(kind: .term(field, value, quoted: true), range: i..<end)); i = end; continue
                }
                tokens.append(Token(kind: .term(field, String(s[valueStart..<j]), quoted: false), range: i..<j))
            } else {
                switch word {
                case "OR", "ODER": tokens.append(Token(kind: .or, range: i..<j))
                case "NOT", "NICHT": tokens.append(Token(kind: .not, range: i..<j))
                case "AND", "UND": break  // AND is implicit
                default: tokens.append(Token(kind: .term(nil, String(word), quoted: false), range: i..<j))
                }
            }
            i = j
        }
        return tokens
    }

    // MARK: Parser

    struct Parser {
        let tokens: [Token]
        let text: String
        let now: Date
        let calendar: Calendar
        var pos = 0
        var depth = 0
        var terms = 0

        init(tokens: [Token], text: String, now: Date, calendar: Calendar) {
            self.tokens = tokens
            self.text = text
            self.now = now
            self.calendar = calendar
        }

        var peek: Token.Kind? { pos < tokens.count ? tokens[pos].kind : nil }

        mutating func parseTop() throws(QueryError) -> Query {
            guard !tokens.isEmpty else { return Query(root: nil, chips: []) }
            var groups: [[Item]] = []
            groups.append(try parseAnd())
            while peek == .or {
                pos += 1
                guard peek != nil, peek != .or else { throw QueryError("Nach „OR“ fehlt ein Begriff.") }
                groups.append(try parseAnd())
            }
            if peek == .rparen { throw QueryError("„)“ ohne passende „(“.") }
            let nonEmpty = groups.filter { !$0.isEmpty }
            if nonEmpty.count <= 1 {
                let items = nonEmpty.first ?? []
                return Query(root: Self.and(items.map(\.node)),
                             chips: items.map { QueryChip(label: $0.label, range: $0.range, text: String(text[$0.range])) })
            }
            let root = QueryNode.or(nonEmpty.map { Self.and($0.map(\.node))! })
            let range = tokens.first!.range.lowerBound..<tokens.last!.range.upperBound
            return Query(root: root, chips: [QueryChip(label: String(text[range]), range: range, text: String(text[range]))])
        }

        struct Item {
            var node: QueryNode
            var label: String
            var range: Range<String.Index>
        }

        static func and(_ nodes: [QueryNode]) -> QueryNode? {
            switch nodes.count {
            case 0: nil
            case 1: nodes[0]
            default: .and(nodes)
            }
        }

        /// Terms up to OR, `)` or the end. Empty when every term was ignorable punctuation.
        mutating func parseAnd() throws(QueryError) -> [Item] {
            var items: [Item] = []
            var sawTerm = false
            while let kind = peek, kind != .or, kind != .rparen {
                sawTerm = true
                if let item = try parseUnary() { items.append(item) }
            }
            if !sawTerm {
                switch peek {
                case .rparen: throw QueryError(pos == 0 ? "„)“ ohne passende „(“." : "Leere Klammer.")
                case .or: throw QueryError("Vor „OR“ fehlt ein Begriff.")
                default: throw QueryError("„(“ ohne passende „)“.")
                }
            }
            return items
        }

        mutating func parseUnary() throws(QueryError) -> Item? {
            let start = tokens[pos].range.lowerBound
            switch tokens[pos].kind {
            case .not:
                pos += 1
                guard let kind = peek, kind != .or, kind != .rparen else { throw QueryError("Nach „-“ fehlt ein Begriff.") }
                guard let inner = try parseUnary() else { return nil }
                return Item(node: .not(inner.node), label: "nicht " + inner.label, range: start..<inner.range.upperBound)
            case .lparen:
                pos += 1
                depth += 1
                guard depth <= QueryParser.maxDepth else { throw QueryError("Zu viele verschachtelte Klammern.") }
                var groups: [[Item]] = [try parseAnd()]
                while peek == .or {
                    pos += 1
                    guard peek != nil, peek != .or, peek != .rparen else { throw QueryError("Nach „OR“ fehlt ein Begriff.") }
                    groups.append(try parseAnd())
                }
                guard peek == .rparen else { throw QueryError("„(“ ohne passende „)“.") }
                let end = tokens[pos].range.upperBound
                pos += 1
                depth -= 1
                let nodes = groups.compactMap { Self.and($0.map(\.node)) }
                guard !nodes.isEmpty else { return nil }
                return Item(node: nodes.count == 1 ? nodes[0] : .or(nodes), label: String(text[start..<end]), range: start..<end)
            case .term(let field, let value, let quoted):
                let token = tokens[pos]
                pos += 1
                terms += 1
                guard terms <= QueryParser.maxTerms else { throw QueryError("Zu viele Suchbegriffe (höchstens \(QueryParser.maxTerms)).") }
                guard let p = try predicate(field, value, quoted: quoted, livePrefix: token.livePrefix) else { return nil }
                return Item(node: p.0, label: p.1, range: token.range)
            case .or, .rparen:
                return nil  // not reached: parseAnd stops before these
            }
        }

        // MARK: Values

        func predicate(_ field: Field?, _ raw: String, quoted: Bool, livePrefix: Bool) throws(QueryError) -> (QueryNode, String)? {
            let value = raw.trimmingCharacters(in: .whitespaces)
            let name = field.map { "„\($0.rawValue):“" } ?? ""
            func required() throws(QueryError) -> String {
                guard !value.isEmpty else { throw QueryError("\(name) braucht einen Wert.") }
                return value
            }
            func text(_ f: QueryPredicate.TextField, _ title: String?) throws(QueryError) -> (QueryNode, String)? {
                var v = SearchText.normalize(value).replacingOccurrences(of: "\"", with: "")
                var prefix = livePrefix
                if !quoted, v.hasSuffix("*") { prefix = true }
                while v.hasSuffix("*") { v.removeLast() }
                guard v.contains(where: { $0.isLetter || $0.isNumber }) else {
                    if f == .any { return nil }  // punctuation alone: nothing to search for
                    throw QueryError("\(name) braucht ein Wort.")
                }
                let shown = quoted ? "„\(value)“" : value
                return (.predicate(.text(f, v, prefix: prefix)), title.map { "\($0): \(shown)" } ?? shown)
            }
            guard let field else { return try text(.any, nil) }
            switch field {
            case .from: return try text(.from, "Von")
            case .to: return try text(.to, "An")
            case .subject: return try text(.subject, "Betreff")
            case .body: return try text(.body, "Text")
            case .filename: return try text(.filename, "Anhang")
            case .pdf: return try text(.pdf, "im PDF")
            case .sender:
                let v = try required().lowercased()
                // "sender:@finom.me": the address without its local part = everyone at that
                // domain (TJ: delete the prefix of a sender chip to widen it to the domain).
                if !quoted, v.hasPrefix("@") {
                    let domain = String(v.dropFirst())
                    guard !domain.isEmpty else { throw QueryError("\(name) braucht eine Adresse oder @domain.") }
                    return (.predicate(.domain(domain)), "Domain: \(domain)")
                }
                return (.predicate(.sender(v)), "Absender: \(v)")
            case .has:
                switch try required().lowercased() {
                case "attachment", "attachments", "anhang", "anhänge": return (.predicate(.has(.any)), "mit Anhang")
                case "pdf": return (.predicate(.has(.pdf)), "mit PDF")
                case "image", "images", "bild", "bilder": return (.predicate(.has(.image)), "mit Bild")
                case "calendar", "kalender", "ics", "invite", "einladung": return (.predicate(.has(.calendar)), "mit Kalendereintrag")
                default: throw QueryError("„has:\(value)“ kenne ich nicht — attachment, pdf, image oder calendar.")
                }
            case .larger, .smaller:
                guard let bytes = QueryParser.size(try required()) else {
                    throw QueryError("\(name) erwartet eine Größe wie 500K, 5M oder 1G.")
                }
                return field == .larger ? (.predicate(.larger(bytes)), "größer als \(value)")
                                        : (.predicate(.smaller(bytes)), "kleiner als \(value)")
            case .after, .before, .until, .date:
                guard let d = QueryParser.date(try required(), now: now, calendar: calendar) else {
                    throw QueryError("\(name) erwartet ein Datum wie 2024, 2024-03, 2024-03-17, 17.3.2024 oder 30d.")
                }
                switch (field, d) {
                case (.after, .period(let start, _)), (.after, .point(let start)):
                    return (.predicate(.dateFrom(start)), "ab \(value)")
                case (.before, .period(let start, _)), (.before, .point(let start)), (.until, .point(let start)):
                    return (.predicate(.dateBefore(start)), "vor \(value)")
                case (.until, .period(_, let end)):
                    return (.predicate(.dateBefore(end)), "bis \(value)")
                case (.date, .period(let start, let end)):
                    return (.and([.predicate(.dateFrom(start)), .predicate(.dateBefore(end))]), "Datum: \(value)")
                default:
                    throw QueryError("„date:“ braucht einen Zeitraum (2024, 2024-03, 17.3.2024) — für „vor 30 Tagen“ before:30d.")
                }
            case .account:
                let v = try required().lowercased()
                return (.predicate(.account(v)), "Konto: \(v)")
            case .folder:
                var v = try required()
                let prefix = !quoted && v.hasSuffix("*")
                while prefix, v.hasSuffix("*") { v.removeLast() }  // quoted: a literal "*" in the name
                guard !v.isEmpty else { throw QueryError("\(name) braucht einen Ordnernamen.") }
                return (.predicate(.folder(v, prefix: prefix)), "Ordner: \(value)")
            case .label:
                return (.predicate(.label(try required().lowercased())), "Label: \(value)")
            case .list:
                return (.predicate(.list(try required().lowercased())), "Liste: \(value)")
            case .listid:
                return (.predicate(.listID(try required().lowercased())), "Liste: \(value)")
            case .domain:
                var v = try required().lowercased()
                if !quoted, v.hasPrefix("@") { v.removeFirst() }  // "@amazon.de"; a quoted value is taken as is
                guard !v.isEmpty else { throw QueryError("\(name) braucht eine Domain wie amazon.de.") }
                return (.predicate(.domain(v)), "Domain: \(v)")
            case .is:
                switch try required().lowercased() {
                case "unread", "ungelesen", "neu": return (.predicate(.flag(.unread)), "ungelesen")
                case "read", "gelesen": return (.predicate(.flag(.read)), "gelesen")
                case "flagged", "starred", "markiert", "wichtig": return (.predicate(.flag(.flagged)), "markiert")
                case "answered", "replied", "beantwortet": return (.predicate(.flag(.answered)), "beantwortet")
                case "list", "newsletter", "liste": return (.predicate(.isList), "Newsletter/Liste")
                case "sent", "gesendet", "versendet": return (.predicate(.isSent), "gesendet")
                case "junk", "spamordner", "spam-ordner", "im-spam": return (.predicate(.inJunk), "im Spam-Ordner")
                default: throw QueryError("„is:\(value)“ kenne ich nicht — unread, read, flagged, answered, list, sent oder junk.")
                }
            case .category:
                let word = try required().lowercased()
                if ["offen", "unbekannt", "open", "none", "keine"].contains(word) { return (.predicate(.category(nil)), "Kategorie: offen") }
                guard let category = MailCategory.parse(word) else {
                    throw QueryError("\(name) kennt „\(value)“ nicht — \(MailCategory.allCases.map(\.queryWord).joined(separator: ", ")) oder offen.")
                }
                return (.predicate(.category(category)), category.label)
            case .on:
                guard ["server"].contains(try required().lowercased()) else { throw QueryError("Gemeint ist „on:server“.") }
                return (.predicate(.onServer), "auf dem Server")
            case .only:
                guard ["archive", "archiv"].contains(try required().lowercased()) else { throw QueryError("Gemeint ist „only:archive“.") }
                return (.predicate(.archiveOnly), "nur im Archiv")
            case .msgid:
                var v = try required()
                if !v.hasPrefix("<") { v = "<" + v + ">" }
                return (.predicate(.messageID(v)), "Message-ID: \(v)")
            case .thread:
                var v = try required()
                if !v.hasPrefix("<") { v = "<" + v + ">" }
                return (.predicate(.thread(v)), "Konversation")
            }
        }
    }

    // MARK: Building queries

    /// A value as the parser reads it back unchanged: quoted when it holds spaces, brackets,
    /// quotes, or would otherwise be read as syntax (leading "-" or "@", trailing "*").
    public static func quote(_ value: String) -> String {
        let plain = value.replacingOccurrences(of: "\"", with: "")
        let needsQuotes = plain.isEmpty || plain.hasPrefix("-") || plain.hasPrefix("@") || plain.hasSuffix("*")
            || plain.contains(where: { $0.isWhitespace || $0 == "(" || $0 == ")" })
        return needsQuotes ? "\"\(plain)\"" : plain
    }

    // MARK: Sizes and dates

    /// "500", "500K", "5M", "1.5G", "2 MB", "3MiB" → bytes (K/M/G = 1024).
    static func size(_ raw: String) -> Int64? {
        let s = raw.lowercased().replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: " ", with: "")
        let split = s.firstIndex(where: { !("0"..."9").contains($0) && $0 != "." }) ?? s.endIndex
        guard let n = Double(s[..<split]), n.isFinite, n >= 0 else { return nil }
        let (k, m, g): (Double, Double, Double) = (1_024, 1_048_576, 1_073_741_824)
        let units: [String: Double] = ["": 1, "b": 1, "k": k, "kb": k, "kib": k, "m": m, "mb": m, "mib": m,
                                       "g": g, "gb": g, "gib": g]
        guard let unit = units[String(s[split...])] else { return nil }
        let bytes = n * unit
        return bytes <= 1e15 ? Int64(bytes) : nil
    }

    enum DateValue: Equatable {
        /// A calendar period: start inclusive, end exclusive.
        case period(Date, Date)
        /// A relative instant ("30d" = 30 days ago).
        case point(Date)
    }

    static func date(_ raw: String, now: Date, calendar: Calendar) -> DateValue? {
        let s = raw.lowercased()
        let today = calendar.startOfDay(for: now)
        switch s {
        case "today", "heute":
            return calendar.date(byAdding: .day, value: 1, to: today).map { .period(today, $0) }
        case "yesterday", "gestern":
            return calendar.date(byAdding: .day, value: -1, to: today).map { .period($0, today) }
        default: break
        }
        let digits = { (t: Substring) in !t.isEmpty && t.allSatisfy { ("0"..."9").contains($0) } }
        // relative: 30d, 2w, 6m, 1y (German: t, j)
        if let unit = s.last, "dtwmyj".contains(unit), digits(s.dropLast()), let n = Int(s.dropLast()), (1...100_000).contains(n) {
            let component: Calendar.Component = switch unit {
            case "d", "t": .day
            case "w": .weekOfYear
            case "m": .month
            default: .year
            }
            return calendar.date(byAdding: component, value: -n, to: now).map { .point($0) }
        }
        var y: Int?, m: Int?, d: Int?
        let dashed = s.split(separator: s.contains("/") ? "/" : "-", omittingEmptySubsequences: false)
        let dotted = s.split(separator: ".", omittingEmptySubsequences: false)
        if dashed.count <= 3, dashed.allSatisfy(digits), dashed[0].count == 4 {
            y = Int(dashed[0])
            if dashed.count > 1 { m = Int(dashed[1]) }
            if dashed.count > 2 { d = Int(dashed[2]) }
        } else if dotted.count == 3, dotted.allSatisfy(digits), dotted[2].count == 4, dotted[0].count <= 2, dotted[1].count <= 2 {
            (d, m, y) = (Int(dotted[0]), Int(dotted[1]), Int(dotted[2]))
        } else {
            return nil
        }
        guard let year = y, (1900...2999).contains(year) else { return nil }
        let parts = DateComponents(year: year, month: m ?? 1, day: d ?? 1)
        guard let start = calendar.date(from: parts) else { return nil }
        let check = calendar.dateComponents([.year, .month, .day], from: start)
        guard check.year == year, check.month == (m ?? 1), check.day == (d ?? 1) else { return nil }  // 2024-02-31
        let step: Calendar.Component = d != nil ? .day : (m != nil ? .month : .year)
        return calendar.date(byAdding: step, value: 1, to: start).map { .period(start, $0) }
    }
}
