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

extension UnsubscribeAssessment {
    /// The memory subject of a newsletter: its list, else its sender.
    public static func memorySubject(listID: String?, fromAddress: String) -> String {
        listID.map { "list:" + $0.lowercased() } ?? "sender:" + fromAddress.lowercased()
    }

    /// Marks MailKeeper's own note after an unsubscribe (so it is written once, and found again).
    public static let noteMarker = "(MailKeeper)"

    /// Why an https target is refused before anything goes out (review 6.5c S1): a host that is
    /// no ordinary public name — numbers in disguise (2130706433, 127.1, 0x7f.0.0.1), percent
    /// signs, a single label, a local suffix — or one in the user's own domain.
    static func hostProblem(_ url: URL, ownDomains: Set<String>) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return String(localized: "Der Abmeldelink hat kein Ziel.") }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.allSatisfy({ ($0.isASCII && ($0.isLetter || $0.isNumber)) || $0 == "." || $0 == "-" }), labels.count >= 2,
              !labels.contains(where: \.isEmpty), let top = labels.last, top.hasPrefix("xn--") || (top.count >= 2 && top.allSatisfy(\.isLetter))
        else { return String(localized: "Der Abmeldelink führt nicht zu einem gewöhnlichen Namen im Internet (\(host)).") }
        let local: Set<String> = ["localhost", "local", "localdomain", "internal", "intranet", "lan", "home", "corp", "private", "onion", "arpa"]
        if local.contains(String(top)) { return String(localized: "Der Abmeldelink führt ins lokale Netz (\(host)).") }
        let domain = LinkCheck.registrableDomain(host)
        if ownDomains.contains(domain), !Relations.freemail.contains(domain) {
            return String(localized: "Der Abmeldelink führt in deine eigene Domain \(domain) – das tut kein Newsletter.")
        }
        return nil
    }
}

extension ArchiveReader {
    /// `relations`, `servers` and `ownDomains` from a caller that holds them (the GUI caches
    /// them; review 6.5c S2) — else computed here.
    public func unsubscribeAssessment(for messageID: Int64, relations: [Relation]? = nil, servers: [String: Set<String>]? = nil,
                                      ownDomains: Set<String>? = nil) throws -> UnsubscribeAssessment? {
        guard let detail = try detail(messageID) else { return nil }
        let headers = HeaderParser.parse((try? layout.blobs.readHead(detail.primaryBlob)) ?? Data()).0
        guard let info = UnsubscribeInfo.parse(headers: headers) else { return nil }
        var blocked: [String] = []
        var notes: [String] = []
        if info.duplicated {
            blocked.append(String(localized: "Die Mail nennt mehr als eine Abmelde-Angabe – eine davon wurde vermutlich unterwegs eingefügt."))
        }
        let c = try classification(of: messageID)
        if c?.phishing == .suspicious || c?.phishing == .likely {
            blocked.append(String(localized: "Die KI hält die Mail für Phishing – ein Abmeldelink kann eine Falle sein."))
        }
        let servers = try servers ?? ownAuthServers()
        let check = try relationCheck(of: messageID, relations: relations, servers: servers, publicAddresses: [])
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
            } else if let problem = UnsubscribeAssessment.hostProblem(https, ownDomains: try ownDomains ?? self.ownDomains()) {
                blocked.append(problem)
            }
        }
        let auth = try authentication(of: messageID, servers: servers)
        let passed = auth.map { $0.trusted && $0.results.dkim == "pass" && $0.results.dmarc == "pass" } ?? false
        // RFC 8058 §4: both headers under the sender's own (aligned) signature — a replayed signed
        // mail with headers put on top passes DKIM but leaves them unsigned (review 6.5c B1)
        let fromDomain = auth?.results.fromDomain ?? check.senderDomain
        let covered = fromDomain.map { DKIMSignature.covers(headers, fields: ["List-Unsubscribe", "List-Unsubscribe-Post"], domain: $0) } ?? false
        let listCovered = fromDomain.map { DKIMSignature.covers(headers, fields: ["List-Unsubscribe"], domain: $0) } ?? false
        let method: UnsubscribeAssessment.Method
        let target: String
        if let https = info.https, info.oneClick, passed, covered {
            method = .oneClick(https)
            target = https.host() ?? https.absoluteString
        } else if let https = info.https {
            method = .web(https)
            target = https.host() ?? https.absoluteString
            if info.oneClick {
                notes.append(passed
                    ? String(localized: "Ein-Klick-Abmeldung angeboten, aber die Signatur des Absenders deckt die Abmelde-Angabe nicht – MailKeeper öffnet die Seite stattdessen im Browser.")
                    : String(localized: "Ein-Klick-Abmeldung angeboten, aber ohne bestätigte Signatur deines Servers – MailKeeper öffnet die Seite stattdessen im Browser."))
            } else if passed, !listCovered {
                notes.append(String(localized: "Die Abmelde-Angabe ist nicht von der Signatur des Absenders gedeckt – gib auf der Seite nichts ein außer der Abmeldung."))
            }
        } else if let mailto = info.mailto {
            method = .mail(mailto)
            target = URLComponents(url: mailto, resolvingAgainstBaseURL: false)?.path ?? ""
            if let subject = URLComponents(url: mailto, resolvingAgainstBaseURL: false)?.queryItems?.first?.value {
                notes.append(String(localized: "Betreff der Abmelde-Mail: „\(subject)“"))
            }
        } else {
            return nil
        }
        // a different host is common (mail services) — said, not held against it
        if let host = info.https?.host()?.lowercased(), let sender = check.senderDomain, LinkCheck.registrableDomain(host) != sender {
            notes.append(String(localized: "Die Abmeldung läuft über \(LinkCheck.registrableDomain(host)), nicht über \(sender) – bei Versanddiensten üblich."))
        }
        // done before (MailKeeper's own note)
        if let from = detail.summary.fromAddress {
            let subject = UnsubscribeAssessment.memorySubject(listID: detail.listID, fromAddress: from)
            if let earlier = try memoryItems().first(where: { $0.kind == .preference && $0.subject == subject
                && ($0.content.text?.contains(UnsubscribeAssessment.noteMarker) ?? false) }), let text = earlier.content.text {
                notes.append(String(localized: "Schon einmal: \(text)"))
            }
        }
        return UnsubscribeAssessment(method: method, target: String(target.prefix(200)), blocked: blocked, notes: notes)
    }
}
