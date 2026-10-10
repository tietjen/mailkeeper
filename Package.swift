// swift-tools-version: 6.0
// MailKeeper — local mail archive for macOS. See docs/adr/ for the architecture.
// Spikes/ hold independent throwaway packages and are not part of this build.
import PackageDescription

let package = Package(
    name: "MailKeeper",
    defaultLocalization: "de",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "MailKeeperKit", targets: ["MailKeeperKit"]),
        .executable(name: "mkctl", targets: ["mkctl"]),
        // Not named "MailKeeper": a case-only clash with "mailkeeper" paths breaks builds on
        // case-insensitive file systems (LaunchKeeper lesson).
        .executable(name: "MailKeeperGUI", targets: ["MailKeeperGUI"]),
    ],
    targets: [
        .target(name: "MailKeeperKit"),
        .executableTarget(name: "mkctl", dependencies: ["MailKeeperKit"]),
        .executableTarget(name: "MailKeeperGUI", dependencies: ["MailKeeperKit"]),
        .testTarget(name: "MailKeeperKitTests", dependencies: ["MailKeeperKit"]),
    ]
)
