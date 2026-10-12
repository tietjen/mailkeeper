import MailKeeperKit
import SwiftUI

/// Settings › Regeln (6.5b): the user's rules — a search and what happens to its mails — and
/// what MailKeeper suggests from repeated decisions. A rule that sets the category runs by
/// itself; one that deletes or moves only says how many mails are ready and opens the plan.
struct RuleSettings: View {
    let model: AppModel
    @State private var selection: Set<String> = []
    @State private var draft: RuleDraft?
    @State private var message: String?

    private var active: [MailRule] { model.mailRules.filter(\.active) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Eine Regel ist eine Suche und was mit ihren Mails geschieht. „Art festlegen“ läuft von selbst – über Regeln und KI, aber nie über deine Entscheidung an einer einzelnen Mail. Löschen und Verschieben laufen nie von selbst: MailKeeper zeigt, wie viele Mails bereit sind, und du bestätigst in der Übersicht.")
                .font(.callout).foregroundStyle(.secondary).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Table(active, selection: $selection) {
                TableColumn("Regel") { r in Text(DisplayText.safe(r.name)).lineLimit(2) }.width(min: 160, ideal: 220)
                TableColumn("Suche") { r in Text(r.query).font(.callout.monospaced()).lineLimit(2).foregroundStyle(.secondary) }.width(min: 140, ideal: 200)
                TableColumn("Aktion") { r in Text(r.action.label) }.width(min: 120, ideal: 170)
                TableColumn("") { r in
                    if r.action.isDestructive {
                        let ready = model.ruleReady[r.id] ?? 0
                        Button(ready == 0 ? "nichts bereit" : "\(ready) bereit – ausführen …") { model.runRule(r) }
                            .controlSize(.small).disabled(ready == 0 || model.actionRunning)
                    } else {
                        Text("läuft von selbst").foregroundStyle(.secondary)
                    }
                }
                .width(min: 120, ideal: 160)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let r = active.first(where: { $0.id == ids.first }) {
                    Button("Bearbeiten …") { draft = RuleDraft(r) }
                    Button("Löschen") { Task { message = await model.forgetRule(r.id) } }
                }
            } primaryAction: { ids in
                if ids.count == 1, let r = active.first(where: { $0.id == ids.first }) { draft = RuleDraft(r) }
            }
            HStack {
                Button("Neue Regel …") { draft = RuleDraft() }
                Spacer()
                if model.loadingRules { ProgressView().controlSize(.small) }
            }
            if !model.ruleSuggestions.isEmpty {
                Divider()
                Text("Vorschläge – weil du es mehrmals getan hast").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.ruleSuggestions) { s in RuleSuggestionRow(model: model, suggestion: s, edit: { draft = RuleDraft(s) }, message: $message) }
                    }
                }
                .frame(maxHeight: 220)
            }
            if let message { Text(DisplayText.safe(message)).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 460)
        .onAppear { model.reloadRules() }
        .sheet(item: $draft) { d in
            RuleEditor(model: model, draft: d) { problem in
                message = problem
                draft = nil
            }
        }
    }
}

struct RuleSuggestionRow: View {
    let model: AppModel
    let suggestion: RuleSuggestion
    let edit: () -> Void
    @Binding var message: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(DisplayText.safe(suggestion.name)).fontWeight(.medium)
                Text("\(suggestion.evidence) · \(suggestion.matches) Mails passen · \(suggestion.query)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            Button("Übernehmen …", action: edit).controlSize(.small)
            Button("Ablehnen") { Task { message = await model.rejectRule(suggestion) } }.controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).stroke(.separator))
    }
}

struct RuleDraft: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case category, serverDelete, moveToJunk
        var id: String { rawValue }
        var label: String {
            switch self {
            case .category: String(localized: "Art festlegen")
            case .serverDelete: String(localized: "nach Tagen vom Server löschen")
            case .moveToJunk: String(localized: "in den Spam-Ordner")
            }
        }
    }

    var id = UUID().uuidString
    var existing: String?
    var name = ""
    var query = ""
    var kind = Kind.category
    var category = MailCategory.newsletter
    var days = 30

    init() {}

    init(query: String, name: String) {
        self.query = query
        self.name = name
    }

    init(_ r: MailRule) {
        existing = r.id
        name = r.name
        query = r.query
        set(r.action)
    }

    init(_ s: RuleSuggestion) {
        name = s.name
        query = s.query
        set(s.action)
    }

    private mutating func set(_ action: MailRule.Action) {
        switch action {
        case .category(let c): kind = .category; category = c
        case .serverDelete(let d): kind = .serverDelete; days = d
        case .moveToJunk: kind = .moveToJunk
        }
    }

    var action: MailRule.Action {
        switch kind {
        case .category: .category(category)
        case .serverDelete: .serverDelete(days: max(1, min(days, 3650)))
        case .moveToJunk: .moveToJunk
        }
    }
}

struct RuleEditor: View {
    let model: AppModel
    @State var draft: RuleDraft
    let done: (String?) -> Void
    @State private var saving = false

    var body: some View {
        let matches = model.ruleMatches(draft.query)
        Form {
            TextField("Name", text: $draft.name, prompt: Text("z. B. LinkedIn-Mitteilungen"))
            TextField("Suche", text: $draft.query, prompt: Text("sender:updates@linkedin.com"))
                .font(.body.monospaced())
            Text(matches.map { "\($0.formatted()) Mails passen heute" } ?? "Keine gültige Suche (Suchsprache wie in der Suchleiste)")
                .font(.caption).foregroundStyle(matches == nil ? .red : .secondary)
            Picker("Aktion", selection: $draft.kind) {
                ForEach(RuleDraft.Kind.allCases) { Text($0.label).tag($0) }
            }
            switch draft.kind {
            case .category:
                Picker("Art", selection: $draft.category) {
                    ForEach(MailCategory.allCases, id: \.self) { Label($0.label, systemImage: $0.icon).tag($0) }
                }
                Text("Läuft von selbst – über Regeln, ähnliche Mails und KI, nie über deine Entscheidung an einer einzelnen Mail. Die Echtheitsprüfung gilt weiter.")
                    .font(.caption).foregroundStyle(.secondary)
            case .serverDelete:
                Stepper("Nach \(draft.days) Tagen", value: $draft.days, in: 1...3650)
                Text("Läuft nie von selbst: MailKeeper zeigt, wie viele Mails bereit sind; du bestätigst in der Übersicht. Das Archiv behält sie.")
                    .font(.caption).foregroundStyle(.secondary)
            case .moveToJunk:
                Text("Läuft nie von selbst: MailKeeper zeigt, wie viele Mails bereit sind; du bestätigst in der Übersicht.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    saving = true
                    Task {
                        let problem = await model.saveRule(id: draft.existing, name: draft.name, query: draft.query, action: draft.action)
                        saving = false
                        done(problem)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || matches == nil)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .padding(.vertical, 8)
    }
}
