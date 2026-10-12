import Foundation

/// Whether — and how — a newsletter can be left from MailKeeper (6.5c, TJ): the List-Unsubscribe
/// target, checked before anything is opened or sent. Locked when the mail looks like phishing, a
/// look-alike or forged, when it is spam (unsubscribing only confirms the address), or when the
/// link itself is suspicious. One click (RFC 8058) only when the own server's check passed —
/// RFC 8058 wants the headers signed; otherwise the page opens in the browser, or a mail.
public struct UnsubscribeAssessment: Sendable, Equatable {
    public enum Method: Sendable, Equatable {
        /// MailKeeper posts `List-Unsubscribe=One-Click` itself.
        case oneClick(URL)
        /// The unsubscribe page opens in the browser.
        case web(URL)
        /// A mail to the list is prepared in the mail program.
        case mail(URL)
    }

    public var method: Method
    /// Where it goes: a host, or the mail address.
    public var target: String
    /// Non-empty: the button is locked, with these reasons.
    public var blocked: [String]
    public var notes: [String]

    public var isBlocked: Bool { !blocked.isEmpty }
}

extension ArchiveReader {
    public func unsubscribeAssessment(for messageID: Int64) throws -> UnsubscribeAssessment? {
        guard let detail = try detail(messageID) else { return nil }
        let headers = HeaderParser.parse((try? layout.blobs.readHead(detail.primaryBlob)) ?? Data()).0
        guard let info = UnsubscribeInfo.parse(listUnsubscribe: headers["List-Unsubscribe"], post: headers["List-Unsubscribe-Post"]) else { return nil }
        var blocked: [String] = []
        var notes: [String] = []
        let c = try classification(of: messageID)
        if c?.phishing == .suspicious || c?.phishing == .likely {
            blocked.append(String(localized: "Die KI hält die Mail für Phishing – ein Abmeldelink kann eine Falle sein."))
        }
        let check = try relationCheck(of: messageID)
        if let r = check.lookAlike, let d = check.senderDomain {
            blocked.append(String(localized: "Die Mail gibt sich als „\(r.name)“ aus, kommt aber von \(d)."))
        }
        if case .failed = check.server {
            blocked.append(String(localized: "Die Prüfung deines Servers ist fehlgeschlagen – der Absender ist vermutlich gefälscht."))
        }
        let ham = c?.verdict == "ham"
        let inJunk = try count(MessageFilter(text: "is:junk ", ids: [messageID])) > 0
        let spam = !ham && (c?.verdict == "spam" || c?.category == .spam || inJunk)
        if spam {
            blocked.append(String(localized: "Bei Spam bestätigt eine Abmeldung nur, dass deine Adresse existiert – lösche die Mail lieber."))
        }
        if let https = info.https {
            let findings = LinkCheck(href: https.absoluteString, text: nil).findings
            if !findings.isEmpty {
                blocked.append(String(localized: "Der Abmeldelink ist auffällig: \(findings.map(\.text).joined(separator: "; "))."))
            }
        }
        let auth = try authentication(of: messageID)
        let signed = auth.map { $0.trusted && $0.results.dkim == "pass" && $0.results.dmarc == "pass" } ?? false
        let method: UnsubscribeAssessment.Method
        let target: String
        if let https = info.https, info.oneClick, signed {
            method = .oneClick(https)
            target = https.host() ?? https.absoluteString
        } else if let https = info.https {
            method = .web(https)
            target = https.host() ?? https.absoluteString
            if info.oneClick {
                notes.append(String(localized: "Ein-Klick-Abmeldung angeboten, aber ohne bestätigte Signatur deines Servers – MailKeeper öffnet die Seite stattdessen im Browser."))
            }
        } else if let mailto = info.mailto {
            method = .mail(mailto)
            target = String(mailto.absoluteString.dropFirst("mailto:".count).prefix { $0 != "?" })
        } else {
            return nil
        }
        // a different host is common (mail services) — said, not held against it
        if let host = info.https?.host()?.lowercased(), let sender = check.senderDomain, LinkCheck.registrableDomain(host) != sender {
            notes.append(String(localized: "Die Abmeldung läuft über \(LinkCheck.registrableDomain(host)), nicht über \(sender) – bei Versanddiensten üblich."))
        }
        return UnsubscribeAssessment(method: method, target: String(target.prefix(200)), blocked: blocked, notes: notes)
    }
}
