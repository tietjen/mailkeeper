import MailKeeperKit
import SwiftUI

/// Settings › Gedächtnis (6.1, ADR-0005): what MailKeeper learned — the user's notes and terms,
/// and examples from the user's decisions. Look, write, forget, export, import.
struct MemorySettings: View {
    let model: AppModel
    @State private var selection: Set<String> = []
    @State private var filter: MemoryKind?
    @State private var draft: NoteDraft?
    @State private var message: String?
    @State private var confirmForgetAll = false

    private var items: [MemoryItem] {
        model.memoryItems.filter { filter == nil || $0.kind == filter }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Was MailKeeper von dir lernt: Notizen und Begriffe, die du schreibst, und Beispiele aus deinen Entscheidungen (Art ändern, Ist Spam, Kein Spam). Die KI bekommt sie ab dem nächsten Schritt beim Einordnen mit. Nichts davon verlässt deinen Mac – außer als Kontext an deinen KI-Endpoint.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Picker("Zeigen", selection: $filter) {
                Text("Alles (\(model.memoryItems.count))").tag(MemoryKind?.none)
                ForEach([MemoryKind.preference, .vocabulary, .example], id: \.self) { kind in
                    Text("\(kind.label) (\(model.memoryItems.filter { $0.kind == kind }.count))").tag(MemoryKind?.some(kind))
                }
            }
            .pickerStyle(.segmented)
            Table(items, selection: $selection) {
                TableColumn("Art") { item in Text(item.kind.label) }.width(min: 70, ideal: 90)
                TableColumn("Inhalt") { item in
                    Text(DisplayText.safe(item.summary)).lineLimit(2).help(DisplayText.safe(item.summary))
                }
                .width(min: 200, ideal: 300)
                TableColumn("Bezug") { item in Text(DisplayText.safe(Self.subjectLabel(item))).lineLimit(1).foregroundStyle(.secondary) }
                    .width(min: 100, ideal: 160)
                TableColumn("Herkunft") { item in Text(item.provenance.label).foregroundStyle(item.provenance.trusted ? Color.primary : Color.orange) }
                    .width(min: 90, ideal: 110)
                TableColumn("Geändert") { item in Text(item.updated.formatted(date: .numeric, time: .omitted)).monospacedDigit() }
                    .width(min: 70, ideal: 80)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let item = model.memoryItems.first(where: { $0.id == ids.first }), item.provenance == .user {
                    Button("Bearbeiten …") { draft = NoteDraft(item) }
                }
                Button("Vergessen") { forget(ids) }
            } primaryAction: { ids in
                if ids.count == 1, let item = model.memoryItems.first(where: { $0.id == ids.first }), item.provenance == .user { draft = NoteDraft(item) }
            }
            HStack {
                Button("Notiz …") { draft = NoteDraft(kind: .preference) }
                    .help("Etwas, das MailKeeper wissen soll, z. B. „Mails vom Steuerberater sind wichtig“")
                Button("Begriff …") { draft = NoteDraft(kind: .vocabulary) }
                    .help("Ein Wort, das du benutzt, z. B. „Firma = das Proton-Konto“")
                Button("Vergessen") { forget(selection) }.disabled(selection.isEmpty)
                    .help("Nicht mehr verwenden und nicht mehr zeigen – deine Entscheidung an der Mail selbst bleibt")
                Spacer()
                Button("Exportieren …") { message = model.exportMemory() }
                    .help("Alles hier als JSON-Datei sichern")
                Button("Importieren …") { Task { message = await model.importMemory() } }
                    .help("Notizen und Begriffe aus einer exportierten Datei übernehmen; Beispiele gehören zum Archiv, aus dem sie stammen")
                Button("Alles vergessen …") { confirmForgetAll = true }.disabled(model.memoryItems.isEmpty)
            }
            if let message { Text(DisplayText.safe(message)).font(.callout).foregroundStyle(.secondary) }
        }
        .padding(20)
        .frame(minWidth: 680, minHeight: 440)
        .onAppear { model.reloadMemory() }
        .sheet(item: $draft) { d in
            NoteEditor(model: model, draft: d) { problem in
                message = problem
                draft = nil
            }
        }
        .confirmationDialog("Alles vergessen?", isPresented: $confirmForgetAll) {
            Button("\(model.memoryItems.count) Einträge vergessen", role: .destructive) { forget(Set(model.memoryItems.map(\.id))) }
        } message: {
            Text("Notizen, Begriffe und Beispiele werden nicht mehr verwendet. Deine Entscheidungen an den Mails bleiben; eine neue Entscheidung wird wieder ein Beispiel.")
        }
    }

    private func forget(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        Task {
            message = await model.forgetMemory(Array(ids))
            selection.subtract(ids)
        }
    }

    static func subjectLabel(_ item: MemoryItem) -> String {
        var parts: [String] = []
        if let range = item.subject.range(of: ":") {
            let value = String(item.subject[range.upperBound...])
            switch item.subject[..<range.lowerBound] {
            case "sender": parts.append(value)
            case "domain": parts.append(String(localized: "Domain \(value)"))
            case "list": parts.append(String(localized: "Liste \(value)"))
            default: parts.append(item.subject)
            }
        } else if !item.subject.isEmpty {
            parts.append(item.subject)
        }
        if !item.scope.isEmpty { parts.append(String(localized: "Konto \(item.scope)")) }
        return parts.isEmpty ? String(localized: "allgemein") : parts.joined(separator: " · ")
    }
}

struct NoteDraft: Identifiable {
    var id: String
    var existing: Bool
    var kind: MemoryKind
    var text = ""
    var about = About.general
    var value = ""
    var scope = ""

    enum About: String, CaseIterable, Identifiable {
        case general, sender, domain, list
        var id: String { rawValue }
        var label: String {
            switch self {
            case .general: String(localized: "allgemein")
            case .sender: String(localized: "Absender")
            case .domain: String(localized: "Domain")
            case .list: String(localized: "Liste")
            }
        }
    }

    init(kind: MemoryKind) {
        id = Memory.newID()
        existing = false
        self.kind = kind
    }

    init(_ item: MemoryItem) {
        id = item.id
        existing = true
        kind = item.kind
        text = item.content.text ?? ""
        scope = item.scope
        if let range = item.subject.range(of: ":"), let about = About(rawValue: String(item.subject[..<range.lowerBound])) {
            self.about = about
            value = String(item.subject[range.upperBound...])
        }
    }

    var subject: String {
        let v = value.trimmingCharacters(in: .whitespaces).lowercased()
        return about == .general || v.isEmpty ? "" : "\(about.rawValue):\(v)"
    }
}

private struct NoteEditor: View {
    let model: AppModel
    @State var draft: NoteDraft
    let done: (String?) -> Void
    @State private var saving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.kind == .vocabulary ? "Begriff" : "Notiz").font(.headline)
            TextEditor(text: $draft.text)
                .font(.body)
                .frame(minHeight: 90)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            Text("\(draft.text.count) von \(Memory.maxText) Zeichen").font(.caption)
                .foregroundStyle(draft.text.count > Memory.maxText ? .red : .secondary)
            Picker("Bezug", selection: $draft.about) {
                ForEach(NoteDraft.About.allCases) { Text($0.label).tag($0) }
            }
            if draft.about != .general {
                TextField(draft.about == .sender ? "max@beispiel.de" : draft.about == .domain ? "beispiel.de" : "List-Id", text: $draft.value)
            }
            Picker("Konto", selection: $draft.scope) {
                Text("alle Konten").tag("")
                ForEach(model.accountConfigs.map(\.id), id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Spacer()
                Button("Abbrechen") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Sichern") {
                    saving = true
                    Task {
                        let problem = await model.saveNote(id: draft.existing ? draft.id : nil, kind: draft.kind, text: draft.text,
                                                           subject: draft.subject, scope: draft.scope)
                        saving = false
                        done(problem)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(saving || draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.text.count > Memory.maxText)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

/// "Warum?" at a model's category (6.2): what it saw from the memory, each with "Vergessen".
struct WhyPopover: View {
    let lines: [AppModel.WhyLine]
    let forget: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Was die KI aus dem Gedächtnis gesehen hat").font(.headline)
            if lines.isEmpty {
                Text("Nichts – eingeordnet nur nach der Mail selbst (oder vor dem Gedächtnis).").foregroundStyle(.secondary)
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(DisplayText.safe(line.title)).fontWeight(.semibold)
                        ForEach(Array(line.detail.enumerated()), id: \.offset) { _, d in
                            Text(DisplayText.safe(d)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    if line.forgettable {
                        Button("Vergessen") { forget(line.id) }.controlSize(.small)
                            .help("Nicht mehr verwenden – die Entscheidung an der Mail selbst bleibt")
                    }
                }
            }
            Text("Alles ansehen und bearbeiten: Einstellungen › Gedächtnis").font(.caption).foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(14)
        .frame(width: 420)
    }
}
