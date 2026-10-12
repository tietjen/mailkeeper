import MailKeeperAI
import MailKeeperKit
import SwiftUI

/// "Inhalt" in the reader (5.8): summarise the mail or its conversation on request, and the
/// summary itself — which model wrote it, how much of the conversation it covers, copy and close.
struct SummaryRow: View {
    let model: AppModel
    let messageID: Int64
    /// The conversation, oldest first (empty when the message stands alone).
    let thread: [MessageSummary]

    var body: some View {
        let mail = AppModel.SummaryScope.mail(messageID)
        let conversation = thread.count > 1 ? AppModel.SummaryScope.thread(thread[0].id) : nil
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Inhalt").foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            VStack(alignment: .leading, spacing: 6) {
                if let conversation, let state = model.summaries[conversation] {
                    SummaryBox(state: state, title: String(localized: "Konversation"), total: thread.count,
                               retry: { model.summarize(conversation, ids: thread.map(\.id)) },
                               close: { model.closeSummary(conversation) }, copy: model.copySummary)
                }
                if let state = model.summaries[mail] {
                    SummaryBox(state: state, title: conversation == nil ? nil : String(localized: "Diese Mail"), total: 1,
                               retry: { model.summarize(mail, ids: [messageID]) },
                               close: { model.closeSummary(mail) }, copy: model.copySummary)
                }
                let askMail = model.summaries[mail] == nil
                let askConversation = conversation.map { model.summaries[$0] == nil } ?? false
                if askMail || askConversation {
                    HStack(spacing: 6) {
                        if askConversation, let conversation {
                            Button("Konversation zusammenfassen (\(thread.count))") { model.summarize(conversation, ids: thread.map(\.id)) }
                                .help("Der Verlauf in wenigen Sätzen: wer was wollte, was entschieden ist, was offen ist (⌥⇧⌘S)")
                        }
                        if askMail {
                            Button(conversation == nil ? "Zusammenfassen" : "Nur diese Mail") { model.summarize(mail, ids: [messageID]) }
                                .help("Worum es geht, die wichtigen Fakten und was zu tun ist (⌥⌘S)")
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .font(.callout)
    }
}

private struct SummaryBox: View {
    let state: AppModel.SummaryState
    let title: String?
    /// Messages the conversation has now — more than the summary covered means new ones came.
    let total: Int
    let retry: () -> Void
    let close: () -> Void
    let copy: (MailSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch state {
            case .running(let since):
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text("\(title.map { "\($0): " } ?? "")fasst zusammen … \(max(0, Int(context.date.timeIntervalSince(since)))) s")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Button("Abbrechen", action: close).controlSize(.small)
                }
            case .failed(let message):
                Text("Zusammenfassen ging nicht: \(DisplayText.safe(message))").foregroundStyle(.red)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 6) {
                    Button("Erneut versuchen", action: retry)
                    Button("Schließen", action: close)
                }
                .controlSize(.small)
            case .done(let s):
                if let title { Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary) }
                if let caution = s.caution {
                    Label(DisplayText.safe(caution), systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange).fontWeight(.semibold)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                }
                Text(DisplayText.safe(s.summary))
                    .textSelection(.enabled)
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                if !s.points.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(s.points.enumerated()), id: \.offset) { _, point in
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("•").foregroundStyle(.secondary)
                                Text(DisplayText.safe(point)).textSelection(.enabled).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                if !s.todo.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(s.todo.enumerated()), id: \.offset) { _, item in
                            Label(DisplayText.safe(item), systemImage: "checkmark.circle")
                                .foregroundStyle(.blue)
                                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                HStack(spacing: 6) {
                    Text(footer(s)).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button { copy(s) } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless).help("Zusammenfassung kopieren")
                    Button { retry() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless).help("Neu zusammenfassen")
                    Button { close() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless).help("Zusammenfassung schließen")
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
    }

    private func footer(_ s: MailSummary) -> String {
        var parts = [s.path == .onDevice ? String(localized: "Modell auf diesem Mac") : DisplayText.safe(s.model),
                     String(format: "%.1f s", s.seconds)]
        if s.total > 1 || s.covered > 1 {
            parts.append(s.covered < s.total ? String(localized: "die letzten \(s.covered) von \(s.total) Nachrichten")
                                             : String(localized: "\(s.covered) Nachrichten"))
        }
        if total > s.total { parts.append(String(localized: "seitdem \(total - s.total) neu")) }
        return parts.joined(separator: " · ")
    }
}

/// "Abmelden" (6.5c, TJ): locked with its reasons when the mail or its link looks wrong; else
/// says how — one click by MailKeeper, the page in the browser, or a mail — and asks first.
struct UnsubscribeRow: View {
    let model: AppModel
    let messageID: Int64
    let assessment: UnsubscribeAssessment
    @State private var confirming = false
    @State private var running = false
    @State private var result: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Abmelden").foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                if assessment.isBlocked {
                    Label("Abmelden gesperrt", systemImage: "hand.raised.fill").foregroundStyle(.red).fontWeight(.semibold)
                    ForEach(Array(assessment.blocked.enumerated()), id: \.offset) { _, reason in
                        Text(DisplayText.safe(reason)).foregroundStyle(.secondary).lineLimit(3)
                            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(spacing: 6) {
                        Button(running ? "Melde ab …" : "Vom Newsletter abmelden …") { confirming = true }
                            .controlSize(.small).disabled(running)
                        Text(Self.how(assessment)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let result { Text(DisplayText.safe(result)).foregroundStyle(.secondary).lineLimit(2) }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .confirmationDialog("Vom Newsletter abmelden?", isPresented: $confirming, titleVisibility: .visible) {
            Button(Self.action(assessment)) {
                running = true
                Task { result = await model.unsubscribe(messageID, confirmed: assessment); running = false }
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text(([Self.explain(assessment)] + assessment.notes).map(DisplayText.safe).joined(separator: "\n\n"))
        }
    }

    static func how(_ a: UnsubscribeAssessment) -> String {
        switch a.method {
        case .oneClick: String(localized: "mit einem Klick bei \(a.target)")
        case .web: String(localized: "Seite \(a.target) im Browser")
        case .mail: String(localized: "Mail an \(a.target)")
        }
    }

    static func action(_ a: UnsubscribeAssessment) -> String {
        switch a.method {
        case .oneClick: String(localized: "Jetzt abmelden")
        case .web: String(localized: "Abmeldeseite öffnen")
        case .mail: String(localized: "Abmelde-Mail vorbereiten")
        }
    }

    static func explain(_ a: UnsubscribeAssessment) -> String {
        switch a.method {
        case .oneClick:
            String(localized: "MailKeeper schickt \(a.target) die standardisierte Ein-Klick-Abmeldung (RFC 8058) – ohne Browser, ohne Cookies. Der Absender ist von deinem Server bestätigt.")
        case .web:
            String(localized: "MailKeeper öffnet die Abmeldeseite \(a.target) im Browser; dort schließt du die Abmeldung ab.")
        case .mail:
            String(localized: "MailKeeper bereitet in deinem Mailprogramm eine Abmelde-Mail an \(a.target) vor; du schickst sie ab.")
        }
    }
}
