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
        // ADR-0009: PDF text extraction runs in this sandboxed XPC service, bundled with the app.
        .executable(name: "MailKeeperPDFService", targets: ["MailKeeperPDFService"]),
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
        // ADR-0004: language models (OpenAI-compatible endpoint, Apple on-device). Kit stays model-free.
        .target(name: "MailKeeperAI", dependencies: ["MailKeeperKit"]),
        .executableTarget(name: "mkctl", dependencies: ["MailKeeperKit", "MailKeeperIMAP", "MailKeeperAI"]),
        .executableTarget(name: "MailKeeperGUI", dependencies: ["MailKeeperKit", "MailKeeperIMAP", "MailKeeperAI"]),
        // PDFKit lives here and is linked only into the service, never into the app.
        .target(name: "MailKeeperPDF", dependencies: ["MailKeeperKit"]),
        .executableTarget(name: "MailKeeperPDFService", dependencies: ["MailKeeperKit", "MailKeeperPDF"]),
        .testTarget(name: "MailKeeperKitTests", dependencies: ["MailKeeperKit"]),
        .testTarget(name: "MailKeeperIMAPTests", dependencies: ["MailKeeperIMAP", "MailKeeperKit"]),
        .testTarget(name: "MailKeeperPDFTests", dependencies: ["MailKeeperPDF", "MailKeeperKit"]),
        .testTarget(name: "MailKeeperAITests", dependencies: ["MailKeeperAI", "MailKeeperKit"]),
    ]
)
