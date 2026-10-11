import MailKeeperKit
import SwiftUI

/// Above the list: the parsed search terms as chips (× removes one), hit count, "save".
struct QueryBar: View {
    let model: AppModel
    @State private var saving: SavedSearch?
    @State private var editing: Int?

    var body: some View {
        if let chips = model.query?.chips, !chips.isEmpty {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(chips.enumerated()), id: \.offset) { index, chip in
                            HStack(spacing: 4) {
                                Button { editing = index } label: { Text(DisplayText.safe(chip.label)).lineLimit(1) }
                                    .buttonStyle(.plain)
                                    .help("Klicken zum Bearbeiten: \(chip.text)")
                                    .popover(isPresented: Binding(get: { editing == index }, set: { if !$0 { editing = nil } })) {
                                        ChipEditor(model: model, chip: chip)
                                    }
                                Button { model.removeChip(chip) } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                                .help("Begriff entfernen")
                            }
                            .font(.callout)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(.quaternary))
                        }
                    }
                }
                Text("\(model.messageIDs.count.formatted()) Treffer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button("Sichern …") { saving = SavedSearch(name: "", query: model.queryForSaving()) }
                    .controlSize(.small)
                    .help("Diese Suche als Ansicht in der Seitenleiste ablegen")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)
            .sheet(item: $saving) { SavedSearchSheet(model: model, search: $0) }
        }
    }
}

/// Toolbar menu: insert common filters, open the syntax help.
struct FilterMenu: View {
    let model: AppModel
    @State private var help = false

    private let filters: [(String, String)] = [
        ("Mit Anhang", "has:attachment"), ("Mit PDF", "has:pdf"), ("Ungelesen", "is:unread"),
        ("Markiert", "is:flagged"), ("Newsletter und Listen", "is:list"), ("Größer als 5 MB", "larger:5M"),
        ("Letzte 30 Tage", "after:30d"), ("Älter als ein Jahr", "before:1y"), ("Nur noch im Archiv", "only:archive"),
    ]

    var body: some View {
        Menu {
            Section("Zur Suche hinzufügen") {
                ForEach(filters, id: \.1) { title, term in
                    Button(title) { model.appendFilter(term) }
                }
            }
            Divider()
            Button("Suchsprache …") { help = true }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .help("Filter zur Suche hinzufügen")
        .sheet(isPresented: $help) { QueryHelp() }
    }
}

struct QueryHelp: View {
    @Environment(\.dismiss) private var dismiss

    private let rows: [(String, String)] = [
        ("rechnung \"jahres abrechnung\"", "alle Wörter und Phrasen; das letzte Wort auch als Anfang"),
        ("from:amazon  to:  subject:  body:", "Wörter in einem Feld (Absender: Name oder Adresse)"),
        ("sender:billing@amazon.de", "exakte Absenderadresse"),
        ("has:attachment  has:pdf  has:image  has:calendar", "Anhänge"),
        ("filename:vertrag", "Name eines Anhangs"),
        ("larger:5M  smaller:100K", "Größe"),
        ("after:2024-03  before:2025  until:2024-12-31", "ab (einschließlich), vor, bis einschließlich"),
        ("date:2024-05  after:30d  before:1y", "Zeitraum; relativ: d, w, m, y"),
        ("account:gmail  folder:INBOX  folder:Archiv/*", "Konto, Ordner (mit Unterordnern)"),
        ("label:Steuer  list:newsletter.example", "Label, Mailingliste"),
        ("is:unread  is:flagged  is:answered  is:list", "Status"),
        ("on:server  only:archive", "noch auf dem Server / nur noch im Archiv"),
        ("-wort  -from:x", "ausschließen"),
        ("a OR b  ( … )", "oder, Klammern"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Suchsprache").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(rows, id: \.0) { example, meaning in
                    GridRow {
                        Text(example).font(.callout.monospaced()).textSelection(.enabled)
                        Text(meaning).font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Deutsch geht auch: von: an: betreff: hat: ist: ab: vor: bis: datum: konto: ordner: größer: kleiner:")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

/// Create or edit a saved search; the query is checked live.
struct SavedSearchSheet: View {
    let model: AppModel
    @State private var search: SavedSearch
    @State private var error: String?
    /// Counted after typing pauses, not on every keystroke (a full-text count per key).
    @State private var count: Int?
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, search: SavedSearch) {
        self.model = model
        _search = State(initialValue: search)
    }

    private var isNew: Bool { !model.savedSearches.contains { $0.id == search.id } }

    private var parseError: String? {
        do throws(QueryError) {
            return try QueryParser.parse(search.query).root == nil ? String(localized: "Die Suche ist leer.") : nil
        } catch {
            return error.message
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "Suche sichern" : "Ansicht bearbeiten").font(.headline)
            Form {
                TextField("Name", text: $search.name, prompt: Text("z. B. Rechnungen 2024"))
                TextField("Suche", text: $search.query, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(2...5)
            }
            if let message = parseError ?? error {
                Text(message).font(.caption).foregroundStyle(.red)
            } else if let n = count {
                Text("\(n.formatted()) Nachrichten").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Sichern") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(search.name.trimmingCharacters(in: .whitespaces).isEmpty || parseError != nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task(id: search.query) {
            count = nil
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, parseError == nil else { return }
            count = model.count(query: search.query)
        }
    }

    private func save() {
        let new = isNew
        do {
            try model.putSavedSearch(search)
            if new { model.showSaved(search.id) }
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}

/// Back and forward like Safari: a click goes one step, holding (or the arrow) lists the
/// stations in that direction.
struct HistoryButtons: View {
    let model: AppModel

    var body: some View {
        let entries = model.history.entries
        let index = model.history.index
        Menu {
            ForEach(Array((0..<max(0, index)).reversed()), id: \.self) { i in
                Button(entries[i].label) { model.restore(i) }
            }
        } label: {
            Label("Zurück", systemImage: "chevron.left")
        } primaryAction: {
            model.goBack()
        }
        .disabled(!model.canGoBack)
        .help("Zurück (⌘[) – gedrückt halten zeigt den Verlauf")
        Menu {
            ForEach(Array(entries.indices.filter { $0 > index }), id: \.self) { i in
                Button(entries[i].label) { model.restore(i) }
            }
        } label: {
            Label("Vorwärts", systemImage: "chevron.right")
        } primaryAction: {
            model.goForward()
        }
        .disabled(!model.canGoForward)
        .help("Vorwärts (⌘])")
    }
}

/// Menu bar: Verlauf › Zurück, Vorwärts and the most recent stations.
struct HistoryCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Verlauf") {
            Button("Zurück") { model.goBack() }
                .keyboardShortcut("[")
                .disabled(!model.canGoBack)
            Button("Vorwärts") { model.goForward() }
                .keyboardShortcut("]")
                .disabled(!model.canGoForward)
            Divider()
            let entries = model.history.entries
            ForEach(Array(entries.indices.suffix(15).reversed()), id: \.self) { i in
                Button { model.restore(i) } label: {
                    if i == model.history.index {
                        Label(entries[i].label, systemImage: "checkmark")
                    } else {
                        Text(entries[i].label)
                    }
                }
            }
        }
    }
}

/// The archives this app knows, the current one checked; open another, create a new one.
struct ArchiveMenuItems: View {
    let model: AppModel

    var body: some View {
        ForEach(model.knownArchives) { archive in
            Button {
                model.switchTo(archive)
            } label: {
                let title = "\(model.archiveName(archive.path)) — \(model.abbreviated(archive.path))"
                if archive.path == model.archiveRoot?.path {
                    Label(title, systemImage: "checkmark")
                } else {
                    Text(title)
                }
            }
        }
        Divider()
        Button("Anderes Archiv öffnen …") { model.openArchive() }
        Button("Neues Archiv anlegen …") { model.createArchive() }
        let others = model.knownArchives.filter { $0.path != model.archiveRoot?.path }
        if !others.isEmpty {
            Divider()
            Menu("Aus der Liste entfernen") {
                ForEach(others) { archive in
                    Button("\(model.archiveName(archive.path)) — \(model.abbreviated(archive.path))") { model.forget(archive) }
                }
            }
        }
    }
}
