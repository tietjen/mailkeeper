import AppKit
import Foundation
import MailKeeperKit

/// RFC 8058 one-click: one POST `List-Unsubscribe=One-Click` to the https target — no cookies, no
/// cache, no redirects (a redirect is answered by opening the page instead), 20 s at most.
enum OneClickUnsubscribe {
    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// The HTTP status.
    static func post(_ url: URL) async throws -> Int {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }
}

extension AppModel {
    func unsubscribeAssessment(_ id: Int64) -> UnsubscribeAssessment? {
        try? reader?.unsubscribeAssessment(for: id)
    }

    /// "Abmelden" (6.5c): checked again at the click, then one click, the page or a mail; logged
    /// (audit) and remembered (a note for the list or sender: further newsletters are unwanted).
    func unsubscribe(_ id: Int64) async -> String {
        guard let reader, let assessment = try? reader.unsubscribeAssessment(for: id) else {
            return String(localized: "Diese Mail bietet keine Abmeldung an.")
        }
        guard !assessment.isBlocked else { return assessment.blocked.joined(separator: " ") }
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
        // the audit log: what was done where (no content)
        if let detail {
            var item = ActionItem(id: 0, sha256: detail.primaryBlob, messageID: detail.messageID, size: detail.summary.size, date: detail.summary.date,
                                  location: nil, identity: nil, state: done ? .done : .failed, reason: assessment.target)
            item.reason = assessment.target
            let job = ActionJob(kind: .unsubscribe, title: summary?.fromDisplay ?? assessment.target, query: nil, graceDays: nil, items: [item])
            try? AuditLog().append(job: job, item: item)
        }
        // remembered: further newsletters of this list or sender are unwanted (the model sees it)
        if done, let address = summary?.fromAddress?.lowercased() {
            let subject = detail?.listID.map { "list:" + $0.lowercased() } ?? "sender:" + address
            let how: String = switch assessment.method {
            case .oneClick: String(localized: "abgemeldet")
            case .web: String(localized: "Abmeldung auf der Webseite angestoßen")
            case .mail: String(localized: "Abmelde-Mail vorbereitet")
            }
            let date = Date.now.formatted(date: .numeric, time: .omitted)
            _ = await saveNote(id: nil, kind: .preference,
                               text: String(localized: "Am \(date) vom Newsletter \(how) (MailKeeper). Weitere Newsletter von hier sind unerwünscht."),
                               subject: subject, scope: "")
        }
        return message
    }
}
