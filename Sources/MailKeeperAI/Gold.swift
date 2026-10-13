import Foundation
import MailKeeperKit

/// What a labelled mail must come out as (ADR-0005 §7, Phase 6.6): one of the acceptable
/// categories (the first is the label, the others are also right — an order confirmation with
/// the invoice attached is both), and whether phishing must be flagged.
public struct GoldExpectation: Sendable, Codable, Equatable {
    public enum Phishing: String, Sendable, Codable {
        /// No phishing flag.
        case none
        /// Suspicion or phishing.
        case flagged
        /// Not judged.
        case any
    }

    public var category: [MailCategory]
    public var phishing: Phishing

    public init(category: [MailCategory], phishing: Phishing = .any) {
        self.category = category
        self.phishing = phishing
    }

    func accepts(_ category: MailCategory) -> Bool { self.category.contains(category) }

    func accepts(_ level: PhishingLevel) -> Bool {
        switch phishing {
        case .none: level == .none
        case .flagged: level != .none
        case .any: true
        }
    }
}

/// One mail of a gold run: the snapshot the model sees, the memory it gets (nil: none) and the
/// label.
public struct GoldItem: Sendable {
    public var id: String
    public var mail: MailSnapshot
    public var memory: MemoryContext?
    public var expect: GoldExpectation

    public init(id: String, mail: MailSnapshot, memory: MemoryContext? = nil, expect: GoldExpectation) {
        self.id = id
        self.mail = mail
        self.memory = memory
        self.expect = expect
    }
}

/// How one mail came out.
public struct GoldOutcome: Sendable, Codable, Equatable {
    public var id: String
    public var expected: [MailCategory]
    public var expectedPhishing: GoldExpectation.Phishing
    public var category: MailCategory?
    public var phishing: PhishingLevel?
    public var reason: String?
    /// Who answered — a router that falls back to the Mac's model would otherwise mix two models in one run.
    public var model: String?
    public var seconds: Double
    /// The model did not answer (after one retry): counted as wrong, said apart.
    public var error: String?

    public var categoryRight: Bool { category.map { expected.contains($0) } ?? false }
    public var phishingRight: Bool {
        guard let phishing else { return false }
        return GoldExpectation(category: expected, phishing: expectedPhishing).accepts(phishing)
    }
    public var right: Bool { categoryRight && phishingRight }
}

/// A run over a gold set: per mail and in sum — accuracy, per category precision and recall
/// (against the label, the first acceptable category), phishing caught and false alarms.
public struct GoldReport: Sendable, Codable, Equatable {
    public var set: String
    /// "ohne Gedächtnis", "mit Gedächtnis", …
    public var mode: String
    public var model: String
    public var time: Date
    public var outcomes: [GoldOutcome]

    public init(set: String, mode: String, model: String, time: Date = .now, outcomes: [GoldOutcome]) {
        self.set = set
        self.mode = mode
        self.model = model
        self.time = time
        self.outcomes = outcomes
    }

    public var total: Int { outcomes.count }
    public var right: Int { outcomes.filter(\.right).count }
    public var categoryRight: Int { outcomes.filter(\.categoryRight).count }
    public var errors: Int { outcomes.filter { $0.error != nil }.count }
    /// Mails that must be flagged, and how many were.
    public var phishingExpected: Int { outcomes.filter { $0.expectedPhishing == .flagged }.count }
    public var phishingCaught: Int { outcomes.filter { $0.expectedPhishing == .flagged && $0.phishingRight }.count }
    /// Mails that must not be flagged, and how many were (false alarms).
    public var phishingClean: Int { outcomes.filter { $0.expectedPhishing == .none }.count }
    public var falseAlarms: Int { outcomes.filter { $0.expectedPhishing == .none && $0.phishing != nil && $0.phishing != PhishingLevel.none }.count }
    public var seconds: Double { outcomes.reduce(0) { $0 + $1.seconds } }

    /// Per category: of the mails labelled with it, how many came out right (recall); of the
    /// mails the model gave it, how many were right (precision) — "right" counts the acceptable
    /// alternatives too.
    public struct CategoryScore: Sendable, Equatable {
        public var category: MailCategory
        public var labelled: Int
        public var labelledRight: Int
        public var given: Int
        public var givenRight: Int
        public var precision: Double? { given == 0 ? nil : Double(givenRight) / Double(given) }
        public var recall: Double? { labelled == 0 ? nil : Double(labelledRight) / Double(labelled) }
    }

    public var perCategory: [CategoryScore] {
        MailCategory.allCases.compactMap { c in
            let labelled = outcomes.filter { $0.expected.first == c }
            let given = outcomes.filter { $0.category == c }
            return labelled.isEmpty && given.isEmpty ? nil
                : CategoryScore(category: c, labelled: labelled.count, labelledRight: labelled.filter(\.categoryRight).count,
                                given: given.count, givenRight: given.filter(\.categoryRight).count)
        }
    }

    /// German lines for mkctl, the test log and the GUI.
    public var summary: [String] {
        func percent(_ a: Int, _ b: Int) -> String { b == 0 ? "–" : "\(Int((Double(a) / Double(b) * 100).rounded())) %" }
        var lines = ["\(set) · \(mode) · \(model): \(right)/\(total) richtig (\(percent(right, total))) · Art \(categoryRight)/\(total)"
                     + (phishingExpected > 0 ? " · Phishing erkannt \(phishingCaught)/\(phishingExpected)" : "")
                     + (phishingClean > 0 ? " · Fehlalarme \(falseAlarms)/\(phishingClean)" : "")
                     + (errors > 0 ? " · \(errors) ohne Antwort" : "")
                     + String(format: " · %.0f s", seconds)]
        let models = Set(outcomes.compactMap(\.model))
        if models.count > 1 { lines.append("  Achtung: gemischte Modelle – \(models.sorted().joined(separator: ", "))") }
        for s in perCategory {
            lines.append("  \(s.category.label.padding(toLength: 20, withPad: " ", startingAt: 0)) gelabelt \(s.labelled), davon richtig \(s.labelledRight)"
                         + " · vergeben \(s.given), davon richtig \(s.givenRight)"
                         + (s.recall.map { String(format: " · Trefferquote %.0f %%", $0 * 100) } ?? "")
                         + (s.precision.map { String(format: " · Präzision %.0f %%", $0 * 100) } ?? ""))
        }
        return lines
    }

    /// A run to compare later runs with: one model answered, and it answered at all (review 6.6:
    /// a fallback mixes models, a dead endpoint fails every mail).
    public var isComparable: Bool { Set(outcomes.compactMap(\.model)).count <= 1 && errors < total }

    /// One line per mail that went wrong.
    public var misses: [String] {
        outcomes.filter { !$0.right }.map { o in
            if let error = o.error { return "✗ \(o.id): keine Antwort – \(error)" }
            let got = o.category?.label ?? "–"
            let fish = o.phishing.map { $0 == .none ? "" : " (\($0.label))" } ?? ""
            let want = o.expected.map(\.label).joined(separator: " oder ")
                + (o.expectedPhishing == .flagged ? ", Phishing" : o.expectedPhishing == .none ? ", kein Phishing" : "")
            return "✗ \(o.id): \(got)\(fish) – erwartet \(want)" + (o.reason.map { " – „\($0)“" } ?? "")
        }
    }

    /// Against an earlier run of the same set and mode (ADR-0005 §7: a change must not cost
    /// accuracy). Models do not answer exactly alike twice, even at temperature 0 (speculative
    /// decoding, batching: two of 32 mails flipped between three identical runs), so the
    /// category may lose `tolerance` mails before it counts as worse; phishing may not lose one.
    /// `worse` fails a check, `flips` are the mails that changed, said either way.
    /// Only the mails both runs have are compared (review 6.6 S3: a private set grows — 30 more
    /// labels are no "regression"); a change of the set is said as a flip line.
    /// `phishingTolerance`: 0 for a stable model; the Mac's model flipped one phishing case
    /// (a forged parcel mail with the own server's dmarc=fail) in five of eight identical runs.
    /// `alarmTolerance`: real mail wobbles more — TJ's 75 clean mails gave 4, then 2 false
    /// alarms in two identical runs (a bowling reservation, a hairdresser's receipt).
    public func comparison(since earlier: GoldReport, tolerance: Int = 2, phishingTolerance: Int = 0,
                           alarmTolerance: Int = 0) -> (worse: [String], flips: [String]) {
        let before = Dictionary(earlier.outcomes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let common = Set(outcomes.map(\.id)).intersection(before.keys)
        let now = GoldReport(set: set, mode: mode, model: model, time: time, outcomes: outcomes.filter { common.contains($0.id) })
        let then = GoldReport(set: earlier.set, mode: earlier.mode, model: earlier.model, time: earlier.time,
                              outcomes: earlier.outcomes.filter { common.contains($0.id) })
        var worse: [String] = []
        if now.right < then.right - tolerance { worse.append("weniger richtig: \(now.right) statt \(then.right) (von \(now.total))") }
        if now.falseAlarms > then.falseAlarms + alarmTolerance { worse.append("mehr Fehlalarme: \(now.falseAlarms) statt \(then.falseAlarms)") }
        if now.phishingCaught < then.phishingCaught - phishingTolerance { worse.append("weniger Phishing erkannt: \(now.phishingCaught) statt \(then.phishingCaught)") }
        var flips: [String] = []
        if common.count != total || common.count != earlier.total {
            flips.append("Gold-Set geändert: \(earlier.total) → \(total) Mails; verglichen werden die \(common.count) gemeinsamen")
        }
        for o in outcomes where o.error == nil {
            guard let b = before[o.id], b.error == nil, b.right != o.right else { continue }
            flips.append(o.right ? "jetzt richtig: \(o.id)" : "jetzt falsch: \(o.id) (\(o.category?.label ?? "–"))")
        }
        return (worse, flips)
    }
}

/// Runs a gold set through the classifier, one mail after another (the endpoint is shared, and
/// a run is a measurement, not a race). A mail the model does not answer is tried once more —
/// then it counts as wrong, with its error.
public struct GoldRunner: Sendable {
    let classifier: MailClassifier

    public init(classifier: MailClassifier) {
        self.classifier = classifier
    }

    public func run(_ items: [GoldItem], set: String, mode: String, model: String,
                    progress: (@Sendable (Int, Int) -> Void)? = nil) async -> GoldReport {
        var outcomes: [GoldOutcome] = []
        for (n, item) in items.enumerated() {
            if Task.isCancelled { break }
            progress?(n, items.count)
            var outcome = GoldOutcome(id: item.id, expected: item.expect.category, expectedPhishing: item.expect.phishing, seconds: 0)
            for attempt in 0..<2 {
                do {
                    let c = try await classifier.classify(item.mail, memory: item.memory)
                    outcome.category = c.category
                    outcome.phishing = c.phishing
                    outcome.reason = c.reason
                    outcome.model = c.model
                    outcome.seconds = c.seconds
                    outcome.error = nil
                    break
                } catch {
                    outcome.error = String(describing: error).prefix(200).description
                    if attempt == 0 { try? await Task.sleep(for: .seconds(2)) }
                }
            }
            outcomes.append(outcome)
        }
        progress?(items.count, items.count)
        return GoldReport(set: set, mode: mode, model: model, outcomes: outcomes)
    }
}

/// A gold case written down (the synthetic set in the repo, `Tests/MailKeeperAITests/Gold`): the
/// mail as RFC 5322 text — fictional, `.example`/`.test` domains — the memory the model gets,
/// and the label. The same mail may come twice, without and with memory: the pair shows what
/// the memory changes.
public struct GoldCase: Sendable, Codable, Equatable {
    public struct Memory: Sendable, Codable, Equatable {
        public var notes: [String]?
        public var relation: [String]?
        /// "passed: dkim=pass dmarc=pass", "failed: dmarc=fail", "foreign"
        public var server: String?
        public var profile: [String]?
        public var examples: [String]?
        public var replyToRelation: String?
    }

    public var id: String
    /// What the case is about.
    public var about: String
    public var mail: String
    public var memory: Memory?
    public var expect: GoldExpectation

    /// The set in a directory: `cases.json` (id, about, file, memory, expect) and the mails in
    /// `mails/`, one RFC 5322 file each — readable and editable as text; a pair shares its file.
    public static func load(directory: URL) throws -> [GoldCase] {
        struct Entry: Decodable { var id: String; var about: String; var file: String; var memory: Memory?; var expect: GoldExpectation }
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: directory.appending(path: "cases.json")))
        return try entries.map { e in
            guard !e.file.contains("/"), !e.file.hasPrefix(".") else { throw AIError.badAnswer("Gold-Fall \(e.id): Dateiname \(e.file)") }
            let mail = try String(contentsOf: directory.appending(path: "mails").appending(path: e.file), encoding: .utf8)
            return GoldCase(id: e.id, about: e.about, mail: mail, memory: e.memory, expect: e.expect)
        }
    }

    /// The item to run: the mail parsed like any other, the memory as the retriever would give it.
    public var item: GoldItem {
        let raw = Data(mail.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n").utf8)
        return GoldItem(id: id, mail: MailSnapshot(MIMEParser.parse(raw)), memory: memory.map(Self.context), expect: expect)
    }

    static func context(_ m: Memory) -> MemoryContext {
        var ctx = MemoryContext()
        ctx.notes = m.notes ?? []
        ctx.relation = m.relation ?? []
        ctx.profile = m.profile ?? []
        ctx.examples = m.examples ?? []
        ctx.replyToRelation = m.replyToRelation
        if let s = m.server {
            let parts = s.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            let detail = parts.count > 1 ? parts[1] : ""
            ctx.server = switch parts[0] {
            case "passed": .passed(detail)
            case "failed": .failed(detail)
            case "neutral": .neutral(detail)
            case "foreign": .foreign
            default: RelationCheck.Server.none
            }
        }
        return ctx
    }

    /// Problems with the written-down set (checked offline, without a model).
    public static func problems(_ cases: [GoldCase]) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for c in cases {
            if !seen.insert(c.id).inserted { out.append("\(c.id): doppelte id") }
            if c.expect.category.isEmpty { out.append("\(c.id): keine Art") }
            let parsed = MIMEParser.parse(Data(c.mail.utf8))
            if parsed.from.first?.address.contains("@") != true { out.append("\(c.id): kein Absender") }
            if parsed.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && parsed.html == nil { out.append("\(c.id): kein Text") }
            // the public repo carries no real mail: every address and link is made up — any
            // address, and any word that ends like a domain (review 6.6: not only .de and .com)
            let words = c.mail.lowercased().split(whereSeparator: { " \n\t<>()\"'=;,/?&[]".contains($0) })
            for w in words {
                let host = (w.split(separator: "@").last.map(String.init) ?? String(w)).trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
                let looksLikeDomain = w.contains("@") || host.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.(com|net|org|io|eu|de|at|ch|info|biz|co|uk|us|me|app|dev|ai|shop|online|cloud|nl|fr|it|es)$"#, options: .regularExpression) != nil
                if looksLikeDomain, host.contains("."), !(host.hasSuffix(".example") || host.hasSuffix(".test") || host.hasSuffix(".invalid")) {
                    out.append("\(c.id): echte Domain? \(host)")
                }
            }
        }
        return out
    }
}

/// The private gold set in the own archive (6.6b): the labelled mails as the model sees them,
/// with or without the memory the retriever gives — and what MailKeeper shows for them today.
public enum GoldArchive {
    public static let set = "dein Archiv"
    /// Real mail and a model that flips: the private set is compared with these tolerances.
    public static func comparison(_ report: GoldReport, since earlier: GoldReport) -> (worse: [String], flips: [String]) {
        report.comparison(since: earlier, tolerance: 2, phishingTolerance: 1, alarmTolerance: 2)
    }
    public static let today = "MailKeeper heute"
    public static let withoutMemory = "KI ohne Gedächtnis"
    public static let withMemory = "KI mit Gedächtnis"

    static func expectation(_ label: GoldLabel) -> GoldExpectation {
        GoldExpectation(category: [label.category], phishing: label.phishing ? .flagged : .none)
    }

    /// The labelled mails still in the archive, as items; `memory` nil runs them without.
    public static func items(reader: ArchiveReader, labels: GoldLabels, memory: MemoryRetriever?) throws -> [GoldItem] {
        let ids = try reader.messageIDs(identities: labels.labels.map(\.identity))
        return try labels.labels.compactMap { label in
            guard let id = ids[label.identity], let parsed = try reader.parsedMessage(id) else { return nil }
            let mail = MailSnapshot(parsed)
            let context = try memory.map { try $0.context(for: id, mail: mail, accounts: try reader.detail(id)?.locations.map(\.account) ?? []) }
            return GoldItem(id: label.identity, mail: mail, memory: context, expect: expectation(label))
        }
    }

    /// What the archive shows now — the category from rules, similar mails, a model or the
    /// user, phishing as a model's flag or the register's "Verdächtig" — no model asked.
    public static func todayReport(reader: ArchiveReader, labels: GoldLabels) throws -> GoldReport {
        let ids = try reader.messageIDs(identities: labels.labels.map(\.identity))
        let outcomes: [GoldOutcome] = try labels.labels.compactMap { label in
            guard let id = ids[label.identity] else { return nil }
            let c = try reader.classification(of: id)
            let warned = try reader.count(MessageFilter(text: "is:verdächtig ", ids: [id])) > 0
            let flagged = warned || c?.phishing == .suspicious || c?.phishing == .likely
            let e = expectation(label)
            // who decided goes into the reason, not the model: "today" is several sources by design
            let source = c.map { "\($0.source.rawValue)" + ($0.reason.map { ": \($0)" } ?? "") }
            return GoldOutcome(id: label.identity, expected: e.category, expectedPhishing: e.phishing, category: c?.category,
                               phishing: flagged ? .suspicious : PhishingLevel.none, reason: source,
                               model: nil, seconds: 0,
                               error: c?.category == nil ? String(localized: "noch offen") : nil)
        }
        return GoldReport(set: set, mode: today, model: "Regeln, ähnliche Mails, KI, du", outcomes: outcomes)
    }

    /// Subjects for the misses: the private set names mails by identity.
    public static func titles(reader: ArchiveReader, identities: [String]) throws -> [String: String] {
        let ids = try reader.messageIDs(identities: identities)
        var out: [String: String] = [:]
        for (identity, id) in ids {
            if let s = try reader.summaries([id]).first { out[identity] = "\(s.fromDisplay): \(s.subject ?? "")" }
        }
        return out
    }
}
