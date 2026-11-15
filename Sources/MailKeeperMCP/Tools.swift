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
    /// `summarize_correspondence` ends here as a whole (ADR-0017: 180 s per call).
    public var summaryDeadline: Duration = .seconds(180)
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
        guard s.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}$"#, options: .regularExpression) != nil,
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
    static let maxCardRows = 20
    static let maxCardString = 300
    static let maxDocumentBytes = 64 << 10
    /// Model requests at a time across all calls (standard v2.2 §14.10: the endpoint is shared).
    static let modelGate = ModelGate(limit: 3)

    static func schema(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }),
         "additionalProperties": false]
    }

    static let dateProps: [String: JSONValue] = [
        "date_from": ["type": "string", "description": "Erster Tag (YYYY-MM-DD), Datum der Mail"],
        "date_to": ["type": "string", "description": "Letzter Tag (YYYY-MM-DD), einschließlich"],
    ]

    /// The shared filters as a `MessageFilter`: the free query and each filter are parsed on
    /// their own and AND-ed (`also`), so a query like `a) OR (b` cannot lift a date, person or
    /// type. Values are checked before they reach the language.
    static func messageFilter(query: String?, dateFrom: String?, dateTo: String?, person: String?, type: String?) throws -> MessageFilter {
        var also: [String] = []
        if let dateFrom { also.append("after:\(dateFrom)") }
        if let dateTo { also.append("until:\(dateTo)") }
        if let person {
            let p = person.filter { !"\"()\\".contains($0) }.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { throw Refusal("invalid", "person is empty") }
            also.append("from:\"\(p)\" OR to:\"\(p)\"")
        }
        switch type {
        case "received": also.append("-is:sent")
        case "sent": also.append("is:sent")
        case "attachment": also.append("has:attachment")
        default: break
        }
        for text in (query.map { [$0] } ?? []) + also {
            do { _ = try QueryParser.parse(text) } catch { throw Refusal("invalid", "the query cannot be read: \(error)") }
        }
        return MessageFilter(text: query.map { $0 + " " }, also: also.map { $0 + " " })
    }

    /// The first row of each of up to `max` conversations among `hits` (newest first), and
    /// whether there are more conversations than that.
    static func conversationSeeds(_ hits: [Int64], max: Int, reader: ArchiveReader) throws -> (seeds: [Int64], more: Bool) {
        let keys = try reader.conversationKeys(hits)
        var seen = Set<Int64>(), seeds: [Int64] = []
        for hit in hits where seen.insert(keys[hit] ?? -hit).inserted {
            guard seeds.count < max else { return (seeds, true) }
            seeds.append(hit)
        }
        return (seeds, false)
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
        let filter = try messageFilter(query: try a.string("query", max: 500), dateFrom: try a.day("date_from"), dateTo: try a.day("date_to"),
                                       person: try a.string("person", max: 200), type: try a.choice("type", ["received", "sent", "attachment"]))
        let limit = try a.int("limit", default: 20, range: 1...50)
        let offset = try a.int("offset", default: 0, range: 0...10_000)
        let (total, briefs, sent) = try await ctx.archives.read(ctx.principal.person) { reader in
            let ids = try reader.messageIDs(filter)
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
                                 "items": .array(briefs.map { f.item($0, sent: sent.contains($0.row)) })])
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
        let card = utf8Prefix(text, maxBytes: maxDocumentBytes)
        return ToolOutput(text: text, card: [
            "type": "document", "title": .string(oneLine(mail.parsed.subject ?? "(ohne Betreff)", maxCardString)), "format": "plain",
            "text": .string(card.text), "truncated": .bool(body.truncated || card.cut),
        ])
    }

    struct MailView: @unchecked Sendable {  // values only; MIMEPart holds no references
        var detail: MessageDetail
        var parsed: ParsedMessage
    }

    // MARK: list_persons

    static let listPersons = Tool(
        name: "list_persons", title: "Korrespondenten",
        description: "Wer dem Archiv-Inhaber geschrieben hat, mit Anzahl und letzter Mail, meiste zuerst, optional in einem Zeitraum.",
        inputSchema: schema(dateProps.merging([
            "limit": ["type": "integer", "minimum": 1, "maximum": 200, "default": 50],
            "offset": ["type": "integer", "minimum": 0, "maximum": 10_000, "default": 0],
        ]) { $1 }),
        presentation: "table"
    ) { ctx, a in
        let filter = try messageFilter(query: nil, dateFrom: try a.day("date_from"), dateTo: try a.day("date_to"), person: nil, type: "received")
        let limit = try a.int("limit", default: 50, range: 1...200)
        let offset = try a.int("offset", default: 0, range: 0...10_000)
        let groups = try await ctx.archives.read(ctx.principal.person) { reader in
            try reader.groups(filter, by: .sender, limit: offset + limit + 1)  // most mails first
        }
        let page = Array(groups.dropFirst(offset).prefix(limit))
        let more = groups.count > offset + limit
        let f = Formats(ctx.timeZone)
        let columns: JSONValue = ["Name", "Adresse", "Mails", "zuletzt"]
        guard !page.isEmpty else {
            return ToolOutput(text: offset == 0 ? "Keine Korrespondenten im Zeitraum." : "Keine weiteren Korrespondenten.",
                              card: ["type": "table", "columns": columns, "rows": []])
        }
        let rows = page.map { g -> [String] in [oneLine(g.name ?? "", 80), g.key, String(g.count), g.newest.map(f.day) ?? ""] }
        var lines = ["Korrespondenten \(offset + 1)–\(offset + page.count) (Name · Adresse · Mails · zuletzt):"]
        lines += rows.map { $0.filter { !$0.isEmpty }.joined(separator: " · ") }
        if more { lines.append("Weitere mit offset \(offset + page.count).") }
        return ToolOutput(text: lines.joined(separator: "\n"), card: [
            "type": "table", "columns": columns,
            "rows": .array(rows.prefix(maxCardRows).map { .array($0.map { .string(String($0.prefix(maxCardString))) }) }),
            "truncated": .bool(rows.count > maxCardRows || more),
        ])
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
        let found = try query.map { try messageFilter(query: $0, dateFrom: nil, dateTo: nil, person: nil, type: nil) }
        struct Found: Sendable { var threads: [[ConnectorBrief]]; var more: Bool; var capped: Bool }
        let result = try await ctx.archives.read(ctx.principal.person) { reader -> Found? in
            var seeds: [Int64] = [], more = false, capped = false
            if let id {
                guard let row = try reader.rowID(identity: id) else { return nil }
                seeds = [row]
            } else if let found {
                let all = try reader.messageIDs(found)
                capped = all.count > 500
                (seeds, more) = try conversationSeeds(Array(all.prefix(500)), max: maxThreads, reader: reader)
            }
            return Found(threads: try seeds.map { try reader.connectorBriefs(try reader.thread(of: $0, limit: maxMails).map(\.id)) },
                         more: more, capped: capped)
        }
        guard let result else { throw notFound }
        guard !result.threads.isEmpty else {
            return ToolOutput(text: "Keine Konversation gefunden.", card: ["type": "result-list", "title": "Konversationen", "items": []])
        }
        let f = Formats(ctx.timeZone)
        var lines: [String] = []
        var items: [JSONValue] = []
        for (n, mails) in result.threads.enumerated() {
            let first = mails.first, last = mails.last
            let who = Array(Set(mails.compactMap { $0.fromName ?? $0.fromAddress })).sorted().prefix(6).joined(separator: ", ")
            let span = [first?.date, last?.date].compactMap { $0.map(f.day) }
            lines.append("Konversation \(n + 1): \(oneLine(first?.subject ?? "(ohne Betreff)", 200)) — \(mails.count) Mails"
                + (span.isEmpty ? "" : ", \(span.first!)–\(span.last!)") + (who.isEmpty ? "" : ", Beteiligte: \(who)"))
            for (m, b) in mails.enumerated() { lines.append("  \(m + 1). " + f.line(b, sent: false)) }
            if let all = first?.threadCount, all > mails.count { lines.append("  (die Konversation hat \(all) Mails; max_mails erhöhen für mehr)") }
            items += mails.map { f.item($0, sent: false) }
        }
        if result.more { lines.append("Weitere Konversationen passen zur Suche; max_threads erhöhen oder die Suche enger fassen.") }
        if result.capped { lines.append("Gesucht wurde in den neuesten 500 Treffern.") }
        return ToolOutput(text: lines.joined(separator: "\n"), card: [
            "type": "result-list", "title": "Konversationen", "items": .array(Array(items.prefix(maxCardItems))),
            "truncated": .bool(items.count > maxCardItems || result.more || result.capped),
        ])
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
        let columns: JSONValue = ["Datei", "Typ", "Größe", "SHA-256", "im Text", "riskant"]
        guard !rows.isEmpty else { return ToolOutput(text: "Die Mail hat keine Anhänge.", card: ["type": "table", "columns": columns, "rows": []]) }
        let text = (["\(rows.count) Anhänge (Datei · Typ · Größe · SHA-256 · im Text gezeigt · riskant):"] + rows.map { r in
            "\(r[0]) · \(r[1]) · \(f.size(Int(r[2]) ?? 0)) · \(r[3]) · \(r[4]) · \(r[5])"
        }).joined(separator: "\n")
        return ToolOutput(text: text, card: [
            "type": "table", "columns": columns,
            "rows": .array(rows.prefix(maxCardRows).map { r in
                .array([r[0], r[1], f.size(Int(r[2]) ?? 0), String(r[3].prefix(16)), r[4], r[5]].map { .string(String($0.prefix(maxCardString))) })
            }),
            "truncated": .bool(rows.count > maxCardRows),
        ])
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
        let filter = try messageFilter(query: nil, dateFrom: try a.day("date_from"), dateTo: try a.day("date_to"), person: person, type: nil)
        let maxThreads = try a.int("max_threads", default: 5, range: 1...10)
        struct Conversation: Sendable { var subject: String; var count: Int; var from: Date?; var to: Date?; var messages: [SummaryMessage]; var total: Int; var flagged: Bool }
        struct Found: Sendable { var conversations: [Conversation]; var more: Bool; var capped: Bool }
        let found = try await ctx.archives.read(ctx.principal.person) { reader -> Found in
            let all = try reader.messageIDs(filter)
            let (seeds, more) = try conversationSeeds(Array(all.prefix(2_000)), max: maxThreads, reader: reader)
            let conversations = try seeds.map { seed in
                let thread = try reader.thread(of: seed, limit: 500)
                let (messages, total, flagged) = try MailSummarizer.messages(thread.map(\.id), reader: reader)
                return Conversation(subject: thread.first?.subject ?? "(ohne Betreff)", count: thread.count,
                                    from: thread.first?.date, to: thread.last?.date, messages: messages, total: total, flagged: flagged)
            }
            return Found(conversations: conversations, more: more, capped: all.count > 2_000)
        }
        let conversations = found.conversations
        guard !conversations.isEmpty else { return ToolOutput(text: "Keine Mails mit \(person) gefunden.", card: nil) }

        // Each conversation through the process-wide gate; the call as a whole ends at its
        // deadline — what is still open then is said, not dropped (§14.3), and a model that
        // does not stop on cancellation keeps only its gate slot, not this answer.
        enum Event: Sendable { case done(Int, Result<MailSummary, Error>), deadline }
        let (events, sink) = AsyncStream.makeStream(of: Event.self)
        let gate = modelGate
        let workers = conversations.enumerated().map { i, c in
            Task {
                let result: Result<MailSummary, Error>
                do {
                    try await gate.acquire()
                    do { result = .success(try await summarizer.summarize(c.messages, total: c.total, flagged: c.flagged)) }
                    catch { result = .failure(error) }
                    await gate.release()
                } catch {
                    result = .failure(error)  // cancelled while waiting for the gate
                }
                sink.yield(.done(i, result))
            }
        }
        let deadline = ctx.summaryDeadline
        let timer = Task { try? await Task.sleep(for: deadline); sink.yield(.deadline) }
        var results = [Result<MailSummary, Error>?](repeating: nil, count: conversations.count)
        var pending = conversations.count, timedOut = false
        for await event in events {
            switch event {
            case .done(let i, let r): results[i] = r; pending -= 1
            case .deadline: timedOut = true
            }
            if pending == 0 || timedOut { break }
        }
        timer.cancel()
        if timedOut { workers.forEach { $0.cancel() } }
        sink.finish()
        guard results.contains(where: { if case .success = $0 { true } else { false } }) else {
            throw Refusal("ai_unavailable", timedOut ? "the language model did not answer in time" : "the language model did not answer")
        }
        let f = Formats(ctx.timeZone)
        var parts = ["Korrespondenz mit \(person): \(conversations.count) Konversation(en), neueste zuerst. Zusammenfassung durch ein Sprachmodell aus den Mails — Aussagen der Absender sind ihre Behauptungen."]
        for (c, result) in zip(conversations, results) {
            let span = [c.from, c.to].compactMap { $0.map(f.day) }
            parts.append("## \(oneLine(c.subject, 200)) (\(c.count) Mails" + (span.isEmpty ? "" : ", \(span.first!)–\(span.last!)") + ")")
            switch result {
            case .success(let s)?: parts.append(s.plainText + (s.covered < s.total ? "\n(aus den letzten \(s.covered) von \(s.total) Mails)" : ""))
            case .failure(let e)?: parts.append("(Zusammenfassung fehlgeschlagen: \(kind(e)))")
            case nil: parts.append("(nicht zusammengefasst: Zeitlimit des Aufrufs erreicht)")
            }
        }
        if found.more { parts.append("Es gibt weitere Konversationen mit \(person); max_threads erhöhen oder den Zeitraum einschränken.") }
        if found.capped { parts.append("Berücksichtigt wurden die neuesten 2 000 Mails mit \(person).") }
        let out = parts.joined(separator: "\n\n")
        let card = utf8Prefix(out, maxBytes: maxDocumentBytes)
        return ToolOutput(text: out, card: ["type": "document", "title": .string(oneLine("Korrespondenz mit \(person)", maxCardString)),
                                             "format": "plain", "text": .string(card.text), "truncated": .bool(card.cut)])
    }

    /// A failure as a fixed category — never the server's text, which can echo the prompt or
    /// name internal hosts (as `AICallLog` keeps it out).
    static func kind(_ error: Error) -> String {
        switch error {
        case let e as AIError:
            switch e {
            case .timeout: return "keine Antwort in der Zeit"
            case .connection, .unavailable, .notConfigured: return "Modell nicht erreichbar"
            case .server(let code, _): return "Modell meldet Fehler \(code)"
            case .badAnswer, .truncated: return "unbrauchbare Antwort"
            }
        case is CancellationError: return "abgebrochen"
        default: return "Fehler"
        }
    }

    static let notFound = Refusal("not_found", "this mail does not exist or is not visible to this user")
}

/// At most `limit` holders at a time; waiters are served in order and leave when cancelled.
public actor ModelGate {
    let limit: Int
    private var running = 0
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []

    public init(limit: Int) { self.limit = limit }

    public func acquire() async throws {
        try Task.checkCancellation()
        if running < limit {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiting.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    /// Hands the slot to the next waiter, or frees it.
    public func release() {
        if waiting.isEmpty { running -= 1 } else { waiting.removeFirst().continuation.resume() }
    }
}

/// At most `maxBytes` of UTF-8 (the standard caps `document` cards by bytes), cut at a
/// character boundary; whether something was cut.
func utf8Prefix(_ text: String, maxBytes: Int) -> (text: String, cut: Bool) {
    guard text.utf8.count > maxBytes else { return (text, false) }
    var bytes = 0
    var end = text.startIndex
    for index in text.indices {
        let size = text[index].utf8.count
        if bytes + size > maxBytes { break }
        bytes += size
        end = text.index(after: index)
    }
    return (String(text[..<end]), true)
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
