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

    /// What the sheet offers (6.9): the accounts the mails lie in and the folders the archive
    /// knows there (INBOX first), the folder they share now; how many lie on a server MailKeeper
    /// may change here (not Gmail, accounts set up) and that server's ordinary folders (6.9b).
    func placementSetup(_ ids: [Int64]) -> PlacementSetup {
        guard let reader, let context = try? reader.placementContext(ids) else { return PlacementSetup() }
        var setup = PlacementSetup()
        setup.accounts = context.accounts.sorted()
        setup.folders = Self.inboxFirst(Set(accounts.filter { context.accounts.contains($0.id) }.flatMap { $0.mailboxes.map(\.name) }))
        setup.current = context.filed.count == 1 ? context.filed.first : nil
        let usable = Set(accountConfigs.filter { $0.kind != .gmail }.map(\.id)).intersection(context.onServer.keys)
        setup.onServer = usable.reduce(into: Set<Int64>()) { $0.formUnion(context.onServer[$1] ?? []) }.count
        setup.serverFolders = Self.inboxFirst(Set(usable.flatMap { (try? reader.ordinaryMailboxes(account: $0)) ?? [] }))
        return setup
    }

    private static func inboxFirst(_ names: Set<String>) -> [String] {
        names.sorted { a, b in
            a.uppercased() == "INBOX" ? b.uppercased() != "INBOX" : b.uppercased() == "INBOX" ? false : a.localizedStandardCompare(b) == .orderedAscending
        }
    }

    /// Files the mails in the archive (journalled); nil: back where they were seen. A problem
    /// there comes back (the sheet stays). Then the sheet closes and, when asked, the server
    /// follows — the sheet showed what and where: it runs at once, checked and logged like every
    /// server action (ADR-0006); what becomes of it there is said on its own (review 6.9 S4).
    func place(_ ids: [Int64], mailbox: String?, server: ServerPlacement = .keep) async -> String? {
        guard let reader else { return nil }
        let identities = (try? reader.identities(of: ids)) ?? []
        if let problem = await writeNow({ writer in _ = try await writer.place(identities: identities, mailbox: mailbox) }) {
            return problem  // writeNow refreshed the sidebar, the list and the reader
        }
        placing = nil
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
                let why = job.reasons.map(\.reason).joined(separator: "; ")
                actionError = why.isEmpty ? String(localized: "Im Archiv abgelegt. Auf dem Server ist nichts zu tun.")
                    : String(localized: "Im Archiv abgelegt. Auf dem Server nichts zu tun: \(why)")
                return nil
            }
            // a busy app says so itself (execute sets actionError): the archive part stays done
            execute(PlannedAction(job: job, summary: summary, filter: MessageFilter(ids: ids), examples: try reader.summaries(Array(ids.prefix(5)))))
        } catch {
            actionError = String(localized: "Im Archiv abgelegt, auf dem Server nicht: \(String(describing: error))")
        }
        return nil
    }
}

/// What the placement sheet offers (see `AppModel.placementSetup`).
struct PlacementSetup {
    var accounts: [String] = []
    var folders: [String] = []
    /// The archive folder all the mails are filed in now, if they share one (preselected).
    var current: String?
    var onServer = 0
    var serverFolders: [String] = []
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
            let setup = model.placementSetup(request.ids)
            accounts = setup.accounts
            folders = setup.folders
            choice = setup.current.flatMap { folders.contains($0) ? $0 : nil } ?? folders.first ?? Self.new
            onServer = setup.onServer
            serverFolders = setup.serverFolders
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
