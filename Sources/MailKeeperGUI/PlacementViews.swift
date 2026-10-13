import MailKeeperKit
import SwiftUI

/// The mails "Ablage ändern" is for (6.9).
struct PlacementRequest: Identifiable {
    var id = UUID()
    var ids: [Int64]
}

extension AppModel {
    func askPlacement(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        placing = PlacementRequest(ids: ids)
    }

    /// The accounts the mails lie in, and the folders the archive knows there (INBOX first).
    func placementFolders(_ ids: [Int64]) -> (accounts: [String], folders: [String]) {
        let mine = Set(ids.prefix(500).flatMap { (try? reader?.detail($0))??.locations.map(\.account) ?? [] })
        let names = accounts.filter { mine.contains($0.id) }.flatMap { $0.mailboxes.map(\.name) }
        let folders = Array(Set(names)).sorted { a, b in
            a.uppercased() == "INBOX" ? b.uppercased() != "INBOX" : b.uppercased() == "INBOX" ? false : a.localizedStandardCompare(b) == .orderedAscending
        }
        return (mine.sorted(), folders)
    }

    /// Files the mails in the archive (journalled); nil: back where they were seen.
    func place(_ ids: [Int64], mailbox: String?) async -> String? {
        guard let reader else { return nil }
        let identities = (try? reader.identities(of: ids)) ?? []
        let problem = await writeNow { writer in _ = try await writer.place(identities: identities, mailbox: mailbox) }
        guard problem == nil else { return problem }
        refresh()  // the sidebar's counts, the list and the reader
        return nil
    }
}

/// "Ablage ändern" (6.9, ADR-0011): where the archive files the mails — a folder it knows or a
/// new one, or back where they were seen. The server is not touched here (6.9b).
struct PlacementSheet: View {
    let model: AppModel
    let request: PlacementRequest
    @Environment(\.dismiss) private var dismiss
    @State private var choice = ""
    @State private var newName = ""
    @State private var folders: [String] = []
    @State private var accounts: [String] = []
    @State private var problem: String?
    @State private var saving = false
    private static let new = "\u{1}new"

    private var target: String? {
        let name = choice == Self.new ? newName.trimmingCharacters(in: .whitespacesAndNewlines) : choice
        return name.isEmpty ? nil : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.ids.count == 1 ? "Ablage ändern" : "Ablage von \(request.ids.count) Mails ändern").font(.title3.weight(.semibold))
            Text("Wo das Archiv die Mail ablegt – unabhängig vom Server. Die Ablage auf dem Server steht unter „Ort“ und ändert sich hier nicht.")
                .font(.callout).foregroundStyle(.secondary).frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Form {
                Picker("Neue Ablage", selection: $choice) {
                    ForEach(folders, id: \.self) { Text(DisplayText.safe($0)).tag($0) }
                    Divider()
                    Text("Neuer Ordner …").tag(Self.new)
                }
                if choice == Self.new {
                    TextField("Name", text: $newName, prompt: Text("z. B. Newsletter oder Archiv/2026"))
                }
                if accounts.count > 1 {
                    Text("Gilt in jedem Konto, in dem die Mail liegt: \(accounts.map(DisplayText.safe).joined(separator: ", ")).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let problem { Text(DisplayText.safe(problem)).font(.callout).foregroundStyle(.red) }
            HStack {
                Button("Zurück, wo abgerufen bzw. importiert") { save(nil) }
                    .help("Die eigene Ablage im Archiv aufheben: die Mail liegt wieder dort, wo MailKeeper sie gefunden hat")
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Ablegen") { save(target) }.keyboardShortcut(.defaultAction).disabled(target == nil || saving)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear {
            let found = model.placementFolders(request.ids)
            accounts = found.accounts
            folders = found.folders
            choice = folders.first ?? Self.new
        }
    }

    private func save(_ mailbox: String?) {
        saving = true
        Task {
            problem = await model.place(request.ids, mailbox: mailbox)
            saving = false
            if problem == nil { dismiss() }
        }
    }
}
