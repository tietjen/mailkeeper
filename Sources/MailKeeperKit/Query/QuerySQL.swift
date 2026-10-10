import Foundation

/// Query tree → SQL condition on `messages m` (ADR-0008). Every user value is a parameter;
/// parameters are appended in the order their placeholders appear in the SQL.
struct QuerySQL {
    private(set) var params: [SQLValue] = []

    mutating func condition(_ node: QueryNode) -> String {
        switch node {
        case .predicate(let p): predicate(p)
        case .not(let inner): "NOT (\(condition(inner)))"
        case .and(let items): combine(items, op: "AND")
        case .or(let items): combine(items, op: "OR")
        }
    }

    /// Full-text leaves of one AND/OR level share a MATCH per table. Plain words (`any`) must be
    /// found in the message OR its attachment text — each word on its own under AND, so a word
    /// in the body and another in the PDF still match (ADR-0009).
    private mutating func combine(_ items: [QueryNode], op: String) -> String {
        var parts: [String] = []
        var message: [String] = []
        var attachment: [String] = []
        for item in items {
            guard case .predicate(.text(let field, let value, let prefix)) = item else {
                parts.append(condition(item))
                continue
            }
            let expression = Self.fts(field, value, prefix: prefix)
            switch field {
            case .pdf: attachment.append(expression)
            case .any where op == "OR": message.append(expression); attachment.append(expression)
            case .any: parts.append(anyText(expression))
            default: message.append(expression)
            }
        }
        let joined = { (e: [String]) in e.map { "(\($0))" }.joined(separator: " \(op) ") }
        if !message.isEmpty { parts.append(match(joined(message), in: "messages_fts")) }
        if !attachment.isEmpty { parts.append(match(joined(attachment), in: "attachment_text_fts")) }
        return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " \(op) ") + ")"
    }

    /// `table` is one of two fixed names, never user input.
    private mutating func match(_ expression: String, in table: String) -> String {
        params.append(.text(expression))
        return "m.id IN (SELECT rowid FROM \(table) WHERE \(table) MATCH ?)"
    }

    private mutating func anyText(_ expression: String) -> String {
        params += [.text(expression), .text(expression)]
        return "m.id IN (SELECT rowid FROM messages_fts WHERE messages_fts MATCH ? "
            + "UNION SELECT rowid FROM attachment_text_fts WHERE attachment_text_fts MATCH ?)"
    }

    private static let columns: [QueryPredicate.TextField: String] = [
        .subject: "subject", .from: "from_text", .to: "to_text", .body: "body", .filename: "attachments",
    ]

    /// One term as FTS5 expression: quoted (the value carries no quotes), spelling variants
    /// OR-ed, optional column filter (fixed names, never user input).
    static func fts(_ field: QueryPredicate.TextField, _ value: String, prefix: Bool) -> String {
        let variants = SearchText.spellingVariants(value).map { "\"\($0)\"" + (prefix ? "*" : "") }
        let group = variants.count == 1 ? variants[0] : "(" + variants.joined(separator: " OR ") + ")"
        guard let column = columns[field] else { return group }
        return "\(column) : \(group)"
    }

    private mutating func predicate(_ p: QueryPredicate) -> String {
        switch p {
        case .text(.any, let value, let prefix):
            return anyText(Self.fts(.any, value, prefix: prefix))
        case .text(.pdf, let value, let prefix):
            return match(Self.fts(.pdf, value, prefix: prefix), in: "attachment_text_fts")
        case .text(let field, let value, let prefix):
            return match(Self.fts(field, value, prefix: prefix), in: "messages_fts")
        case .sender(let address):
            params.append(.text(address))
            return "m.from_addr = ? COLLATE NOCASE"
        case .domain(let domain):
            params.append(.text(domain))
            return "lower(substr(m.from_addr, instr(m.from_addr, '@') + 1)) = ? AND instr(m.from_addr, '@') > 0"
        case .has(.any):
            return "m.attachment_count > 0"
        case .has(.pdf):
            return attachment("(a.mime_type = 'application/pdf' OR a.filename LIKE '%.pdf')")
        case .has(.image):
            return attachment("a.mime_type LIKE 'image/%'")
        case .has(.calendar):
            return attachment("(a.mime_type IN ('text/calendar', 'application/ics') OR a.filename LIKE '%.ics')")
        case .larger(let bytes):
            params.append(.int(bytes))
            return "m.size > ?"
        case .smaller(let bytes):
            params.append(.int(bytes))
            return "m.size < ?"
        case .dateFrom(let date):
            params.append(.double(date.timeIntervalSince1970))
            return "m.date >= ?"
        case .dateBefore(let date):
            params.append(.double(date.timeIntervalSince1970))
            return "m.date < ?"
        case .account(let id):
            return location("l.account_id = ?", .text(id))
        case .folder(let name, prefix: false):
            return location("l.mailbox = ? COLLATE NOCASE", .text(name))
        case .folder(let name, prefix: true):
            return location("l.mailbox LIKE ? ESCAPE '\\'", .text(Self.escapeLike(name) + "%"))
        case .label(let label):
            return location("instr(char(31) || lower(l.labels) || char(31), char(31) || ? || char(31)) > 0", .text(label))
        case .list(let id):
            params.append(.text("%" + Self.escapeLike(id) + "%"))
            return "m.list_id LIKE ? ESCAPE '\\'"
        case .listID(let id):
            params.append(.text(id))
            return "m.list_id = ?"
        case .isList:
            return "(m.list_id IS NOT NULL OR m.list_unsubscribe = 1)"
        case .flag(.unread):
            return "NOT " + location(Self.flag, .text(" \\seen "))
        case .flag(.read):
            return location(Self.flag, .text(" \\seen "))
        case .flag(.flagged):
            return location(Self.flag, .text(" \\flagged "))
        case .flag(.answered):
            return location(Self.flag, .text(" \\answered "))
        case .onServer:
            return location("l.on_server = 1")
        case .archiveOnly:
            return "NOT " + location("l.on_server = 1")
        case .messageID(let id):
            params.append(.text(id))
            return "m.message_id = ?"
        case .thread(let id):
            params.append(.text(id))
            return "m.thread_id IN (SELECT t.thread_id FROM messages t WHERE t.message_id = ? AND t.thread_id IS NOT NULL)"
        }
    }

    private static let flag = "instr(' ' || lower(l.flags) || ' ', ?) > 0"

    /// Uncorrelated `IN` subqueries, evaluated once per query: a correlated EXISTS can make
    /// SQLite scan a big mailbox once per message (see ArchiveReader.whereClause).
    private mutating func location(_ condition: String, _ value: SQLValue? = nil) -> String {
        if let value { params.append(value) }
        return "m.id IN (SELECT l.message_id FROM locations l WHERE \(condition))"
    }

    private func attachment(_ condition: String) -> String {
        "m.id IN (SELECT a.message_id FROM attachments a WHERE a.is_inline = 0 AND \(condition))"
    }

    static func escapeLike(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
