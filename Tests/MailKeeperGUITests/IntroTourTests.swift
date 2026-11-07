import Foundation
import Testing

@testable import MailKeeperGUI

/// A defaults domain of its own, so a test never writes into the running user's.
private func freshDefaults(_ name: String) -> UserDefaults {
    let suite = "de.paranoidsecurity.MailKeeper.tests.\(name)"
    UserDefaults.standard.removePersistentDomain(forName: suite)
    return UserDefaults(suiteName: suite)!
}

/// The tour's state machine (8.5). Everything here is the logic the reviews found wrong: what
/// the checkbox promises, which card is current, and that nothing but the card's own buttons
/// ends the tour (TJ: it vanished when MailKeeper lost focus).
@MainActor
@Suite("Rundgang (8.5)")
struct IntroTourTests {
    @Test("Erststart führt, danach nicht mehr")
    func firstLaunchOnly() {
        let defaults = freshDefaults(#function)
        let first = IntroTour(defaults: defaults)
        first.startIfWanted()
        #expect(first.step == .sidebar)
        #expect(first.showAtStart == false)  // die Box ist aus und sagt die Wahrheit

        first.startIfWanted()  // zweite Ansicht im selben Lauf
        #expect(first.generation == 1, "der Rundgang darf nicht zweimal starten")

        while first.step != nil { first.next() }
        #expect(first.wasSeen)

        let second = IntroTour(defaults: defaults)
        second.startIfWanted()
        #expect(second.step == nil)
    }

    @Test("Angehakte Box bringt ihn wieder — das war der Fehler aus dem Review")
    func tickedBoxWins() {
        let defaults = freshDefaults(#function)
        let first = IntroTour(defaults: defaults)
        first.startIfWanted()
        first.showAtStart = true   // Nutzer hakt in der Karte an
        while first.step != nil { first.next() }

        let second = IntroTour(defaults: defaults)
        #expect(second.showAtStart == true)
        second.startIfWanted()
        #expect(second.step == .sidebar)
    }

    @Test("Ein nil vom Blatt beendet nichts — nur die Knöpfe")
    func onlyTheButtonsEndIt() {
        let defaults = freshDefaults(#function)
        let tour = IntroTour(defaults: defaults)
        tour.start()
        while tour.step != .done { tour.next() }
        tour.cardAppeared(tour.generation)
        #expect(tour.sheet.wrappedValue != nil)
        tour.sheet.wrappedValue = nil                 // Fenster zu, Blatt ausgetauscht
        #expect(tour.step == .done, "ein Fokuswechsel oder Klick daneben darf den Rundgang nicht beenden")
        #expect(tour.sheet.wrappedValue != nil, "die Karte kommt wieder")
        #expect(!tour.wasSeen)

        tour.finish(seen: true)                       // „Überspringen“
        #expect(tour.step == nil)
        #expect(IntroTour(defaults: defaults).startedWouldRun == false)
    }

    @Test("Verlorener Anker macht aus dem Popover ein Blatt")
    func lostAnchorBecomesASheet() {
        let tour = IntroTour(defaults: freshDefaults(#function))
        tour.start()
        tour.cardAppeared(tour.generation)
        #expect(tour.popoverCard(.sidebar) != nil)
        tour.anchorLost(tour.generation - 1)          // eine alte Meldung ändert nichts
        #expect(tour.popoverCard(.sidebar) != nil)
        tour.anchorLost(tour.generation)              // Seitenleiste eingeklappt
        #expect(tour.popoverCard(.sidebar) == nil)
        #expect(tour.sheet.wrappedValue?.step == .sidebar)
        tour.next()
        #expect(tour.popoverCard(.list) != nil, "der nächste Schritt versucht es wieder am Fenster")
    }

    @Test("Ein Anker, der nie erscheint, fällt aufs Blatt zurück")
    func neverAnchoredFallsBack() async throws {
        let tour = IntroTour(defaults: freshDefaults(#function))
        tour.start()
        #expect(tour.popoverCard(.sidebar) != nil)
        try await Task.sleep(for: .seconds(2))
        #expect(tour.popoverCard(.sidebar) == nil)
        #expect(tour.sheet.wrappedValue?.step == .sidebar)
    }

    @Test("Nie zwei Karten gleichzeitig")
    func neverTwoCards() {
        let tour = IntroTour(defaults: freshDefaults(#function))
        tour.start()
        while tour.step != nil {
            let shown = IntroTour.Step.allCases.filter { tour.popoverCard($0) != nil }
            let sheet = tour.sheet.wrappedValue == nil ? 0 : 1
            #expect(shown.count + sheet == 1, "Schritt \(tour.step!) zeigt \(shown.count + sheet) Karten")
            tour.next()
        }
    }

    @Test("Jeder Schritt hat Titel und Text")
    func everyStepHasWords() {
        for step in IntroTour.Step.allCases {
            #expect(String(describing: step.title).isEmpty == false)
            #expect(String(describing: step.text).isEmpty == false)
        }
    }
}

/// The setup on the first launch (TJ): separate from the tour, but the tour follows it the
/// first time — and an existing user is not greeted with it after an update.
@MainActor
@Suite("Einrichtung")
struct SetupAssistantTests {
    @Test("Erster Start: erst die Einrichtung, danach der Rundgang")
    func firstLaunchRunsSetupThenTour() {
        let defaults = freshDefaults(#function)
        let tour = IntroTour(defaults: defaults)
        let setup = SetupAssistant(defaults: defaults)
        #expect(setup.startIfFirstLaunch(tourSeen: tour.wasSeen))
        #expect(setup.page == .welcome)
        #expect(tour.step == nil, "der Rundgang wartet")

        #expect(setup.startIfFirstLaunch(tourSeen: tour.wasSeen), "ein zweites Fenster startet nichts neu, sagt aber: läuft")
        setup.next()
        #expect(setup.page == .archive)
        setup.next()
        setup.next()                                   // letzte Seite → fertig
        #expect(setup.page == nil)
        #expect(setup.takeTourFollows())
        #expect(!setup.takeTourFollows(), "nur einmal")
        tour.startIfWanted()
        #expect(tour.step == .sidebar)
    }

    @Test("Später zählt als gesehen, der Rundgang folgt trotzdem")
    func laterStillLeadsToTheTour() {
        let defaults = freshDefaults(#function)
        let setup = SetupAssistant(defaults: defaults)
        #expect(setup.startIfFirstLaunch(tourSeen: false))
        setup.finish()
        #expect(setup.takeTourFollows())
        #expect(!SetupAssistant(defaults: defaults).startIfFirstLaunch(tourSeen: false), "beim nächsten Start nicht mehr")
    }

    @Test("Wer den Rundgang kennt, bekommt die Einrichtung nicht ungefragt")
    func existingUsersAreLeftAlone() {
        let defaults = freshDefaults(#function)
        let setup = SetupAssistant(defaults: defaults)
        #expect(!setup.startIfFirstLaunch(tourSeen: true))
        #expect(setup.page == nil)
    }

    @Test("Aus dem Hilfemenü: ohne Rundgang danach")
    func fromTheMenuNoTourFollows() {
        let setup = SetupAssistant(defaults: freshDefaults(#function))
        setup.start()
        setup.back()                                   // auf der ersten Seite: bleibt
        #expect(setup.page == .welcome)
        setup.finish()
        #expect(!setup.takeTourFollows())
    }
}

/// The first launch creates no archive (TJ): nothing left behind by an app that is tried and
/// removed, and the setup asks where the mail goes.
@Suite("Archiv beim Start")
struct InitialArchiveTests {
    @Test("Erster Start legt nichts an")
    func firstLaunchCreatesNothing() {
        #expect(AppModel.initialArchive(environment: nil, hasBookmark: false, standardExists: false) == .none)
        #expect(AppModel.initialArchive(environment: "", hasBookmark: false, standardExists: false) == .none)
    }

    @Test("Ein vorhandenes Archiv öffnet sich wie bisher")
    func existingArchivesOpen() {
        #expect(AppModel.initialArchive(environment: nil, hasBookmark: true, standardExists: false) == .remembered)
        #expect(AppModel.initialArchive(environment: nil, hasBookmark: true, standardExists: true) == .remembered)
        #expect(AppModel.initialArchive(environment: nil, hasBookmark: false, standardExists: true) == .standard)
        #expect(AppModel.initialArchive(environment: "~/A", hasBookmark: true, standardExists: true) == .environment("~/A"))
    }
}

extension IntroTour {
    /// Was `startIfWanted` täte — für die Tests, ohne den Start wirklich auszulösen.
    var startedWouldRun: Bool {
        startIfWanted()
        return step != nil
    }
}
