import Sparkle
import SwiftUI

/// Self-updates (Phase 8, ADR-0013). MailKeeper is not in the App Store, so it brings its own
/// updater: Sparkle checks an appcast, verifies an EdDSA signature against the public key in
/// `Info.plist` and installs only what that key signed.
///
/// A dev build carries no feed (`SUFeedURL` is left out in `build-app.sh`), so it never pulls a
/// release over itself. The menu entry then says so instead of doing nothing.
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
        // startingUpdater: Sparkle does its scheduled check by itself; the first run asks the
        // user whether that is wanted (Sparkle's own permission prompt).
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
}

/// The menu entry. Disabled while a check runs; absent from a build without a feed.
struct CheckForUpdatesButton: View {
    @State private var canCheck = Updates.shared.canCheck

    var body: some View {
        if Updates.shared.isAvailable {
            Button("Nach Updates suchen …") { Updates.shared.checkNow() }
                .disabled(!canCheck)
                .task {
                    // `canCheckForUpdates` is KVO-observable; polling once a second is enough
                    // for a menu item and saves a KVO bridge.
                    while !Task.isCancelled {
                        canCheck = Updates.shared.canCheck
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
        }
    }
}
