import Sparkle
import SwiftUI

/// Self-updates (Phase 8, ADR-0013). MailKeeper is not in the App Store, so it brings its own
/// updater: Sparkle checks an appcast, verifies an EdDSA signature against the public key in
/// `Info.plist` and installs only what that key signed.
///
/// A dev build carries no feed (`SUFeedURL` is left out in `build-app.sh`), so it never pulls a
/// release over itself; the menu entry is then absent.
///
/// Whether Sparkle looks by itself is the user's decision: `SUEnableAutomaticChecks` is left
/// out of the Info.plist on purpose, so Sparkle asks on the second start instead of quietly
/// contacting github.com from the first.
@MainActor
final class Updates {
    static let shared = Updates()

    /// nil when the build has no feed — a dev build, or one made without signing.
    private let controller: SPUStandardUpdaterController?

    private init() {
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            controller = nil
            return
        }
        // startingUpdater: Sparkle schedules its own checks once the user has allowed them
        // (its permission prompt, which appears because SUEnableAutomaticChecks is unset).
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    }

    var isAvailable: Bool { controller != nil }

    /// Whether Sparkle looks by itself. Mirrors `SUEnableAutomaticChecks`, and is what the
    /// user toggles in the settings.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    func checkNow() { controller?.updater.checkForUpdates() }

    /// False while a check is running — the menu entry greys out.
    var canCheck: Bool { controller?.updater.canCheckForUpdates ?? false }

    /// KVO on Sparkle's own property, so the menu entry follows a running check. The value comes
    /// out of the change, not from the updater: that property is main-actor isolated while this
    /// callback is not. `.new` fills `newValue` on the `.initial` notification as well, so the
    /// entry starts out enabled instead of greyed; `canCheck` stands in were it ever missing.
    func observeCanCheck(_ changed: @escaping @MainActor (Bool) -> Void) -> NSKeyValueObservation? {
        controller?.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { _, change in
            let value = change.newValue
            Task { @MainActor in changed(value ?? Updates.shared.canCheck) }
        }
    }
}

/// The menu entry. Disabled while a check runs; absent from a build without a feed.
struct CheckForUpdatesButton: View {
    @State private var model = CheckForUpdatesModel()

    var body: some View {
        if Updates.shared.isAvailable {
            Button("Nach Updates suchen …") { Updates.shared.checkNow() }
                .disabled(!model.canCheck)
        }
    }
}

/// Sparkle publishes `canCheckForUpdates` through KVO. A `.task` on a menu command is not
/// reliably run by SwiftUI, so the state is observed rather than polled.
@MainActor
@Observable
final class CheckForUpdatesModel {
    private(set) var canCheck = Updates.shared.canCheck
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = Updates.shared.observeCanCheck { [weak self] value in
            self?.canCheck = value
        }
    }
}
