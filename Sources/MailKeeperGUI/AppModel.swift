import AppKit
import MailKeeperIMAP
import MailKeeperKit
import Observation
import SwiftUI

enum SidebarItem: Hashable {
    case all
    case account(String)
    case mailbox(account: String, name: String)

    var filter: MessageFilter {
        switch self {
        case .all: MessageFilter()
        case .account(let a): MessageFilter(account: a)
        case .mailbox(let a, let m): MessageFilter(account: a, mailbox: m)
        }
    }
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
    var sort: MessageSort = .date
    var ascending = false
    private(set) var messageIDs: [Int64] = []
    /// Bumped whenever `messageIDs` is replaced; the table reloads on change.
    private(set) var listGeneration = 0
    var selectedMessageID: Int64?

    private(set) var importStatus: ImportStatus?
    private(set) var importRunning = false
    private(set) var accountConfigs: [AccountConfig] = []
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
            refresh()
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
        accountConfigs = (try? AccountStore(layout: reader.layout).load()) ?? []
        accounts = (try? reader.accounts()) ?? []
        stats = try? reader.stats()
        reloadList()
    }

    func reloadList() {
        guard let reader else { return }
        var filter = sidebarSelection?.filter ?? MessageFilter()
        let text = searchText.trimmingCharacters(in: .whitespaces)
        filter.text = text.isEmpty ? nil : text
        do {
            messageIDs = try reader.messageIDs(filter, sort: sort, ascending: ascending)
            listError = nil
        } catch {
            messageIDs = []
            listError = "\(error)"  // an I/O error must not look like "no results"
        }
        listGeneration += 1
        if let sel = selectedMessageID, !messageIDs.contains(sel) { selectedMessageID = nil }
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
        Task.detached { [weak self] in
            defer { if accessing { source.stopAccessingSecurityScopedResource() } }
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
                }
            } catch {
                await MainActor.run {
                    self?.importStatus?.error = "\(error)"
                    self?.importStatus?.finished = true
                    self?.importRunning = false
                }
            }
        }
    }

    func dismissImportStatus() {
        importStatus = nil
    }

    // MARK: Accounts & sync (read-only)

    func hasPassword(_ account: AccountConfig) -> Bool {
        (try? credentials.password(for: account)) != nil
    }

    func addAccount(_ account: AccountConfig, password: String) throws {
        guard let layout = reader?.layout else { return }
        try AccountStore(layout: layout).add(account)
        try credentials.save(password, for: account)
        accountConfigs = (try? AccountStore(layout: layout).load()) ?? []
    }

    func removeAccount(_ id: String) {
        guard let layout = reader?.layout, let account = accountConfigs.first(where: { $0.id == id }) else { return }
        try? AccountStore(layout: layout).remove(id)
        try? credentials.delete(for: account)
        accountConfigs = (try? AccountStore(layout: layout).load()) ?? []
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
        Task.detached { [weak self] in
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
            }
        }
    }
}
