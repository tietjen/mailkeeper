import AppKit
import SwiftUI

/// The tour of the window (8.5): a few cards at the real parts of the window, so the first
/// look is not a wall of empty columns. On the first launch it follows the setup
/// (`SetupAssistant`); both can be run again from the Help menu.
///
/// Four things about this are not obvious, all learned the hard way:
///
/// 1. The columns of a `NavigationSplitView` are hosted separately, so one overlay spanning the
///    window cannot point at them. Each step therefore hangs as a popover on the view it talks
///    about.
/// 2. That popover is an `NSPopover` of our own with `.applicationDefined` behaviour, not
///    SwiftUI's `.popover`. SwiftUI's is transient: it closed whenever MailKeeper lost focus or
///    the user clicked next to it — and took the whole tour with it (TJ, 0.1.0). Only the card's
///    own buttons end the tour now.
/// 3. A popover only appears when its anchor is on screen. A collapsed sidebar or a hidden
///    toolbar would stall the tour for good — so a step that has not appeared after a moment, or
///    whose anchor leaves the window, is shown as a sheet instead.
/// 4. Cards are presented by identity, not by a boolean: a late message about the previous card
///    must not act on the current one.
@MainActor
@Observable
final class IntroTour {
    enum Step: Int, CaseIterable, Identifiable {
        case sidebar, list, reader, toolbar, done
        var id: Int { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .sidebar: "Die Seitenleiste"
            case .list: "Die Liste"
            case .reader: "Der Leser"
            case .toolbar: "Abrufen und Suchen"
            case .done: "Das war's"
            }
        }

        var text: LocalizedStringKey {
            switch self {
            case .sidebar:
                "Oben „Alle Nachrichten“ aus allen Konten, darunter Papierkorb und „Verdächtig“. Dann jedes Konto mit seinen Ordnern – „Alle Ordner“ zeigt nur dieses Konto. Gespeicherte Suchen landen als eigene Ansicht darüber."
            case .list:
                "Die Mails der gewählten Ansicht. Über „Ansicht“ in der Symbolleiste wird daraus eine Gruppierung nach Absender, Domain oder Liste — so räumt man ein volles Postfach auf, statt Mail für Mail."
            case .reader:
                "Rechts die geöffnete Mail. „Ort“ sagt, ob sie noch auf dem Server liegt oder nur noch im Archiv, „Echtheit“, was der empfangende Mailserver über den Absender festgestellt hat."
            case .toolbar:
                "Rechts oben Abrufen – es holt neue Mail aus allen Konten dieses Archivs, nur lesend – und Importieren für vorhandene Maildir-, mbox- oder .eml-Bestände. In der Mitte die Ansicht, daneben das Suchfeld."
            case .done:
                "Das Archiv wechselst du mit einem Klick auf den Fenstertitel. Was beim Löschen und Verschieben auf dem Server mit dem Archiv passiert, steht in der Hilfe (⌘?) unter „Server und Archiv“. Rundgang und Einrichtung findest du im Hilfemenü wieder."
            }
        }

        /// Steps with nothing in the window to point at are sheets from the start.
        var isSheet: Bool { self == .done }
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

    /// The tour has been finished or skipped once — then the setup does not come back by itself
    /// either: whoever saw the tour has been through the first launch.
    var wasSeen: Bool { defaults.bool(forKey: Self.seenKey) }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        showAtStart = defaults.bool(forKey: Self.atStartKey)
    }

    /// Called when the window is up (or the setup is done). Runs on the first launch, and after
    /// that only if the box in the card is ticked — never twice in one launch.
    func startIfWanted() {
        guard !started else { return }
        guard showAtStart || !wasSeen else { return }
        start()
    }

    func start() {
        started = true
        go(to: Step.allCases[0])
    }

    func next() {
        guard let step, let following = Step(rawValue: step.rawValue + 1) else { return finish() }
        go(to: following)
    }

    /// Only the card's buttons call this ("Überspringen", "Fertig"): whoever clicks one has
    /// decided. Losing focus or clicking next to a card ends nothing (TJ).
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

    /// The view a popover hangs on left the window (sidebar collapsed, toolbar item gone into
    /// the overflow): the card moves into a sheet instead of vanishing.
    func anchorLost(_ generation: Int) {
        guard generation == self.generation, step?.isSheet == false else { return }
        asSheet = true
    }

    /// The card a step's popover shows: non-nil only while this step is current and anchored.
    func popoverCard(_ step: Step) -> IntroCardID? { card(step, sheet: false) }

    /// The sheet over the whole window: the steps with no anchor, and any that fell back to one.
    /// A `nil` written back (the window closing, a sheet being swapped) ends nothing — the
    /// getter still names the card, so SwiftUI shows it again.
    var sheet: Binding<IntroCardID?> {
        Binding(get: { self.step.flatMap { self.card($0, sheet: true) } }, set: { _ in })
    }

    private func card(_ step: Step, sheet: Bool) -> IntroCardID? {
        guard self.step == step, asSheet == sheet else { return nil }
        return IntroCardID(id: generation, step: step)
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
                        .keyboardShortcut(.cancelAction)
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
        modifier(IntroStepModifier(tour: tour, step: step, edge: edge))
    }
}

/// Reads the tour in `body`, so a step change redraws the anchor with its new card.
private struct IntroStepModifier: ViewModifier {
    let tour: IntroTour
    let step: IntroTour.Step
    let edge: Edge

    func body(content: Content) -> some View {
        content.background(IntroPopoverAnchor(tour: tour, card: tour.popoverCard(step), edge: edge))
    }
}

/// An invisible view behind the anchor that owns the step's `NSPopover`. `.applicationDefined`
/// and a delegate that refuses every close the popover did not ask for: the card stays through
/// a switch to another app and a click next to it, and goes only when the tour moves on.
private struct IntroPopoverAnchor: NSViewRepresentable {
    let tour: IntroTour
    let card: IntroCardID?
    let edge: Edge

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        let coordinator = context.coordinator
        view.changed = { [weak coordinator] in coordinator?.anchorChanged() }
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        context.coordinator.show(card, tour: tour, anchor: view, edge: edge)
    }

    static func dismantleNSView(_ view: AnchorView, coordinator: Coordinator) {
        coordinator.close()
    }

    final class AnchorView: NSView {
        /// Into or out of a window, or laid out: a card that could not be shown yet may be now.
        var changed: (() -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            changed?()
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            changed?()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }  // never takes a click from the anchor
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        private var popover: NSPopover?
        private var shown: IntroCardID?
        /// What should be on screen; kept while the anchor has no window yet.
        private var wanted: (card: IntroCardID, tour: IntroTour, anchor: AnchorView, edge: Edge)?

        func show(_ card: IntroCardID?, tour: IntroTour, anchor: AnchorView, edge: Edge) {
            // No card for this anchor (another step, or this one moved into a sheet): forget it
            // entirely, or a later layout pass would bring the old card back beside the sheet.
            guard let card else { return close() }
            guard card != shown || popover == nil else { return }
            close()
            wanted = (card, tour, anchor, edge)
            present()
        }

        func anchorChanged() {
            guard let wanted else { return }
            if wanted.anchor.window == nil {
                guard popover != nil else { return }  // not shown yet: wait for the window
                // The anchor left the window while its card was up: from now on the tour shows
                // it as a sheet. Told after this AppKit callback, not in the middle of it.
                let (tour, id) = (wanted.tour, wanted.card.id)
                close()
                Task { @MainActor in tour.anchorLost(id) }
            } else if popover == nil {
                present()
            }
        }

        private func present() {
            guard popover == nil, let wanted, let window = wanted.anchor.window, !wanted.anchor.bounds.isEmpty else { return }
            guard window.isVisible else {
                // the window is about to come up (tour started from onAppear): try again shortly
                let card = wanted.card
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self, self.wanted?.card == card else { return }
                    self.present()
                }
                return
            }
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            popover.animates = true
            popover.delegate = self
            let host = NSHostingController(rootView: IntroCard(tour: wanted.tour, card: wanted.card))
            host.sizingOptions = .preferredContentSize
            popover.contentViewController = host
            popover.show(relativeTo: wanted.anchor.bounds, of: wanted.anchor, preferredEdge: Self.rectEdge(wanted.edge))
            self.popover = popover
            shown = wanted.card
        }

        func close() {
            popover?.close()  // `close()` skips the delegate; only our own closes get through
            popover = nil
            shown = nil
            wanted = nil
        }

        func popoverShouldClose(_ popover: NSPopover) -> Bool { false }

        /// The anchor view is not flipped: `.maxY` is its top edge.
        private static func rectEdge(_ edge: Edge) -> NSRectEdge {
            switch edge {
            case .leading: .minX
            case .trailing: .maxX
            case .top: .maxY
            case .bottom: .minY
            }
        }
    }
}
