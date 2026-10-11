import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Einordnen: Regeln, Speicher, Filter (5.4)")
struct ClassificationTests {
    func rule(_ from: String, _ subject: String, list: String? = nil, unsubscribe: Bool = false, precedence: String? = nil,
              auto: String? = nil, pdf: Bool = false) -> MailCategory? {
        Heuristics.classify(HeuristicFeatures(from: from, subject: subject, listID: list, listUnsubscribe: unsubscribe,
                                              precedence: precedence, autoSubmitted: auto, hasPDF: pdf))?.category
    }

    @Test func rulesSettleTheStructuralClassesOnly() {
        #expect(rule("news@shop.example", "Neue Herbstmode", list: "news.shop.example") == .newsletter)
        #expect(rule("info@shop.example", "Nur heute: -20 %", unsubscribe: true) == .newsletter)
        #expect(rule("x@y.example", "Digest", precedence: "bulk") == .newsletter)
        #expect(rule("noreply@github.example", "[repo] Run failed") == .notification)
        #expect(rule("monitor@host.example", "Disk full", auto: "auto-generated") == .notification)
        #expect(rule("MAILER-DAEMON@mx.example", "Undelivered Mail Returned to Sender") == .notification)
        #expect(rule("billing@telekom.example", "Ihre Rechnung für März", pdf: true) == .invoice)
        #expect(rule("billing@telekom.example", "Ihre Rechnung für März") == nil)  // no PDF: a model decides
        #expect(rule("shop@amazon.example", "Ihre Bestellung wurde versandt") == .orderShipping)
        #expect(rule("buchung@bahn.example", "Ihre Buchungsbestätigung") == .travel)
        #expect(rule("deals@x.example", "Lieferung gratis!", list: "deals.x.example") == .newsletter)  // a list wins over words
        #expect(rule("notifications@github.example", "[repo] PR merged", list: "repo.github.example", unsubscribe: true) == .notification)
        #expect(rule("noreply@newsletter.example", "Wochenrückblick", list: "news.example") == .newsletter)  // plain noreply: still a newsletter
        // never by rule: people, work, account and phishing — a rule would lend a fake security mail credibility
        #expect(rule("security@bank-alert.example", "Ihr Konto wurde gesperrt – Passwort bestätigen") == nil)
        #expect(rule("max@familie.example", "Grillen am Samstag?") == nil)
        #expect(rule("kanzlei@stb.example", "Unterlagen Jahresabschluss") == nil)
    }

    @Test func categoriesAreStoredFilteredAndModelAnswersSurviveTheRules() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "cat"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest([
            (sampleMessage(id: "<n@t.test>", subject: "News", extraHeaders: "List-Id: <news.t.test>\n"), LocationInfo(account: "a", mailbox: "INBOX", providerID: "1")),
            (sampleMessage(id: "<p@t.test>", subject: "Grillen?", from: "max@familie.example"), LocationInfo(account: "a", mailbox: "INBOX", providerID: "2")),
            (sampleMessage(id: "<o@t.test>", subject: "Ihre Bestellung wurde versandt", from: "shop@amazon.example"), LocationInfo(account: "a", mailbox: "INBOX", providerID: "3")),
        ])
        let r = try ArchiveReader(layout: layout)
        #expect(try r.heuristicPendingCount() == 3)
        #expect(try await writer.classifyHeuristically() == 3)
        #expect(try await writer.classifyHeuristically() == 0)
        let subjects = { (q: String) in Set(try r.summaries(try r.messageIDs(MessageFilter(text: q + " "))).compactMap(\.subject)) }
        #expect(try subjects("kategorie:newsletter") == ["News"] && subjects("category:order") == ["Ihre Bestellung wurde versandt"])
        #expect(try subjects("kategorie:offen") == ["Grillen?"])
        let open = try #require(try r.openForClassification(MessageFilter(), limit: 10).first)
        try await writer.setClassification(messageID: open, category: .personal, source: .endpoint, model: "llm-fast", reason: "Einladung")
        _ = try await writer.classifyHeuristically()  // the rules never overwrite a model's answer
        #expect(try subjects("art:persönlich") == ["Grillen?"] && subjects("kategorie:offen").isEmpty)
        let c = try #require(try r.classification(of: open))
        #expect(c.source == .endpoint && c.model == "llm-fast" && c.reason == "Einladung")
        #expect(try r.categoryCounts()[.newsletter] == 1)
        #expect(throws: QueryError.self) { _ = try QueryParser.parse("kategorie:quatsch ") }
    }
}
