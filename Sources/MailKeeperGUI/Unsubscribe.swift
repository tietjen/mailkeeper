import AppKit
import Foundation
import MailKeeperKit

extension AppModel {
    /// "Abmelden" (6.5c): checked again at the click — it must still say what the user confirmed
    /// (review 6.5c C1) — and the host must lead into the public internet (S1); then one click,
    /// the page or a mail; logged (audit) and remembered once (a note for the list or sender:
    /// further newsletters are unwanted).
    func unsubscribe(_ id: Int64, confirmed: UnsubscribeAssessment) async -> String {
        guard let reader, let assessment = unsubscribeAssessment(id) else {
            return String(localized: "Diese Mail bietet keine Abmeldung an.")
        }
        guard !assessment.isBlocked else { return assessment.blocked.joined(separator: " ") }
        guard assessment.method == confirmed.method else {
            return String(localized: "Die Prüfung sagt inzwischen etwas anderes als eben – sieh dir die Abmeldung bitte noch einmal an.")
        }
        switch assessment.method {
        case .oneClick(let url), .web(let url):
            switch await PublicHost.resolvesPublicly(url.host() ?? "") {
            case true?: break
            case false?: return String(localized: "\(assessment.target) führt in ein lokales Netz – MailKeeper ruft das nicht auf.")
            case nil: return String(localized: "\(assessment.target) ist nicht erreichbar (der Name löst sich nicht auf).")
            }
        case .mail: break
        }
        var message: String
        var done = true
        switch assessment.method {
        case .oneClick(let url):
            do {
                let status = try await OneClickUnsubscribe.post(url)
                if (200..<300).contains(status) {
                    message = String(localized: "Abgemeldet bei \(assessment.target).")
                } else if (300..<400).contains(status) {
                    NSWorkspace.shared.open(url)
                    message = String(localized: "\(assessment.target) leitet weiter – die Abmeldeseite ist im Browser geöffnet.")
                } else {
                    done = false
                    message = String(localized: "\(assessment.target) antwortet mit \(status) – die Abmeldung ist nicht bestätigt.")
                }
            } catch {
                done = false
                message = String(localized: "\(assessment.target) nicht erreichbar: \(error.localizedDescription)")
            }
        case .web(let url):
            NSWorkspace.shared.open(url)
            message = String(localized: "Die Abmeldeseite von \(assessment.target) ist im Browser geöffnet.")
        case .mail(let url):
            NSWorkspace.shared.open(url)
            message = String(localized: "Die Abmelde-Mail an \(assessment.target) ist vorbereitet – noch absenden.")
        }
        let detail = try? reader.detail(id)
        let summary = summaries([id]).first
        // the audit log: how and where, by domain (no content, no list address with its token —
        // review 6.5c C3); one click is done when the server said so, a page or mail only opened
        if let detail {
            let how: String = switch assessment.method {
            case .oneClick: "one-click"
            case .web: "web (geöffnet)"
            case .mail: "mail (vorbereitet)"
            }
            let domain = LinkCheck.registrableDomain(String(assessment.target.split(separator: "@").last ?? ""))
            let item = ActionItem(id: 0, sha256: detail.primaryBlob, messageID: detail.messageID, size: detail.summary.size, date: detail.summary.date,
                                  location: nil, identity: nil, state: done ? .done : .failed, reason: "\(how): \(domain)")
            let job = ActionJob(kind: .unsubscribe, title: domain, query: nil, graceDays: nil, items: [item])
            try? AuditLog().append(job: job, item: item)
        }
        // remembered once: further newsletters of this list or sender are unwanted (the model sees it)
        if done, let address = summary?.fromAddress {
            let subject = UnsubscribeAssessment.memorySubject(listID: detail?.listID, fromAddress: address)
            let known = ((try? reader.memoryItems(subject: subject)) ?? []).contains {
                $0.kind == .preference && ($0.content.text?.contains(UnsubscribeAssessment.noteMarker) ?? false)
            }
            if !known {
                let how: String = switch assessment.method {
                case .oneClick: String(localized: "abgemeldet")
                case .web: String(localized: "Abmeldung auf der Webseite angestoßen")
                case .mail: String(localized: "Abmelde-Mail vorbereitet")
                }
                let date = Date.now.formatted(date: .numeric, time: .omitted)
                let text = String(localized: "Am \(date) vom Newsletter \(how) \(UnsubscribeAssessment.noteMarker). Weitere Newsletter von hier sind unerwünscht.")
                if let problem = await saveNote(id: nil, kind: .preference, text: text, subject: subject, scope: "") {
                    message += " " + String(localized: "Die Notiz fürs Gedächtnis ließ sich gerade nicht speichern: \(problem)")
                }
            }
        }
        return message
    }
}
