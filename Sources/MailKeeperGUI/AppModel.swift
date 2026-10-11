import AppKit
import LocalAuthentication
import MailKeeperAI
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
        guard archive.path != archiveRoot?.path else { return }
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
        guard !actionRunning, !syncRunning, !importRunning else {
            if accessing { url.stopAccessingSecurityScopedResource() }
            actionError = String(localized: "Erst wenn Import, Abruf oder Aktion fertig sind, lässt sich das Archiv wechseln.")
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

    func openArchive() {
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
        guard !actionRunning, !syncRunning, !importRunning, open(url, create: true) else {
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
        }
        textIndexTask?.cancel()  // belongs to the previous archive
        textIndexTask = nil
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
        case .all, nil: MessageFilter()
        }
    }

    func reloadList() {
        guard let reader else { return }
        reloading = true
        defer { reloading = false }
        var filter = scopeFilter
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
            case .export: return
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
        case .export:
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
        guard let root = archiveRoot, !actionRunning, !syncRunning, !importRunning else { return }
        actionRunning = true
        let indexing = pauseTextIndexing()
        Task.detached { [weak self] in
            await indexing?.value
            var problem: String?
            do { try await work(try ArchiveWriter(layout: try ArchiveLayout.open(at: root, create: false))) } catch {
                problem = "\(error)"
            }
            await MainActor.run {
                guard let self else { return }
                self.actionRunning = false
                if let problem { self.actionError = problem }
                self.selectedMessageIDs = []
                self.refresh()
                self.startTextIndexing()
            }
        }
    }

    // MARK: PDF text (ADR-0009)

    /// Runs the background queue when there is work and the writer is free (no import, no
    /// sync, no mkctl holding the archive — then it simply tries again next time).
    func startTextIndexing() {
        guard let root = archiveRoot, let reader, textIndexTask == nil, !syncRunning, !importRunning, !actionRunning else { return }
        textStats = try? reader.attachmentTextStats()
        let expired = (stats?.trashed ?? 0) > 0  // may hold mail older than 30 days to purge
        let rules = ((try? reader.heuristicPendingCount()) ?? 0) > 0  // categories by rule (5.4)
        let pdfs = (textStats?.pending ?? 0) > 0 && PDFTextClient.isBundled
        guard pdfs || expired || rules else { return }
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
                if pdfs {
                    _ = try await AttachmentIndexer(writer: writer, extractor: extractor).run { p in
                        Task { @MainActor in if self?.textIndexToken == token { self?.textIndexProgress = p } }
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

    // MARK: KI (Phase 5, ADR-0004)

    private(set) var aiConfig = AIConfig()
    private(set) var aiKeyStored = false
    private var aiRouterCache: AIRouter?

    /// Settings › KI: saves the settings (in the archive) and, when given, the API key (keychain).
    func saveAI(_ config: AIConfig, key: String?) throws {
        guard let layout = reader?.layout else { return }
        if let endpoint = config.endpoint, let problem = AIConfig.transportProblem(endpoint) { throw AIError.badAnswer(problem) }
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

    private func runClassification(_ ids: [Int64], title: String = String(localized: "Einordnen"), automatic: Bool = false) {
        guard let root = archiveRoot, let router = aiRouter(), !actionRunning, !syncRunning, !importRunning else {
            if !aiConfig.enabled { actionError = String(localized: "Die KI ist nicht eingerichtet (Einstellungen › KI).") }
            return
        }
        actionRunning = true
        actionProgress = ActionRunProgress(title: title, done: 0, total: ids.count, failed: 0, resumable: false)
        let indexing = pauseTextIndexing()
        actionTask = Task.detached { [weak self] in
            await indexing?.value
            var problem: String?
            var failed = 0
            do {
                let layout = try ArchiveLayout.open(at: root, create: false)
                let reader = try ArchiveReader(layout: layout)
                let writer = try ArchiveWriter(layout: layout)
                let classifier = MailClassifier(router: router)
                for (n, id) in ids.enumerated() {
                    try Task.checkCancellation()
                    do {
                        guard let parsed = try reader.parsedMessage(id) else { continue }
                        let c = try await classifier.classify(MailSnapshot(parsed))
                        try await writer.setClassification(messageID: id, category: c.category,
                                                           source: c.path == .onDevice ? .onDevice : .endpoint, model: c.model, reason: c.reason)
                    } catch let error as AIError {
                        failed += 1
                        if case .notConfigured = error { throw error }
                        if failed >= 5, failed == n + 1 { throw error }  // nothing works: stop early, say why
                    }
                    let done = n + 1, f = failed
                    await MainActor.run { self?.actionProgress?.done = done; self?.actionProgress?.failed = f }
                }
            } catch is CancellationError {
                problem = String(localized: "Einordnen angehalten; was fertig war, bleibt.")
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
                    if automatic {  // quietly in the status line; no further automatic run this session
                        self.autoJunkFailed = true
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

    /// The model judges every mail in the spam folders that nobody has judged yet.
    func checkJunk() {
        guard let ids = try? reader?.junkToCheck(limit: Self.maxClassify), !ids.isEmpty else {
            actionError = String(localized: "Im Spam-Ordner ist nichts Ungeprüftes.")
            return
        }
        runClassification(ids, title: String(localized: "Spam prüfen"))
    }

    /// "Kein Spam → Posteingang": one mail at once (checked, queued, logged); several through the plan.
    func rescueSelection() {
        guard let reader else { return }
        let ids = actionSelection
        guard !ids.isEmpty else { return }
        do {
            let title = ids.count == 1 ? String(localized: "1 Mail aus dem Spam-Ordner") : String(localized: "\(ids.count) Mails aus dem Spam-Ordner")
            let (job, summary) = try reader.planRescue(MessageFilter(ids: ids), title: title, accounts: accountConfigs)
            let plan = PlannedAction(job: job, summary: summary, filter: MessageFilter(ids: ids),
                                     examples: try reader.summaries(Array(ids.prefix(5))))
            if ids.count == 1, job.items.count == 1, job.count(.planned) == 1 {
                execute(plan)  // TJ: one click — the checks, the queue and the audit run all the same
            } else if job.count(.planned) == 0 {
                actionError = job.reasons.first.map { "\($0.reason)" }
                    ?? String(localized: "Für diese Mail kennt MailKeeper keinen Spam-Ordner auf einem Server (importiert?).")
            } else {
                pendingPlan = plan
            }
        } catch {
            actionError = "\(error)"
        }
    }

    /// "Ist Spam": the user's decision (journalled).
    func markSpamSelection() {
        guard let reader, let identities = try? reader.identities(of: actionSelection), !identities.isEmpty else { return }
        withWriter { writer in
            for identity in identities { try await writer.setUserClassification(identity: identity, category: .spam) }
        }
        contentGeneration += 1
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
                                   folders: Array(Set(accounts.flatMap { $0.mailboxes.map(\.name) })).sorted())
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
                // new mail in checked spam folders: the model looks at it (5.5)
                if let self, self.aiConfig.enabled, self.spamAccountsEnabled, !self.autoJunkFailed,
                   let ids = try? self.reader?.junkToCheck(limit: 50), !ids.isEmpty {
                    self.runClassification(ids, title: String(localized: "Spam prüfen"), automatic: true)
                } else {
                    self?.startTextIndexing()
                }
            }
        }
    }
}
