import AppKit
import MailKeeperIMAP
import MailKeeperKit
import Observation
import SwiftUI

/// The content column: the message list, or the cleanup view grouped one way.
enum ViewMode: String, CaseIterable, Identifiable {
    case messages, sender, domain, list
    var id: String { rawValue }

    var group: GroupMode? {
        switch self {
        case .messages: nil
        case .sender: .sender
        case .domain: .domain
        case .list: .list
        }
    }
}

enum SidebarItem: Hashable {
    case all
    case account(String)
    case mailbox(account: String, name: String)
    case saved(UUID)
}

enum ImportKind: String, CaseIterable, Identifiable {
    case maildir, mbox, eml
    var id: String { rawValue }

    var title: String {
        switch self {
        case .maildir: String(localized: "Maildir-Ordner …")
        case .mbox: String(localized: "mbox-Datei (auch Google Takeout) …")
        case .eml: String(localized: "Ordner mit .eml-Dateien …")
        }
    }
}

struct ImportStatus: Equatable {
    var title: String
    var progress = ImportProgress()
    var finished = false
    var error: String?
}

/// App state on the main actor. The reader connection lives here; imports run on the
/// archive writer actor in the background and report progress back.
@MainActor @Observable
final class AppModel {
    private(set) var archiveRoot: URL?
    private(set) var reader: ArchiveReader?
    private(set) var accounts: [AccountSummary] = []
    private(set) var stats: ArchiveStats?
    private(set) var openError: String?
    private(set) var volumeEncrypted: Bool?

    var sidebarSelection: SidebarItem? = .all { didSet { reloadList() } }
    var searchText = "" { didSet { scheduleSearch() } }
    /// The parsed search text (chips), and why it does not parse.
    private(set) var query: Query?
    private(set) var queryError: String?
    private(set) var savedSearches: [SavedSearch] = []
    private(set) var savedCounts: [UUID: Int] = [:]
    private(set) var labels: [String] = []
    var viewMode: ViewMode = .messages { didSet { if viewMode != oldValue { reloadList() } } }
    private(set) var groups: [MessageGroup] = []
    /// PDF text queue (ADR-0009): progress while it runs, totals for the status bar.
    private(set) var textIndexProgress: AttachmentIndexProgress?
    private(set) var textStats: AttachmentTextStats?
    private var textIndexTask: Task<Void, Never>?
    private var textIndexToken: UUID?
    private let pdfText = PDFTextClient()
    var sort: MessageSort = .date
    var ascending = false
    private(set) var messageIDs: [Int64] = []
    /// Bumped whenever `messageIDs` is replaced; the table reloads on change.
    private(set) var listGeneration = 0
    var selectedMessageID: Int64?
    /// Bumped when the model selects a message itself (conversation list); the table follows.
    private(set) var selectionRequest = 0

    private(set) var importStatus: ImportStatus?
    private(set) var importRunning = false
    private(set) var accountConfigs: [AccountConfig] = []
    /// Keychain presence per account, refreshed with the account list (not per redraw).
    private(set) var passwordPresent: [String: Bool] = [:]
    private(set) var syncProgress: SyncProgress?
    private(set) var syncRunning = false
    var syncMessage: String?
    private let credentials = CredentialStore()
    private(set) var listError: String?
    private var searchTask: Task<Void, Never>?
    private var scopedURL: URL?

    private static let bookmarkKey = "archiveBookmark"

    init() {
        openInitialArchive()
    }

    // MARK: Archive location

    /// Default: inside the app container (sandboxed) or ~/Library/Application Support (unsandboxed,
    /// shared with mkctl). A user-chosen location is remembered as a security-scoped bookmark.
    private func openInitialArchive() {
        // Development override (only effective unsandboxed): MAILKEEPER_ARCHIVE=/path
        if let env = ProcessInfo.processInfo.environment["MAILKEEPER_ARCHIVE"], !env.isEmpty {
            open(URL(fileURLWithPath: (env as NSString).expandingTildeInPath), create: true)
            return
        }
        if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale) else {
                // The chosen archive is unreachable (volume not mounted, folder gone). Do not fall
                // back to another archive silently: imports would land in the wrong place.
                openError = String(localized: "Das gewählte Archiv ist nicht erreichbar. Ist das Laufwerk angeschlossen?")
                return
            }
            if url.startAccessingSecurityScopedResource() { scopedURL = url }
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) {
                UserDefaults.standard.set(fresh, forKey: Self.bookmarkKey)
            }
            open(url, create: false)
            return
        }
        let fallback = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MailKeeper/Archive")
        open(fallback, create: true)
    }

    @discardableResult
    func open(_ url: URL, create: Bool) -> Bool {
        do {
            let layout = try ArchiveLayout.open(at: url, create: create)
            reader = try ArchiveReader(layout: layout)
            archiveRoot = url
            volumeEncrypted = layout.volumeIsEncrypted
            openError = nil
            selectedMessageID = nil
            textIndexTask?.cancel()  // belongs to the previous archive
            textIndexTask = nil
            refresh()
            startTextIndexing()
            return true
        } catch {
            reader = nil
            archiveRoot = url
            openError = "\(error)"
            accounts = []
            messageIDs = []
            listGeneration += 1
            return false
        }
    }

    func chooseArchive() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Archiv verwenden")
        panel.message = String(localized: "Wähle einen bestehenden MailKeeper-Archivordner oder einen leeren Ordner für ein neues Archiv.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        guard open(url, create: true) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return  // keep the previous bookmark; the error is shown
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = accessing ? url : nil
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope]) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
    }

    // MARK: Data

    func refresh() {
        guard let reader else { return }
        reloadAccounts(reader.layout)
        accounts = (try? reader.accounts()) ?? []
        stats = try? reader.stats()
        labels = (try? reader.labels()) ?? []
        reloadSavedSearches()
        reloadList()
    }

    /// The sidebar's part of the filter: account, mailbox or a saved search's query.
    private var scopeFilter: MessageFilter {
        switch sidebarSelection {
        case .account(let a): MessageFilter(account: a)
        case .mailbox(let a, let m): MessageFilter(account: a, mailbox: m)
        case .saved(let id): MessageFilter(base: savedSearches.first { $0.id == id }?.query)
        case .all, nil: MessageFilter()
        }
    }

    func reloadList() {
        guard let reader else { return }
        var filter = scopeFilter
        // Untrimmed: a trailing space ends the live prefix of the last word (ADR-0008).
        let text = searchText.allSatisfy(\.isWhitespace) ? nil : searchText
        do throws(QueryError) {
            query = if let text { try QueryParser.parse(text) } else { nil }
            queryError = nil
        } catch {
            // "from:" while typing the value: keep the current list, no error yet.
            if searchText.hasSuffix(":") { return }
            // Otherwise fail closed: no list rather than a wider one.
            query = nil
            queryError = error.message
            messageIDs = []
            listGeneration += 1
            selectedMessageID = nil
            return
        }
        filter.text = text
        do {
            if let mode = viewMode.group {
                groups = try reader.groups(filter, by: mode)
                listError = nil
                return
            }
            messageIDs = try reader.messageIDs(filter, sort: sort, ascending: ascending)
            listError = nil
        } catch let error as QueryError {
            messageIDs = []
            queryError = String(localized: "Gespeicherte Suche: \(error.message)")
        } catch {
            messageIDs = []
            listError = "\(error)"  // an I/O error must not look like "no results"
        }
        listGeneration += 1
        if let sel = selectedMessageID, !messageIDs.contains(sel) { selectedMessageID = nil }
    }

    // MARK: Query helpers

    var suggestions: [QueryCompletion.Suggestion] {
        let folders = Set(accounts.flatMap(\.mailboxes).map(\.name)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return QueryCompletion.suggestions(for: searchText, folders: folders, accounts: accounts.map(\.id), labels: labels)
    }

    /// Removes one top-level term from the search text.
    func removeChip(_ chip: QueryChip) {
        guard chip.range.upperBound <= searchText.endIndex else { return }
        var text = searchText
        text.removeSubrange(chip.range)
        let rest = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        searchText = rest.isEmpty ? "" : rest + " "  // the trailing space keeps the last word exact
    }

    /// Cleanup view → the group's messages: back to the list, narrowed by the group's exact query.
    func openGroup(_ group: MessageGroup) {
        appendFilter(group.query)
        viewMode = .messages
    }

    /// Appends a filter term (from the Filter menu) to the search text.
    func appendFilter(_ term: String) {
        let base = searchText.trimmingCharacters(in: .whitespaces)
        searchText = (base.isEmpty ? "" : base + " ") + term + " "
    }

    // MARK: Saved searches

    private func reloadSavedSearches() {
        guard let reader else { return }
        savedSearches = (try? SavedSearchStore(layout: reader.layout).load()) ?? []
        savedCounts = Dictionary(uniqueKeysWithValues: savedSearches.compactMap { s in
            (try? reader.count(MessageFilter(base: s.query))).map { (s.id, $0) }
        })
    }

    /// The current view as one self-contained query: sidebar scope plus search text.
    func queryForSaving() -> String {
        let text = searchText.trimmingCharacters(in: .whitespaces)
        let quote = { (v: String) in v.contains(where: { $0.isWhitespace || "()\"".contains($0) }) ? "\"\(v.replacingOccurrences(of: "\"", with: ""))\"" : v }
        var scope: [String] = []
        switch sidebarSelection {
        case .account(let a): scope = ["account:\(a)"]
        case .mailbox(let a, let m): scope = ["account:\(a)", "folder:\(quote(m))"]
        case .saved(let id): if let base = savedSearches.first(where: { $0.id == id })?.query { scope = ["(\(base))"] }
        case .all, nil: break
        }
        return (scope + (text.isEmpty ? [] : [text.contains(" OR ") && !scope.isEmpty ? "(\(text))" : text])).joined(separator: " ")
    }

    func putSavedSearch(_ search: SavedSearch) throws {
        guard let layout = reader?.layout else { return }
        try SavedSearchStore(layout: layout).put(search)
        reloadSavedSearches()
        if case .saved(let id) = sidebarSelection, id == search.id { reloadList() }
    }

    func count(query: String) -> Int? {
        try? reader?.count(MessageFilter(base: query))
    }

    /// After saving the current search as a view: show the view, clear the search field.
    func showSaved(_ id: UUID) {
        searchText = ""
        sidebarSelection = .saved(id)
    }

    func deleteSavedSearch(_ id: UUID) {
        guard let layout = reader?.layout else { return }
        try? SavedSearchStore(layout: layout).remove(id)
        if case .saved(id) = sidebarSelection { sidebarSelection = .all }
        reloadSavedSearches()
    }

    func setSort(_ sort: MessageSort, ascending: Bool) {
        guard sort != self.sort || ascending != self.ascending else { return }
        self.sort = sort
        self.ascending = ascending
        reloadList()
    }

    /// Debounced so typing does not query on every keystroke.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.reloadList()
        }
    }

    func summaries(_ ids: [Int64]) -> [MessageSummary] {
        (try? reader?.summaries(ids)) ?? []
    }

    func detail(_ id: Int64) -> MessageDetail? {
        try? reader?.detail(id)
    }

    // MARK: Conversations

    func thread(of id: Int64) -> [MessageSummary] {
        (try? reader?.thread(of: id)) ?? []
    }

    /// Shows a message chosen outside the table; the table selects its row if it is listed.
    func reveal(_ id: Int64) {
        selectedMessageID = id
        selectionRequest += 1
    }

    /// The whole conversation in the list: all mailboxes, `thread:<Message-ID>`.
    func showThread(of id: Int64) {
        guard let query = (try? reader?.threadQuery(of: id)) ?? nil else { return }
        viewMode = .messages
        searchText = query + " "
        sidebarSelection = .all  // reloads now, with the new search text
        reveal(id)
    }

    /// Reads and parses the stored message off the main thread (large mails take a while).
    func parse(_ detail: MessageDetail) async -> ParsedMessage? {
        guard let blobs = reader?.layout.blobs else { return nil }
        let sha = detail.primaryBlob
        return await Task.detached(priority: .userInitiated) {
            (try? blobs.read(sha)).map(MIMEParser.parse)
        }.value
    }

    // MARK: Import

    func startImport(_ kind: ImportKind) {
        guard let root = archiveRoot, !importRunning, !syncRunning else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = kind != .mbox
        panel.canChooseFiles = kind == .mbox
        panel.prompt = String(localized: "Importieren")
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let account = source.deletingPathExtension().lastPathComponent
        importStatus = ImportStatus(title: String(localized: "Import \(source.lastPathComponent)"))
        importRunning = true

        let accessing = source.startAccessingSecurityScopedResource()
        let indexing = pauseTextIndexing()
        Task.detached { [weak self] in
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
            await indexing?.value  // the queue holds the writer until it has stopped
            let report: @Sendable (ImportProgress) -> Void = { p in
                Task { @MainActor in self?.importStatus?.progress = p }
            }
            do {
                let writer = try ArchiveWriter(layout: try ArchiveLayout.open(at: root, create: true))
                let result: ImportProgress
                switch kind {
                case .maildir: result = try await MaildirImporter(root: source, account: account).run(writer: writer, progress: report)
                case .mbox: result = try await MboxImporter(file: source, account: account).run(writer: writer, progress: report)
                case .eml: result = try await EMLImporter(root: source, account: account).run(writer: writer, progress: report)
                }
                await MainActor.run {
                    self?.importStatus?.progress = result
                    self?.importStatus?.finished = true
                    self?.importRunning = false
                    self?.refresh()
                    self?.startTextIndexing()
                }
            } catch {
                await MainActor.run {
                    self?.importStatus?.error = "\(error)"
                    self?.importStatus?.finished = true
                    self?.importRunning = false
                    self?.startTextIndexing()
                }
            }
        }
    }

    func dismissImportStatus() {
        importStatus = nil
    }

    // MARK: PDF text (ADR-0009)

    /// Runs the background queue when there is work and the writer is free (no import, no
    /// sync, no mkctl holding the archive — then it simply tries again next time).
    func startTextIndexing() {
        guard let root = archiveRoot, let reader, textIndexTask == nil, !syncRunning, !importRunning else { return }
        textStats = try? reader.attachmentTextStats()
        guard (textStats?.pending ?? 0) > 0 else { return }
        let extractor = pdfText
        let token = UUID()
        textIndexToken = token
        textIndexTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let writer = try ArchiveWriter(layout: try ArchiveLayout.open(at: root, create: false))
                _ = try await AttachmentIndexer(writer: writer, extractor: extractor).run { p in
                    Task { @MainActor in if self?.textIndexToken == token { self?.textIndexProgress = p } }
                }
            } catch {
                // cancelled for an import/sync, or the archive is locked: resumes later
            }
            await MainActor.run {
                guard let self, self.textIndexToken == token else { return }
                self.textIndexTask = nil
                self.textIndexToken = nil
                self.textIndexProgress = nil
                self.textStats = try? self.reader?.attachmentTextStats()
            }
        }
    }

    /// Stops the queue so import or sync can open the writer; await the returned task first.
    private func pauseTextIndexing() -> Task<Void, Never>? {
        let task = textIndexTask
        task?.cancel()
        return task
    }

    // MARK: Accounts & sync (read-only)

    func hasPassword(_ account: AccountConfig) -> Bool {
        passwordPresent[account.id] ?? false
    }

    private func reloadAccounts(_ layout: ArchiveLayout) {
        accountConfigs = (try? AccountStore(layout: layout).load()) ?? []
        passwordPresent = Dictionary(uniqueKeysWithValues: accountConfigs.map { ($0.id, credentials.exists(for: $0)) })
    }

    func addAccount(_ account: AccountConfig, password: String) throws {
        guard let layout = reader?.layout else { return }
        try AccountStore(layout: layout).add(account)
        try credentials.save(password, for: account)
        reloadAccounts(layout)
    }

    /// Removes the account configuration; archived mail stays. The keychain entry is shared by
    /// every archive using the same mailbox, so deleting it is the caller's explicit choice.
    func removeAccount(_ id: String, deletePassword: Bool) {
        guard let layout = reader?.layout, let account = accountConfigs.first(where: { $0.id == id }) else { return }
        try? AccountStore(layout: layout).remove(id)
        let stillUsed = accountConfigs.contains { $0.id != id && CredentialStore.key(for: $0) == CredentialStore.key(for: account) }
        if deletePassword, !stillUsed { try? credentials.delete(for: account) }
        reloadAccounts(layout)
    }

    func testAccount(_ id: String) async -> String {
        guard let account = accountConfigs.first(where: { $0.id == id }) else { return "" }
        guard let password = try? credentials.password(for: account) else { return String(localized: "Kein Passwort im Schlüsselbund.") }
        do {
            let check = try await SyncCoordinator.check(account, password: password)
            return String(localized: "Verbindung ok — abgerufen werden \(check.selected.count) von \(check.mailboxes.count) Postfächern.")
        } catch {
            return "\(error)"
        }
    }

    /// Fetches new mail from all configured accounts, one after another, read-only.
    func syncAll() {
        guard let root = archiveRoot, !syncRunning, !importRunning, !accountConfigs.isEmpty else { return }
        let accounts = accountConfigs
        let credentials = self.credentials
        syncRunning = true
        syncMessage = nil
        let indexing = pauseTextIndexing()
        Task.detached { [weak self] in
            await indexing?.value  // the queue holds the writer until it has stopped
            var summary: [String] = []
            do {
                let writer = try ArchiveWriter(layout: try ArchiveLayout.open(at: root, create: false))
                for account in accounts {
                    do {
                        let r = try await SyncCoordinator.sync(account, writer: writer, credentials: credentials) { p in
                            Task { @MainActor in self?.syncProgress = p }
                        }
                        summary.append("\(account.displayName): \(r.newMessages) neu" + (r.failures.isEmpty ? "" : " · \(r.failures.count) Fehler: \(r.failures.joined(separator: "; "))"))
                    } catch {
                        summary.append("\(account.displayName): \(error)")
                    }
                    await MainActor.run { self?.refresh() }
                }
            } catch {
                summary.append("\(error)")
            }
            let text = summary.joined(separator: "\n")
            await MainActor.run {
                self?.syncRunning = false
                self?.syncProgress = nil
                self?.syncMessage = text
                self?.refresh()
                self?.startTextIndexing()
            }
        }
    }
}
