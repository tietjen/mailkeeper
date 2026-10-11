import Foundation
import MailKeeperKit

public struct MailClassification: Sendable, Equatable {
    public var category: MailCategory
    /// One short sentence, display-safe.
    public var reason: String
    /// Phishing apart from the category (TJ, 5.6): a spam newsletter is no phishing, a fake
    /// invoice can be both.
    public var phishing: PhishingLevel
    public var phishingReason: String?
    public var path: AIPath
    public var model: String
    public var seconds: Double
}

/// A model's category for a mail the rules left open (ADR-0004 §1, Phase 5.4). The mail goes
/// in fenced (5.2) — headers and a bounded excerpt — and the answer is one of the nine
/// categories under a strict schema. A category is a label, never a reason to act on its own.
public struct MailClassifier: Sendable {
    let router: AIRouter

    public init(router: AIRouter) {
        self.router = router
    }

    public func classify(_ mail: MailSnapshot) async throws -> MailClassification {
        let fence = Fence()
        let result = try await router.chat(ChatRequest(task: .classify, system: Self.instructions(fence), user: fence.wrap(mail.rendered(maxText: 1_200)),
                                                       schema: Self.schema, maxTokens: 300))
        struct Answer: Decodable { var category: String; var reason: String; var phishing: String; var phishing_reason: String? }
        let answer = try result.decode(Answer.self)
        guard let category = MailCategory(rawValue: answer.category), let phishing = PhishingLevel(rawValue: answer.phishing) else {
            throw AIError.badAnswer(String(localized: "Unbekannte Kategorie in der Antwort"))
        }
        let phishingReason = answer.phishing_reason.map { PromptText.line($0, max: 200) }.flatMap { $0.isEmpty ? nil : $0 }
        return MailClassification(category: category, reason: PromptText.line(answer.reason, max: 160),
                                  phishing: phishing, phishingReason: phishing == .none ? nil : phishingReason,
                                  path: result.path, model: result.model, seconds: result.seconds)
    }

    static let schema = AISchema.object(name: "classification", properties: [
        .init("category", .choice(name: "category", values: MailCategory.allCases.map(\.rawValue))),
        .init("reason", .string(), description: "Begründung, höchstens zehn Wörter, Deutsch"),
        .init("phishing", .choice(name: "phishing", values: PhishingLevel.allCases.map(\.rawValue))),
        .init("phishing_reason", .string(), description: "Bei verdacht/ja: die konkreten Anzeichen, höchstens 20 Wörter", optional: true),
    ])

    static func instructions(_ fence: Fence) -> String {
        """
        Du ordnest E-Mails genau einer Kategorie zu.
        newsletter: abonnierter Newsletter oder Marketing eines Absenders, bei dem man Kunde oder Abonnent ist
        notification: automatische Benachrichtigung von Systemen, Diensten, sozialen Netzwerken, Kalendern, Monitoring
        invoice: Rechnung, Quittung, Beleg, Zahlungsbestätigung, Abrechnung eines echten Geschäfts
        order_shipping: Bestellbestätigung, Versand- oder Lieferinformation
        account_security: Anmeldung, Passwort, Einmalcode, Sicherheitswarnung eines echten Dienstes
        personal: persönliche Nachricht eines Menschen aus Familie oder Freundeskreis
        work: berufliche Nachricht eines Menschen (Kunden, Partner, Kollegen, Berater, Behörden)
        travel: Buchung, Ticket, Check-in, Reiseunterlagen
        spam: unerwünschte Werbung, Betrug, Phishing – auch wenn sie sich als Rechnung oder Sicherheitswarnung tarnt
        Die Begründung ist ein Stichwortsatz von höchstens zehn Wörtern, z. B. „Einladung von Max zum Grillen“.

        Getrennt davon bewertest du Phishing: Die Mail will Zugangsdaten, Zahlungen, persönliche Daten oder das \
        Öffnen von Schadsoftware erschleichen und gibt sich dafür als Bank, Dienst, Händler, Behörde oder bekannte \
        Person aus. Anzeichen: Linktext zeigt eine andere Domain als das Ziel, Absender- oder Linkdomain passt nicht \
        zur genannten Firma, Druck („sofort“, „gesperrt“, „letzte Mahnung“), Reply-To auf eine fremde Domain, \
        fehlgeschlagene Prüfung des eigenen Servers (dmarc=fail, dkim=fail), Kurzlinks oder IP-Adressen als Ziel.
        Newsletter leiten Klicks oft über Tracking-Domains (mailchimp, sendgrid, hubspot …) – das allein ist kein Phishing.
        phishing: nein = keine Anzeichen; verdacht = einzelne Anzeichen; ja = klare Täuschung.
        \(fence.rule)
        """
    }
}
