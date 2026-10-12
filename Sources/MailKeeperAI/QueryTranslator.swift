import Foundation
import MailKeeperKit

/// What the archive offers to search in — names only, for the model to use the right ones.
public struct QueryContext: Sendable, Equatable {
    public var accounts: [String]
    public var folders: [String]
    /// The user's terms from the memory (6.2): "Firma = Konto proton".
    public var vocabulary: [String]

    public init(accounts: [String] = [], folders: [String] = [], vocabulary: [String] = []) {
        self.accounts = accounts
        self.folders = folders
        self.vocabulary = vocabulary
    }
}

public struct QueryTranslation: Sendable, Equatable {
    /// Query text in MailKeeper's search language (ADR-0008), already parsed once.
    public var query: String
    /// One short sentence, display-safe.
    public var explanation: String
    public var path: AIPath
    public var model: String
    public var seconds: Double
}

/// Everyday language → search language (ADR-0008, Phase 5.3). The model only writes query text;
/// MailKeeper's own parser checks it (fail closed: an invalid query never runs, one retry with
/// the parser's message, then an error). The text is shown — editable — before it searches.
public struct QueryTranslator: Sendable {
    let router: AIRouter

    public init(router: AIRouter) {
        self.router = router
    }

    public static let maxInput = 500
    public static let maxQuery = 600

    public func translate(_ text: String, context: QueryContext, now: Date = Date()) async throws -> QueryTranslation {
        let input = PromptText.line(text, max: Self.maxInput)
        guard !input.isEmpty else { throw AIError.badAnswer(String(localized: "Nichts zu übersetzen")) }
        let system = Self.instructions(context: context, now: now)
        var user = "Suchwunsch: \(input)"
        var lastError = ""
        var seconds = 0.0
        for attempt in 1...2 {
            let result = try await router.chat(ChatRequest(task: .search, system: system, user: user, schema: Self.schema, maxTokens: 400))
            seconds += result.seconds
            struct Answer: Decodable { var query: String; var explanation: String }
            let answer = try result.decode(Answer.self)
            let query = PromptText.line(answer.query, max: Self.maxQuery + 1)
            var problem: String?
            if query.isEmpty {
                problem = String(localized: "leer")
            } else if query.count > Self.maxQuery {
                problem = String(localized: "zu lang")
            } else {
                do throws(QueryError) { _ = try QueryParser.parse(query + " ", now: now) } catch { problem = error.message }
            }
            guard let problem else {
                return QueryTranslation(query: query, explanation: PromptText.line(answer.explanation, max: 200),
                                        path: result.path, model: result.model, seconds: seconds)
            }
            lastError = problem
            guard attempt == 1 else { break }
            user = """
            Suchwunsch: \(input)
            Deine vorige Abfrage „\(query)“ ist ungültig: \(problem). Gib eine gültige Abfrage aus.
            """
        }
        throw AIError.badAnswer(String(localized: "Die KI hat keine gültige Suche erzeugt (\(lastError))."))
    }

    static let schema = AISchema.object(name: "search", properties: [
        .init("query", .string(), description: "Die Abfrage in der Suchsprache"),
        .init("explanation", .string(), description: "Was die Suche findet, höchstens zwölf Wörter, ohne die Abfrage zu wiederholen"),
    ])

    static func instructions(context: QueryContext, now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "de_DE")
        let today = now.formatted(.iso8601.year().month().day())
        let weekday = calendar.weekdaySymbols[calendar.component(.weekday, from: now) - 1]
        let accounts = context.accounts.prefix(20).map { PromptText.line($0, max: 40) }.joined(separator: ", ")
        let folders = context.folders.prefix(60).map { PromptText.line($0, max: 60) }.joined(separator: ", ")
        let vocabulary = context.vocabulary.prefix(20).map { PromptText.line($0, max: 120) }.joined(separator: "; ")
        return """
        Du übersetzt Suchwünsche für ein Mail-Archiv in seine Suchsprache. Gib nur Felder aus dieser Liste aus:

        wort "genaue phrase"           Wörter/Phrasen im Text, alle müssen vorkommen
        from:x  to:x  subject:x  body:x  Wort im Absender (Name oder Adresse), Empfänger, Betreff, Text
        sender:a@b.de  sender:@b.de    exakte Absenderadresse bzw. ganze Domain (nur wenn genannt)
        domain:b.de  listid:x  list:x  exakte Absenderdomain, exakte List-Id, List-Id enthält x
        filename:x  pdf:x              Wort im Anhangsnamen bzw. nur im Text von PDF-Anhängen
        has:attachment|pdf|image|calendar
        larger:5M  smaller:100K        Größe
        after:2024-03  before:2025  until:2024-12-31  date:2024-05   Zeiträume (Jahr, Monat oder Tag)
        after:30d  before:1y           relativ: d Tage, w Wochen, m Monate, y Jahre; date:heute, date:gestern
        account:x  folder:x  folder:Archiv/*  label:x
        is:unread|read|flagged|answered|list|sent   on:server   only:archive   (is:sent = selbst gesendete Mails)
        is:junk  is:phishing           im Spam-Ordner; von der KI als Phishing(-Verdacht) bewertet
        kategorie:newsletter|benachrichtigung|rechnung|bestellung|konto|persönlich|arbeit|reise|spam|offen   Art der Mail
        -wort  -from:x                 Ausschluss
        a OR b   ( … )                 Alternativen und Klammern; Leerzeichen heißt UND

        Regeln:
        - Heute ist \(weekday), der \(today). Rechne relative Angaben in Zeiträume um: „2024“ → date:2024, \
        „letztes Jahr“ → date:\(calendar.component(.year, from: now) - 1), „seit März“ → after:\(calendar.component(.year, from: now))-03, \
        „letzte Woche“ → after:7d, „älter als zwei Jahre“ → before:2y.
        - Firmen und Personen als from:name (ein Wort, klein), sender: oder domain: nur bei genannter Adresse/Domain.
        - Begriffe für Mailarten als Wörter mit Alternativen, z. B. Rechnungen → (rechnung OR invoice OR beleg). \
        kategorie: nur, wenn ausdrücklich nach der Einordnung gefragt ist („alle Newsletter“, „noch nicht eingeordnet“ → \
        kategorie:offen) – es findet nur bereits eingeordnete Mails. Phishing → is:phishing, Spam-Ordner → is:junk.
        - Füllwörter (von, mit, alle, Mails, zeig mir) lässt du weg. Keine Felder erfinden, keine Erklärungen in die Abfrage.
        - Konten: \(accounts.isEmpty ? "—" : accounts)
        - Ordner: \(folders.isEmpty ? "—" : folders)\(vocabulary.isEmpty ? "" : "\n        - Begriffe des Nutzers (sie gelten): " + vocabulary)
        - Im Zweifel die einfachere Abfrage.

        Beispiele (Suchwunsch → query | explanation):
        „Rechnungen von Amazon 2024 mit PDF“ → from:amazon (rechnung OR invoice) date:2024 has:pdf | Rechnungen von Amazon aus 2024 mit PDF-Anhang
        „ungelesene Newsletter der letzten Woche“ → is:unread is:list after:7d | Ungelesene Newsletter der letzten sieben Tage
        „große Mails mit Anhang, älter als zwei Jahre, noch auf dem Server“ → larger:5M has:attachment before:2y on:server | Große alte Mails mit Anhang, die noch auf dem Server liegen
        „Mails von Max über den Workshop“ → from:max workshop | Mails von Max, in denen „Workshop“ vorkommt
        „Kündigungen als PDF“ → pdf:kündigung | PDF-Anhänge, in denen „Kündigung“ steht
        „alles im Ordner Steuer, außer von Elster“ → folder:Steuer -from:elster | Ordner Steuer ohne Mails von Elster
        „was ich Max 2025 geschickt habe“ → is:sent to:max date:2025 | Von dir an Max gesendete Mails aus 2025
        Die explanation beschreibt nur das Ergebnis – nie, wie du übersetzt hast.
        """
    }
}
