import Foundation
import Testing

@testable import MailKeeperGUI

/// The tour's state machine (8.5). Everything here is the logic the review of 8.5 found
/// wrong twice: what the checkbox promises, and which `nil` from a binding counts as the
/// user closing a card.
@MainActor
@Suite("Einführung (8.5)")
struct IntroTourTests {
    /// A defaults domain of its own, so a test never writes into the running user's.
    private func freshDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "de.paranoidsecurity.MailKeeper.tests.\(name)"
        UserDefaults.standard.removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite)!
    }

    @Test("Erststart führt, danach nicht mehr")
    func firstLaunchOnly() {
        let defaults = freshDefaults()
        let first = IntroTour(defaults: defaults)
        first.startIfWanted()
        #expect(first.step == .welcome)
        #expect(first.showAtStart == false)  // die Box ist aus und sagt die Wahrheit

        first.startIfWanted()  // zweite Ansicht im selben Lauf
        #expect(first.generation == 1, "die Tour darf nicht zweimal starten")

        while first.step != nil { first.next() }

        let second = IntroTour(defaults: defaults)
        second.startIfWanted()
        #expect(second.step == nil)
    }

    @Test("Angehakte Box bringt sie wieder — das war der Fehler aus dem Review")
    func tickedBoxWins() {
        let defaults = freshDefaults()
        let first = IntroTour(defaults: defaults)
        first.startIfWanted()
        first.showAtStart = true   // Nutzer hakt in der Karte an
        while first.step != nil { first.next() }

        let second = IntroTour(defaults: defaults)
        #expect(second.showAtStart == true)
        second.startIfWanted()
        #expect(second.step == .welcome)
    }

    @Test("Überspringen zählt als gesehen, ein Klick daneben nicht")
    func skipCountsClickingAsideDoesNot() {
        let aside = freshDefaults("aside")
        let tour = IntroTour(defaults: aside)
        tour.startIfWanted()
        tour.cardAppeared(tour.generation)
        tour.sheet.wrappedValue = nil          // Klick neben die Karte
        #expect(tour.step == nil)
        #expect(IntroTour(defaults: aside).startedWouldRun, "kommt beim nächsten Start wieder")

        let skipped = freshDefaults("skip")
        let other = IntroTour(defaults: skipped)
        other.startIfWanted()
        other.finish(seen: true)
        #expect(IntroTour(defaults: skipped).startedWouldRun == false)
    }

    @Test("Ein nil von einer Karte, die nie erschien, beendet nichts")
    func staleNilIsIgnored() {
        let tour = IntroTour(defaults: freshDefaults())
        tour.start()
        tour.next()  // .sidebar, Popover, noch kein onAppear
        #expect(tour.step == .sidebar)
        tour.popover(.sidebar).wrappedValue = nil
        #expect(tour.step == .sidebar, "ohne onAppear kann niemand geklickt haben")

        tour.cardAppeared(tour.generation)
        tour.popover(.sidebar).wrappedValue = nil
        #expect(tour.step == nil)
    }

    @Test("Ein nil vom falschen Schritt beendet nichts")
    func nilFromAnotherStepIsIgnored() {
        let tour = IntroTour(defaults: freshDefaults())
        tour.start()
        tour.next()
        tour.cardAppeared(tour.generation)
        tour.popover(.list).wrappedValue = nil        // die Karte, die gerade nicht zu sehen ist
        #expect(tour.step == .sidebar)
        tour.sheet.wrappedValue = nil                 // und das Blatt erst recht nicht
        #expect(tour.step == .sidebar)
    }

    @Test("Nie zwei Karten gleichzeitig")
    func neverTwoCards() {
        let tour = IntroTour(defaults: freshDefaults())
        tour.start()
        while tour.step != nil {
            let shown = IntroTour.Step.allCases.filter { tour.popover($0).wrappedValue != nil }
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

extension IntroTour {
    /// Was `startIfWanted` täte — für die Tests, ohne den Start wirklich auszulösen.
    var startedWouldRun: Bool {
        startIfWanted()
        return step != nil
    }
}
