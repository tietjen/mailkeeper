import MailKeeperKit
import SwiftUI

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                Sidebar(model: model)
                    .frame(minWidth: 190)  // hard floor: narrower, the list shows only the counts
                    .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 400)
            } content: {
                Group {
                    if model.viewMode == .messages {
                        MessageTable(model: model)
                    } else {
                        GroupTable(model: model)
                    }
                }
                    .navigationSplitViewColumnWidth(min: 420, ideal: 640)
                    .overlay {
                        if model.preparingArchive {
                            ContentUnavailableView {
                                ProgressView()
                            } description: {
                                Text("Das Archiv wird für diese Version vorbereitet (Konversationen, Suche) …")
                            }
                        } else if let error = model.openError {
                            ContentUnavailableView {
                                Label("Archiv nicht geöffnet", systemImage: "archivebox")
                            } description: {
                                Text(error)
                            } actions: {
                                Button("Archiv öffnen …") { model.openArchive() }
                            if model.knownArchives.count > 1 {
                                Menu("Archiv wechseln") { ArchiveMenuItems(model: model) }.fixedSize()
                            }
                            }
                        } else if let error = model.listError {
                            ContentUnavailableView {
                                Label("Index nicht lesbar", systemImage: "exclamationmark.triangle")
                            } description: {
                                Text(error)
                            } actions: {
                                Button("Erneut versuchen") { model.refresh() }
                            }
                        } else if let error = model.queryError {
                            ContentUnavailableView {
                                Label("Suche unvollständig", systemImage: "exclamationmark.magnifyingglass")
                            } description: {
                                Text(error)
                            }
                        } else if model.viewMode != .messages ? model.groups.isEmpty : model.messageIDs.isEmpty {
                            let searching = !model.searchText.allSatisfy(\.isWhitespace)
                            ContentUnavailableView {
                                Label(searching ? "Keine Treffer" : (model.viewMode == .messages ? "Keine Nachrichten" : "Nichts zum Aufräumen"),
                                      systemImage: searching ? "magnifyingglass" : (model.viewMode == .messages ? "tray" : "sparkles"))
                            } description: {
                                if searching {
                                    VStack(spacing: 10) {
                                        Text("Die Suche lässt hier nichts übrig. Alle Begriffe müssen zutreffen.")
                                        if !model.archiveKnowsServers {
                                            Text("„Auf dem Server“ trifft in diesem Archiv nie zu: Es enthält nur importierte Mails (Maildir, mbox, .eml), und für die kennt MailKeeper keinen Server-Ort. Den gibt es erst für Mails, die ein Konto abgerufen hat (Einstellungen › Konten).")
                                                .foregroundStyle(.orange)
                                        }
                                        if !model.emptyHints.isEmpty {
                                            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                                                ForEach(model.emptyHints) { hint in
                                                    GridRow {
                                                        Text("Ohne „\(DisplayText.safe(hint.chip.label))“: \(hint.count.formatted()) Treffer")
                                                        Button("Entfernen") { model.removeChip(hint.chip) }.controlSize(.small)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            } actions: {
                                if searching { Button("Suche zurücksetzen") { model.setSearch("") } }
                            }
                        }
                    }
                    .safeAreaInset(edge: .top, spacing: 0) {
                        VStack(spacing: 0) {
                            if model.sidebarSelection == .trash { TrashBar(model: model) }
                            if model.sidebarSelection == .spamReview { SpamReviewBar(model: model) }
                            TranslationNoteBar(model: model)
                            QueryBar(model: model)
                        }
                    }
            } detail: {
                if model.viewMode != .messages {
                    if let detail = model.groupDetail {
                        GroupDetailView(model: model, detail: detail)
                    } else {
                        CleanupOverviewView(model: model)
                    }
                } else if model.actionSelection.count > 1 {
                    SelectionSummaryView(model: model)
                } else if let id = model.selectedMessageID {
                    ReaderView(model: model, messageID: id)
                } else {
                    ContentUnavailableView("Keine Nachricht ausgewählt", systemImage: "envelope")
                }
            }
            StatusBar(model: model)  // below, not an inset: the AppKit table ignores insets (last row was hidden)
        }
        .navigationTitle(model.currentArchiveName)
        .toolbarTitleMenu { ArchiveMenuItems(model: model) }  // click the title: switch archives (TJ)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Suchen, z. B. from:amazon has:pdf")
        .searchSuggestions {
            ForEach(model.suggestions, id: \.completion) { s in
                HStack {
                    Text(s.title).font(.body.monospaced())
                    Spacer()
                    Text(s.detail).foregroundStyle(.secondary)
                }
                .searchCompletion(s.completion)
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                HistoryButtons(model: model)
            }
            ToolbarItem(placement: .principal) {
                Picker("Ansicht", selection: $model.viewMode) {
                    Label("Nachrichten", systemImage: "list.bullet").tag(ViewMode.messages)
                    Label("Absender", systemImage: "person.2").tag(ViewMode.sender)
                    Label("Domains", systemImage: "globe").tag(ViewMode.domain)
                    Label("Listen", systemImage: "newspaper").tag(ViewMode.list)
                }
                .pickerStyle(.segmented)
                .help("Nachrichten einzeln oder zum Aufräumen gruppiert nach Absender, Domain oder Mailingliste")
            }
            ToolbarItem {
                FilterMenu(model: model)
            }
            ToolbarItem {
                TranslateButton(model: model)
            }
            ToolbarItem {
                Button { model.syncAll() } label: {
                    if model.syncRunning { ProgressView().controlSize(.small) } else { Label("Abrufen", systemImage: "arrow.down.circle") }
                }
                .disabled(model.syncRunning || model.importRunning || model.accountConfigs.isEmpty)
                .help(model.accountConfigs.isEmpty ? "Erst ein Konto anlegen: Einstellungen › Konten" : "Neue Mails von allen Konten abrufen (nur lesend)")
            }
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
        .sheet(item: $model.pendingPlan) { PlanSheet(model: model, plan: $0) }
        .sheet(item: $model.actionResult) { ResultSheet(model: model, job: $0) }
        .sheet(item: $model.pendingExport) { ExportSheet(model: model, request: $0) }
        .alert("Export fertig", isPresented: Binding(get: { model.exportResult != nil }, set: { if !$0 { model.exportResult = nil } }),
               presenting: model.exportResult) { report in
            Button("Im Finder zeigen") { model.revealExport(report); model.exportResult = nil }
            Button("OK", role: .cancel) { model.exportResult = nil }
        } message: { report in
            Text("\(report.exported.formatted()) Mails (\(report.bytes.formatted(.byteCount(style: .file)))) nach „\(report.destination.lastPathComponent)“."
                 + report.problems.sorted { $0.key < $1.key }.map { "\n\($0.value.formatted()) nicht exportiert: \($0.key)" }.joined())
        }
        .alert("Aktion", isPresented: Binding(get: { model.actionError != nil }, set: { if !$0 { model.actionError = nil } })) {
            Button("OK") { model.actionError = nil }
        } message: {
            Text(model.actionError ?? "")
        }
        .sheet(isPresented: Binding(get: { model.importStatus != nil }, set: { if !$0 { model.dismissImportStatus() } })) {
            if let status = model.importStatus { ImportSheet(model: model, status: status) }
        }
    }
}

struct Sidebar: View {
    @Bindable var model: AppModel
    @State private var editing: SavedSearch?

    var body: some View {
        List(selection: $model.sidebarSelection) {
            Label("Alle Nachrichten", systemImage: "tray.full")
                .badge(model.stats?.messages ?? 0)
                .tag(SidebarItem.all)
            if !model.savedSearches.isEmpty {
                Section("Ansichten") {
                    ForEach(model.savedSearches) { search in
                        Label(search.name, systemImage: "magnifyingglass.circle")
                            .badge(model.savedCounts[search.id] ?? 0)
                            .help(search.query)
                            .tag(SidebarItem.saved(search.id))
                            .contextMenu {
                                Button("Bearbeiten …") { editing = search }
                                Button("Löschen", role: .destructive) { model.deleteSavedSearch(search.id) }
                            }
                    }
                }
            }
            Section("Archiv") {
                Label("Papierkorb", systemImage: "trash")
                    .badge(model.stats?.trashed ?? 0)
                    .tag(SidebarItem.trash)
                if (model.junkReview?.total ?? 0) > 0 || model.spamAccountsEnabled {
                    Label("Spam-Prüfung", systemImage: "checkmark.shield")
                        .badge(model.junkReview?.notSpam ?? 0)
                        .tag(SidebarItem.spamReview)
                        .help("Mails in den Spam-Ordnern; die Zahl: was die KI nicht für Spam hält")
                }
            }
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
        .sheet(item: $editing) { SavedSearchSheet(model: model, search: $0) }
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
    @State private var loaded: (id: Int64, detail: MessageDetail, message: ParsedMessage, thread: [MessageSummary])?
    @State private var category: Classification?
    @State private var inJunk = false
    @State private var hovered: LinkCheck?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView("Nachricht nicht lesbar", systemImage: "exclamationmark.triangle")
            } else if let loaded {
                // While the next message loads, the previous one stays (dimmed) instead of a
                // spinner: no flicker, and the conversation list keeps its place.
                content(loaded.detail, loaded.message, loaded.thread)
                    .opacity(loaded.id == messageID ? 1 : 0.5)
            } else {
                ProgressView()
            }
        }
        .task(id: "\(messageID)-\(model.contentGeneration)") {
            failed = false
            hovered = nil
            guard let detail = model.detail(messageID), let message = await model.parse(detail) else {
                failed = true
                return
            }
            let thread = detail.summary.threadCount > 1 ? model.thread(of: messageID) : []
            if !Task.isCancelled {
                loaded = (messageID, detail, message, thread)
                category = model.classification(of: messageID)
                inJunk = model.isInJunk(messageID)
            }
        }
    }

    @ViewBuilder
    private func content(_ detail: MessageDetail, _ message: ParsedMessage, _ thread: [MessageSummary]) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                header(detail, message, thread)
                    .padding(12)
                Divider()
                if let html = message.html, let rules = ContentRules.shared.list {
                    MessageWebView(html: html, message: message, rules: rules) { hovered = $0 }
                        .overlay(alignment: .bottomLeading) { if let hovered { LinkTargetBar(link: hovered) } }
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
    private func header(_ d: MessageDetail, _ m: ParsedMessage, _ thread: [MessageSummary]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(m.subject?.isEmpty == false ? DisplayText.safe(m.subject!) : String(localized: "(kein Betreff)"))
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .contextMenu { AttributeMenuItems(model: model, options: MessageFilters.subject(m.subject ?? ""), copy: m.subject) }
            // TJ: click an attribute to filter by it; the filter lands in the bar, editable there.
            filterRow("Von", m.from.map { ($0.display, MessageFilters.sender($0), $0.address, nil) })
            if !m.to.isEmpty { filterRow("An", m.to.map { ($0.display, MessageFilters.recipient($0), $0.address, nil) }) }
            if !m.cc.isEmpty { filterRow("Kopie", m.cc.map { ($0.display, MessageFilters.recipient($0), $0.address, nil) }) }
            if let date = m.date {
                filterRow("Datum", [(date.formatted(date: .long, time: .shortened), MessageFilters.date(date), nil, nil)])
            }
            placeRow(d)
            categoryRow()
            filterRow("Ablage", d.locations.map {
                ("\($0.account) › \($0.mailbox)", MessageFilters.place(account: $0.account, mailbox: $0.mailbox), nil,
                 $0.isOnServer ? "server.rack" : "archivebox")
            })
            if let list = d.listID { filterRow("Liste", [(list, MessageFilters.list(list), list, nil)]) }
            if thread.count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Verlauf").foregroundStyle(.secondary).frame(width: 64, alignment: .trailing).font(.callout)
                    ConversationList(model: model, current: d.summary.id, thread: thread)
                }
            }
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

    /// What kind of mail (5.4) and who said so: a rule, the endpoint's model or the one on this Mac.
    @ViewBuilder
    private func categoryRow() -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Art").foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            if let c = category?.category {
                Button {
                    model.appendFilter("kategorie:\(c.queryWord)")
                } label: {
                    Label(c.label, systemImage: c.icon)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.purple.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Alle Mails dieser Art zeigen")
                Text(DisplayText.safe(categorySource)).foregroundStyle(.secondary).lineLimit(2)
                    .help(DisplayText.safe(categorySource))
                if let verdictText { Text(verdictText).foregroundStyle(.green) }
            } else {
                Text(category == nil ? "noch nicht eingeordnet" : "offen – keine Regel passt").foregroundStyle(.secondary)
            }
            if model.aiConfig.enabled, category?.source != .user {
                Button(category?.category == nil ? "Mit KI einordnen" : "Neu einordnen") { model.classifySelection() }
                    .controlSize(.small).disabled(model.actionRunning)
            }
            if inJunk {
                Button("Kein Spam → Posteingang") { model.rescueSelection() }
                    .controlSize(.small).disabled(model.actionRunning)
                    .help("Auf dem Server aus dem Spam-Ordner in den Posteingang verschieben; das Archiv merkt es sich")
                if category?.verdict != "spam" {
                    Button("Ist Spam") { model.markSpamSelection() }.controlSize(.small)
                }
            }
        }
        .font(.callout)
    }

    private var categorySource: String {
        guard let c = category else { return "" }
        switch c.source {
        case .heuristic: return String(localized: "Regel: \(c.rule ?? "—")")
        case .endpoint: return "\(c.model ?? "KI"): \(c.reason ?? "")"
        case .onDevice: return String(localized: "Modell auf diesem Mac: \(c.reason ?? "")")
        case .user: return String(localized: "deine Entscheidung")
        }
    }

    private var verdictText: String? {
        switch category?.verdict {
        case "ham": String(localized: "du: kein Spam")
        case "spam": String(localized: "du: Spam")
        default: nil
        }
    }

    /// Where the message is (TJ): server and archive, archive only, or trash — exactly one.
    private func placeRow(_ d: MessageDetail) -> some View {
        let (icon, title, tint): (String, String, Color) = switch d.place {
        case .serverAndArchive: ("server.rack", String(localized: "Server und Archiv"), .blue)
        case .archiveOnly: ("archivebox", String(localized: "Nur im Archiv"), .secondary)
        case .trash: ("trash", String(localized: "Im Papierkorb"), .orange)
        }
        let detail: String = switch d.place {
        case .serverAndArchive:
            String(localized: "auf dem Server: ") + d.locations.filter(\.isOnServer).map { "\($0.account) › \($0.mailbox)" }.joined(separator: ", ")
        case .archiveOnly:
            d.locations.contains { $0.uid != nil } ? String(localized: "auf dem Server gelöscht") : String(localized: "importiert, auf keinem Server")
        case .trash:
            d.purgeDate().map { String(localized: "wird am \($0.formatted(date: .long, time: .omitted)) endgültig gelöscht") } ?? ""
        }
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Ort").foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Label(title, systemImage: icon)
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(tint.opacity(0.12)))
            Text(DisplayText.safe(detail)).foregroundStyle(.secondary).lineLimit(2)
            if d.place == .trash {
                Button("Wiederherstellen") { model.restoreSelection() }.controlSize(.small).disabled(model.actionRunning)
            } else if d.place == .archiveOnly {
                Button("Zurückspielen …") { model.planSelection(.restore) }.controlSize(.small).disabled(model.actionRunning)
                    .help("Die Mail aus dem Archiv wieder auf den Server laden")
            }
        }
        .font(.callout)
    }

    /// A header row whose values open filter menus.
    private func filterRow(_ label: LocalizedStringKey, _ values: [(text: String, options: [FilterOption], copy: String?, icon: String?)]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            WrapLayout(spacing: 10) {
                ForEach(Array(values.prefix(12).enumerated()), id: \.offset) { _, v in
                    AttributeMenu(model: model, text: v.text, options: v.options, copy: v.copy, systemImage: v.icon)
                }
                if values.count > 12 { Text("+\(values.count - 12)").foregroundStyle(.secondary) }
            }
        }
        .font(.callout)
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
            if let p = model.syncProgress {
                ProgressView().controlSize(.mini)
                Text(syncText(p)).lineLimit(1)
            } else if let message = model.syncMessage {
                Label(message.replacingOccurrences(of: "\n", with: " · "), systemImage: "checkmark.circle")
                    .lineLimit(1)
                    .help(message)
                    .onTapGesture { model.syncMessage = nil }
            }
            if let p = model.actionProgress {
                ProgressView(value: Double(min(p.done, p.total)), total: Double(max(p.total, 1)))
                    .frame(width: 70)
                    .controlSize(.mini)
                Text("\(p.title): \(p.done.formatted()) von \(p.total.formatted())" + (p.failed > 0 ? " · \(p.failed) fehlgeschlagen" : ""))
                Button { model.cancelAction() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .help(p.resumable ? "Nach dem laufenden Stapel anhalten; der Rest lässt sich fortsetzen" : "Anhalten")
            } else if let job = model.unfinishedJobs.first {
                Button {
                    model.resume(job)
                } label: {
                    Label("Unterbrochener Auftrag: \(AppModel.actionTitle(job.kind)) (\(job.open.count) offen) – fortsetzen …",
                          systemImage: "exclamationmark.arrow.circlepath")
                }
                .buttonStyle(.link)
            }
            if let p = model.textIndexProgress, p.total > 0 {
                ProgressView(value: Double(min(p.done, p.total)), total: Double(p.total))
                    .frame(width: 70)
                    .controlSize(.mini)
                Text("PDFs durchsuchbar machen: \(p.done.formatted()) von \(p.total.formatted())")
                    .help("Läuft im Hintergrund in einem abgeschotteten Prozess ohne Netz- und Dateizugriff. Import und Abruf haben Vorrang.")
            }
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

    private func syncText(_ p: SyncProgress) -> String {
        let box = p.mailbox.map { " · \(DisplayText.safe($0)) (\(p.mailboxIndex + 1)/\(p.mailboxCount))" } ?? ""
        switch p.phase {
        case .fetching: return "Abruf \(p.account)\(box): \(p.fetched) von \(p.toFetch) neuen Mails"
        case .flags: return "Abruf \(p.account)\(box): Markierungen abgleichen"
        case .deletions: return "Abruf \(p.account)\(box): Löschungen prüfen"
        default: return "Abruf \(p.account)\(box) …"
        }
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

/// The messages of the current conversation, oldest first; click opens one, the button lists
/// the whole conversation (`thread:<Message-ID>`, across mailboxes).
struct ConversationList: View {
    let model: AppModel
    let current: Int64
    let thread: [MessageSummary]
    /// Remembered across messages and launches: opening another mail of the conversation
    /// keeps the list open.
    @AppStorage("readerConversationExpanded") private var expanded = false

    private static let rowHeight: CGFloat = 22
    private static let visibleRows = 8

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 4) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(thread) { m in row(m).id(m.id) }
                        }
                    }
                    .frame(height: Self.rowHeight * CGFloat(min(thread.count, Self.visibleRows)))
                    .scrollIndicators(thread.count > Self.visibleRows ? .automatic : .never)
                    .onAppear { proxy.scrollTo(current, anchor: .center) }
                    .onChange(of: current) { withAnimation { proxy.scrollTo(current, anchor: .center) } }
                }
                Button("Ganze Konversation in der Liste zeigen") { model.showThread(of: current) }
                    .buttonStyle(.link)
            }
            .font(.callout)
            .padding(.top, 2)
        } label: {
            Text("\(thread.count) Nachrichten in dieser Konversation").font(.callout)
        }
    }

    /// The open message: tinted background, accent marker, bold. Others: plain, clickable.
    private func row(_ m: MessageSummary) -> some View {
        let isCurrent = m.id == current
        return Button { if !isCurrent { model.reveal(m.id) } } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrowtriangle.right.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.accentColor)
                    .opacity(isCurrent ? 1 : 0)
                Text(m.date.map { $0.formatted(date: .numeric, time: .shortened) } ?? "—")
                    .monospacedDigit()
                    .frame(width: 118, alignment: .leading)
                Text(DisplayText.safe(m.fromDisplay)).lineLimit(1).frame(width: 150, alignment: .leading)
                Text(DisplayText.safe(m.subject ?? "")).lineLimit(1)
                Spacer(minLength: 0)
            }
            .fontWeight(isCurrent ? .semibold : .regular)
            .padding(.horizontal, 6)
            .frame(height: Self.rowHeight)
            .background(RoundedRectangle(cornerRadius: 5).fill(isCurrent ? Color.accentColor.opacity(0.18) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)  // not .disabled: that would grey out the highlight
        .help(isCurrent ? String(localized: "Diese Nachricht ist geöffnet") : String(localized: "Nachricht öffnen"))
    }
}

/// Bottom of the reader while the pointer is on a link (TJ): where it really goes — and, in
/// orange, why it looks like a lure (text shows another domain, bare IP, punycode, shortener …).
struct LinkTargetBar: View {
    let link: LinkCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: link.isSuspicious ? "exclamationmark.triangle.fill" : "link")
                    .foregroundStyle(link.isSuspicious ? .orange : .secondary)
                Text(verbatim: DisplayText.safe(String(link.target.prefix(300))))
                    .lineLimit(1).truncationMode(.middle)
            }
            if link.isSuspicious {
                if let shown = link.shownDomain, let domain = link.domain, link.findings.contains(.textShowsOtherDomain) {
                    Text("Angezeigt: \(DisplayText.safe(shown)) · Ziel: \(DisplayText.safe(domain))").fontWeight(.semibold).foregroundStyle(.orange)
                }
                ForEach(link.findings.filter { $0 != .textShowsOtherDomain }, id: \.self) { f in
                    Text(f.text).foregroundStyle(.orange)
                }
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .padding(6)
        .frame(maxWidth: 640, alignment: .leading)
        .allowsHitTesting(false)
    }
}
