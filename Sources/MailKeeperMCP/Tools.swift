import Foundation
import MailKeeperKit
import MailKeeperAI

/// Summarises one conversation — `MailSummarizer` through LiteLLM in the server, a fake in tests.
public protocol ConversationSummarizer: Sendable {
    func summarize(_ messages: [SummaryMessage], total: Int, flagged: Bool) async throws -> MailSummary
}

extension MailSummarizer: ConversationSummarizer {
    public func summarize(_ messages: [SummaryMessage], total: Int, flagged: Bool) async throws -> MailSummary {
        try await summarize(messages, total: Optional(total), flagged: flagged)
    }
}

/// What a tool call sees.
public struct ToolContext: Sendable {
    public var principal: Principal
    public var archives: ArchiveAccess
    public var summarizer: (any ConversationSummarizer)?
    public var timeZone: TimeZone
    public var now: Date
}

/// A tool's answer before the envelope: the model's text and the card.
public struct ToolOutput: Sendable {
    public var text: String
    public var card: JSONValue?
}

public struct Tool: Sendable {
    public var name: String
    public var title: String
    public var description: String
    public var inputSchema: JSONValue
    public var presentation: String
    public var run: @Sendable (ToolContext, Args) async throws -> ToolOutput

    /// `tools/list` entry: annotations plus the v2 metadata (standard v2.2 §2).
    public var listing: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description), "inputSchema": inputSchema,
            "annotations": ["title": .string(title), "readOnlyHint": true, "destructiveHint": false,
                            "idempotentHint": true, "openWorldHint": false],
            "_meta": ["v2": ["risk": "read_only", "data_class": "personal", "confirmation": "none", "audit": "metadata",
                             "output_trust": "external", "presentation": ["type": .string(presentation)]]],
        ]
    }
}

/// Arguments, checked strictly: an unknown name or a value outside its limit is refused, never
/// cut quietly (standard v2.2 §14.3).
public struct Args: Sendable {
    let raw: [String: JSONValue]

    public init(_ raw: [String: JSONValue], allowed: Set<String>) throws {
        if let unknown = raw.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Refusal("invalid", "unknown argument \"\(unknown.prefix(40))\"", hint: "allowed: " + allowed.sorted().joined(separator: ", "))
        }
        self.raw = raw
    }

    func string(_ key: String, max: Int, required: Bool = false) throws -> String? {
        guard let value = raw[key], !value.isNull else {
            if required { throw Refusal("invalid", "\(key) is required") }
            return nil
        }
        guard let s = value.string else { throw Refusal("invalid", "\(key) must be a string") }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= max else { throw Refusal("limit_exceeded", "\(key) is too long", limit: .int(Int64(max)), got: .int(Int64(t.count))) }
        if required, t.isEmpty { throw Refusal("invalid", "\(key) is empty") }
        return t.isEmpty ? nil : t
    }

    func int(_ key: String, default value: Int, range: ClosedRange<Int>) throws -> Int {
        guard let v = raw[key], !v.isNull else { return value }
        guard let i = v.integer else { throw Refusal("invalid", "\(key) must be an integer") }
        guard range.contains(Int(i)) else {
            throw Refusal("limit_exceeded", "\(key) must be \(range.lowerBound)–\(range.upperBound)",
                          limit: .int(Int64(range.upperBound)), got: .int(i))
        }
        return Int(i)
    }

    /// A day, `YYYY-MM-DD`, that exists.
    func day(_ key: String) throws -> String? {
        guard let s = try string(key, max: 10) else { return nil }
        let parts = s.split(separator: "-")
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else {
            throw Refusal("invalid", "\(key) must be a day like 2026-11-01")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: y, month: m, day: d) else {
            throw Refusal("invalid", "\(key) is no such day")
        }
        return s
    }

    func choice(_ key: String, _ allowed: [String]) throws -> String? {
        guard let s = try string(key, max: 40) else { return nil }
        guard allowed.contains(s) else { throw Refusal("invalid", "\(key) must be one of " + allowed.joined(separator: ", ")) }
        return s
    }
}

// MARK: The tools

public enum MailTools {
    public static let all: [Tool] = [search, fetch, listPersons, mailThread, mailAttachments, summarizeCorrespondence]

    static let dataClass: JSONValue = "personal"
    static let maxCardItems = 100
    static let maxCardString = 300
    static let maxDocument = 64 << 10

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
         "additionalProperties": false]
    }

    static let dateProps: [String: JSONValue] = [
        "date_from": ["type": "string", "description": "Erster Tag (YYYY-MM-DD), Datum der Mail"],
        "date_to": ["type": "string", "description": "Letzter Tag (YYYY-MM-DD), einschließlich"],
    ]

    /// Query text from the shared filters; values are checked before they reach the language.
    static func filterQuery(query: String?, dateFrom: String?, dateTo: String?, person: String?, type: String?) throws -> String {
        var parts: [String] = []
        if let query { parts.append("(\(query))") }
        if let dateFrom { parts.append("after:\(dateFrom)") }
        if let dateTo { parts.append("until:\(dateTo)") }
        if let person {
            let p = person.filter { !"\"()\\".contains($0) }.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { throw Refusal("invalid", "person is empty") }
            parts.append("(from:\"\(p)\" OR to:\"\(p)\")")
        }
        switch type {
        case "received": parts.append("-is:sent")
        case "sent": parts.append("is:sent")
        case "attachment": parts.append("has:attachment")
        default: break
        }
        let text = parts.joined(separator: " ")
        if !text.isEmpty {
            do { _ = try QueryParser.parse(text) } catch { throw Refusal("invalid", "the query cannot be read: \(error)") }
        }
        return text + " "
    }

    // MARK: search

    static let search = Tool(
        name: "search", title: "Mails suchen",
        description: "Sucht im eigenen Mail-Archiv (Suchsprache wie in MailKeeper: Wörter, from:, to:, subject:, has:pdf, folder: …). "
            + "Liefert Kurzbriefe ohne Volltext; den Inhalt einer Mail holt fetch.",
        inputSchema: schema(dateProps.merging([
            "query": ["type": "string", "description": "Suchtext, höchstens 500 Zeichen"],
            "person": ["type": "string", "description": "Absender oder Empfänger (Adresse oder Name)"],
            "type": ["type": "string", "enum": ["received", "sent", "attachment"]],
            "limit": ["type": "integer", "minimum": 1, "maximum": 50, "default": 20],
            "offset": ["type": "integer", "minimum": 0, "maximum": 10_000, "default": 0],
        ]) { $1 }),
        presentation: "result-list"
    ) { ctx, a in
        let text = try filterQuery(query: try a.string("query", max: 500), dateFrom: try a.day("date_from"), dateTo: try a.day("date_to"),
                                   person: try a.string("person", max: 200), type: try a.choice("type", ["received", "sent", "attachment"]))
        let limit = try a.int("limit", default: 20, range: 1...50)
        let offset = try a.int("offset", default: 0, range: 0...10_000)
        let (total, briefs, sent) = try await ctx.archives.read(ctx.principal.person) { reader in
            let ids = try reader.messageIDs(MessageFilter(text: text))
            let page = Array(ids.dropFirst(offset).prefix(limit))
            return (ids.count, try reader.connectorBriefs(page), Set(try reader.messageIDs(MessageFilter(text: "is:sent ", ids: page))))
        }
        let f = Formats(ctx.timeZone)
        guard !briefs.isEmpty else {
            return ToolOutput(text: total == 0 ? "Keine Mail gefunden." : "Keine weiteren Treffer (insgesamt \(total)).",
                              card: ["type": "result-list", "title": "Mails", "items": []])
        }
        var lines = ["\(total) Treffer, hier \(offset + 1)–\(offset + briefs.count):"]
        for (n, b) in briefs.enumerated() {
            lines.append("\(offset + n + 1). " + f.line(b, sent: sent.contains(b.row)))
            if let s = b.snippet.map({ oneLine($0, 200) }), !s.isEmpty { lines.append("   " + s) }
        }
        if offset + briefs.count < total { lines.append("Weitere mit offset \(offset + briefs.count).") }
        return ToolOutput(text: lines.joined(separator: "\n"),
                          card: ["type": "result-list", "title": .string("Mails (\(total))"),
                                 "items": .array(briefs.prefix(maxCardItems).map { f.item($0, sent: sent.contains($0.row)) })])
    }

    // MARK: fetch

    static let fetch = Tool(
        name: "fetch", title: "Mail lesen",
        description: "Eine Mail mit Kopfzeilen, Anhangsliste und Text, nach Token-Budget gekürzt. "
            + "query: Stichworte mit Komma — dann die passendsten Absätze in Reihenfolge, sonst der Anfang.",
        inputSchema: schema([
            "id": ["type": "string", "description": "id aus search, mail_thread oder list"],
            "max_tokens": ["type": "integer", "minimum": 200, "maximum": 20_000, "default": 4_000],
            "query": ["type": "string", "description": "Stichworte, mit Komma getrennt"],
        ], required: ["id"]),
        presentation: "document"
    ) { ctx, a in
        let id = try a.string("id", max: 1_000, required: true)!
        let maxTokens = try a.int("max_tokens", default: Budget.defaultTokens, range: Budget.tokenRange)
        let keywords = try a.string("query", max: 500)
        let mail = try await ctx.archives.read(ctx.principal.person) { reader -> MailView? in
            guard let row = try reader.rowID(identity: id), let detail = try reader.detail(row),
                  let parsed = try reader.parsedMessage(row) else { return nil }
            return MailView(detail: detail, parsed: parsed)
        }
        guard let mail else { throw notFound }
        let f = Formats(ctx.timeZone)
        var head = ["Betreff: \(oneLine(mail.parsed.subject ?? "(ohne Betreff)", 300))"]
        if !mail.parsed.from.isEmpty { head.append("Von: " + mail.parsed.from.map(\.display).joined(separator: ", ")) }
        if !mail.parsed.to.isEmpty { head.append("An: " + oneLine(mail.parsed.to.map(\.display).joined(separator: ", "), 600)) }
        if !mail.parsed.cc.isEmpty { head.append("Cc: " + oneLine(mail.parsed.cc.map(\.display).joined(separator: ", "), 600)) }
        if let d = mail.detail.summary.date { head.append("Datum: \(f.minute(d)) (\(ctx.timeZone.identifier))") }
        head.append("Ablage: " + mail.detail.filed.map { "\($0.account)/\($0.mailbox)" }.joined(separator: ", "))
        let named = mail.parsed.attachments.filter { !$0.isInline }
        if !named.isEmpty {
            head.append("Anhänge: " + named.map { a in
                "\(AttachmentSafety.sanitizedFilename(a.filename, mimeType: a.mimeType)) (\(f.size(a.size)), \(a.mimeType))"
            }.joined(separator: "; "))
        }
        head.append("id: \(id)")
        let header = head.joined(separator: "\n")
        let budget = maxTokens * Budget.charsPerToken - header.count - 2
        let body = Budget.select(mail.parsed.text, maxChars: max(200, budget), keywords: keywords)
        let text = header + "\n\n" + body.text
        let cardText = String(text.prefix(maxDocument))
        return ToolOutput(text: text, card: [
            "type": "document", "title": .string(oneLine(mail.parsed.subject ?? "(ohne Betreff)", maxCardString)), "format": "plain",
            "text": .string(cardText), "truncated": .bool(body.truncated || cardText.count < text.count),
        ])
    }

    struct MailView: @unchecked Sendable {  // values only; MIMEPart holds no references
        var detail: MessageDetail
        var parsed: ParsedMessage
    }

    // MARK: list_persons

    static let listPersons = Tool(
        name: "list_persons", title: "Korrespondenten",
        description: "Wer dem Archiv-Inhaber geschrieben hat, mit Anzahl und letzter Mail, optional in einem Zeitraum.",
        inputSchema: schema(dateProps.merging(["limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 50]]) { $1 }),
        presentation: "table"
    ) { ctx, a in
        let text = try filterQuery(query: nil, dateFrom: try a.day("date_from"), dateTo: try a.day("date_to"), person: nil, type: "received")
        let limit = try a.int("limit", default: 50, range: 1...200)
        let groups = try await ctx.archives.read(ctx.principal.person) { reader in
            try reader.groups(MessageFilter(text: text), by: .sender, limit: limit)
        }
        let f = Formats(ctx.timeZone)
        let sorted = groups.sorted { $0.count != $1.count ? $0.count > $1.count : $0.key < $1.key }.prefix(limit)
        guard !sorted.isEmpty else { return ToolOutput(text: "Keine Korrespondenten im Zeitraum.", card: ["type": "table", "columns": ["Name", "Adresse", "Mails", "zuletzt"], "rows": []]) }
        let rows = sorted.map { g -> [String] in
            [oneLine(g.name ?? "", 80), g.key, String(g.count), g.newest.map(f.day) ?? ""]
        }
        let text2 = (["\(sorted.count) Korrespondenten (Name · Adresse · Mails · zuletzt):"]
            + rows.map { $0.filter { !$0.isEmpty }.joined(separator: " · ") }).joined(separator: "\n")
        return ToolOutput(text: text2, card: ["type": "table", "columns": ["Name", "Adresse", "Mails", "zuletzt"],
                                               "rows": .array(rows.prefix(20).map { .array($0.map { .string(String($0.prefix(maxCardString))) }) })])
    }

    // MARK: mail_thread

    static let mailThread = Tool(
        name: "mail_thread", title: "Konversation",
        description: "Die Konversation zu einer Mail (id) oder die Konversationen zu einer Suche (query), älteste zuerst, "
            + "mit Absendern und Anhängen je Mail.",
        inputSchema: schema([
            "id": ["type": "string"], "query": ["type": "string", "description": "Suchtext wie bei search"],
            "max_threads": ["type": "integer", "minimum": 1, "maximum": 5, "default": 3],
            "max_mails": ["type": "integer", "minimum": 1, "maximum": 100, "default": 40],
        ]),
        presentation: "result-list"
    ) { ctx, a in
        let id = try a.string("id", max: 1_000)
        let query = try a.string("query", max: 500)
        guard (id == nil) != (query == nil) else { throw Refusal("invalid", "give either id or query") }
        let maxThreads = try a.int("max_threads", default: 3, range: 1...5)
        let maxMails = try a.int("max_mails", default: 40, range: 1...100)
        let text = try query.map { try filterQuery(query: $0, dateFrom: nil, dateTo: nil, person: nil, type: nil) }
        let threads = try await ctx.archives.read(ctx.principal.person) { reader -> [[ConnectorBrief]]? in
            var seeds: [Int64] = []
            if let id {
                guard let row = try reader.rowID(identity: id) else { return nil }
                seeds = [row]
            } else if let text {
                let hits = Array(try reader.messageIDs(MessageFilter(text: text)).prefix(500))
                let keys = try reader.conversationKeys(hits)
                var seen = Set<Int64>()
                for hit in hits where seeds.count < maxThreads {
                    if seen.insert(keys[hit] ?? -hit).inserted { seeds.append(hit) }
                }
            }
            return try seeds.map { seed in try reader.connectorBriefs(try reader.thread(of: seed, limit: maxMails).map(\.id)) }
        }
        guard let threads else { throw notFound }
        guard !threads.isEmpty else { return ToolOutput(text: "Keine Konversation gefunden.", card: ["type": "result-list", "title": "Konversationen", "items": []]) }
        let f = Formats(ctx.timeZone)
        var lines: [String] = []
        var items: [JSONValue] = []
        for (n, mails) in threads.enumerated() {
            let first = mails.first, last = mails.last
            let who = Array(Set(mails.compactMap { $0.fromName ?? $0.fromAddress })).sorted().prefix(6).joined(separator: ", ")
            let span = [first?.date, last?.date].compactMap { $0.map(f.day) }
            lines.append("Konversation \(n + 1): \(oneLine(first?.subject ?? "(ohne Betreff)", 200)) — \(mails.count) Mails"
                + (span.isEmpty ? "" : ", \(span.first!)–\(span.last!)") + (who.isEmpty ? "" : ", Beteiligte: \(who)"))
            for (m, b) in mails.enumerated() { lines.append("  \(m + 1). " + f.line(b, sent: false)) }
            if let more = first?.threadCount, more > mails.count { lines.append("  (die Konversation hat \(more) Mails; max_mails erhöhen für mehr)") }
            items += mails.map { f.item($0, sent: false) }
        }
        return ToolOutput(text: lines.joined(separator: "\n"),
                          card: ["type": "result-list", "title": "Konversationen", "items": .array(Array(items.prefix(maxCardItems)))])
    }

    // MARK: mail_attachments

    static let mailAttachments = Tool(
        name: "mail_attachments", title: "Anhänge einer Mail",
        description: "Die Anhänge einer Mail mit Dateiname, Typ, Größe und SHA-256 (Paperless führt dieselbe Prüfsumme als checksum).",
        inputSchema: schema(["id": ["type": "string"]], required: ["id"]),
        presentation: "table"
    ) { ctx, a in
        let id = try a.string("id", max: 1_000, required: true)!
        let rows = try await ctx.archives.read(ctx.principal.person) { reader -> [[String]]? in
            guard let row = try reader.rowID(identity: id), let parsed = try reader.parsedMessage(row) else { return nil }
            return parsed.attachments.map { info in
                let name = AttachmentSafety.sanitizedFilename(info.filename, mimeType: info.mimeType)
                let data = parsed.data(of: info)
                return [name, info.mimeType, String(data?.count ?? info.size), data.map(sha256Hex) ?? "",
                        info.isInline ? "ja" : "nein", AttachmentSafety.isRisky(filename: name, mimeType: info.mimeType) ? "ja" : "nein"]
            }
        }
        guard let rows else { throw notFound }
        let f = Formats(ctx.timeZone)
        guard !rows.isEmpty else { return ToolOutput(text: "Die Mail hat keine Anhänge.", card: ["type": "table", "columns": ["Datei", "Typ", "Größe", "SHA-256", "im Text", "riskant"], "rows": []]) }
        let text = (["\(rows.count) Anhänge (Datei · Typ · Größe · SHA-256 · im Text gezeigt · riskant):"] + rows.map { r in
            "\(r[0]) · \(r[1]) · \(f.size(Int(r[2]) ?? 0)) · \(r[3]) · \(r[4]) · \(r[5])"
        }).joined(separator: "\n")
        return ToolOutput(text: text, card: ["type": "table", "columns": ["Datei", "Typ", "Größe", "SHA-256", "im Text", "riskant"],
                                              "rows": .array(rows.prefix(20).map { r in .array([r[0], r[1], f.size(Int(r[2]) ?? 0), String(r[3].prefix(16)), r[4], r[5]].map { .string(String($0.prefix(maxCardString))) }) })])
    }

    // MARK: summarize_correspondence

    static let summarizeCorrespondence = Tool(
        name: "summarize_correspondence", title: "Korrespondenz zusammenfassen",
        description: "Fasst die Konversationen mit einer Person zusammen, neueste zuerst (KI über LiteLLM; je Konversation die letzten 25 Mails).",
        inputSchema: schema(dateProps.merging([
            "person": ["type": "string", "description": "Adresse oder Name"],
            "max_threads": ["type": "integer", "minimum": 1, "maximum": 10, "default": 5],
        ]) { $1 }, required: ["person"]),
        presentation: "document"
    ) { ctx, a in
        guard let summarizer = ctx.summarizer else {
            throw Refusal("ai_unavailable", "no language model is configured for summaries")
        }
        let person = try a.string("person", max: 200, required: true)!
        let text = try filterQuery(query: nil, dateFrom: try a.day("date_from"), dateTo: try a.day("date_to"), person: person, type: nil)
        let maxThreads = try a.int("max_threads", default: 5, range: 1...10)
        struct Conversation: Sendable { var subject: String; var count: Int; var from: Date?; var to: Date?; var messages: [SummaryMessage]; var total: Int; var flagged: Bool }
        let conversations = try await ctx.archives.read(ctx.principal.person) { reader -> [Conversation] in
            let hits = Array(try reader.messageIDs(MessageFilter(text: text)).prefix(2_000))
            let keys = try reader.conversationKeys(hits)
            var seen = Set<Int64>(), seeds: [Int64] = []
            for hit in hits where seeds.count < maxThreads {
                if seen.insert(keys[hit] ?? -hit).inserted { seeds.append(hit) }
            }
            return try seeds.map { seed in
                let thread = try reader.thread(of: seed, limit: 500)
                let (messages, total, flagged) = try MailSummarizer.messages(thread.map(\.id), reader: reader)
                return Conversation(subject: thread.first?.subject ?? "(ohne Betreff)", count: thread.count,
                                    from: thread.first?.date, to: thread.last?.date, messages: messages, total: total, flagged: flagged)
            }
        }
        guard !conversations.isEmpty else { return ToolOutput(text: "Keine Mails mit \(person) gefunden.", card: nil) }
        // three at a time: the endpoint is shared (standard v2.2 §14.10)
        var results = [Result<MailSummary, Error>?](repeating: nil, count: conversations.count)
        try await withThrowingTaskGroup(of: (Int, Result<MailSummary, Error>).self) { group in
            var next = 0
            func start() {
                guard next < conversations.count else { return }
                let i = next, c = conversations[i]
                next += 1
                group.addTask {
                    do { return (i, .success(try await summarizer.summarize(c.messages, total: c.total, flagged: c.flagged))) }
                    catch { return (i, .failure(error)) }
                }
            }
            for _ in 0..<min(3, conversations.count) { start() }
            while let (i, result) = try await group.next() {
                results[i] = result
                start()
            }
        }
        guard results.contains(where: { if case .success = $0 { true } else { false } }) else {
            throw Refusal("ai_unavailable", "the language model did not answer")
        }
        let f = Formats(ctx.timeZone)
        var parts = ["Korrespondenz mit \(person): \(conversations.count) Konversation(en), neueste zuerst. Zusammenfassung durch ein Sprachmodell aus den Mails — Aussagen der Absender sind ihre Behauptungen."]
        for (c, result) in zip(conversations, results) {
            let span = [c.from, c.to].compactMap { $0.map(f.day) }
            parts.append("## \(oneLine(c.subject, 200)) (\(c.count) Mails" + (span.isEmpty ? "" : ", \(span.first!)–\(span.last!)") + ")")
            switch result {
            case .success(let s)?: parts.append(s.plainText + (s.covered < s.total ? "\n(aus den letzten \(s.covered) von \(s.total) Mails)" : ""))
            case .failure(let e)?: parts.append("(Zusammenfassung fehlgeschlagen: \(Self.kind(e)))")
            case nil: parts.append("(nicht zusammengefasst)")
            }
        }
        let out = parts.joined(separator: "\n\n")
        return ToolOutput(text: out, card: ["type": "document", "title": .string(oneLine("Korrespondenz mit \(person)", maxCardString)),
                                             "format": "plain", "text": .string(String(out.prefix(maxDocument))), "truncated": .bool(out.count > maxDocument)])
    }

    static func kind(_ error: Error) -> String {
        if let e = error as? AIError { return String(describing: e).prefix(120).description }
        return "Fehler"
    }

    static let notFound = Refusal("not_found", "this mail does not exist or is not visible to this user")
}

/// One line of text, at most `max` characters.
func oneLine(_ s: String, _ max: Int) -> String {
    let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return flat.count > max ? String(flat.prefix(max - 1)) + "…" : flat
}

/// Dates, sizes and items in the configured zone.
struct Formats {
    let dayFormat: DateFormatter
    let minuteFormat: DateFormatter

    init(_ zone: TimeZone) {
        dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.calendar = Calendar(identifier: .gregorian)
        dayFormat.timeZone = zone
        dayFormat.dateFormat = "yyyy-MM-dd"
        minuteFormat = DateFormatter()
        minuteFormat.locale = Locale(identifier: "en_US_POSIX")
        minuteFormat.calendar = Calendar(identifier: .gregorian)
        minuteFormat.timeZone = zone
        minuteFormat.dateFormat = "yyyy-MM-dd HH:mm"
    }

    func day(_ d: Date) -> String { dayFormat.string(from: d) }
    func minute(_ d: Date) -> String { minuteFormat.string(from: d) }

    func size(_ bytes: Int) -> String {
        bytes >= 1 << 20 ? String(format: "%.1f MB", Double(bytes) / 1_048_576) : bytes >= 1024 ? "\(bytes / 1024) KB" : "\(bytes) B"
    }

    /// The correspondent: the sender, or for mail the person sent, the first recipient.
    func person(_ b: ConnectorBrief, sent: Bool) -> String {
        if sent, let to = b.to?.split(separator: ",").first { return "an " + oneLine(String(to), 80) }
        return oneLine(b.fromName.flatMap { $0.isEmpty ? nil : $0 } ?? b.fromAddress ?? "", 80)
    }

    func line(_ b: ConnectorBrief, sent: Bool) -> String {
        var parts = [b.date.map(minute) ?? "ohne Datum", person(b, sent: sent), oneLine(b.subject ?? "(ohne Betreff)", 200)]
        if b.attachmentCount > 0 { parts.append("\(b.attachmentCount) Anhang" + (b.attachmentCount == 1 ? "" : "e")) }
        parts.append("id \(b.identity)")
        return parts.joined(separator: " · ")
    }

    func item(_ b: ConnectorBrief, sent: Bool) -> JSONValue {
        var o: [String: JSONValue] = [
            "id": .string(b.identity), "title": .string(oneLine(b.subject ?? "(ohne Betreff)", MailTools.maxCardString)),
            "type": "mail", "person": .string(person(b, sent: sent)), "data_class": MailTools.dataClass,
        ]
        if let d = b.date { o["date"] = .string(day(d)) }
        let snippet = oneLine([person(b, sent: sent), b.snippet ?? ""].filter { !$0.isEmpty }.joined(separator: " — "), MailTools.maxCardString)
        if !snippet.isEmpty { o["snippet"] = .string(snippet) }
        if let link = deepLink(b.messageID) { o["deep_link"] = .string(link) }
        return .object(o)
    }

    /// RFC 2392 `mid:` URL of a Message-ID (as in the Paperless ledger, ADR-0016).
    func deepLink(_ messageID: String?) -> String? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%<>"))
        guard let mid = messageID?.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")), !mid.isEmpty,
              let encoded = mid.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return "mid:" + encoded
    }
}
