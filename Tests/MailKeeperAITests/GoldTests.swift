import Foundation
import Testing
@testable import MailKeeperAI
@testable import MailKeeperKit

/// The synthetic gold set (6.6, ADR-0005 §7) lives next to this file in `Gold/`.
enum GoldSet {
    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Gold")
    static let baselineURL = directory.appending(path: "baseline.json")

    static func cases() throws -> [GoldCase] { try GoldCase.load(directory: directory) }

    /// The last accepted run per model: a change must not do worse (regressions fail the live run).
    static func baseline() -> [String: GoldReport] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: GoldReport].self, from: Data(contentsOf: baselineURL))) ?? [:]
    }

    static func save(_ report: GoldReport) throws {
        var all = baseline()
        all[report.model] = report
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(all).write(to: baselineURL, options: .atomic)
    }
}

@Suite("Gold-Set (6.6)")
struct GoldSetTests {
    @Test func theSetIsWellFormedAndMadeUp() throws {
        let cases = try GoldSet.cases()
        #expect(cases.count >= 30)
        #expect(GoldCase.problems(cases).isEmpty, "\(GoldCase.problems(cases))")
        // every category and both phishing sides are covered
        let labels = Set(cases.compactMap(\.expect.category.first))
        #expect(labels == Set(MailCategory.allCases), "\(Set(MailCategory.allCases).subtracting(labels))")
        #expect(cases.contains { $0.expect.phishing == .flagged } && cases.contains { $0.expect.phishing == .none })
        // a pair: the same mail without and with memory
        let pairs = cases.filter { $0.id.contains("+") }
        #expect(pairs.count >= 4)
        for p in pairs {
            let base = try #require(cases.first { $0.id == String(p.id.split(separator: "+")[0]) }, "\(p.id)")
            #expect(base.mail == p.mail && base.memory == nil && p.memory != nil)
        }
    }

    @Test func casesBecomeWhatTheModelSees() throws {
        let cases = try GoldSet.cases()
        let phish = try #require(cases.first { $0.id == "bank-phish" }).item
        #expect(phish.mail.from == "sicherheit@musterbank-kundenservice.example" && phish.memory == nil)
        #expect(phish.mail.links.first?.findings.contains(.textShowsOtherDomain) == true)
        let pair = try #require(cases.first { $0.id == "versand-gefaelscht+server" }).item
        #expect(pair.memory?.server == .failed("dkim=fail spf=fail dmarc=fail"))
        let paid = try #require(cases.first { $0.id == "zahlung+beziehung" }).item
        #expect(paid.memory?.replyToRelation == "Bezahldienst" && paid.memory?.server == .passed("dkim=pass spf=pass dmarc=pass"))
        // the model gets the own server's word instead of what the mail claims
        #expect(GoldCase.problems([GoldCase(id: "x", about: "", mail: "From: a@echte-firma.de\n\nText", memory: nil,
                                            expect: GoldExpectation(category: [.work]))]).contains { $0.contains("echte Domain") })
    }

    @Test func theReportCountsAndComparesRuns() {
        func o(_ id: String, _ want: [MailCategory], _ got: MailCategory?, _ wantFish: GoldExpectation.Phishing = .none, _ fish: PhishingLevel = .none) -> GoldOutcome {
            GoldOutcome(id: id, expected: want, expectedPhishing: wantFish, category: got, phishing: got == nil ? nil : fish, seconds: 1)
        }
        let before = GoldReport(set: "t", mode: "m", model: "x", outcomes: [
            o("a", [.work], .work), o("b", [.spam], .spam, .flagged, .likely), o("c", [.newsletter], .newsletter), o("d", [.invoice, .orderShipping], .orderShipping),
        ])
        #expect(before.right == 4 && before.phishingCaught == 1 && before.falseAlarms == 0)
        let after = GoldReport(set: "t", mode: "m", model: "x", outcomes: [
            o("a", [.work], .personal), o("b", [.spam], .spam, .flagged, .none), o("c", [.newsletter], .newsletter, .none, .suspicious),
            { var d = o("d", [.invoice, .orderShipping], nil); d.error = "timeout"; return d }(),
        ])
        #expect(after.right == 0 && after.categoryRight == 2 && after.falseAlarms == 1 && after.phishingCaught == 0)
        let work = after.perCategory.first { $0.category == .work }
        #expect(work?.labelled == 1 && work?.given == 0 && work?.recall == 0 && work?.precision == nil)
        // an acceptable alternative counts for the category given, not for the label's recall twice
        let shipping = before.perCategory.first { $0.category == .orderShipping }
        let invoice = before.perCategory.first { $0.category == .invoice }
        #expect(shipping?.labelled == 0 && shipping?.given == 1 && shipping?.precision == 1)
        #expect(invoice?.labelled == 1 && invoice?.labelledRight == 1 && invoice?.recall == 1 && invoice?.given == 0)
        let (worse, flips) = after.comparison(since: before)
        #expect(worse.contains { $0.hasPrefix("weniger richtig") } && worse.contains { $0.hasPrefix("mehr Fehlalarme") }
                && worse.contains { $0.hasPrefix("weniger Phishing erkannt") })
        #expect(flips.contains("jetzt falsch: a (Persönlich)") && !flips.contains { $0.contains(" d") })  // no answer is said apart
        #expect(after.misses.contains { $0.hasPrefix("✗ a: Persönlich – erwartet Arbeit") })
        #expect(before.comparison(since: before) == ([], []))
        // the category may wobble by the tolerance, phishing may not
        let oneFlip = GoldReport(set: "t", mode: "m", model: "x", outcomes: [o("a", [.work], .personal)] + before.outcomes.dropFirst())
        #expect(oneFlip.comparison(since: before).worse.isEmpty && oneFlip.comparison(since: before, tolerance: 0).worse.count == 1)
    }
}

/// The live run: `MAILKEEPER_AI=1 MAILKEEPER_GOLD=1 swift test --filter AILiveGold`. Compares with
/// `Gold/baseline.json` (per model); `MAILKEEPER_GOLD_SAVE=1` makes this run the new baseline.
@Suite("AILive gold", .enabled(if: ProcessInfo.processInfo.environment["MAILKEEPER_AI"] == "1"
                               && ProcessInfo.processInfo.environment["MAILKEEPER_GOLD"] == "1"), .serialized)
struct AILiveGoldTests {
    func run(_ config: AIConfig, key: String?, model: String) async throws {
        let classifier = MailClassifier(router: AIRouter(config: config, apiKey: key, log: AICallLog(url: tempDir().appending(path: "ai.jsonl"))))
        let report = await GoldRunner(classifier: classifier).run(try GoldSet.cases().map(\.item), set: "synthetisch", mode: "Gold-Set im Repo", model: model)
        for line in report.summary + report.misses { print(line) }
        if ProcessInfo.processInfo.environment["MAILKEEPER_GOLD_SAVE"] == "1" {
            try GoldSet.save(report)
            print("als Basislinie gesichert: \(GoldSet.baselineURL.lastPathComponent)")
        } else if let base = GoldSet.baseline()[model] {
            let (worse, flips) = report.comparison(since: base)
            for line in flips { print("seit der Basislinie: \(line)") }
            for line in worse { print("Rückschritt: \(line)") }
            #expect(worse.isEmpty, "\(worse)")
        } else {
            print("keine Basislinie für \(model) – MAILKEEPER_GOLD_SAVE=1 sichert diesen Lauf")
        }
        #expect(report.errors == 0)
    }

    @Test func theEndpoint() async throws {
        var (config, key) = try AILiveTests.config()
        config.onDevice = false  // a failing endpoint must not hand the run to the Mac's model
        try await run(config, key: key, model: config.model(for: .classify))
    }

    @Test(.enabled(if: OnDeviceProvider.availability.available)) func theMacsModel() async throws {
        try await run(AIConfig(enabled: true, endpoint: nil), key: nil, model: "apple-on-device")
    }
}
