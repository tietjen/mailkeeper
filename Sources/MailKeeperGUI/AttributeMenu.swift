import AppKit
import MailKeeperKit
import SwiftUI

/// A mail attribute in the reader (sender, recipient, date, folder, list) that opens filters:
/// show all such mails, add to the search, or exclude. Dotted underline = clickable.
struct AttributeMenu: View {
    let model: AppModel
    let text: String
    let options: [FilterOption]
    var copy: String?
    /// e.g. server or archive for a folder.
    var systemImage: String?
    /// Actions beside the filters (the folder: "Ablage ändern …", 6.9).
    var actions: [AttributeAction] = []

    var body: some View {
        Menu {
            AttributeMenuItems(model: model, options: options, copy: copy)
            if !actions.isEmpty {
                Divider()
                ForEach(actions) { a in Button(a.title, action: a.action) }
            }
        } label: {
            HStack(spacing: 3) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(.secondary).font(.caption) }
                Text(DisplayText.safe(text))
                    .underline(true, pattern: .dot, color: .secondary)
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Klicken: nach diesem Merkmal filtern")
    }
}

struct AttributeAction: Identifiable {
    var id: String { title }
    var title: String
    var action: () -> Void
}

struct AttributeMenuItems: View {
    let model: AppModel
    let options: [FilterOption]
    var copy: String?

    var body: some View {
        if !options.isEmpty {
            Section("Alle Mails mit …") {
                ForEach(options) { o in Button(DisplayText.safe(o.title)) { model.apply(o, .show) } }
            }
            Menu("Zur Suche hinzufügen") {
                ForEach(options) { o in Button(DisplayText.safe(o.title)) { model.apply(o, .add) } }
            }
            Menu("Ausschließen") {
                ForEach(options) { o in Button(DisplayText.safe(o.title)) { model.apply(o, .exclude) } }
            }
        }
        if let copy {
            Divider()
            Button("Kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy, forType: .string)
            }
        }
    }
}

/// Editing one term of the search (TJ: "sender:no-reply@finom.me" → delete the prefix →
/// "sender:@finom.me", the whole domain). Checked live; an invalid term cannot be applied.
struct ChipEditor: View {
    let model: AppModel
    let chip: QueryChip
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel, chip: QueryChip) {
        self.model = model
        self.chip = chip
        _text = State(initialValue: chip.text)
    }

    private var problem: String? {
        do throws(QueryError) {
            return try QueryParser.parse(text + " ").root == nil ? String(localized: "Der Begriff ist leer.") : nil
        } catch {
            return error.message
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Begriff", text: $text)
                .font(.body.monospaced())
                .frame(minWidth: 320)
                .onSubmit { apply() }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            } else if let label = try? QueryParser.parse(text + " ").chips.map(\.label).joined(separator: ", ") {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Entfernen", role: .destructive) { model.removeChip(chip); dismiss() }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Übernehmen") { apply() }.keyboardShortcut(.defaultAction).disabled(problem != nil)
            }
        }
        .padding(12)
    }

    private func apply() {
        guard problem == nil else { return }
        model.replaceChip(chip, with: text)
        dismiss()
    }
}
