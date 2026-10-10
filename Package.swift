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
    dependencies: [
        // ADR-0002: IMAP via swift-nio-imap (0.x, pinned exactly) on NIOPosix + NIOSSL
        // (Network.framework cannot do STARTTLS). Only MailKeeperIMAP depends on them.
        .package(url: "https://github.com/apple/swift-nio-imap.git", exact: "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
    ],
    targets: [
        .target(name: "MailKeeperKit"),
        .target(name: "MailKeeperIMAP", dependencies: [
            "MailKeeperKit",
            .product(name: "NIOIMAP", package: "swift-nio-imap"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ]),
        .executableTarget(name: "mkctl", dependencies: ["MailKeeperKit", "MailKeeperIMAP"]),
        .executableTarget(name: "MailKeeperGUI", dependencies: ["MailKeeperKit", "MailKeeperIMAP"]),
        .testTarget(name: "MailKeeperKitTests", dependencies: ["MailKeeperKit"]),
        .testTarget(name: "MailKeeperIMAPTests", dependencies: ["MailKeeperIMAP", "MailKeeperKit"]),
    ]
)
