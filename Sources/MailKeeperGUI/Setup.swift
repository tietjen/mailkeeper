import MailKeeperKit
import SwiftUI

/// The setup on the first launch: how MailKeeper works, where the archive goes, which
/// mailboxes it fetches. Separate from the tour of the window (`IntroTour`), which follows it
/// the first time; both come back from the Help menu (TJ).
///
/// The first launch creates no archive (`AppModel.initialArchive`) — the second page is where
/// one comes into being, at the default location or in a folder the user picks.
@MainActor
@Observable
final class SetupAssistant {
    enum Page: Int, CaseIterable {
        case welcome, archive, accounts
    }

    private static let seenKey = "setupSeen"

    private(set) var page: Page?
    /// The tour follows when the setup ends — only on the first launch.
    private(set) var tourFollows = false

    @ObservationIgnored private let defaults: UserDefaults
    /// The window may appear more than once in a launch; the first launch is decided once.
    @ObservationIgnored private var launchDecided = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isShown: Bool { page != nil }

    /// Whether the setup opens by itself at launch: never finished, and the tour never seen
    /// either. Whoever saw the tour has been through a first launch already — an update must
    /// not greet an existing user with a setup they did long ago.
    func runsAtLaunch(tourSeen: Bool) -> Bool {
        !defaults.bool(forKey: Self.seenKey) && !tourSeen
    }

    /// Called when the window is up. Starts the setup on a first launch, once per launch, and
    /// says whether it is on screen — then the tour waits for it.
    func startIfFirstLaunch(tourSeen: Bool) -> Bool {
        guard !launchDecided else { return isShown }
        launchDecided = true
        guard runsAtLaunch(tourSeen: tourSeen) else { return false }
        start(tourFollows: true)
        return true
    }

    func start(tourFollows: Bool = false) {
        self.tourFollows = tourFollows
        page = .welcome
    }

    func next() {
        guard let page else { return }
        guard let following = Page(rawValue: page.rawValue + 1) else { return finish() }
        self.page = following
    }

    func back() {
        guard let page, let previous = Page(rawValue: page.rawValue - 1) else { return }
        self.page = previous
    }

    /// "Später" as well as the last button: either way the user has seen it.
    func finish() {
        defaults.set(true, forKey: Self.seenKey)
        page = nil
    }

    /// The sheet went away without a button (the window was closed): not seen — the next
    /// launch offers it again.
    func close() {
        page = nil
    }

    /// Asked once when the sheet is gone: start the tour now? Resets, so it is asked once.
    func takeTourFollows() -> Bool {
        defer { tourFollows = false }
        return tourFollows
    }
}

struct SetupSheet: View {
    let setup: SetupAssistant
    let model: AppModel
    @State private var addingAccount = false
    /// An error of the archive buttons (folder not empty, nothing there), shown on the page:
    /// the window's own alert cannot appear while this sheet is up.
    @State private var archiveError: String?

    /// What the archive page says went wrong: a refusal of the button itself, or an archive
    /// that was found but could not be opened (newer format, locked index) — that one lands in
    /// the window's "Archiv nicht geöffnet", which this sheet covers.
    private var shownArchiveError: String? {
        archiveError ?? (model.hasArchive ? nil : model.openError)
    }

    /// Runs one archive button. They work synchronously (the folder panel is modal), so a
    /// refusal they leave in `actionError` is theirs — taken here and shown on the page, before
    /// the window's alert could be drawn behind the sheet. Errors of anything else stay put.
    private func archiveAction(_ action: () -> Void) {
        archiveError = nil
        let before = model.actionError
        action()
        if let error = model.actionError, error != before {
            archiveError = error
            model.actionError = before
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let page = setup.page {
                HStack {
                    Text("Einrichtung").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(page.rawValue + 1) von \(SetupAssistant.Page.allCases.count)")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                Group {
                    switch page {
                    case .welcome: welcome
                    case .archive: archive
                    case .accounts: accounts
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer(minLength: 0)
                footer(page)
            }
        }
        .padding(20)
        .frame(width: 560, height: 470)
        .sheet(isPresented: $addingAccount) { AddAccountSheet(model: model) }
        .onChange(of: setup.page) { archiveError = nil }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Willkommen bei MailKeeper").font(.title2.weight(.semibold))
            Text("MailKeeper sichert deine Postfächer in ein Archiv auf diesem Mac – durchsuchbar, aufräumbar und lesbar auch ohne diese App.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ServerArchiveDiagram()
            point("doc.on.doc", "Abrufen kopiert neue Mails vom Server ins Archiv. Auf dem Server ändert sich dabei nichts – nicht einmal das Gelesen-Zeichen.")
            point("lock.shield", "Das Archiv vergisst nichts. Löschst du eine Mail auf dem Server, bleibt sie im Archiv („Nur im Archiv“). Verschiebst du sie, steht sie im Archiv danach im alten und im neuen Ordner – gespeichert nur einmal.")
            point("hand.raised", "Den Server ändert MailKeeper nur, wenn du es verlangst: Löschen, Zurückspielen, Verschieben – und immer erst nach einem Plan, den du bestätigst.")
        }
    }

    private var archive: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dein Archiv").font(.title2.weight(.semibold))
            Text("Ein Archiv ist ein Ordner auf diesem Mac. Darin liegen die Mails, der Suchindex und die Konten, die in dieses Archiv abrufen. Du kannst mehrere Archive haben – etwa privat und Arbeit –, jedes mit eigenen Konten.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.hasArchive, let root = model.archiveRoot {
                GroupBox {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Offen: \(model.currentArchiveName)", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Spacer()
                    }
                    Text(model.abbreviated(root.path(percentEncoded: false)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack {
                    Button("Anderes Archiv anlegen …") { archiveAction(model.createArchive) }
                    Button("Vorhandenes Archiv öffnen …") { archiveAction(model.openArchive) }
                }
                .disabled(model.archiveSwitchBlocked)
            } else {
                choice("Am Standard-Ort anlegen", "Im Ordner der App unter ~/Library/Containers. Genügt zum Ausprobieren.") {
                    archiveAction(model.createStandardArchive)
                }
                choice("In eigenem Ordner anlegen …", "Ein leerer Ordner deiner Wahl – etwa auf einem verschlüsselten Laufwerk oder dort, wo dein Backup hinschaut. Nötig, wenn du auch mkctl benutzen willst.") {
                    archiveAction(model.createArchive)
                }
                choice("Vorhandenes Archiv öffnen …", "Ein Ordner, in dem schon ein MailKeeper-Archiv liegt.") {
                    archiveAction(model.openArchive)
                }
            }
            if let error = shownArchiveError {
                Text(DisplayText.safe(error)).font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Wechseln kannst du jederzeit: über einen Klick auf den Fenstertitel oder Ablage › Archiv wechseln. Die Mails liegen als gewöhnliche .eml-Dateien im Archiv – am besten auf einem verschlüsselten Laufwerk (FileVault) und im Backup.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Postfächer verbinden").font(.title2.weight(.semibold))
            Text("Jedes Postfach ist ein Konto: Gmail, Proton Mail Bridge oder ein beliebiges IMAP-Postfach. Ein Archiv nimmt beliebig viele Konten auf – dafür brauchst du kein zweites Archiv.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.hasArchive {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Konten in „\(model.currentArchiveName)“").font(.callout.weight(.semibold))
                        if model.accountConfigs.isEmpty {
                            Text("noch keines").foregroundStyle(.secondary)
                        }
                        ForEach(model.accountConfigs, id: \.id) { account in
                            HStack(spacing: 8) {
                                Image(systemName: AccountsSettings.icon(account.kind)).frame(width: 18)
                                Text(DisplayText.safe(account.displayName))
                                Text(DisplayText.safe(account.username)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.preparingArchive {
                    // accounts are written through the reader, which exists once this is done
                    Label("Das Archiv wird für diese Version vorbereitet (Konversationen, Suche) …", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
                Button(model.accountConfigs.isEmpty ? "Konto hinzufügen …" : "Weiteres Konto hinzufügen …") { addingAccount = true }
                    .disabled(model.reader == nil)
                Text("MailKeeper prüft die Verbindung, bevor es speichert. Passwörter liegen im Schlüsselbund, nicht im Archiv. In der Seitenleiste steht danach jedes Konto mit seinen Ordnern; „Alle Nachrichten“ zeigt alle zusammen. Später findest du die Konten unter Einstellungen › Konten.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("Die Konten werden im Archiv gespeichert – leg zuerst eines an.", systemImage: "archivebox")
                    .foregroundStyle(.orange)
                Button("Zurück zum Archiv") { setup.back() }
            }
        }
    }

    // MARK: Pieces

    private func point(_ symbol: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    private func choice(_ title: LocalizedStringKey, _ detail: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(title, action: action)
                .frame(width: 210, alignment: .leading)
                .disabled(model.archiveSwitchBlocked)
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The first fetch can start right from the setup: an account is there and nothing has been
    /// fetched into this archive yet.
    private var offersFetch: Bool {
        model.reader != nil && !model.accountConfigs.isEmpty && (model.stats?.messages ?? 0) == 0
            && !model.syncRunning && !model.importRunning && !model.actionRunning
    }

    private func footer(_ page: SetupAssistant.Page) -> some View {
        HStack {
            Button("Später") { setup.finish() }
                .keyboardShortcut(.cancelAction)
                .help("Die Einrichtung schließen. Du findest sie unter Hilfe › Einrichtung …")
            Spacer()
            if page != .welcome {
                Button("Zurück") { setup.back() }
            }
            switch page {
            case .welcome:
                Button("Weiter") { setup.next() }.keyboardShortcut(.defaultAction)
            case .archive:
                Button("Weiter") { setup.next() }.keyboardShortcut(.defaultAction)
                    .disabled(!model.hasArchive)
                    .help(model.hasArchive ? "" : "Erst ein Archiv anlegen oder öffnen")
            case .accounts:
                if offersFetch {
                    Button(setup.tourFollows ? "Abrufen und weiter" : "Abrufen und fertig") {
                        model.syncAll()
                        setup.finish()
                    }
                    .keyboardShortcut(.defaultAction)
                    .help("Holt die Mails aller Konten dieses Archivs, nur lesend. Der erste Abruf lädt alles und kann dauern.")
                } else {
                    Button(setup.tourFollows ? "Weiter" : "Fertig") { setup.finish() }.keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}

/// Server and archive in one picture: what goes which way (setup, help).
struct ServerArchiveDiagram: View {
    var body: some View {
        HStack(spacing: 10) {
            box("server.rack", "Mailserver", "dein Konto, z. B. Gmail", tint: .blue)
            VStack(spacing: 4) {
                Text("Abrufen, nur lesend").font(.caption)
                Image(systemName: "arrow.right").font(.title3.weight(.semibold))
                Image(systemName: "arrow.left").font(.title3).foregroundStyle(.tertiary)
                Text("nur auf deinen Befehl, mit Plan").font(.caption).foregroundStyle(.secondary)
            }
            .multilineTextAlignment(.center)
            .frame(width: 150)
            box("archivebox", "Archiv", "ein Ordner auf diesem Mac", tint: .green)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func box(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey, tint: Color) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.title2)
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(tint)
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 86)
        .background(RoundedRectangle(cornerRadius: 8).fill(tint.opacity(0.1)))
    }
}

/// The window without an archive (first launch): what an archive is, and the two ways to one.
struct NoArchiveView: View {
    let model: AppModel
    let startSetup: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Noch kein Archiv", systemImage: "archivebox")
        } description: {
            Text("MailKeeper legt deine Mails in einem Archiv ab – einem Ordner auf diesem Mac. Die Einrichtung legt eines an und verbindet deine Postfächer.")
        } actions: {
            Button("Einrichtung starten", action: startSetup)
            Button("Vorhandenes Archiv öffnen …") { model.openArchive() }
        }
    }
}

/// An archive with nothing in it yet: what fills it, and the button for it — instead of a bare
/// "Keine Nachrichten" after the setup was skipped.
struct EmptyArchiveView: View {
    let model: AppModel
    let addAccount: () -> Void

    var body: some View {
        if model.accountConfigs.isEmpty {
            ContentUnavailableView {
                Label("„\(model.currentArchiveName)“ ist noch leer", systemImage: "archivebox")
            } description: {
                Text("Verbinde ein Postfach, dann kopiert „Abrufen“ seine Mails hierher. Oder lies vorhandene Mails ein: Maildir, mbox (auch Google Takeout) oder .eml.")
            } actions: {
                Button("Konto hinzufügen …", action: addAccount)
                Menu("Importieren") {
                    ForEach(ImportKind.allCases) { kind in
                        Button(kind.title) { model.startImport(kind) }
                    }
                }
                .fixedSize()
                if model.knownArchives.count > 1 {
                    Menu("Archiv wechseln") { ArchiveMenuItems(model: model) }.fixedSize()
                        .disabled(model.archiveSwitchBlocked)
                }
            }
        } else if model.syncRunning {
            ContentUnavailableView {
                Label("Der erste Abruf läuft", systemImage: "arrow.down.circle")
            } description: {
                Text("Die Mails erscheinen hier, sobald der Abruf sie geholt hat. Den Fortschritt zeigt die Statusleiste unten.")
            }
        } else {
            ContentUnavailableView {
                Label("Noch nichts abgerufen", systemImage: "arrow.down.circle")
            } description: {
                Text("Abrufen holt die Mails aller Konten dieses Archivs, nur lesend. Der erste Abruf lädt alles und kann dauern; danach kommt nur Neues.")
            } actions: {
                Button("Jetzt abrufen") { model.syncAll() }
                    .disabled(model.importRunning || model.actionRunning)
            }
        }
    }
}
