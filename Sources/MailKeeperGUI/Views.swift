import MailKeeperKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            Sidebar(model: model)
                .frame(minWidth: 190)  // hard floor: narrower, the list shows only the counts
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
        } content: {
            MessageTable(model: model)
                .navigationSplitViewColumnWidth(min: 420, ideal: 640)
                .overlay {
                    if let error = model.openError {
                        ContentUnavailableView {
                            Label("Archiv nicht geöffnet", systemImage: "archivebox")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Archiv wählen …") { model.chooseArchive() }
                        }
                    } else if let error = model.listError {
                        ContentUnavailableView {
                            Label("Index nicht lesbar", systemImage: "exclamationmark.triangle")
                        } description: {
                            Text(error)
                        } actions: {
                            Button("Erneut versuchen") { model.refresh() }
                        }
                    } else if model.messageIDs.isEmpty {
                        ContentUnavailableView(model.searchText.isEmpty ? "Keine Nachrichten" : "Keine Treffer",
                                               systemImage: model.searchText.isEmpty ? "tray" : "magnifyingglass")
                    }
                }
        } detail: {
            if let id = model.selectedMessageID {
                ReaderView(model: model, messageID: id)
            } else {
                ContentUnavailableView("Keine Nachricht ausgewählt", systemImage: "envelope")
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Archiv durchsuchen")
        .toolbar {
            ToolbarItem {
                Menu {
                    ForEach(ImportKind.allCases) { kind in
                        Button(kind.title) { model.startImport(kind) }
                    }
                } label: {
                    Label("Importieren", systemImage: "square.and.arrow.down")
                }
                .help("Mails aus Maildir, mbox oder .eml-Dateien ins Archiv übernehmen")
            }
        }
        .safeAreaInset(edge: .bottom) { StatusBar(model: model) }
        .sheet(isPresented: Binding(get: { model.importStatus != nil }, set: { if !$0 { model.dismissImportStatus() } })) {
            if let status = model.importStatus { ImportSheet(model: model, status: status) }
        }
    }
}

struct Sidebar: View {
    @Bindable var model: AppModel

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Label("Alle Nachrichten", systemImage: "tray.full")
                .badge(model.stats?.messages ?? 0)
                .tag(SidebarItem.all)
            ForEach(model.accounts, id: \.id) { account in
                Section(account.name) {
                    ForEach(account.mailboxes, id: \.self) { box in
                        Label(box.name, systemImage: icon(for: box.name))
                            .badge(box.count)
                            .tag(SidebarItem.mailbox(account: account.id, name: box.name))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func icon(for name: String) -> String {
        switch name.lowercased() {
        case "inbox", "posteingang": "tray"
        case let n where n.contains("sent") || n.contains("gesendet"): "paperplane"
        case let n where n.contains("trash") || n.contains("papierkorb"): "trash"
        case let n where n.contains("spam") || n.contains("junk"): "xmark.bin"
        case let n where n.contains("draft") || n.contains("entw"): "doc"
        case let n where n.contains("archiv"): "archivebox"
        default: "folder"
        }
    }
}

struct ReaderView: View {
    let model: AppModel
    let messageID: Int64
    @State private var loaded: (id: Int64, detail: MessageDetail, message: ParsedMessage)?
    @State private var failed = false

    var body: some View {
        Group {
            if let loaded, loaded.id == messageID {
                content(loaded.detail, loaded.message)
            } else if failed {
                ContentUnavailableView("Nachricht nicht lesbar", systemImage: "exclamationmark.triangle")
            } else {
                ProgressView()
            }
        }
        .task(id: messageID) {
            failed = false
            guard let detail = model.detail(messageID), let message = await model.parse(detail) else {
                failed = true
                return
            }
            if !Task.isCancelled { loaded = (messageID, detail, message) }
        }
    }

    @ViewBuilder
    private func content(_ detail: MessageDetail, _ message: ParsedMessage) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                header(detail, message)
                    .padding(12)
                Divider()
                if let html = message.html, let rules = ContentRules.shared.list {
                    MessageWebView(html: html, message: message, rules: rules)
                } else {
                    ScrollView {
                        Text(message.text)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                    }
                }
            }
    }

    @ViewBuilder
    private func header(_ d: MessageDetail, _ m: ParsedMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.subject?.isEmpty == false ? DisplayText.safe(m.subject!) : String(localized: "(kein Betreff)"))
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            row("Von", m.from.map(\.display).joined(separator: ", "))
            if !m.to.isEmpty { row("An", m.to.map(\.display).joined(separator: ", ")) }
            if !m.cc.isEmpty { row("Kopie", m.cc.map(\.display).joined(separator: ", ")) }
            if let date = m.date { row("Datum", date.formatted(date: .long, time: .shortened)) }
            row("Ablage", d.locations.map { "\($0.account) › \($0.mailbox)" }.joined(separator: " · "))
            let files = m.attachments.filter { !$0.isInline }
            if !files.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Anhänge").foregroundStyle(.secondary).frame(width: 64, alignment: .trailing).font(.callout)
                    AttachmentBar(message: m, attachments: files)
                }
                .padding(.top, 2)
            }
            if m.html != nil {
                Label("Externe Inhalte sind blockiert", systemImage: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Text(DisplayText.safe(value)).textSelection(.enabled).lineLimit(3)
        }
        .font(.callout)
    }
}

struct StatusBar: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if let stats = model.stats {
                Text("\(model.messageIDs.count) von \(stats.messages) Nachrichten")
                Text(ByteCountFormatter.string(fromByteCount: stats.blobBytes, countStyle: .file))
            }
            if model.volumeEncrypted == false {
                Label("Archiv-Volume ist nicht verschlüsselt", systemImage: "lock.open")
                    .foregroundStyle(.orange)
                    .help("Mails liegen unverschlüsselt als .eml im Archiv. Nutze FileVault oder ein verschlüsseltes Volume.")
            }
            Spacer()
            if let root = model.archiveRoot {
                Text(root.path(percentEncoded: false))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

struct ImportSheet: View {
    let model: AppModel
    let status: ImportStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(status.title).font(.headline)
            if !status.finished { ProgressView().progressViewStyle(.linear) }
            let p = status.progress
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow { Text("Nachrichten"); Text("\(p.messages)") }
                GridRow { Text("Neu"); Text("\(p.newMessages)") }
                GridRow { Text("Weitere Ablageorte"); Text("\(p.newLocations)") }
                GridRow { Text("Schon im Archiv"); Text("\(p.unchanged)") }
                GridRow { Text("Fehlgeschlagen"); Text("\(p.failed)") }
                GridRow { Text("Datenmenge"); Text(ByteCountFormatter.string(fromByteCount: p.bytes, countStyle: .file)) }
            }
            .font(.callout.monospacedDigit())
            if let error = status.error ?? p.lastError {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button(status.finished ? "Fertig" : "Im Hintergrund") { model.dismissImportStatus() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
