import SwiftUI

/// The tour on first start (8.5): a few cards at the real parts of the window, so the first
/// look is not a wall of empty columns.
///
/// Three things about this are not obvious, all learned the hard way in LaunchKeeper:
///
/// 1. The columns of a `NavigationSplitView` are hosted separately, so one overlay spanning the
///    window cannot point at them. Each step therefore hangs as a native `.popover` on the view
///    it talks about.
/// 2. A popover only appears when its anchor is on screen. A collapsed sidebar or a hidden
///    toolbar would stall the tour for good — so a step that has not appeared after a moment is
///    shown as a sheet instead.
/// 3. Cards are presented by identity, not by a boolean, and a dismissal only counts when the
///    card it comes from is still the one being presented. Otherwise the late message of the
///    previous card ends the tour, or the fallback switch to a sheet does.
@MainActor
@Observable
final class IntroTour {
    enum Step: Int, CaseIterable, Identifiable {
        case welcome, sidebar, list, reader, toolbar, accounts, done
        var id: Int { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .welcome: "Willkommen bei MailKeeper"
            case .sidebar: "Die Seitenleiste"
            case .list: "Die Liste"
            case .reader: "Der Leser"
            case .toolbar: "Abrufen und Suchen"
            case .accounts: "Als Nächstes: ein Postfach"
            case .done: "Das war's"
            }
        }

        var text: LocalizedStringKey {
            switch self {
            case .welcome:
                "MailKeeper holt deine Mail in ein Archiv auf diesem Mac — durchsuchbar, aufräumbar, und lesbar auch ohne diese App. Ein kurzer Rundgang zeigt dir, wo was liegt."
            case .sidebar:
                "Hier stehen alle Nachrichten, der Papierkorb, „Verdächtig“ — und, sobald du eines eingerichtet hast, jedes Konto mit seinen Ordnern. Gespeicherte Suchen landen als eigene Ansicht darüber."
            case .list:
                "Die Mails der gewählten Ansicht. Über „Ansicht“ in der Symbolleiste wird daraus eine Gruppierung nach Absender, Domain oder Liste — so räumt man ein volles Postfach auf, statt Mail für Mail."
            case .reader:
                "Rechts die geöffnete Mail. Zwei Zeilen lohnen den Blick: „Ort“ sagt, wo die Mail liegt, „Echtheit“, was der empfangende Mailserver über den Absender festgestellt hat."
            case .toolbar:
                "Rechts oben Abrufen und Importieren, in der Mitte die Ansicht, daneben das Suchfeld. Abgerufen wird nur lesend — auf dem Server ändert MailKeeper nichts, solange du es nicht verlangst."
            case .accounts:
                "Ohne Postfach bleibt es leer. Unter Einstellungen › Konten richtest du eines ein: IMAP, Gmail oder die Proton Mail Bridge. Ein vorhandenes Archiv liest Ablage › Importieren ein."
            case .done:
                "Alles Weitere steht in der Hilfe (⌘?) und im Handbuch. Diesen Rundgang findest du im Hilfemenü unter „Einführung zeigen“ wieder."
            }
        }

        /// Steps with nothing in the window to point at are sheets from the start.
        var isSheet: Bool { self == .welcome || self == .accounts || self == .done }
    }

    private static let atStartKey = "introAtStart"   // the user's wish, off unless asked for
    private static let seenKey = "introSeen"         // the tour has run to its end once

    private(set) var step: Step?
    /// Counts up with every step, so a card knows which one it is.
    private(set) var generation = 0
    /// A step whose anchor never showed up falls back to a sheet.
    private(set) var asSheet = false
    /// Set once per launch, so two views appearing do not start the tour twice.
    @ObservationIgnored private var started = false
    @ObservationIgnored private var appeared = false
    @ObservationIgnored private var fallback: Task<Void, Never>?

    /// Where the two flags live. A parameter only so the tests can have their own domain
    /// instead of writing into the running user's defaults.
    @ObservationIgnored private let defaults: UserDefaults

    var showAtStart: Bool {
        didSet { defaults.set(showAtStart, forKey: Self.atStartKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showAtStart = defaults.bool(forKey: Self.atStartKey)
    }

    /// Called when the window is up. Runs on the first launch, and after that only if the box
    /// in the card is ticked — never twice in one launch.
    func startIfWanted() {
        guard !started else { return }
        guard showAtStart || !defaults.bool(forKey: Self.seenKey) else { return }
        start()
    }

    func start() {
        started = true
        go(to: .welcome)
    }

    func next() {
        guard let step, let following = Step(rawValue: step.rawValue + 1) else { return finish() }
        go(to: following)
    }

    /// `seen` only for the two buttons: whoever clicks "Skip" or "Done" has decided. A card
    /// closed by a click next to it has not — a stray click in the sidebar during step 2
    /// should not cost the introduction for good, so that one comes back next launch.
    func finish(seen: Bool = true) {
        if seen { defaults.set(true, forKey: Self.seenKey) }
        fallback?.cancel()
        fallback = nil
        step = nil
        asSheet = false
    }

    private func go(to next: Step) {
        fallback?.cancel()
        generation += 1
        appeared = false
        asSheet = next.isSheet
        step = next
        guard !next.isSheet else { return }
        let mine = generation
        fallback = Task { [weak self] in
            // Long enough for a sheet to finish animating away before the next popover opens:
            // a shorter wait showed the card twice on a slow Mac.
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, !Task.isCancelled, generation == mine, !appeared else { return }
            // The anchor is not on screen — a collapsed sidebar, a hidden toolbar. Show the card
            // as a sheet rather than let the tour stall on a popover that never opens.
            asSheet = true
        }
    }

    /// A card says it is on screen; until then the fallback is still armed.
    func cardAppeared(_ generation: Int) {
        guard generation == self.generation else { return }
        appeared = true
    }

    /// What a view binds its popover to: non-nil only while this step is current and anchored.
    func popover(_ step: Step) -> Binding<IntroCardID?> {
        Binding(
            get: { self.card(step, sheet: false) },
            set: { if $0 == nil { self.dismissed(step, sheet: false) } })
    }

    /// The sheet over the whole window: the steps with no anchor, and any that fell back to one.
    var sheet: Binding<IntroCardID?> {
        Binding(
            get: { self.step.flatMap { self.card($0, sheet: true) } },
            set: { if $0 == nil, let step = self.step { self.dismissed(step, sheet: true) } })
    }

    private func card(_ step: Step, sheet: Bool) -> IntroCardID? {
        guard self.step == step, asSheet == sheet else { return nil }
        return IntroCardID(id: generation, step: step)
    }

    /// Ends the tour — but only for the card that is actually being presented. A `nil` written
    /// back by a popover we ourselves just took down (next step, or the switch to a sheet) is
    /// not the user closing anything.
    private func dismissed(_ step: Step, sheet: Bool) {
        guard card(step, sheet: sheet) != nil, appeared else { return }
        finish(seen: false)
    }
}

/// Identity of one shown card: which step, and which time round.
struct IntroCardID: Identifiable, Equatable {
    let id: Int
    let step: IntroTour.Step
}

struct IntroCard: View {
    let tour: IntroTour
    let card: IntroCardID

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(card.step.title).font(.headline)
            Text(card.step.text)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Toggle("Beim Start zeigen", isOn: Bindable(tour).showAtStart)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(card.step.rawValue + 1) von \(IntroTour.Step.allCases.count)")
                    .font(.caption).foregroundStyle(.tertiary)
                if card.step != .done {
                    Button("Überspringen") { tour.finish(seen: true) }
                }
                Button(card.step == .done ? "Fertig" : "Weiter") { tour.next() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { tour.cardAppeared(card.id) }
    }
}

extension View {
    /// Hangs a tour step on the part of the window it is about.
    func introStep(_ step: IntroTour.Step, _ tour: IntroTour, edge: Edge) -> some View {
        popover(item: tour.popover(step), arrowEdge: edge) { card in
            IntroCard(tour: tour, card: card)
        }
    }
}
