import Foundation
import Testing
@testable import MailKeeperAI
@testable import MailKeeperKit

@Suite("Zusammenfassung auf Abruf (5.8)")
struct SummaryTests {
    static func mail(_ from: String, _ subject: String, _ text: String, day: Int = 1, name: String? = nil) -> MailSnapshot {
        MailSnapshot(from: from, fromName: name, to: ["jan@own.test"], subject: subject,
                     date: Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: day, hour: 9)), text: text)
    }

    static func summarizer(_ answers: [String]) -> (MailSummarizer, ScriptedProvider) {
        let p = ScriptedProvider(answers)
        let router = AIRouter(config: AIConfig(enabled: true), endpoint: nil, onDevice: p, log: AICallLog(url: tempDir().appending(path: "l.jsonl")))
        return (MailSummarizer(router: router), p)
    }

    @Test func aConversationGoesInFencedOldestFirstAndRepliesWithoutTheirQuote() async throws {
        let (summarizer, p) = Self.summarizer([#"{"summary":"Max fragt nach Donnerstag, du sagst zu.","points":["Treffen Donnerstag 18 Uhr"],"todo":["Donnerstag 18 Uhr da sein"],"scam":"nein","scam_reason":"keine Warnsignale"}"#])
        let thread = [
            SummaryMessage(Self.mail("max@x.de", "Treffen", "Kommst du Donnerstag um 18 Uhr?", day: 1, name: "Max")),
            SummaryMessage(Self.mail("jan@own.test", "Re: Treffen", "Ja, passt.\n\nAm 1. Mai schrieb Max <max@x.de>:\n> Kommst du Donnerstag um 18 Uhr?", day: 2),
                           sentByUser: true),
        ]
        let s = try await summarizer.summarize(thread, total: 9)
        #expect(s.summary == "Max fragt nach Donnerstag, du sagst zu." && s.points == ["Treffen Donnerstag 18 Uhr"] && s.todo == ["Donnerstag 18 Uhr da sein"])
        #expect(s.caution == nil)  // "nein" with a reason anyway: no caution
        #expect(s.covered == 2 && s.total == 9 && s.path == .onDevice)
        let request = try #require(await p.requests.first)
        #expect(request.task == .summarize && request.schema != nil && request.system.contains("Konversation"))
        // the Mac's model reads the compact version; MailKeeper's own note stands outside the fence
        #expect(request.user.hasPrefix("Hinweis von MailKeeper: Die Konversation hat 9 Nachrichten; hier stehen die letzten 2."))
        #expect(request.user.contains("<<<MAIL-") && request.user.contains("--- Nachricht 1 von 2") && request.user.contains("(von dir gesendet)"))
        #expect(request.user.components(separatedBy: "Kommst du Donnerstag").count == 2)  // the reply's quote is gone
        #expect(request.user.contains("Betreff: Treffen") && request.user.contains("Betreff: Re: Treffen"))
    }

    @Test func aScamHasNoToDosAndTheAnswerIsCleanedAndBounded() async throws {
        let answer = #"{"summary":"Angeblich ist dein Konto gesperrt.‮","points":["a","","b","c","d","e","f","g"],"todo":["Daten bestätigen"],"scam":"ja","scam_reason":"Linkziel passt nicht zur Bank"}"#
        let (summarizer, _) = Self.summarizer([answer, answer.replacingOccurrences(of: #""scam":"ja""#, with: #""scam":"nein""#),
                                               answer.replacingOccurrences(of: #""scam_reason":"Linkziel passt nicht zur Bank""#, with: #""scam_reason":null"#)])
        let mail = [SummaryMessage(Self.mail("security@bank-verify.example", "Konto gesperrt", "Bestätigen Sie sofort Ihre Daten."))]
        let s = try await summarizer.summarize(mail)
        #expect(s.summary == "Angeblich ist dein Konto gesperrt." && s.caution == "Linkziel passt nicht zur Bank")
        #expect(s.todo.isEmpty && s.points == ["a", "b", "c", "d", "e", "f"])  // a model's caution only tightens
        let flagged = try await summarizer.summarize(mail, flagged: true)
        #expect(flagged.caution == nil && flagged.todo.isEmpty)  // MailKeeper's own flag: no to-dos either
        let unexplained = try await summarizer.summarize(mail)
        #expect(unexplained.caution == PhishingLevel.likely.label && unexplained.todo.isEmpty)
    }

    @Test func theBudgetIsSharedLongTextsAreCut() {
        #expect(MailSummarizer.allot([100, 5_000, 300], budget: 2_000) == [100, 1_600, 300])
        #expect(MailSummarizer.allot([5_000, 5_000], budget: 2_000) == [1_000, 1_000])
        #expect(MailSummarizer.allot([10, 20], budget: 1_000) == [10, 20])
        let long = [SummaryMessage(Self.mail("a@x.de", "Lang", String(repeating: "x", count: 50_000)))]
        let compact = MailSummarizer.render(long, budget: MailSummarizer.compactBudget)
        #expect(compact.count < MailSummarizer.compactBudget + 300 && compact.hasSuffix(" […]"))
        #expect(MailSummarizer.render(long, budget: MailSummarizer.budget).count > compact.count)
    }

    @Test func messagesFromTheArchiveKnowWhatWasSentAndWhatIsFlagged() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "sum"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest([
            (sampleMessage(id: "<q@t.test>", subject: "Frage", body: "Kommst du?"), LocationInfo(account: "x", mailbox: "INBOX", providerID: "1")),
            (sampleMessage(id: "<a@t.test>", subject: "Re: Frage", body: "Ja.", extraHeaders: "In-Reply-To: <q@t.test>\n"),
             LocationInfo(account: "x", mailbox: "Sent", providerID: "2")),
        ])
        let reader = try ArchiveReader(layout: layout)
        let ids = try reader.thread(of: try #require(try reader.messageIDs(MessageFilter()).first)).map(\.id)
        #expect(ids.count == 2)
        var input = try MailSummarizer.messages(ids, reader: reader)
        #expect(input.messages.map(\.sentByUser) == [false, true] && input.total == 2 && !input.flagged)
        try await writer.setClassification(messageID: ids[0], category: .spam, source: .endpoint, model: "m", reason: "r", phishing: .likely, phishingReason: "x")
        input = try MailSummarizer.messages(ids, reader: reader)
        #expect(input.flagged)
    }

    @Test func plainTextForTheClipboard() {
        let s = MailSummary(summary: "Kurz.", points: ["Frist 31.5."], todo: ["Antworten"], caution: nil, covered: 1, total: 1,
                            path: .endpoint, model: "llm-fast", seconds: 1)
        #expect(s.plainText == "Kurz.\n\n• Frist 31.5.\n\n☐ Antworten")
    }
}

@Suite("AILive summary", .enabled(if: ProcessInfo.processInfo.environment["MAILKEEPER_AI"] == "1"), .serialized)
struct AILiveSummaryTests {
    static let thread = [
        SummaryMessage(SummaryTests.mail("info@stb-beispiel.example", "Unterlagen Jahresabschluss 2025",
                                         "Hallo Herr Muster,\nfür den Jahresabschluss 2025 fehlen uns noch die Kontoauszüge Dezember und die Rechnung der Firma Müller über 1.240 €. Bitte senden Sie uns beides bis zum 15. Juni.\nViele Grüße\nAnna Berg", day: 2, name: "Anna Berg")),
        SummaryMessage(SummaryTests.mail("jan@own.test", "Re: Unterlagen Jahresabschluss 2025",
                                         "Hallo Frau Berg,\ndie Kontoauszüge kommen morgen, die Rechnung Müller suche ich noch raus.\nGruß Jan\n\nAm 2. Mai schrieb Anna Berg <info@stb-beispiel.example>:\n> für den Jahresabschluss 2025 fehlen uns noch", day: 3),
                       sentByUser: true),
        SummaryMessage(SummaryTests.mail("info@stb-beispiel.example", "Re: Re: Unterlagen Jahresabschluss 2025",
                                         "Danke, die Kontoauszüge sind da. Die Rechnung Müller fehlt weiterhin – ohne sie können wir nicht abschließen.\nAnna Berg", day: 10, name: "Anna Berg")),
    ]

    @Test func theEndpointSummarisesAConversation() async throws {
        let (config, key) = try AILiveTests.config()
        let s = try await MailSummarizer(router: AIRouter(config: config, apiKey: key, log: AICallLog(url: tempDir().appending(path: "ai.jsonl"))))
            .summarize(Self.thread)
        print(s.plainText, "—", s.model, String(format: "%.1f s", s.seconds))
        #expect(s.path == .endpoint && s.summary.contains("Müller") && s.caution == nil)
        #expect(s.todo.contains { $0.contains("Müller") || $0.contains("Rechnung") })
    }

    @Test(.enabled(if: OnDeviceProvider.availability.available)) func theMacsModelSummarisesTheCompactVersion() async throws {
        let router = AIRouter(config: AIConfig(enabled: true, onDevice: true), apiKey: nil, log: AICallLog(url: tempDir().appending(path: "ai.jsonl")))
        let s = try await MailSummarizer(router: router).summarize(Self.thread)
        print(s.plainText, "—", s.model, String(format: "%.1f s", s.seconds))
        #expect(s.path == .onDevice && !s.summary.isEmpty)
    }
}
