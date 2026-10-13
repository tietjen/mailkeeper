import AppKit
import LocalAuthentication
import MailKeeperAI
import MailKeeperIMAP
import MailKeeperKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import Synchronization

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

/// One station of the back/forward history: where the user was and what was selected.
struct NavigationEntry: Sendable, Equatable {
    var viewMode: ViewMode
    var sidebar: SidebarItem?
    var searchText: String
    var groupID: String?
    var messageID: Int64?
    var label: String
    /// Created by typing in the search field: the next keystrokes fold into it.
    var typed: Bool
    var time: Date

    func samePlace(as other: NavigationEntry) -> Bool {
        viewMode == other.viewMode && sidebar == other.sidebar
            && searchText.trimmingCharacters(in: .whitespaces) == other.searchText.trimmingCharacters(in: .whitespaces)
    }
}

enum SidebarItem: Hashable {
    case all
    case account(String)
    case mailbox(account: String, name: String)
    case saved(UUID)
    /// The archive trash (Phase 4.3).
    case trash
    /// Mails in spam folders, with the model's verdict (5.5).
    case spamReview
    /// Suspicious mail outside the spam folders (6.4).
    case suspicious
}

/// A planned job waiting for the user's go (plan sheet).
struct PlannedAction: Identifiable {
    var id = UUID()
    var job: ActionJob
    var summary: ActionPlanSummary
    var filter: MessageFilter
    var examples: [MessageSummary]
    /// Already stored in the queue (resume, retry of a stored job): run without creating it.
    var stored = false
}

/// An export waiting for its format and destination (export sheet).
struct ExportRequest: Identifiable {
    var id = UUID()
    var filter: MessageFilter
    var title: String
    var count: Int
    var bytes: Int64
}

/// An archive this app has opened before (TJ: switch between configured archives). The
/// bookmark carries the sandbox permission across launches.
struct KnownArchive: Codable, Identifiable, Equatable {
    var path: String
    var bookmark: Data?
    var lastOpened: Date
    var id: String { path }
}

struct ActionRunProgress: Equatable {
    var title: String
    var done: Int
    var total: Int
    var failed: Int
    /// A queued job resumes after a stop; an export does not.
    var resumable = true
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
    /// True while a schema migration runs in the background (first start after an update).
    private(set) var preparingArchive = false
    private(set) var volumeEncrypted: Bool?

    var sidebarSelection: SidebarItem? = .all { didSet { if !batching { reloadList() } } }
    var searchText = "" {
        didSet {
            searchTyped = !settingSearch  // the search field's binding, not a drill-down
            if !settingSearch, searchTranslation != nil { searchTranslation = nil }  // edited by hand: the note is stale
            if !batching { scheduleSearch() }
        }
    }
    private var settingSearch = false
    private var searchTyped = false
    /// Several view properties change at once (history restore): one reload at the end.
    private var batching = false
    /// Back/forward (TJ: "Vor und Zurück … an eine bestimmte Stelle meiner Recherche").
    private(set) var history = NavigationHistory<NavigationEntry>()
    private var restoring = false
    /// Selections changed by a reload must not rewrite the previous station.
    private var reloading = false
    /// The parsed search text (chips), and why it does not parse.
    private(set) var query: Query?
    private(set) var queryError: String?
    private(set) var savedSearches: [SavedSearch] = []
    private(set) var savedCounts: [UUID: Int] = [:]
    private(set) var labels: [String] = []
    var viewMode: ViewMode = .messages { didSet { if viewMode != oldValue, !batching { reloadList() } } }
    private(set) var groups: [MessageGroup] = []
    /// Phase 4: the table's selection (several rows), the plan waiting for a go, the running job.
    var selectedMessageIDs: Set<Int64> = []
    var pendingPlan: PlannedAction?
    var pendingExport: ExportRequest?
    var exportResult: ExportReport?
    var actionResult: ActionJob?
    var actionError: String?
    private(set) var actionProgress: ActionRunProgress?
    private(set) var actionRunning = false
    private(set) var unfinishedJobs: [ActionJob] = []
    private var actionTask: Task<Void, Never>?
    private let audit = AuditLog()
    /// Cleanup view, right-hand pane: the selected group's details, else an overview.
    var selectedGroupID: String? {
        didSet {
            if selectedGroupID != oldValue { loadGroupDetail() }
            noteSelection()
        }
    }
    private(set) var groupDetail: GroupDetail?
    private(set) var cleanupOverview: CleanupOverview?
    /// The filter of the last successful list/group load (scope + search).
    private var lastFilter: MessageFilter?
    /// PDF text queue (ADR-0009): progress while it runs, totals for the status bar.
    private(set) var textIndexProgress: AttachmentIndexProgress?
    private(set) var embedProgress: EmbeddingIndexer.Progress?
    private(set) var textStats: AttachmentTextStats?
    private var textIndexTask: Task<Void, Never>?
    private var textIndexToken: UUID?
    private let pdfText = PDFTextClient()
    var sort: MessageSort = .date
    var ascending = false
    private(set) var messageIDs: [Int64] = []
    /// Bumped whenever `messageIDs` is replaced; the table reloads on change.
    private(set) var listGeneration = 0
    /// Bumped whenever the archive changed (action, sync, import, trash): the reader reloads the
    /// open message even though the selection stayed (TJ: place still said "Server" after a delete).
    private(set) var contentGeneration = 0
    var selectedMessageID: Int64? { didSet { if selectedMessageID != oldValue { noteSelection() } } }
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

    private(set) var knownArchives: [KnownArchive] = []
    private static let knownArchivesKey = "knownArchives"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.knownArchivesKey),
           let list = try? JSONDecoder().decode([KnownArchive].self, from: data) {
            knownArchives = list
        } else {
            // First start with the list: take over what the app knew before — the one remembered
            // archive (bookmark) and the default location, if it holds an archive.
            if let data = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                    knownArchives.append(KnownArchive(path: url.path, bookmark: data, lastOpened: .distantPast))
                }
            }
            let standard = Self.defaultArchiveURL
            if FileManager.default.fileExists(atPath: standard.appending(path: "archive.json").path),
               !knownArchives.contains(where: { $0.path == standard.path }) {
                knownArchives.append(KnownArchive(path: standard.path, bookmark: try? standard.bookmarkData(options: [.withSecurityScope]),
                                                  lastOpened: .distantPast))
            }
            saveKnownArchives()
        }
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
        open(Self.defaultArchiveURL, create: true)
    }

    static var defaultArchiveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "MailKeeper/Archive")
    }

    // MARK: Known archives

    /// "Standard-Archiv" for the default location, else the folder's name.
    func archiveName(_ path: String?) -> String {
        guard let path else { return "MailKeeper" }
        // Compare paths: URL(fileURLWithPath:) adds a trailing "/" for an existing folder, so URLs differ.
        if URL(fileURLWithPath: path).standardizedFileURL.path == Self.defaultArchiveURL.standardizedFileURL.path {
            return String(localized: "Standard-Archiv")
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    var currentArchiveName: String { archiveName(archiveRoot?.path) }

    /// "~/Documents/MailArchivTest"
    func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }

    private func remember(_ url: URL) {
        let bookmark = try? url.bookmarkData(options: [.withSecurityScope])
        knownArchives.removeAll { $0.path == url.path }
        knownArchives.insert(KnownArchive(path: url.path, bookmark: bookmark, lastOpened: Date()), at: 0)
        saveKnownArchives()
        if let bookmark { UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey) }  // reopened at the next launch
    }

    private func saveKnownArchives() {
        if let data = try? JSONEncoder().encode(knownArchives) { UserDefaults.standard.set(data, forKey: Self.knownArchivesKey) }
    }

    /// Removes an archive from the list (its files stay untouched).
    func forget(_ archive: KnownArchive) {
        knownArchives.removeAll { $0.path == archive.path }
        saveKnownArchives()
    }

    func switchTo(_ archive: KnownArchive) {
        guard archive.path != archiveRoot?.path, !refuseSwitchWhileBusy() else { return }
        var url = URL(fileURLWithPath: archive.path)
        if let data = archive.bookmark {
            var stale = false
            guard let resolved = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale) else {
                actionError = String(localized: "„\(archiveName(archive.path))“ ist nicht erreichbar. Ist das Laufwerk angeschlossen?")
                return
            }
            url = resolved
        }
        openExisting(url)
    }

    /// Opens a folder that already holds an archive; never creates one (TJ ended up in an empty
    /// archive because choosing any empty folder silently created it).
    private func openExisting(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        guard FileManager.default.fileExists(atPath: url.appending(path: "archive.json").path) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            actionError = String(localized: "In „\(abbreviated(url.path))“ liegt kein MailKeeper-Archiv. Ein neues legst du mit „Neues Archiv anlegen …“ an.")
            return
        }
        guard !refuseSwitchWhileBusy() else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return
        }
        guard open(url, create: false) else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            return
        }
        if scopedURL != url { scopedURL?.stopAccessingSecurityScopedResource() }
        scopedURL = accessing ? url : nil
        remember(url)
    }

    /// Whether another archive may be opened now; says why not (TJ: asked mid-check). The
    /// running job writes only into the archive it started in, so it must end first.
    var archiveSwitchBlocked: Bool { actionRunning || syncRunning || importRunning }

    private func refuseSwitchWhileBusy() -> Bool {
        guard archiveSwitchBlocked else { return false }
        actionError = actionRunning
            ? String(localized: "Gerade läuft „\(actionProgress?.title ?? String(localized: "eine Aktion"))“. Das Archiv lässt sich wechseln, sobald sie fertig ist – oder halte sie mit × unten in der Statusleiste an; was fertig ist, bleibt.")
            : String(localized: "Erst wenn Import oder Abruf fertig sind, lässt sich das Archiv wechseln.")
        return true
    }

    func openArchive() {
        guard !refuseSwitchWhileBusy() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = String(localized: "Öffnen")
        panel.message = String(localized: "Wähle einen Ordner, der ein MailKeeper-Archiv enthält.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openExisting(url)
    }

    /// A new archive, only in an empty folder.
    func createArchive() {
        guard !refuseSwitchWhileBusy() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Anlegen")
        panel.message = String(localized: "Wähle einen leeren Ordner für das neue Archiv – oder lege mit „Neuer Ordner“ einen an.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        if FileManager.default.fileExists(atPath: url.appending(path: "archive.json").path) {
            if accessing { url.stopAccessingSecurityScopedResource() }
            openExisting(url)  // already an archive: open it
            return
        }
        let visible = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }
        guard visible.isEmpty else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            actionError = String(localized: "„\(abbreviated(url.path))“ ist nicht leer. Ein neues Archiv braucht einen leeren Ordner.")
            return
        }
        guard !refuseSwitchWhileBusy(), open(url, create: true) else {  // was silent while busy
            if accessing { url.stopAccessingSecurityScopedResource() }
            return
        }
        if scopedURL != url { scopedURL?.stopAccessingSecurityScopedResource() }
        scopedURL = accessing ? url : nil
        remember(url)
    }

    @discardableResult
    func open(_ url: URL, create: Bool) -> Bool {
        if url != archiveRoot {
            history.clear()  // stations of another archive mean nothing here
            // nothing planned in one archive may run in another (review 4.7)
            pendingPlan = nil
            pendingExport = nil
            actionResult = nil
            exportResult = nil
            lastFilter = nil
            junkReview = nil
            autoJunkFailed = false
            vectorCache = nil
            rankedMode = nil
            rankedIDs = []
            embedFailed = false
            translationTask?.cancel()
            translationTask = nil
            for (_, running) in summaryTasks { running.task.cancel() }
            summaryTasks = [:]
            summaries = [:]
            summaryOrder = []
        }
        textIndexTask?.cancel()  // belongs to the previous archive
        textIndexTask = nil
        goldTask?.cancel()
        goldTask = nil
        goldGeneration += 1
        goldProgress = nil
        goldResults = []
        goldMessage = nil
        goldLabels = GoldLabels()  // the previous archive's labels never show for another
        goldLoadError = nil
        textIndexToken = nil
        textIndexProgress = nil
        do {
            let layout = try ArchiveLayout.open(at: url, create: create)
            if ArchiveReader.needsMigration(layout) {
                // Can take a while (conversations for every message): not on the main thread,
                // and waiting for mkctl's lock instead of failing.
                reader = nil
                archiveRoot = url
                openError = nil
                preparingArchive = true
                accounts = []
                messageIDs = []
                listGeneration += 1
                Task { [weak self] in
                    let result = await Task.detached(priority: .userInitiated) { Result { try ArchiveReader.migrate(layout) } }.value
                    guard let self, self.archiveRoot == url, self.preparingArchive else { return }
                    self.preparingArchive = false
                    switch result {
                    case .success: _ = self.open(url, create: false)
                    case .failure(let error): self.openError = "\(error)"
                    }
                }
                return true
            }
            preparingArchive = false
            reader = try ArchiveReader(layout: layout)
            if url != archiveRoot || !knownArchives.contains(where: { $0.path == url.path }) { remember(url) }
            archiveRoot = url
            volumeEncrypted = layout.volumeIsEncrypted
            openError = nil
            selectedMessageID = nil
            do {
                goldLabels = try GoldStore(layout: layout).load()
            } catch {
                goldLoadError = "\(error)"
            }
            refresh()
            reloadUnfinishedJobs()
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

    func chooseArchive() { openArchive() }

    // MARK: Data

    func refresh() {
        guard let reader else { return }
        junkReview = try? reader.junkReview()
        suspiciousCount = (try? reader.count(MessageFilter(base: "is:verdächtig -is:junk"))) ?? 0
        memoryItems = (try? reader.memoryItems()) ?? []
        authServersCache = nil
        ownDomainsCache = nil
        relations = (try? reader.relations(includeRejected: true)) ?? []
        contentGeneration += 1
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
        case .trash: MessageFilter(trash: .only)
        case .spamReview: MessageFilter(base: "is:junk")
        case .suspicious: MessageFilter(base: "is:verdächtig -is:junk")
        case .all, nil: MessageFilter()
        }
    }

    func reloadList() {
        guard let reader else { return }
        reloading = true
        defer { reloading = false }
        var filter = scopeFilter
        // 5.7: by meaning ("~ text") or similar to a mail — a ranked list, not the parser's
        if let semantic = semanticText {
            query = nil
            queryError = nil
            if rankedMode != .semantic(semantic) {
                rankedMode = nil
                messageIDs = []
                listGeneration += 1
                startSemanticSearch(semantic)
                return
            }
        } else if case .semantic = rankedMode {
            rankedMode = nil
            rankedIDs = []
        }
        if rankedMode != nil {
            filter.ids = rankedIDs
            do {
                if let order = rankedSort {  // TJ: a column click sorts a ranked list too
                    messageIDs = try reader.messageIDs(filter, sort: order.sort, ascending: order.ascending)
                } else {
                    let rank = Dictionary(uniqueKeysWithValues: rankedIDs.enumerated().map { ($1, $0) })
                    messageIDs = try reader.messageIDs(filter).sorted { (rank[$0] ?? .max) < (rank[$1] ?? .max) }
                }
                listError = nil
            } catch {
                messageIDs = []
                listError = "\(error)"
            }
            listGeneration += 1
            return
        }
        // Untrimmed: a trailing space ends the live prefix of the last word (ADR-0008).
        let text = searchText.allSatisfy(\.isWhitespace) ? nil : searchText
        do throws(QueryError) {
            query = if let text { try QueryParser.parse(text) } else { nil }
            queryError = nil
        } catch {
            // "from:" while typing the value: keep the current list, no error yet — but only while
            // it is the list of this scope (review 4.7: the trash bar must never sit on another list).
            if searchText.hasSuffix(":"), var last = lastFilter {
                last.text = nil
                if last == filter { return }
            }
            // Otherwise fail closed: no list (and no groups) rather than a wider one.
            query = nil
            queryError = error.message
            messageIDs = []
            groups = []
            groupDetail = nil
            cleanupOverview = nil
            listGeneration += 1
            selectedMessageID = nil
            return
        }
        filter.text = text
        lastFilter = filter
        do {
            if let mode = viewMode.group {
                groups = try reader.groups(filter, by: mode)
                listError = nil
                if let id = selectedGroupID, !groups.contains(where: { $0.id == id }) {
                    selectedGroupID = nil  // didSet loads the overview
                } else {
                    loadGroupDetail()  // same group (or none), new scope or search
                }
                recordNavigation()
                return
            }
            messageIDs = try reader.messageIDs(filter, sort: sort, ascending: ascending)
            listError = nil
            explainEmptyResult(filter)
        } catch let error as QueryError {
            messageIDs = []
            groups = []
            groupDetail = nil
            cleanupOverview = nil
            queryError = String(localized: "Gespeicherte Suche: \(error.message)")
        } catch {
            messageIDs = []
            listError = "\(error)"  // an I/O error must not look like "no results"
        }
        listGeneration += 1
        if let sel = selectedMessageID, !messageIDs.contains(sel) { selectedMessageID = nil }
        // The table keeps only the open message selected after a reload: so does the model.
        selectedMessageIDs = selectedMessageID.map { [$0] } ?? []
        if listError == nil { recordNavigation() }
    }

    // MARK: Back / forward

    var canGoBack: Bool { history.canGoBack }
    var canGoForward: Bool { history.canGoForward }

    func goBack() { if history.canGoBack { restore(history.index - 1) } }
    func goForward() { if history.canGoForward { restore(history.index + 1) } }

    /// Returns to a station: view, scope, search, then its selection — without a new step.
    func restore(_ position: Int) {
        guard let entry = history.move(to: position) else { return }
        restoring = true
        defer { restoring = false }
        searchTask?.cancel()
        batching = true
        viewMode = entry.viewMode
        sidebarSelection = entry.sidebar
        setSearch(entry.searchText)
        batching = false
        reloadList()
        if entry.viewMode != .messages { selectedGroupID = entry.groupID }
        if let message = entry.messageID { reveal(message) } else { selectedMessageID = nil }
    }

    /// Search text set by the app (drill-downs, chips, buckets), not typed.
    func setSearch(_ text: String) {
        settingSearch = true
        searchText = text
        settingSearch = false
    }

    /// After a successful load: a new station, or the same place (only the selection moves).
    private func recordNavigation() {
        guard !restoring else { return }
        var entry = NavigationEntry(viewMode: viewMode, sidebar: sidebarSelection, searchText: searchText,
                                    groupID: viewMode == .messages ? nil : selectedGroupID,
                                    messageID: viewMode == .messages ? selectedMessageID : nil,
                                    label: "", typed: searchTyped, time: Date())
        entry.label = navigationLabel(entry)
        if let current = history.current, current.samePlace(as: entry) {
            history.updateCurrent { $0.groupID = entry.groupID; $0.messageID = entry.messageID; $0.label = entry.label }
            return
        }
        let keystroke = entry.typed && (history.current.map {
            $0.typed && $0.viewMode == entry.viewMode && $0.sidebar == entry.sidebar && entry.time.timeIntervalSince($0.time) < 4
        } ?? false)
        history.push(entry, replacingCurrent: keystroke)
    }

    /// A row clicked in the table: the current station remembers it.
    private func noteSelection() {
        guard !restoring, !reloading, let current = history.current else { return }
        var entry = current
        entry.groupID = viewMode == .messages ? nil : selectedGroupID
        entry.messageID = viewMode == .messages ? selectedMessageID : nil
        let label = navigationLabel(entry)
        history.updateCurrent { $0.groupID = entry.groupID; $0.messageID = entry.messageID; $0.label = label }
    }

    /// "Domains · Newsletter/Liste, ungelesen · krautreporter.de"
    private func navigationLabel(_ e: NavigationEntry) -> String {
        var parts: [String] = []
        switch e.viewMode {
        case .messages: parts.append(String(localized: "Nachrichten"))
        case .sender: parts.append(String(localized: "Absender"))
        case .domain: parts.append(String(localized: "Domains"))
        case .list: parts.append(String(localized: "Listen"))
        }
        switch e.sidebar {
        case .account(let a): parts.append(accounts.first { $0.id == a }?.name ?? a)
        case .mailbox(_, let m): parts.append(m)
        case .saved(let id): if let name = savedSearches.first(where: { $0.id == id })?.name { parts.append(name) }
        case .trash: parts.append(String(localized: "Papierkorb"))
        case .spamReview: parts.append(String(localized: "Spam-Prüfung"))
        case .suspicious: parts.append(String(localized: "Verdächtig"))
        case .all, nil: break
        }
        let search = e.searchText.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            let chips = (try? QueryParser.parse(search).chips.map(\.label)) ?? [search]
            let text = chips.joined(separator: ", ")
            parts.append(text.count > 60 ? String(text.prefix(60)) + "…" : text)
        }
        if let g = e.groupID, let group = groups.first(where: { $0.id == g }) {
            parts.append(group.name ?? group.key)
        } else if let m = e.messageID, let s = summaries([m]).first {
            parts.append(s.subject ?? String(localized: "(kein Betreff)"))
        }
        return DisplayText.safe(parts.joined(separator: " · "))
    }

    /// Where the user is (window subtitle, status line): the sidebar's place.
    var placeName: String {
        switch sidebarSelection {
        case .account(let a): accounts.first { $0.id == a }?.name ?? a
        case .mailbox(let a, let m): "\(accounts.first { $0.id == a }?.name ?? a) › \(m)"
        case .saved(let id): savedSearches.first { $0.id == id }?.name ?? String(localized: "Gespeicherte Suche")
        case .trash: String(localized: "Papierkorb")
        case .spamReview: String(localized: "Spam-Prüfung")
        case .suspicious: String(localized: "Verdächtig")
        case .all, nil: String(localized: "Alle Nachrichten")
        }
    }

    /// The status line's count, in the words of the place (TJ: "0 von 41.046 Nachrichten" in an
    /// empty "Verdächtig" read like an empty archive).
    var countText: String {
        let n = messageIDs.count
        let searching = !searchText.allSatisfy(\.isWhitespace)
        switch sidebarSelection {
        case .suspicious where !searching:
            return n == 0 ? String(localized: "Keine verdächtigen Mails") : n == 1 ? String(localized: "1 verdächtige Mail") : String(localized: "\(n) verdächtige Mails")
        case .spamReview where !searching:
            return String(localized: "\(n) im Spam-Ordner")
        case .trash where !searching:
            return String(localized: "\(n) im Papierkorb")
        default:
            return String(localized: "\(n) von \(stats?.messages ?? 0) Nachrichten")
        }
    }

    // MARK: Query helpers

    var suggestions: [QueryCompletion.Suggestion] {
        let folders = Set(accounts.flatMap(\.mailboxes).map(\.name)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return QueryCompletion.suggestions(for: searchText, folders: folders, accounts: accounts.map(\.id), labels: labels)
    }

    enum FilterUse { case show, add, exclude }

    /// A filter from the reader: show all such mails (whole archive, by date; Back returns), or
    /// add it to / exclude it from the current search.
    func apply(_ option: FilterOption, _ use: FilterUse) {
        switch use {
        case .show:
            searchTask?.cancel()
            batching = true
            viewMode = .messages
            sidebarSelection = .all
            setSearch(option.query + " ")
            batching = false
            reloadList()
            if let current = selectedMessageID { reveal(current) }  // it matches: keep it in view
        case .add:
            appendFilter(option.query)
        case .exclude:
            appendFilter(option.excluded)
        }
    }

    /// Replaces one top-level term (chip editor).
    func replaceChip(_ chip: QueryChip, with newText: String) {
        guard let range = currentRange(of: chip) else { return }
        var text = searchText
        text.replaceSubrange(range, with: newText.trimmingCharacters(in: .whitespaces))
        let rest = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        setSearch(rest.isEmpty ? "" : rest + " ")
    }

    /// The chip's range in the current text: its own if it still covers the same term, else
    /// found in a fresh parse (the text may have changed since the chips were made).
    private func currentRange(of chip: QueryChip) -> Range<String.Index>? {
        if chip.range.upperBound <= searchText.endIndex, String(searchText[chip.range]) == chip.text { return chip.range }
        return (try? QueryParser.parse(searchText).chips.first(where: { $0.text == chip.text }))?.range
    }

    /// Removes one top-level term from the search text.
    func removeChip(_ chip: QueryChip) {
        guard let rest = textWithout(chip) else { return }
        setSearch(rest)
    }

    private func textWithout(_ chip: QueryChip) -> String? {
        guard let range = currentRange(of: chip) else { return nil }
        var text = searchText
        text.removeSubrange(range)
        let rest = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return rest.isEmpty ? "" : rest + " "  // the trailing space keeps the last word exact
    }

    /// A term whose removal would give results back, for the "Keine Treffer" view (TJ: a search
    /// for large mails on the server found nothing — the archive holds only imports).
    struct EmptyHint: Identifiable {
        var id: String { chip.text }
        var chip: QueryChip
        var count: Int
    }

    private(set) var emptyHints: [EmptyHint] = []
    /// Whether any message in this archive has a known server location (imports have none).
    private(set) var archiveKnowsServers = true

    private func explainEmptyResult(_ filter: MessageFilter) {
        emptyHints = []
        guard messageIDs.isEmpty, viewMode == .messages, let reader, let chips = query?.chips, !chips.isEmpty else { return }
        for chip in chips.prefix(8) {
            guard let rest = textWithout(chip) else { continue }
            var without = filter
            without.text = rest.isEmpty ? nil : rest
            if let n = try? reader.count(without), n > 0 { emptyHints.append(EmptyHint(chip: chip, count: n)) }
        }
        emptyHints.sort { $0.count > $1.count }
        if chips.contains(where: { $0.text.lowercased().contains("on:server") }) {
            archiveKnowsServers = ((try? reader.count(MessageFilter(text: "on:server "))) ?? 1) > 0
        } else {
            archiveKnowsServers = true
        }
    }

    /// Cleanup view → the group's messages: back to the list, narrowed by the group's exact query.
    func openGroup(_ group: MessageGroup) {
        appendFilter(group.query)
        viewMode = .messages
    }

    // MARK: Rules (6.5b)

    private(set) var mailRules: [MailRule] = []
    private(set) var ruleReady: [String: Int] = [:]
    private(set) var ruleSuggestions: [RuleSuggestion] = []
    private(set) var loadingRules = false

    /// Rules, what the destructive ones would act on now, and suggestions from repeated decisions.
    func reloadRules() {
        guard let layout = reader?.layout, !loadingRules else { return }
        loadingRules = true
        Task {
            let result = await Task.detached(priority: .utility) { () -> ([MailRule], [String: Int], [RuleSuggestion])? in
                guard let r = try? ArchiveReader(layout: layout) else { return nil }
                let rules = (try? r.rules(includeRejected: true)) ?? []
                var ready: [String: Int] = [:]
                for rule in rules where rule.active && rule.action.isDestructive { ready[rule.id] = (try? r.ready(rule)) ?? 0 }
                return (rules, ready, (try? r.ruleSuggestions(audit: AuditLog().entries())) ?? [])
            }.value
            loadingRules = false
            guard reader?.layout.root == layout.root, let result else { return }
            (mailRules, ruleReady, ruleSuggestions) = result
        }
    }

    func saveRule(id: String?, name: String, query: String, action: MailRule.Action) async -> String? {
        let problem = await writeNow { writer in
            try await writer.saveRule(id: id, name: name, query: query, action: action)
            _ = try await writer.applyCategoryRules()
        }
        reloadRules()
        contentGeneration += 1
        return problem
    }

    /// After a sync: destructive rules with mails ready are mentioned in the status line.
    func noteReadyRules() {
        guard let reader else { return }
        let ready = ((try? reader.rules()) ?? []).filter(\.action.isDestructive).map { (try? reader.ready($0)) ?? 0 }.reduce(0, +)
        guard ready > 0 else { return }
        syncMessage = [syncMessage, String(localized: "Regeln: \(ready) Mails bereit (Aufräumen › Vorschläge oder Einstellungen › Regeln)")]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
        reloadRules()
    }

    func rejectRule(_ s: RuleSuggestion) async -> String? {
        let problem = await writeNow { writer in try await writer.rejectRule(name: s.name, query: s.query, action: s.action) }
        reloadRules()
        return problem
    }

    func forgetRule(_ id: String) async -> String? {
        let problem = await writeNow { writer in
            try await writer.forgetMemory([id])
            _ = try await writer.applyCategoryRules()
        }
        reloadRules()
        contentGeneration += 1
        return problem
    }

    /// A destructive rule: its mails through the plan sheet (ADR-0006) — never by itself.
    func runRule(_ rule: MailRule) {
        switch rule.action {
        case .category: return
        case .serverDelete(let days):
            plan(.serverDelete, filter: MessageFilter(text: "(\(rule.query)) "), title: rule.name, graceDays: days)
        case .moveToJunk:
            plan(.moveToJunk, filter: MessageFilter(text: "(\(rule.query)) -is:junk "), title: rule.name)  // an OR inside stays inside (review 6 R4)
        }
    }

    /// For the rule editor: how many mails a query covers (nil: not valid search language).
    func ruleMatches(_ query: String) -> Int? {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return try? reader?.count(MessageFilter(text: query + " "))
    }

    var rulesReadyTotal: Int { ruleReady.values.reduce(0, +) }

    // MARK: Cleanup suggestions (6.5a)

    private(set) var cleanupSuggestions: [CleanupSuggestion] = []
    private(set) var loadingSuggestions = false

    func reloadSuggestions() {
        guard let layout = reader?.layout, !loadingSuggestions else { return }
        loadingSuggestions = true
        Task {
            let result = await Task.detached(priority: .utility) { (try? ArchiveReader(layout: layout).cleanupSuggestions()) ?? [] }.value
            loadingSuggestions = false
            guard reader?.layout.root == layout.root else { return }
            cleanupSuggestions = result
        }
    }

    /// "Ansehen": the suggestion's mails in the list, all mailboxes.
    func showSuggestion(_ s: CleanupSuggestion) {
        viewMode = .messages
        setSearch(s.query + " ")
        sidebarSelection = .all  // reloads with the new search text
    }

    /// "Vom Server löschen …" / "Aus dem Archiv löschen …": the plan sheet, as everywhere.
    func planSuggestion(_ s: CleanupSuggestion, _ kind: ActionKind) {
        plan(kind, filter: MessageFilter(text: s.query + " "), title: s.title)
    }

    /// A newsletter's groups (unsubscribe lives there): the list shows only them — the suggestion's
    /// search stands in the search field — and the biggest is selected (TJ: the view jumped and
    /// the selected group was somewhere off screen).
    func openSuggestionGroup(_ s: CleanupSuggestion) {
        guard let group = s.group else { return }
        viewMode = group.mode == .list ? .list : group.mode == .domain ? .domain : .sender
        setSearch(s.query + " ")
        sidebarSelection = .all  // reloads with the new search text
        selectedGroupID = group.id
    }

    /// Only what the right-hand pane shows: the selected group's details, else the overview.
    private func loadGroupDetail() {
        guard let reader, let filter = lastFilter, viewMode != .messages else { return }
        if let id = selectedGroupID, let group = groups.first(where: { $0.id == id }) {
            groupDetail = try? reader.groupDetail(group, within: filter)
            cleanupOverview = nil
        } else {
            groupDetail = nil
            var base = filter
            base.text = Self.removing(ArchiveReader.cleanupBuckets.map(\.query).filter(isBucketActive), from: searchText)
            cleanupOverview = try? reader.cleanupOverview(base)
        }
    }

    // MARK: Overview buckets — one at a time (TJ combined several, nothing was left, nothing said why)

    /// A bucket is active when all its terms stand in the search as top-level terms.
    func isBucketActive(_ query: String) -> Bool {
        let chips = Set(self.query?.chips.map(\.text) ?? [])
        let terms = query.split(separator: " ").map(String.init)
        return !terms.isEmpty && terms.allSatisfy(chips.contains)
    }

    /// Click on a bucket: turns it off, or replaces the active one with it.
    func toggleBucket(_ bucket: CleanupOverview.Bucket) {
        let active = ArchiveReader.cleanupBuckets.map(\.query).filter(isBucketActive)
        let wasActive = active.contains(bucket.query)
        var text = Self.removing(active, from: searchText)
        if !wasActive { text = (text.isEmpty ? "" : text) + bucket.query + " " }
        setSearch(text)
    }

    func clearBuckets() {
        setSearch(Self.removing(ArchiveReader.cleanupBuckets.map(\.query).filter(isBucketActive), from: searchText))
    }

    /// The search text without the given queries' terms (top-level terms only), normalised.
    private static func removing(_ queries: [String], from text: String) -> String {
        let terms = Set(queries.flatMap { $0.split(separator: " ").map(String.init) })
        guard !terms.isEmpty, let parsed = try? QueryParser.parse(text) else { return text }
        var result = text
        for chip in parsed.chips.reversed() where terms.contains(chip.text) {
            result.removeSubrange(chip.range)  // back to front: earlier ranges stay valid
        }
        let rest = result.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return rest.isEmpty ? "" : rest + " "
    }

    /// One of the group's recent mails: the group's messages in the list, that mail selected.
    func openMessage(_ id: Int64, of group: MessageGroup) {
        appendFilter(group.query)
        viewMode = .messages
        reveal(id)
    }

    /// From a domain or list group to one of its senders.
    func showSender(_ address: String) {
        viewMode = .sender
        selectedGroupID = "\(GroupMode.sender.rawValue):\(address)"
    }

    /// A saved view for exactly this group within the current scope and search.
    func savedSearch(for group: MessageGroup) -> SavedSearch {
        let text = [searchText.trimmingCharacters(in: .whitespaces), group.query].filter { !$0.isEmpty }.joined(separator: " ") + " "
        let query: String = switch sidebarSelection {
        case .account(let a): SavedSearchStore.query(account: a, text: text)
        case .mailbox(let a, let m): SavedSearchStore.query(account: a, mailbox: m, text: text)
        case .saved(let id): SavedSearchStore.query(base: savedSearches.first { $0.id == id }?.query, text: text)
        case .spamReview: SavedSearchStore.query(base: "is:junk", text: text)
        case .suspicious: SavedSearchStore.query(base: "is:verdächtig -is:junk", text: text)
        case .all, .trash, nil: SavedSearchStore.query(text: text)
        }
        return SavedSearch(name: group.name ?? group.key, query: query)
    }

    /// Appends a filter term (from the Filter menu) to the search text.
    func appendFilter(_ term: String) {
        let base = searchText.trimmingCharacters(in: .whitespaces)
        setSearch((base.isEmpty ? "" : base + " ") + term + " ")
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
        switch sidebarSelection {
        case .account(let a): SavedSearchStore.query(account: a, text: searchText)
        case .mailbox(let a, let m): SavedSearchStore.query(account: a, mailbox: m, text: searchText)
        case .saved(let id): SavedSearchStore.query(base: savedSearches.first { $0.id == id }?.query, text: searchText)
        case .spamReview: SavedSearchStore.query(base: "is:junk", text: searchText)
        case .suspicious: SavedSearchStore.query(base: "is:verdächtig -is:junk", text: searchText)
        case .all, .trash, nil: SavedSearchStore.query(text: searchText)
        }
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
        setSearch("")
        sidebarSelection = .saved(id)
    }

    func deleteSavedSearch(_ id: UUID) {
        guard let layout = reader?.layout else { return }
        try? SavedSearchStore(layout: layout).remove(id)
        if case .saved(id) = sidebarSelection { sidebarSelection = .all }
        reloadSavedSearches()
    }

    func setSort(_ sort: MessageSort, ascending: Bool) {
        if rankedMode != nil {  // a ranked list keeps its own order; the list behind it keeps its sort
            guard rankedSort?.sort != sort || rankedSort?.ascending != ascending else { return }
            rankedSort = (sort, ascending)
            reloadList()
            return
        }
        guard sort != self.sort || ascending != self.ascending else { return }
        self.sort = sort
        self.ascending = ascending
        reloadList()
    }

    /// The order the table header shows: a column, or none while a ranked list is by score.
    var tableSort: (sort: MessageSort, ascending: Bool)? {
        rankedMode != nil ? rankedSort : (sort, ascending)
    }

    /// Back to "most similar first".
    func sortRankedByScore() {
        guard rankedMode != nil, rankedSort != nil else { return }
        rankedSort = nil
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
        setSearch(query + " ")
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
        guard let root = archiveRoot, reader != nil, !importRunning, !syncRunning, !actionRunning else { return }
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
                // In a function of its own: the writer (and its archive lock) is gone when it
                // returns, before the PDF queue tries to open one.
                let result = try await Self.runImport(kind, source: source, account: account, root: root, progress: report)
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

    private nonisolated static func runImport(_ kind: ImportKind, source: URL, account: String, root: URL,
                                              progress: @escaping @Sendable (ImportProgress) -> Void) async throws -> ImportProgress {
        let writer = try ArchiveWriter(layout: try ArchiveLayout.open(at: root, create: true))
        switch kind {
        case .maildir: return try await MaildirImporter(root: source, account: account).run(writer: writer, progress: progress)
        case .mbox: return try await MboxImporter(file: source, account: account).run(writer: writer, progress: progress)
        case .eml: return try await EMLImporter(root: source, account: account).run(writer: writer, progress: progress)
        }
    }

    func dismissImportStatus() {
        importStatus = nil
    }

    // MARK: Actions (Phase 4, ADR-0006: plan -> execute -> verify -> audit)

    /// The selected rows, or the open message when only one is selected.
    var actionSelection: [Int64] {
        selectedMessageIDs.count > 1 ? Array(selectedMessageIDs) : (selectedMessageID.map { [$0] } ?? [])
    }

    func planSelection(_ kind: ActionKind) {
        let ids = actionSelection
        guard !ids.isEmpty else { return }
        plan(kind, filter: MessageFilter(ids: ids), title: ids.count == 1 ? String(localized: "1 ausgewählte Mail")
                                                                        : String(localized: "\(ids.count) ausgewählte Mails"))
    }

    func planGroup(_ kind: ActionKind, _ group: MessageGroup) {
        guard var filter = lastFilter else { return }
        filter.also.append(group.query)
        plan(kind, filter: filter, title: group.name ?? group.key)
    }

    func plan(_ kind: ActionKind, filter: MessageFilter, title: String, graceDays: Int = 30, restore: RestoreOptions = RestoreOptions()) {
        guard let reader else { return }
        do {
            let planned: (ActionJob, ActionPlanSummary)
            switch kind {
            case .serverDelete: planned = try reader.planServerDelete(filter, title: title, accounts: accountConfigs, graceDays: graceDays)
            case .archiveDelete: planned = try reader.planArchiveDelete(filter, title: title)
            case .restore: planned = try reader.planRestore(filter, title: title, accounts: accountConfigs, options: restore)
            case .moveToInbox: planned = try reader.planRescue(filter, title: title, accounts: accountConfigs)
            case .moveToJunk: planned = try reader.planMarkSpam(filter, title: title, accounts: accountConfigs)
            case .export, .unsubscribe: return
            }
            let examples = try reader.summaries(Array(try reader.messageIDs(filter).prefix(5)))
            pendingPlan = PlannedAction(job: planned.0, summary: planned.1, filter: filter, examples: examples)
        } catch {
            actionError = "\(error)"
        }
    }

    /// Plan sheet: another grace period, same selection.
    func replan(_ plan: PlannedAction, graceDays: Int) {
        self.plan(plan.job.kind, filter: plan.filter, title: plan.job.title, graceDays: graceDays)
        pendingPlan?.id = plan.id  // same sheet, new numbers
    }

    // MARK: Export (4.6)

    /// The selected messages (in the trash view: from the trash).
    func exportSelection() {
        let ids = actionSelection
        guard !ids.isEmpty else { return }
        var filter = MessageFilter(ids: ids)
        if sidebarSelection == .trash { filter.trash = .only }
        prepareExport(filter, title: ids.count == 1 ? String(localized: "1 ausgewählte Mail") : String(localized: "\(ids.count) ausgewählte Mails"))
    }

    /// Everything the list shows (search, folder, filters).
    func exportResults() {
        guard let lastFilter else { return }
        prepareExport(lastFilter, title: String(localized: "Alle Mails der Liste"))
    }

    var canExportResults: Bool { lastFilter != nil && !messageIDs.isEmpty }

    private func prepareExport(_ filter: MessageFilter, title: String) {
        guard let reader else { return }
        do {
            let totals = try reader.totals(filter)
            pendingExport = ExportRequest(filter: filter, title: title, count: totals.count, bytes: totals.bytes)
        } catch {
            actionError = "\(error)"
        }
    }

    /// Asks where to, then writes in the background (progress and stop in the status bar).
    func runExport(_ request: ExportRequest, format: ExportFormat) {
        guard let layout = reader?.layout, !actionRunning, !syncRunning, !importRunning else { return }
        let destination: URL
        switch format {
        case .eml:
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Exportieren")
            panel.message = String(localized: "Ordner für die .eml-Dateien – am besten ein neuer, leerer. Vorhandene Dateien werden nie überschrieben.")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        case .mbox:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "MailKeeper-Export.mbox"
            panel.canCreateDirectories = true
            panel.prompt = String(localized: "Exportieren")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }
        pendingExport = nil
        let filter = request.filter
        actionRunning = true
        actionProgress = ActionRunProgress(title: String(localized: "Exportieren"), done: 0, total: request.count, failed: 0, resumable: false)
        // the PDF queue pauses (its expiry purge could remove a trashed blob mid-export)
        let indexing = pauseTextIndexing()
        actionTask = Task.detached { [weak self] in
            await indexing?.value
            let accessing = destination.startAccessingSecurityScopedResource()
            defer { if accessing { destination.stopAccessingSecurityScopedResource() } }
            var report: ExportReport?
            var problem: String?
            do {
                let items = try ArchiveReader(layout: layout).exportItems(filter)  // off the main thread
                // mbox: the save panel confirmed replacing an existing file
                report = try await ArchiveExporter(blobs: layout.blobs).export(items, format: format, to: destination,
                                                                               replace: format == .mbox) { done, total in
                    Task { @MainActor in self?.actionProgress?.done = done; self?.actionProgress?.total = total }
                }
            } catch is CancellationError {
                problem = format == .mbox ? String(localized: "Export abgebrochen; es ist keine mbox-Datei entstanden, eine ersetzte bleibt wie sie war.")
                                          : String(localized: "Export abgebrochen; die schon geschriebenen Dateien bleiben.")
            } catch {
                problem = "\(error)"
            }
            await MainActor.run {
                guard let self else { return }
                self.actionRunning = false
                self.actionProgress = nil
                self.actionTask = nil
                if let report { self.exportResult = report }
                if let problem { self.actionError = problem }
                self.startTextIndexing()
            }
        }
    }

    func revealExport(_ report: ExportReport) {
        if report.destination.hasDirectoryPath || (try? report.destination.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            NSWorkspace.shared.open(report.destination)  // the eml folder itself
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([report.destination])
        }
    }

    /// Plan sheet: another destination or date for a restore, same selection.
    func replan(_ plan: PlannedAction, restore: RestoreOptions) {
        self.plan(.restore, filter: plan.filter, title: plan.job.title, restore: restore)
        pendingPlan?.id = plan.id
    }

    /// Where a restore may go: mailboxes of the accounts set up here that MailKeeper syncs
    /// (known in the archive, inside the account's selection) — never one it does not look at.
    var restoreTargets: [(account: String, mailboxes: [String])] {
        accountConfigs.compactMap { config in
            let boxes = (accounts.first { $0.id == config.id }?.mailboxes.map(\.name) ?? [])
                .filter(config.policy.mayContain)
            return boxes.isEmpty ? nil : (config.id, boxes)
        }
    }

    /// Kind of an account set up here (the plan sheet mentions Proton's slow uploads).
    func accountKind(_ id: String) -> AccountConfig.Kind? { accountConfigs.first { $0.id == id }?.kind }

    /// The user's go: store the job, run it in the background (the PDF queue pauses, like for
    /// import and sync), show the result.
    func execute(_ plan: PlannedAction) {
        guard let root = archiveRoot, !actionRunning, !syncRunning, !importRunning else { return }
        pendingPlan = nil
        let job = plan.job, stored = plan.stored
        let accounts = accountConfigs, credentials = self.credentials, audit = self.audit
        actionRunning = true
        actionProgress = ActionRunProgress(title: Self.actionTitle(job.kind), done: 0, total: job.open.count, failed: 0)
        let indexing = pauseTextIndexing()
        actionTask = Task.detached { [weak self] in
            await indexing?.value  // the queue holds the writer until it has stopped
            var result: ActionJob?
            var problem: String?
            do {
                let layout = try ArchiveLayout.open(at: root, create: false)
                if !stored { try ActionStore(layout: layout).create(job) }
                result = try await Self.run(job.id, kind: job.kind, layout: layout, accounts: accounts, credentials: credentials,
                                            audit: audit) { done, total, failed in
                    Task { @MainActor in self?.actionProgress?.done = done; self?.actionProgress?.total = total; self?.actionProgress?.failed = failed }
                }
            } catch is CancellationError {
                problem = String(localized: "Abgebrochen. Erledigtes bleibt erledigt; der Rest lässt sich fortsetzen.")
            } catch {
                problem = "\(error)"
            }
            await MainActor.run {
                guard let self else { return }
                self.actionRunning = false
                self.actionProgress = nil
                self.actionTask = nil
                if let result { self.actionResult = result }
                if let problem { self.actionError = problem }
                self.refresh()
                self.reloadUnfinishedJobs()
                self.startTextIndexing()
            }
        }
    }

    private nonisolated static func run(_ id: UUID, kind: ActionKind, layout: ArchiveLayout, accounts: [AccountConfig],
                                        credentials: CredentialStore, audit: AuditLog,
                                        progress: @escaping @Sendable (Int, Int, Int) -> Void) async throws -> ActionJob {
        let writer = try ArchiveWriter(layout: layout)
        switch kind {
        case .serverDelete:
            return try await SyncCoordinator.deleteOnServer(id, writer: writer, accounts: accounts, credentials: credentials,
                                                            audit: audit) { p in progress(p.done + p.failed + p.skipped, p.total, p.failed) }
        case .archiveDelete:
            return try await ArchiveDeleteExecutor(writer: writer, store: ActionStore(layout: layout), audit: audit).run(id) { d, t in
                progress(d, t, 0)
            }
        case .restore:
            return try await SyncCoordinator.restoreOnServer(id, writer: writer, accounts: accounts, credentials: credentials,
                                                             audit: audit) { p in progress(p.done + p.failed + p.skipped, p.total, p.failed) }
        case .moveToInbox:
            return try await SyncCoordinator.rescueToInbox(id, writer: writer, accounts: accounts, credentials: credentials,
                                                           audit: audit) { p in progress(p.done + p.failed + p.skipped, p.total, p.failed) }
        case .moveToJunk:
            return try await SyncCoordinator.moveToJunk(id, writer: writer, accounts: accounts, credentials: credentials,
                                                        audit: audit) { p in progress(p.done + p.failed + p.skipped, p.total, p.failed) }
        case .export, .unsubscribe:
            return try ActionStore(layout: layout).load(id)
        }
    }

    /// Plan sheet rows: per account (server delete) or per target mailbox (restore).
    private static func perTarget(_ items: [ActionItem]) -> [String: Int] {
        var out: [String: Int] = [:]
        for i in items {
            if let a = i.location?.account { out[a, default: 0] += 1 } else if let t = i.target { out["\(t.account) › \(t.mailbox)", default: 0] += 1 }
        }
        return out
    }

    func cancelAction() { actionTask?.cancel() }

    /// The failed items as a new job, through the plan sheet again.
    func retryFailed(_ job: ActionJob) {
        let failed = job.items.filter { $0.state == .failed }
        guard !failed.isEmpty else { return }
        let items = failed.enumerated().map { n, item -> ActionItem in
            var i = item
            i.id = n
            i.state = .planned
            i.reason = nil
            return i
        }
        var retry = ActionJob(kind: job.kind, title: job.title, query: job.query, graceDays: job.graceDays, restore: job.restore, items: items)
        retry.title = String(localized: "\(job.title) – erneut")
        actionResult = nil
        pendingPlan = PlannedAction(job: retry, summary: ActionPlanSummary(messages: items.count, archiveOnly: 0, perAccount: Self.perTarget(items)),
                                    filter: MessageFilter(ids: []), examples: [])
    }

    /// Jobs a crash or quit interrupted (planned or claimed items left).
    func reloadUnfinishedJobs() {
        guard let layout = reader?.layout else { unfinishedJobs = []; return }
        let (jobs, broken) = ActionStore(layout: layout).load()
        unfinishedJobs = jobs.filter { !$0.isFinished }
        if !broken.isEmpty {
            actionError = String(localized: "\(broken.count) Auftragsdateien waren nicht lesbar und liegen jetzt unter queue/broken im Archiv (nichts wurde ausgeführt).")
        }
    }

    func resume(_ job: ActionJob) {
        pendingPlan = PlannedAction(job: job, summary: ActionPlanSummary(messages: job.open.count, archiveOnly: 0, perAccount: Self.perTarget(job.open)),
                                    filter: MessageFilter(ids: []), examples: [], stored: true)
    }

    func discard(_ job: ActionJob) {
        guard let layout = reader?.layout else { return }
        try? ActionStore(layout: layout).cancel(job: job.id)
        reloadUnfinishedJobs()
    }

    static func actionTitle(_ kind: ActionKind) -> String {
        switch kind {
        case .serverDelete: String(localized: "Auf dem Server löschen")
        case .archiveDelete: String(localized: "Aus dem Archiv löschen")
        case .restore: String(localized: "Auf den Server zurückspielen")
        case .export: String(localized: "Exportieren")
        case .moveToInbox: String(localized: "Kein Spam → Posteingang")
        case .moveToJunk: String(localized: "Ist Spam → Spam-Ordner")
        case .unsubscribe: String(localized: "Vom Newsletter abmelden")
        }
    }

    // MARK: Archive trash

    /// Back from the trash (not destructive: no queue, no confirmation).
    func restoreSelection() {
        guard let reader, let identities = try? reader.identities(of: actionSelection), !identities.isEmpty else { return }
        withWriter { _ = try await $0.untrash(identities) }
    }

    /// Deleting for good asks for Touch ID or the password first (ADR-0006).
    func purgeSelection() async {
        // only what is in the trash, whatever the list shows (the writer checks again)
        guard let reader, let trashed = try? Set(reader.trashedIdentities()),
              let identities = try? reader.identities(of: actionSelection).filter(trashed.contains), !identities.isEmpty else { return }
        guard await authenticate(String(localized: "\(identities.count) Mails endgültig aus dem Archiv löschen")) else { return }
        withWriter { _ = try await $0.purge(identities) }
    }

    func emptyTrash() async {
        guard let reader, let identities = try? reader.trashedIdentities(), !identities.isEmpty else { return }
        guard await authenticate(String(localized: "Den Papierkorb des Archivs leeren (\(identities.count) Mails)")) else { return }
        withWriter { _ = try await $0.purge(identities) }
    }

    private func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            actionError = String(localized: "Ohne Touch ID oder Passwort kann nicht endgültig gelöscht werden.")
            return false
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// A short writer job (trash, untrash, purge): pauses the PDF queue, refreshes afterwards.
    private func withWriter(_ work: @escaping @Sendable (ArchiveWriter) async throws -> Void) {
        Task {
            if let problem = await writeNow(work) { actionError = problem }
            selectedMessageIDs = []
        }
    }

    /// Runs `work` with the archive's writer (background indexing paused meanwhile) and says what
    /// went wrong — also that MailKeeper is busy, which used to drop the request silently.
    private func writeNow(_ work: @escaping @Sendable (ArchiveWriter) async throws -> Void) async -> String? {
        guard let root = archiveRoot else { return nil }
        guard !actionRunning, !syncRunning, !importRunning else {
            return String(localized: "MailKeeper ist gerade beschäftigt (Abruf, Import oder eine Aktion) – bitte gleich noch einmal.")
        }
        actionRunning = true
        let indexing = pauseTextIndexing()
        let problem: String? = await Task.detached {
            await indexing?.value
            do {
                try await work(try ArchiveWriter(layout: try ArchiveLayout.open(at: root, create: false)))
                return nil
            } catch {
                return "\(error)"
            }
        }.value
        actionRunning = false
        guard archiveRoot == root else { return problem }
        refresh()
        startTextIndexing()
        return problem
    }

    // MARK: Relationship register (6.3, ADR-0010 §6)

    private(set) var relations: [Relation] = []
    private(set) var relationSuggestions: [RelationSuggestion] = []
    private(set) var loadingRelations = false

    /// Reads the register and computes the suggestions off the main thread.
    func reloadRelations() {
        guard let layout = reader?.layout, !loadingRelations else { return }
        loadingRelations = true
        Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([Relation], [RelationSuggestion])? in
                guard let r = try? ArchiveReader(layout: layout) else { return nil }
                return ((try? r.relations(includeRejected: true)) ?? [], (try? r.relationSuggestions()) ?? [])
            }.value
            loadingRelations = false
            guard reader?.layout.root == layout.root, let result else { return }
            (relations, relationSuggestions) = result
        }
    }

    private var authServersCache: [String: Set<String>]?
    private var ownDomainsCache: Set<String>?
    private var warningsRefreshed = false

    /// The register's and the own server's word on a message (reader "Echtheit").
    func relationCheck(_ messageID: Int64) -> RelationCheck? {
        guard let reader else { return nil }
        if authServersCache == nil { authServersCache = try? reader.ownAuthServers() }
        return try? reader.relationCheck(of: messageID, relations: relations.isEmpty ? nil : relations.filter(\.confirmed),
                                         servers: authServersCache)
    }

    /// "Abmelden" (6.5c): the check, with the cached own servers, relations and own domains
    /// (review 6.5c S2 — it runs for every message shown and every cleanup group).
    func unsubscribeAssessment(_ id: Int64) -> UnsubscribeAssessment? {
        guard let reader else { return nil }
        if authServersCache == nil { authServersCache = try? reader.ownAuthServers() }
        if ownDomainsCache == nil { ownDomainsCache = try? reader.ownDomains() }
        return try? reader.unsubscribeAssessment(for: id, relations: relations.isEmpty ? nil : relations.filter(\.confirmed),
                                                 servers: authServersCache, ownDomains: ownDomainsCache)
    }

    /// "Gehört dazu": the sender's domain joins the relation it was taken for a look-alike of.
    func addDomain(_ domain: String, to relation: Relation) async -> String? {
        await saveRelation(id: relation.id, name: relation.name, domains: relation.domains + [domain], since: relation.since, until: relation.until)
    }

    /// Other mails of these domains a model holds for phishing or spam (for "Einschätzung korrigieren").
    func modelFlagged(fromDomains domains: Set<String>, name: String?, excluding id: Int64) -> [Int64] {
        (try? reader?.modelFlagged(fromDomains: domains, orName: name, excluding: id)) ?? []
    }

    func proposedRelation(for id: Int64, replyTo: String?) -> ProposedRelation {
        (try? reader?.proposedRelation(for: id, replyTo: replyTo)) ?? ProposedRelation(name: "", domains: [])
    }

    /// "Einschätzung korrigieren" (6.4b, TJ): the user's word that the mail is genuine
    /// (journalled; ends phishing and spam), optionally a note for the model and a relation as a
    /// firm rule — then this mail and the alike ones go to the model again with that knowledge.
    func correctVerdict(messageID: Int64, note: String?, noteDomain: String, relation: (id: String?, name: String, domains: [String])?,
                        recheck: [Int64]) async -> String? {
        guard let reader, let identity = try? reader.identities(of: [messageID]).first else { return nil }
        let existing = relation.flatMap { r in r.id.flatMap { id in relations.first { $0.id == id } } }
        let problem = await writeNow { writer in
            try await writer.confirmNotSpam(identity: identity)
            if let note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try await writer.saveNote(kind: .preference, text: note, subject: "domain:" + noteDomain)
            }
            if let relation {
                try await writer.saveRelation(id: relation.id, name: relation.name, domains: relation.domains,
                                              since: existing?.since, until: existing?.until)
                try await writer.refreshWarnings()
            }
        }
        reloadRelations()
        if problem == nil, aiConfig.enabled, !recheck.isEmpty {
            runClassification([messageID] + recheck.filter { $0 != messageID }, title: String(localized: "Neu einordnen"))
        }
        contentGeneration += 1
        return problem
    }

    func addPublicAddress(_ address: String) async -> String? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard a.contains("@"), !a.contains(" ") else { return String(localized: "Bitte eine Mailadresse eingeben, z. B. kontakt@beispiel.de") }
        return await saveNote(id: nil, kind: .preference, text: String(localized: "Öffentliche Adresse – Erstkontakte dort sind unaufgefordert"),
                              subject: "public:" + a, scope: "")
    }

    var publicAddressItems: [MemoryItem] { memoryItems.filter { $0.subject.hasPrefix("public:") } }

    func saveRelation(id: String?, name: String, domains: [String], since: Date?, until: Date?) async -> String? {
        let problem = await writeNow { writer in
            try await writer.saveRelation(id: id, name: name, domains: domains, since: since, until: until)
            try await writer.refreshWarnings()  // review 6 S1: "Verdächtig" follows the register
        }
        reloadRelations()
        return problem
    }

    func rejectRelation(_ suggestion: RelationSuggestion) async -> String? {
        let problem = await writeNow { writer in
            try await writer.rejectRelation(name: suggestion.name, domains: suggestion.domains)
            try await writer.refreshWarnings()
        }
        reloadRelations()
        return problem
    }

    func forgetRelation(_ id: String) async -> String? {
        let problem = await writeNow { writer in
            try await writer.forgetMemory([id])
            try await writer.refreshWarnings()
        }
        reloadRelations()
        return problem
    }

    // MARK: Memory (6.1, ADR-0005)

    private(set) var memoryItems: [MemoryItem] = []

    func reloadMemory() {
        memoryItems = (try? reader?.memoryItems()) ?? []
    }

    /// "Art ändern": the user's category for these mails — journalled, an example for the memory.
    func setUserCategory(_ category: MailCategory, ids: [Int64]) {
        guard let reader, let identities = try? reader.identities(of: Array(ids.prefix(Self.maxClassify))), !identities.isEmpty else { return }
        withWriter { writer in
            for identity in identities { try await writer.setUserClassification(identity: identity, category: category) }
        }
    }

    /// One line of "Warum?": a memory item the model saw, or the sender profile (as of now).
    struct WhyLine: Identifiable {
        var id: String
        var title: String
        var detail: [String]
        var forgettable: Bool
    }

    func why(_ messageID: Int64) -> [WhyLine] {
        guard let reader, let sources = try? reader.suggestionSources(of: messageID) else { return [] }
        return sources.compactMap { source in
            if source.hasPrefix("profile:") {
                guard let profile = try? reader.senderProfile(of: messageID) else { return nil }
                return WhyLine(id: source, title: String(localized: "Absenderprofil \(profile.address) (Stand jetzt)"), detail: profile.lines, forgettable: false)
            }
            guard let item = try? reader.memoryItem(source) else { return nil }
            let title: String = switch item.kind {
            case .example: String(localized: "Deine Entscheidung")
            case .vocabulary: String(localized: "Dein Begriff")
            case .relation: String(localized: "Deine Beziehung")
            case .rule: String(localized: "Deine Regel")
            default: String(localized: "Deine Notiz")
            }
            return WhyLine(id: source, title: title + (item.active ? "" : String(localized: " (inzwischen vergessen)")),
                           detail: [item.summary], forgettable: item.active)
        }
    }

    func saveNote(id: String?, kind: MemoryKind, text: String, subject: String, scope: String) async -> String? {
        await writeNow { writer in try await writer.saveNote(id: id, kind: kind, text: text, subject: subject, scope: scope) }
    }

    func forgetMemory(_ ids: [String]) async -> String? {
        let rules = ids.contains { $0.hasPrefix("rule:") }
        let problem = await writeNow { writer in
            try await writer.forgetMemory(ids)
            if rules { _ = try await writer.applyCategoryRules() }  // its labels go with it (review 6 R1)
        }
        if rules {
            reloadRules()
            contentGeneration += 1
        }
        return problem
    }

    func exportMemory() -> String? {
        guard let reader else { return nil }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "MailKeeper-Gedaechtnis.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        do {
            try reader.exportMemory().write(to: url, options: [.atomic])
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Notes, terms, rules and relations from a file; returns a message for the view.
    func importMemory() async -> String? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard let data = try? Data(contentsOf: url) else { return String(localized: "Die Datei ließ sich nicht lesen.") }
        let count = Mutex(0)
        if let problem = await writeNow({ writer in let n = try await writer.importMemory(data); count.withLock { $0 = n } }) { return problem }
        let n = count.withLock { $0 }
        return n == 0 ? String(localized: "Nichts Neues in der Datei.") : String(localized: "\(n) Einträge übernommen (Notizen, Begriffe, Regeln, Beziehungen).")
    }

    // MARK: PDF text (ADR-0009)

    /// Runs the background queue when there is work and the writer is free (no import, no
    /// sync, no mkctl holding the archive — then it simply tries again next time).
    func startTextIndexing() {
        guard let root = archiveRoot, let reader, textIndexTask == nil, !syncRunning, !importRunning, !actionRunning else { return }
        textStats = try? reader.attachmentTextStats()
        let expired = (stats?.trashed ?? 0) > 0  // may hold mail older than 30 days to purge
        let rules = ((try? reader.heuristicPendingCount()) ?? 0) > 0  // categories by rule (5.4)
        let headers = ((try? reader.headerFieldsPending()) ?? 0) > 0  // authentication and delivery (6.3)
        let categoryRules = ((try? reader.rules()) ?? []).contains { !$0.action.isDestructive }  // the user's rules (6.5b)
        let warnings = !warningsRefreshed  // once per launch: the own servers may have changed since (review 6 B1)
        let pdfs = (textStats?.pending ?? 0) > 0 && PDFTextClient.isBundled
        // vectors for semantic search (5.7): only with an endpoint, never on the Mac's model
        let router = aiConfig.enabled && aiConfig.endpoint != nil && !embedFailed ? aiRouter() : nil
        let embeds = router != nil && ((try? reader.embeddingCounts(model: aiConfig.model(for: .embed))).map { $0.done < $0.total } ?? false)
        let similarDue = router != nil && ((try? reader.staleSimilarCount()) ?? 0) > 0  // a stricter vote decides again
        guard pdfs || expired || rules || headers || categoryRules || warnings || embeds || similarDue else { return }
        let extractor = pdfText
        let token = UUID()
        textIndexToken = token
        textIndexTask = Task.detached(priority: .utility) { [weak self] in
            do {
                let writer = try ArchiveWriter(layout: try ArchiveLayout.open(at: root, create: false))
                let purged = try await writer.purgeExpired(days: 30)  // archive trash: 30 days, then for good (ADR-0006)
                if purged.messages > 0 || purged.backOnServer > 0 { await MainActor.run { self?.refresh() } }
                if rules {  // fast: headers only, no message is read
                    while try await writer.classifyHeuristically() > 0 { try Task.checkCancellation() }
                    await MainActor.run { self?.contentGeneration += 1 }
                }
                if headers {  // reads only each mail's header: a minute or two for 40k
                    while try await writer.indexHeaderFields() > 0 { try Task.checkCancellation() }
                }
                if categoryRules || rules, try await writer.applyCategoryRules() > 0 {  // after the rules: the user's rules win
                    await MainActor.run { self?.contentGeneration += 1 }
                }
                if warnings || headers {
                    let changed = try await writer.refreshWarnings()
                    await MainActor.run {
                        self?.warningsRefreshed = true  // only once it ran: a sync may cancel the pass before (review 6 R6)
                        if changed > 0 { self?.refresh() }
                    }
                }
                if pdfs {
                    _ = try await AttachmentIndexer(writer: writer, extractor: extractor).run { p in
                        Task { @MainActor in if self?.textIndexToken == token { self?.textIndexProgress = p } }
                    }
                }
                if embeds || similarDue, let router {
                    let indexer = EmbeddingIndexer(router: router, writer: writer)
                    do {
                        if embeds {
                            try await indexer.run { p in Task { @MainActor in if self?.textIndexToken == token { self?.embedProgress = p } } }
                        }
                        if try await indexer.decideOpenBySimilarity() > 0 { await MainActor.run { self?.contentGeneration += 1 } }
                        await MainActor.run { self?.vectorCache = nil }  // new vectors: rebuilt on the next search
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        await MainActor.run { self?.embedFailed = true }  // endpoint away: not again this session
                    }
                }
            } catch {
                // cancelled for an import/sync, or the archive is locked: resumes later
            }
            await MainActor.run {
                guard let self, self.textIndexToken == token else { return }
                self.textIndexTask = nil
                self.textIndexToken = nil
                self.textIndexProgress = nil
                self.embedProgress = nil
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
        aiConfig = AIConfigStore(layout: layout).load()
        aiKeyStored = aiConfig.secretKey.map(credentials.secretExists) ?? false
        aiRouterCache = nil
    }

    // MARK: Gold set (6.6, ADR-0005 §7) — the views and runs live in GoldSettings.swift

    var goldLabels = GoldLabels()
    /// gold.json is there but unreadable: nothing is saved over it (review 6.6 S5).
    var goldLoadError: String?
    var goldProgress: GoldProgress?
    /// Which run may publish (a run of an archive left and reopened must not).
    var goldGeneration = 0
    var goldResults: [GoldResult] = []
    var goldMessage: String?
    var goldTask: Task<Void, Never>?

    // MARK: KI (Phase 5, ADR-0004)

    private(set) var aiConfig = AIConfig()
    private(set) var aiKeyStored = false
    private var aiRouterCache: AIRouter?

    /// Settings › KI: saves the settings (in the archive) and, when given, the API key (keychain).
    func saveAI(_ config: AIConfig, key: String?) throws {
        guard let layout = reader?.layout else { return }
        if let endpoint = config.endpoint, let problem = AIConfig.transportProblem(endpoint) { throw AIError.badAnswer(problem) }
        if config.endpoint == nil, let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // the key is stored per endpoint: without one it would silently get lost (TJ)
            throw AIError.badAnswer(String(localized: "Erst die Adresse des Endpoints eintragen – der Schlüssel gehört zu ihr."))
        }
        if let key = key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty, let secretKey = config.secretKey {
            try credentials.saveSecret(key, key: secretKey, label: "MailKeeper – KI-Endpoint \(config.endpoint?.host() ?? "")",
                                       description: "API-Schlüssel (MailKeeper)")
        }
        try AIConfigStore(layout: layout).save(config)
        aiConfig = config
        aiKeyStored = config.secretKey.map(credentials.secretExists) ?? false
        aiRouterCache = nil
    }

    func removeAIKey() {
        guard let secretKey = aiConfig.secretKey else { return }
        try? credentials.deleteSecret(key: secretKey)
        aiKeyStored = false
        aiRouterCache = nil
    }

    /// The router for the current settings (key read from the keychain once).
    func aiRouter() -> AIRouter? {
        guard aiConfig.enabled else { return nil }
        if let aiRouterCache { return aiRouterCache }
        let key = aiConfig.secretKey.flatMap { try? credentials.secret(key: $0) }
        let router = AIRouter(config: aiConfig, apiKey: key)
        aiRouterCache = router
        return router
    }

    // MARK: Categories (5.4)

    func classification(of id: Int64) -> Classification? {
        try? reader?.classification(of: id)
    }

    /// The selected messages, asked of the model (also those the rules decided: the user asks).
    func classifySelection() {
        let ids = actionSelection
        guard !ids.isEmpty else { return }
        runClassification(Array(ids.prefix(Self.maxClassify)))
    }

    /// Of the list, those the rules left open.
    func classifyOpenInList() {
        guard let reader, let filter = lastFilter, let ids = try? reader.openForClassification(filter, limit: Self.maxClassify), !ids.isEmpty else {
            actionError = String(localized: "In dieser Liste ist keine Mail offen – die Regeln haben alle eingeordnet.")
            return
        }
        runClassification(ids)
    }

    static let maxClassify = 500

    private func runClassification(_ ids: [Int64], title: String = String(localized: "Einordnen"), automatic: Bool = false,
                                   screened: [ScreeningCandidate] = []) {
        guard let root = archiveRoot, let router = aiRouter(), !actionRunning, !syncRunning, !importRunning else {
            if !aiConfig.enabled { actionError = String(localized: "Die KI ist nicht eingerichtet (Einstellungen › KI).") }
            return
        }
        actionRunning = true
        actionProgress = ActionRunProgress(title: title, done: 0, total: ids.count, failed: 0, resumable: false)
        let indexing = pauseTextIndexing()
        let embedModel = aiConfig.endpoint != nil ? aiConfig.model(for: .embed) : nil
        actionTask = Task.detached { [weak self] in
            await indexing?.value
            var problem: String?
            var stopped = false
            var failed = 0
            do {
                let layout = try ArchiveLayout.open(at: root, create: false)
                let reader = try ArchiveReader(layout: layout)
                let writer = try ArchiveWriter(layout: layout)
                // 6.4: the register's warnings at once; "looked at" for a model's candidate only
                // after its answer — a stopped run leaves the rest for the next one
                try await writer.setScreened(screened.filter { !$0.needsModel })
                try await writer.setScreened(screened.filter(\.needsModel), markScreened: false)
                let screenedAfter = Dictionary(screened.filter(\.needsModel).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                let classifier = MailClassifier(router: router)
                let memory = try MemoryRetriever(reader: reader, embedModel: embedModel)  // 6.2: what the user taught
                for (n, id) in ids.enumerated() {
                    try Task.checkCancellation()
                    do {
                        // the user decided this one: no model call, nothing would be written (review 5.9 N7)
                        if try reader.classification(of: id)?.source == .user { continue }
                        guard let parsed = try reader.parsedMessage(id) else { continue }
                        let mail = MailSnapshot(parsed)
                        let accounts = try reader.detail(id)?.locations.map(\.account) ?? []
                        let c = try await classifier.classify(mail, memory: try memory.context(for: id, mail: mail, accounts: accounts))
                        try await writer.setClassification(messageID: id, category: c.category,
                                                           source: c.path == .onDevice ? .onDevice : .endpoint, model: c.model, reason: c.reason,
                                                           phishing: c.phishing, phishingReason: c.phishingReason, sources: c.sources)
                        if let candidate = screenedAfter[id] { try await writer.setScreened([candidate]) }
                    } catch let error as AIError {
                        failed += 1
                        if case .notConfigured = error { throw error }
                        if failed >= 5, failed == n + 1 { throw error }  // nothing works: stop early, say why
                    }
                    let done = n + 1, f = failed
                    await MainActor.run { self?.actionProgress?.done = done; self?.actionProgress?.failed = f }
                }
            } catch is CancellationError {
                problem = String(localized: "Angehalten; was fertig war, bleibt.")
                stopped = true
            } catch {
                problem = "\(error)"
            }
            let message = problem ?? (failed > 0 ? String(localized: "\(failed) Mails ließen sich nicht einordnen (siehe ~/Library/Logs/MailKeeper/ai.jsonl).") : nil)
            await MainActor.run {
                guard let self else { return }
                self.actionRunning = false
                self.actionProgress = nil
                self.actionTask = nil
                if let message {
                    if automatic {  // quietly in the status line; after a failure (not the user's stop) no further automatic run this session
                        if !stopped { self.autoJunkFailed = true }
                        self.syncMessage = [self.syncMessage, String(localized: "Spam-Prüfung: \(message)")].compactMap { $0 }.joined(separator: "\n")
                    } else {
                        self.actionError = message
                    }
                }
                self.contentGeneration += 1
                self.refresh()
                self.startTextIndexing()
            }
        }
    }

    // MARK: Summaries (5.8)

    /// What a summary is of: one message, or a conversation — named by its oldest message, so
    /// every message of it shows the same summary.
    enum SummaryScope: Hashable {
        case mail(Int64)
        case thread(Int64)
    }

    enum SummaryState: Equatable {
        case running(since: Date)
        case done(MailSummary)
        case failed(String)
    }

    /// This session's summaries: asked for, read, never stored (ADR-0004 as built 5.8).
    private(set) var summaries: [SummaryScope: SummaryState] = [:]
    private var summaryTasks: [SummaryScope: (token: UUID, task: Task<Void, Never>)] = [:]
    private var summaryOrder: [SummaryScope] = []
    static let keptSummaries = 50

    /// `ids` oldest first: the message itself, or its conversation (the newest 25 go in).
    func summarize(_ scope: SummaryScope, ids: [Int64]) {
        guard let root = archiveRoot, !ids.isEmpty else { return }
        guard let router = aiRouter() else {
            actionError = String(localized: "Die KI ist nicht eingerichtet (Einstellungen › KI).")
            return
        }
        summaryTasks[scope]?.task.cancel()
        summaries[scope] = .running(since: .now)
        summaryOrder.removeAll { $0 == scope }
        summaryOrder.append(scope)
        while summaryOrder.count > Self.keptSummaries {
            let old = summaryOrder.removeFirst()
            summaryTasks[old]?.task.cancel()
            summaryTasks[old] = nil
            summaries[old] = nil
        }
        let token = UUID()
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            let state: SummaryState
            do {
                let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
                let input = try MailSummarizer.messages(ids, reader: reader)
                let summary = try await MailSummarizer(router: router).summarize(input.messages, total: input.total, flagged: input.flagged)
                state = .done(summary)
            } catch is CancellationError {
                return
            } catch {
                state = .failed("\(error)")
            }
            await MainActor.run {
                // a newer request for the same scope, a close or another archive: not ours to show
                guard let self, self.summaryTasks[scope]?.token == token else { return }
                self.summaries[scope] = state
                self.summaryTasks[scope] = nil
            }
        }
        summaryTasks[scope] = (token, task)
    }

    /// The menu: the shown message, or its conversation.
    func summarizeSelected(conversation: Bool) {
        guard let id = selectedMessageID else { return }
        let ids = conversation ? thread(of: id).map(\.id) : [id]
        guard let first = ids.first else { return }
        summarize(conversation && ids.count > 1 ? .thread(first) : .mail(id), ids: ids)
    }

    /// Stops a running summary or puts a finished one away.
    func closeSummary(_ scope: SummaryScope) {
        summaryTasks[scope]?.task.cancel()
        summaryTasks[scope] = nil
        summaries[scope] = nil
        summaryOrder.removeAll { $0 == scope }
    }

    func copySummary(_ summary: MailSummary) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary.plainText, forType: .string)
    }

    // MARK: Spam and phishing outside the spam folder (6.4)

    static let screeningDays = 14
    static let screeningPerSync = 30

    /// After a sync: new mail in checked spam folders and the suspicious part of new mail
    /// elsewhere go to the model; the register's warnings are noted even without a model.
    func screenNewMail() {
        guard let reader else { return }
        let since = Date.now.addingTimeInterval(-Double(Self.screeningDays) * 86_400)
        let candidates = (try? reader.screeningCandidates(since: since, limit: Self.screeningPerSync * 3)) ?? []
        let junk = aiConfig.enabled && spamAccountsEnabled ? ((try? reader.junkToCheck(limit: 50)) ?? []) : []
        let ask = Array(candidates.filter(\.needsModel).map(\.id).prefix(Self.screeningPerSync))
        if aiConfig.enabled, !autoJunkFailed, !(junk.isEmpty && ask.isEmpty) {
            runClassification(junk + ask, title: String(localized: "Spam & Phishing prüfen"), automatic: true, screened: candidates)
            if !actionRunning { startTextIndexing() }  // the run could not start (review 6 C5)
        } else if !candidates.isEmpty {
            // without a model (or after a failed automatic run): only the deterministic warnings
            Task { _ = await writeNow { writer in try await writer.setScreened(candidates) } }
        } else {
            startTextIndexing()
        }
    }

    /// "Posteingang prüfen" in the "Verdächtig" view: mail of the last `days` days that no model
    /// has judged, including what the screening passed over.
    func screenInbox(days: Int) {
        guard let reader else { return }
        guard aiConfig.enabled else {
            actionError = String(localized: "Die KI ist nicht eingerichtet (Einstellungen › KI).")
            return
        }
        let since = Date.now.addingTimeInterval(-Double(days) * 86_400)
        let candidates = (try? reader.screeningCandidates(since: since, limit: Self.maxClassify, again: true)) ?? []
        let ask = candidates.filter(\.needsModel).map(\.id)
        guard !candidates.isEmpty else {
            actionError = String(localized: "In diesem Zeitraum gibt es nichts zu prüfen.")
            return
        }
        runClassification(ask, title: String(localized: "Posteingang prüfen"), screened: candidates)
    }

    /// The sidebar badge — counted at refresh, not on every redraw.
    private(set) var suspiciousCount = 0

    // MARK: Spam review (5.5)

    private(set) var junkReview: ArchiveReader.JunkReview?
    var spamAccountsEnabled: Bool { accountConfigs.contains { $0.policy.includeJunk } }

    func isInJunk(_ id: Int64) -> Bool { anyInJunk([id]) }

    /// One query for several messages (the context menu must not scan per message).
    func anyInJunk(_ ids: [Int64]) -> Bool {
        guard !ids.isEmpty else { return false }
        return ((try? reader?.count(MessageFilter(text: "is:junk ", ids: ids))) ?? 0) > 0
    }

    /// After a failed automatic spam check, no further automatic runs this session (the endpoint
    /// is away: no alert after every sync).
    private var autoJunkFailed = false

    /// Settings › Konten: read (and check) the account's spam folder too.
    func setSpamCheck(_ id: String, _ on: Bool) {
        guard let layout = reader?.layout else { return }
        var all = accountConfigs
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].policy.includeJunk = on
        do { try AccountStore(layout: layout).save(all) } catch { actionError = "\(error)" }
        reloadAccounts(layout)
    }

    /// The model judges spam-folder mails: the unchecked ones, those the Mac's model judged, or
    /// all a model judged — never what the user decided.
    func checkJunk(_ which: ArchiveReader.JunkCheck = .unchecked) {
        guard let ids = try? reader?.junkToCheck(limit: Self.maxClassify, which), !ids.isEmpty else {
            actionError = String(localized: "Dafür ist im Spam-Ordner nichts zu prüfen.")
            return
        }
        runClassification(ids, title: String(localized: "Spam prüfen"))
    }

    /// "Kein Spam → Posteingang": one mail at once (checked, queued, logged); several through the plan.
    func rescueSelection() {
        guard let reader, !actionSelection.isEmpty else { return }
        do {
            // only what lies in a spam folder: a mixed selection must not journal "kein Spam" for
            // INBOX mail that was never judged (review 5.9 S2)
            let ids = try reader.messageIDs(MessageFilter(text: "is:junk ", ids: actionSelection))
            guard !ids.isEmpty else {
                actionError = String(localized: "Keine der ausgewählten Mails liegt in einem Spam-Ordner.")
                return
            }
            let title = ids.count == 1 ? String(localized: "1 Mail aus dem Spam-Ordner") : String(localized: "\(ids.count) Mails aus dem Spam-Ordner")
            let (job, summary) = try reader.planRescue(MessageFilter(ids: ids), title: title, accounts: accountConfigs)
            // Mails with no spam folder on a server MailKeeper knows (imported): nothing to move,
            // but the user's "Kein Spam" counts — recorded at once (TJ).
            let onServer = Set(job.items.compactMap(\.identity))
            let archiveOnly = try reader.identities(of: ids).filter { !onServer.contains($0) }
            if !archiveOnly.isEmpty {
                withWriter { writer in for identity in archiveOnly { try await writer.confirmNotSpam(identity: identity) } }
                contentGeneration += 1
            }
            let plan = PlannedAction(job: job, summary: summary, filter: MessageFilter(ids: ids),
                                     examples: try reader.summaries(Array(ids.prefix(5))))
            if ids.count == 1, job.items.count == 1, job.count(.planned) == 1 {
                execute(plan)  // TJ: one click — the checks, the queue and the audit run all the same
            } else if job.count(.planned) == 0 {
                if archiveOnly.isEmpty, let reason = job.reasons.first?.reason { actionError = reason }
            } else {
                pendingPlan = plan
            }
        } catch {
            actionError = "\(error)"
        }
    }

    /// Whether a "Kein Spam" would move something on a server (a spam-folder location fetched over IMAP).
    func canRescue(_ id: Int64) -> Bool {
        guard let reader, let job = try? reader.planRescue(MessageFilter(ids: [id]), title: "", accounts: accountConfigs).0 else { return false }
        return job.count(.planned) > 0
    }

    /// "Ist Spam": the user's decision (journalled) — and, for mail on a server outside its spam
    /// folder, the move there (6.4, ADR-0006 §9): one mail at once, several through the plan.
    func markSpamSelection() {
        guard let reader, !actionSelection.isEmpty else { return }
        do {
            let ids = actionSelection
            let inJunk = Set(try reader.messageIDs(MessageFilter(text: "is:junk ", ids: ids)))
            let others = ids.filter { !inJunk.contains($0) }
            var verdictOnly = try reader.identities(of: Array(inJunk))
            var plan: PlannedAction?
            if !others.isEmpty {
                let title = others.count == 1 ? String(localized: "1 Mail in den Spam-Ordner") : String(localized: "\(others.count) Mails in den Spam-Ordner")
                let filter = MessageFilter(ids: others)
                let (job, summary) = try reader.planMarkSpam(filter, title: title, accounts: accountConfigs)
                let moving = Set(job.items.filter { $0.state == .planned }.compactMap(\.identity))
                verdictOnly += try reader.identities(of: others).filter { !moving.contains($0) }  // imported: the verdict only
                if job.count(.planned) > 0 {
                    plan = PlannedAction(job: job, summary: summary, filter: filter, examples: try reader.summaries(Array(others.prefix(5))))
                }
            }
            if let plan, verdictOnly.isEmpty, others.count == 1, plan.job.items.count == 1 {
                execute(plan)  // one click — the checks, the queue and the audit run all the same
                return
            }
            if !verdictOnly.isEmpty {
                let identities = verdictOnly
                withWriter { writer in
                    for identity in identities { try await writer.setUserClassification(identity: identity, category: .spam) }
                }
                contentGeneration += 1
            }
            if let plan { pendingPlan = plan }
        } catch {
            actionError = "\(error)"
        }
    }

    /// Whether "Ist Spam" would move this mail on a server (it lies in an ordinary mailbox there).
    func canMoveToJunk(_ id: Int64) -> Bool {
        guard let reader, let job = try? reader.planMarkSpam(MessageFilter(ids: [id]), title: "", accounts: accountConfigs).0 else { return false }
        return job.count(.planned) > 0
    }

    // MARK: Similar mails and semantic search (5.7)

    enum RankedMode: Equatable {
        case similar(id: Int64, subject: String)
        case semantic(String)
    }

    private(set) var rankedMode: RankedMode? {
        didSet { if rankedMode != oldValue { rankedSort = nil; if case .similar = rankedMode {} else { rankedSender = nil } } }
    }
    private var rankedIDs: [Int64] = []
    /// A column order chosen in a ranked list; nil = by score (each new ranked list starts there).
    private(set) var rankedSort: (sort: MessageSort, ascending: Bool)?
    private(set) var rankedSearching = false
    private var embedFailed = false
    private var vectorCache: VectorIndex?

    /// The text after a leading "~" in the search field: search by meaning.
    var semanticText: String? {
        let t = searchText.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("~") else { return nil }
        let rest = t.dropFirst().trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? nil : rest
    }

    /// The archive's vectors (loaded once). Nil when the archive changed while loading — ids of
    /// one archive mean nothing in another (review 5.9 C1).
    private func vectors() async -> VectorIndex? {
        if let vectorCache { return vectorCache }
        guard let layout = reader?.layout, let root = archiveRoot else { return nil }
        let model = aiConfig.model(for: .embed)
        let index = await Task.detached(priority: .userInitiated) { try? ArchiveReader(layout: layout).vectorIndex(model: model) }.value
        guard archiveRoot == root else { return nil }
        vectorCache = (index?.count ?? 0) > 0 ? index : nil
        return vectorCache
    }

    /// Mails like this one: the mail itself first, then the 100 most similar (reader: "Ähnliche
    /// Mails"). TJ deleted "all similar" and the mail he started from stayed — it belongs in.
    func showSimilar(_ id: Int64) {
        let summary = summaries([id]).first
        let root = archiveRoot
        Task {
            guard let index = await vectors(), archiveRoot == root else { return }
            guard let v = index.vector(of: id) else {
                actionError = String(localized: "Für diese Mail gibt es noch keinen Vektor – die Embeddings laufen im Hintergrund (Statusleiste).")
                return
            }
            rankedIDs = [id] + index.nearest(to: v, k: 100, excluding: id).map(\.id)
            rankedMode = .similar(id: id, subject: summary?.subject ?? "")
            rankedSender = sender(of: summary, within: rankedIDs)
            reloadList()
        }
    }

    /// The starting mail's sender, when the archive holds more of its mails than the list shows.
    struct RankedSender: Equatable {
        var name: String
        var query: String
        var total: Int
        var listed: Int
    }

    private(set) var rankedSender: RankedSender?

    private func sender(of summary: MessageSummary?, within ids: [Int64]) -> RankedSender? {
        guard let reader, let address = summary?.fromAddress, address.contains("@"), !address.contains("\"") else { return nil }
        let query = "sender:" + QueryParser.quote(address)
        guard let total = try? reader.count(MessageFilter(text: query + " ")),
              let listed = try? reader.count(MessageFilter(text: query + " ", ids: ids)), total > listed else { return nil }
        return RankedSender(name: summary?.fromName ?? address, query: query, total: total, listed: listed)
    }

    /// All mails of the starting mail's sender, in every mailbox.
    func showAllFromRankedSender() {
        guard let sender = rankedSender else { return }
        let anchor: Int64? = if case .similar(let id, _) = rankedMode { id } else { nil }
        rankedMode = nil
        rankedIDs = []
        viewMode = .messages
        setSearch(sender.query + " ")
        sidebarSelection = .all  // reloads with the new search text
        if let anchor { reveal(anchor) }
    }

    func closeRanked() {
        let wasSemantic: Bool = if case .semantic = rankedMode { true } else { false }
        rankedMode = nil
        rankedIDs = []
        if wasSemantic { setSearch("") } else { reloadList() }
    }

    /// "~ text": the query's vector against the archive's (endpoint only).
    private func startSemanticSearch(_ text: String) {
        guard !rankedSearching, let router = aiRouter() else {
            if !aiConfig.enabled { queryError = String(localized: "Suche nach Bedeutung braucht die KI (Einstellungen › KI).") }
            return
        }
        rankedSearching = true
        let root = archiveRoot
        Task {
            defer { rankedSearching = false }
            do {
                guard let index = await vectors() else {
                    if archiveRoot == root { queryError = String(localized: "Noch keine Vektoren – die Embeddings laufen im Hintergrund (Statusleiste).") }
                    return
                }
                let q = VectorMath.normalized(try await router.embed([text]).first ?? [])
                guard archiveRoot == root else { return }
                guard semanticText == text else {  // typed on meanwhile: search the current text
                    rankedSearching = false
                    reloadList()
                    return
                }
                rankedIDs = index.nearest(to: q, k: 200).map(\.id)
                rankedMode = .semantic(text)
                reloadList()
            } catch {
                queryError = "\(error)"
            }
        }
    }

    func searchByMeaning() {
        let t = searchText.trimmingCharacters(in: .whitespaces)
        setSearch(t.hasPrefix("~") ? String(t.dropFirst()).trimmingCharacters(in: .whitespaces) : "~ " + t)
    }

    // MARK: Search in everyday language (5.3)

    struct SearchTranslationNote: Equatable {
        var original: String
        var query: String?
        var explanation: String
        var path: AIPath?
        var model: String
        var seconds: Double
        var failed: Bool { query == nil }
    }

    private(set) var translatingSearch = false
    var searchTranslation: SearchTranslationNote?
    private var translationTask: Task<Void, Never>?

    var canTranslateSearch: Bool {
        aiConfig.enabled && !translatingSearch && !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The search field's text, read as everyday language, becomes query text — shown, editable,
    /// with a way back (the model never searches by itself; the parser checks what it wrote).
    func translateSearch() {
        guard canTranslateSearch, let router = aiRouter() else { return }
        let original = searchText
        let context = QueryContext(accounts: accounts.map(\.id),
                                   folders: Array(Set(accounts.flatMap { $0.mailboxes.map(\.name) })).sorted(),
                                   vocabulary: memoryItems.filter { $0.kind == .vocabulary }.compactMap(\.content.text))
        translatingSearch = true
        searchTranslation = nil
        translationTask = Task { [weak self] in
            do {
                let t = try await QueryTranslator(router: router).translate(original, context: context)
                guard let self, !Task.isCancelled else { return }
                self.searchTranslation = SearchTranslationNote(original: original, query: t.query, explanation: t.explanation,
                                                               path: t.path, model: t.model, seconds: t.seconds)
                self.setSearch(t.query + " ")
            } catch is CancellationError {
            } catch {
                self?.searchTranslation = SearchTranslationNote(original: original, query: nil, explanation: "\(error)",
                                                                path: nil, model: "", seconds: 0)
            }
            self?.translatingSearch = false
        }
    }

    func cancelTranslation() {
        translationTask?.cancel()
        translatingSearch = false
    }

    /// Back to the words as typed.
    func undoTranslation() {
        guard let note = searchTranslation else { return }
        searchTranslation = nil
        setSearch(note.original)
    }

    /// The connection test of the settings, for a config not yet saved.
    func testAI(_ config: AIConfig, key: String?) async -> AIRouter.TestReport {
        var config = config
        config.enabled = true
        let typed = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = config.secretKey.flatMap { try? credentials.secret(key: $0) }
        return await AIRouter(config: config, apiKey: (typed?.isEmpty == false ? typed : nil) ?? stored).test()
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
        guard let root = archiveRoot, reader != nil, !syncRunning, !importRunning, !actionRunning, !accountConfigs.isEmpty else { return }
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
                        summary.append("\(account.displayName): \(r.newMessages) neu"
                                       + (r.back > 0 ? " · \(r.back) wieder auf dem Server" : "")
                                       + (r.deletedBefore > 0 ? " · \(r.deletedBefore) endgültig gelöschte nicht wieder geholt" : "")
                                       + (r.failures.isEmpty ? "" : " · \(r.failures.count) Fehler: \(r.failures.joined(separator: "; "))"))
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
                // new mail: the model looks at what is new in checked spam folders (5.5) and at the
                // suspicious part of what is new elsewhere (6.4) — quietly
                self?.screenNewMail()
                self?.noteReadyRules()
            }
        }
    }
}
