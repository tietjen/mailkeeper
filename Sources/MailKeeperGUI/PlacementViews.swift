import MailKeeperKit
import SwiftUI

/// The mails "Ablage ändern" is for (6.9).
struct PlacementRequest: Identifiable {
    var id = UUID()
    var ids: [Int64]
}

/// What "Ablage ändern" does on the server (6.9b, TJ).
enum ServerPlacement: Hashable {
    case keep
    /// The same folder as in the archive (only where it exists — none is created).
    case same
    case other(String)
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

    /// How many of the mails lie on a server MailKeeper may change here (not Gmail, accounts set
    /// up), and that server's ordinary folders MailKeeper knows (6.9b).
    func serverPlacementInfo(_ ids: [Int64]) -> (count: Int, folders: [String]) {
        guard let reader else { return (0, []) }
        let usable = Set(accountConfigs.filter { $0.kind != .gmail }.map(\.id))
        var count = 0
        var accounts: Set<String> = []
        for id in ids.prefix(500) {
            guard let d = try? reader.detail(id) else { continue }
            let here = d.locations.filter { $0.isOnServer && usable.contains($0.account) }.map(\.account)
            if !here.isEmpty { count += 1; accounts.formUnion(here) }
        }
        let folders = Set(accounts.flatMap { (try? reader.ordinaryMailboxes(account: $0)) ?? [] })
        return (count, folders.sorted { a, b in a.uppercased() == "INBOX" || (b.uppercased() != "INBOX" && a.localizedStandardCompare(b) == .orderedAscending) })
    }

    /// Files the mails in the archive (journalled); nil: back where they were seen. Then, when
    /// asked, on the server too — the sheet showed what and where: it runs at once, checked
    /// and logged like every server action (ADR-0006).
    func place(_ ids: [Int64], mailbox: String?, server: ServerPlacement = .keep) async -> String? {
        guard let reader else { return nil }
        let identities = (try? reader.identities(of: ids)) ?? []
        let problem = await writeNow { writer in _ = try await writer.place(identities: identities, mailbox: mailbox) }
        guard problem == nil else { return problem }
        refresh()  // the sidebar's counts, the list and the reader
        let onServer: String? = switch server {
        case .keep: nil
        case .same: mailbox
        case .other(let name): name
        }
        guard let target = onServer else { return nil }
        do {
            let (job, summary) = try reader.planMoveToFolder(MessageFilter(ids: ids), mailbox: target,
                                                             title: String(localized: "Ablage „\(target)“"), accounts: accountConfigs)
            guard job.count(.planned) > 0 else {
                return job.reasons.first.map { String(localized: "Im Archiv abgelegt; auf dem Server nichts zu tun: \($0.reason)") }
            }
            execute(PlannedAction(job: job, summary: summary, filter: MessageFilter(ids: ids), examples: try reader.summaries(Array(ids.prefix(5)))))
        } catch {
            return "\(error)"
        }
        return nil
    }
}

/// "Ablage ändern" (6.9, ADR-0011): where the archive files the mails — a folder it knows or a
/// new one, or back where they were seen; on the server the same folder, another, or no change (6.9b).
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
    @State private var onServer = 0
    @State private var serverFolders: [String] = []
    @State private var server = ServerChoice.keep
    @State private var otherFolder = ""
    private static let new = "\u{1}new"

    enum ServerChoice: Hashable { case keep, same, other }

    private var serverPlacement: ServerPlacement {
        switch server {
        case .keep: .keep
        case .same: .same
        case .other: otherFolder.isEmpty ? .keep : .other(otherFolder)
        }
    }

    private var target: String? {
        let name = choice == Self.new ? newName.trimmingCharacters(in: .whitespacesAndNewlines) : choice
        return name.isEmpty ? nil : name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.ids.count == 1 ? "Ablage ändern" : "Ablage von \(request.ids.count) Mails ändern").font(.title3.weight(.semibold))
            Text("Wo das Archiv die Mail ablegt – unabhängig vom Server. Die Ablage auf dem Server steht unter „Ort“; ob sie mitwandert, entscheidest du unten.")
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
                if onServer > 0 {  // 6.9b: TJ's three choices
                    Section(onServer == 1 ? "Auf dem Server" : "Auf dem Server (\(onServer) Mails)") {
                        Picker("Server", selection: $server) {
                            Text("Nicht ändern").tag(ServerChoice.keep)
                            if let target { Text("Ebenso nach „\(DisplayText.safe(target))“").tag(ServerChoice.same) }
                            if !serverFolders.isEmpty { Text("In einen anderen Ordner …").tag(ServerChoice.other) }
                        }
                        if server == .other {
                            Picker("Ordner", selection: $otherFolder) {
                                ForEach(serverFolders, id: \.self) { Text(DisplayText.safe($0)).tag($0) }
                            }
                        }
                        Text("Auf dem Server legt MailKeeper keine Ordner an: fehlt der Ordner dort, bleibt die Mail, wo sie ist. Aus dem Spam-Ordner heraus lernt der Spam-Filter des Servers „erwünscht“.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
            let info = model.serverPlacementInfo(request.ids)
            onServer = info.count
            serverFolders = info.folders
            otherFolder = serverFolders.first ?? ""
        }
    }

    private func save(_ mailbox: String?) {
        saving = true
        Task {
            problem = await model.place(request.ids, mailbox: mailbox, server: mailbox == nil ? .keep : serverPlacement)
            saving = false
            if problem == nil { dismiss() }
        }
    }
}
