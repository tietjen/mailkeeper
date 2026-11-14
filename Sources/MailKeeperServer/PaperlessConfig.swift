import Foundation
import MailKeeperKit

/// Which attachments go to Paperless, and where the dry run writes down what it would hand over
/// (ADR-0016). Generic: names of tags, owners and storage paths come from the deployment.
public struct PaperlessExport: Decodable, Sendable, Equatable {
    public enum Mode: String, Sendable, Equatable {
        /// Decide and write it down, upload nothing (mailkeeper-server Phase 2).
        case dryRun
    }

    public static let defaultMaxMessageBytes = 64 << 20

    public var mode: Mode
    /// One ledger per person and setting (`<person>-<fingerprint>.jsonl`): every message with
    /// attachments, every attachment with its SHA-256, the decision and its reason.
    public var ledgerDirectory: String
    /// Only messages this query (ADR-0008) matches, e.g. `-is:list -is:junk`. Absent: all. Field
    /// terms only — see `ruleProblem`.
    public var rule: String?
    /// Only messages that arrived on or after this day (YYYY-MM-DD in `timeZone`). Absent: the
    /// whole archive.
    public var since: String?
    /// IANA name ("Europe/Berlin"): which day a mail belongs to, for `since` and the documents'
    /// date — explicit, not the container's TZ, which may change between runs.
    public var timeZone: String
    /// File name extensions to hand over, lower case without dot ("pdf", "docx").
    public var extensions: [String]
    /// Smaller attachments stay out — logos and icons in signatures.
    public var minBytes: Int
    /// Larger messages are not read (noted in the ledger): parsing holds a message two or three
    /// times in memory, and one that kills the process would be tried again every run.
    public var maxMessageBytes: Int

    enum CodingKeys: String, CodingKey, CaseIterable {
        case mode, ledgerDirectory, rule, since, timeZone, extensions, minBytes, maxMessageBytes
    }

    public init(mode: Mode = .dryRun, ledgerDirectory: String, rule: String? = nil, since: String? = nil,
                timeZone: String = "UTC", extensions: [String], minBytes: Int, maxMessageBytes: Int = defaultMaxMessageBytes) {
        self.mode = mode
        self.ledgerDirectory = ledgerDirectory
        self.rule = rule
        self.since = since
        self.timeZone = timeZone
        self.extensions = extensions
        self.minBytes = minBytes
        self.maxMessageBytes = maxMessageBytes
    }

    public init(from decoder: Decoder) throws {
        try requireKnownKeys(decoder, CodingKeys.self, in: "paperless")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try c.decode(String.self, forKey: .mode)
        // Uploading comes later (Phase 4); until then a typo must not look like a mode.
        guard let mode = Mode(rawValue: raw) else { throw ConfigError("paperless: mode must be \"dryRun\" (uploading is not built yet)") }
        self.init(mode: mode,
                  ledgerDirectory: try c.decode(String.self, forKey: .ledgerDirectory),
                  rule: try c.decodeIfPresent(String.self, forKey: .rule),
                  since: try c.decodeIfPresent(String.self, forKey: .since),
                  timeZone: try c.decode(String.self, forKey: .timeZone),
                  extensions: try c.decode([String].self, forKey: .extensions),
                  minBytes: try c.decode(Int.self, forKey: .minBytes),
                  maxMessageBytes: try c.decodeIfPresent(Int.self, forKey: .maxMessageBytes) ?? Self.defaultMaxMessageBytes)
    }

    /// Gregorian in `timeZone` — never the locale's calendar (a Buddhist one would read 2026 as 1483).
    public func calendar() throws -> Calendar {
        guard let zone = TimeZone(identifier: timeZone) else { throw ConfigError("paperless: unknown timeZone \"\(timeZone)\"") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// The first day as a date (midnight in `timeZone`), if any.
    public func sinceDate() throws -> Date? {
        guard let since else { return nil }
        let calendar = try calendar()
        let parts = since.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              let date = calendar.date(from: DateComponents(year: y, month: m, day: d)),
              calendar.dateComponents([.year, .month, .day], from: date) == DateComponents(year: y, month: m, day: d)
        else { throw ConfigError("paperless: since must be a day like 2026-11-01") }
        return date
    }

    /// What decides a person's documents, as 12 hex digits: the ledger's file name carries it,
    /// so a changed rule, list, threshold or person model starts a new ledger and decides every
    /// message again — the old one stays as it was, a record of the old setting.
    public func fingerprint(for person: PaperlessPerson) -> String {
        struct Canonical: Encodable {
            var v = 1
            var rule: String?, since: String?, timeZone: String, extensions: [String], minBytes: Int, maxMessageBytes: Int
            var owner: String, tags: [String], storagePath: String?
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let canonical = Canonical(rule: rule?.trimmingCharacters(in: .whitespacesAndNewlines), since: since, timeZone: timeZone,
                                  extensions: extensions.sorted(), minBytes: minBytes, maxMessageBytes: maxMessageBytes,
                                  owner: person.owner, tags: person.tags, storagePath: person.storagePath)
        return String(sha256Hex((try? encoder.encode(canonical)) ?? Data()).prefix(12))
    }

    /// The search field is lenient — an unknown `field:` is a word, punctuation alone is nothing —
    /// which for a rule would mean a typo widens it: `-iss:junk` excludes the mails containing
    /// "iss junk" instead of the spam folder, `-` matches everything. A rule therefore takes only
    /// field terms, and only those the server can answer (no classification, no PDF text); dates go
    /// into `since`, which knows the time zone.
    static func ruleProblem(_ rule: String) -> String? {
        let text = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "empty — leave rule out to take every message" }
        if text.range(of: #"(^|\s)-(\s|$)"#, options: .regularExpression) != nil {
            return "a lone \"-\" (write -is:list, without a space)"
        }
        let query: Query
        do { query = try QueryParser.parse(text) } catch { return "\(error)" }
        guard let root = query.root else { return "no condition in it" }
        return problem(in: root)
    }

    private static func problem(in node: QueryNode) -> String? {
        switch node {
        case .and(let nodes), .or(let nodes): return nodes.lazy.compactMap(problem(in:)).first
        case .not(let inner): return problem(in: inner)
        case .predicate(let p):
            switch p {
            case .text(.any, let words, _):
                return "\"\(words)\" is plain text — a rule takes fields only (from:, subject:, is:, folder: …); is the field name misspelt?"
            case .text(.pdf, _, _): return "pdf: needs the PDF text, which the server does not extract"
            case .category, .isPhishing, .isSuspicious, .isFalsePositive:
                return "category, phishing and suspicion come from classification, which the server does not run"
            case .dateFrom, .dateBefore:
                // Would run in the container's zone and calendar, relative ones at decision time.
                return "dates belong in since, not in the rule"
            default: return nil
            }
        }
    }

    func validate() throws {
        guard ledgerDirectory.hasPrefix("/") else { throw ConfigError("paperless: ledgerDirectory must be an absolute path") }
        if let rule, let problem = Self.ruleProblem(rule) { throw ConfigError("paperless: rule: \(problem)") }
        _ = try calendar()
        _ = try sinceDate()
        guard !extensions.isEmpty else { throw ConfigError("paperless: extensions is empty — nothing would be handed over") }
        var seen = Set<String>()
        for ext in extensions {
            guard !ext.isEmpty, ext.count <= 16, ext.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber) }) else {
                throw ConfigError("paperless: extension \"\(ext)\" — lower case letters and digits, without dot")
            }
            guard seen.insert(ext).inserted else { throw ConfigError("paperless: extension \"\(ext)\" appears twice") }
            // Programs, macro documents, web pages and link files never go anywhere by rule.
            guard !AttachmentSafety.isRisky(filename: "x." + ext, mimeType: "application/octet-stream") else {
                throw ConfigError("paperless: extension \"\(ext)\" is a program, macro document, web page or link file")
            }
        }
        guard minBytes >= 0 else { throw ConfigError("paperless: minBytes must not be negative") }
        guard maxMessageBytes >= 1 << 20 else { throw ConfigError("paperless: maxMessageBytes must be at least 1 MiB") }
    }
}

/// How one person's attachments land in Paperless — the person model (owner, tags, storage path).
public struct PaperlessPerson: Decodable, Sendable, Equatable {
    public var owner: String
    public var tags: [String]
    public var storagePath: String?

    enum CodingKeys: String, CodingKey, CaseIterable { case owner, tags, storagePath }

    public init(owner: String, tags: [String], storagePath: String? = nil) {
        self.owner = owner
        self.tags = tags
        self.storagePath = storagePath
    }

    public init(from decoder: Decoder) throws {
        try requireKnownKeys(decoder, CodingKeys.self, in: "person paperless")
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(owner: try c.decode(String.self, forKey: .owner), tags: try c.decode([String].self, forKey: .tags),
                  storagePath: try c.decodeIfPresent(String.self, forKey: .storagePath))
    }

    func validate(person: String) throws {
        func usable(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespaces).isEmpty && !s.contains(where: \.isNewline) }
        guard usable(owner) else { throw ConfigError("\(person): paperless owner is empty") }
        guard !tags.isEmpty, tags.allSatisfy(usable) else { throw ConfigError("\(person): paperless tags must be non-empty names") }
        guard Set(tags).count == tags.count else { throw ConfigError("\(person): a paperless tag appears twice") }
        if let storagePath, !usable(storagePath) { throw ConfigError("\(person): paperless storagePath is empty") }
    }
}
