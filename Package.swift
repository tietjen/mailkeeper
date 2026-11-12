// swift-tools-version: 6.0
// MailKeeper — local mail archive for macOS. See docs/adr/ for the architecture.
// Spikes/ hold independent throwaway packages and are not part of this build.
//
// On Linux only the shared core builds — Kit, IMAP, AI, mkctl and the server mailkeeperd
// (mailkeeper-server). The app, the PDF service and Sparkle are macOS-only.
import PackageDescription

var products: [Product] = [
    .library(name: "MailKeeperKit", targets: ["MailKeeperKit"]),
    .executable(name: "mkctl", targets: ["mkctl"]),
    // mailkeeper-server: fetches the configured mailboxes into one archive per person.
    .executable(name: "mailkeeperd", targets: ["mailkeeperd"]),
]

var dependencies: [Package.Dependency] = [
    // ADR-0002: IMAP via swift-nio-imap (0.x, pinned exactly) on NIOPosix + NIOSSL
    // (Network.framework cannot do STARTTLS). Only MailKeeperIMAP depends on them.
    .package(url: "https://github.com/apple/swift-nio-imap.git", exact: "0.4.0"),
    .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
    .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
    // SHA-256 on Linux, where CryptoKit does not exist. Same API; on macOS nothing links it,
    // so the core there stays free of outside code. Declared on both so the pin is shared.
    .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
]

/// Linux stand-ins for frameworks macOS brings along.
let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto", condition: .when(platforms: [.linux]))
let sqlite: Target.Dependency = .target(name: "CSQLite", condition: .when(platforms: [.linux]))

var targets: [Target] = [
    // The system SQLite on Linux (libsqlite3-dev). The index needs FTS5 and, for
    // `contentless_delete`, 3.43 or newer — `Database` checks the version when it opens.
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])]),
    .target(name: "MailKeeperKit", dependencies: [crypto, sqlite]),
    .target(name: "MailKeeperIMAP", dependencies: [
        "MailKeeperKit", crypto,
        .product(name: "NIOIMAP", package: "swift-nio-imap"),
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "NIOSSL", package: "swift-nio-ssl"),
    ]),
    // ADR-0004: language models (OpenAI-compatible endpoint, Apple on-device). Kit stays model-free.
    .target(name: "MailKeeperAI", dependencies: ["MailKeeperKit"]),
    .executableTarget(name: "mkctl", dependencies: ["MailKeeperKit", "MailKeeperIMAP", "MailKeeperAI"]),
    // The server (mailkeeper-server): configuration, the fetch loop, its status. A library, so
    // the tests reach it; mailkeeperd is only the command line around it.
    .target(name: "MailKeeperServer", dependencies: ["MailKeeperKit", "MailKeeperIMAP"]),
    .executableTarget(name: "mailkeeperd", dependencies: ["MailKeeperKit", "MailKeeperServer"]),
    .testTarget(name: "MailKeeperKitTests", dependencies: ["MailKeeperKit"]),
    .testTarget(name: "MailKeeperIMAPTests", dependencies: ["MailKeeperIMAP", "MailKeeperKit"]),
    .testTarget(name: "MailKeeperServerTests", dependencies: ["MailKeeperServer", "MailKeeperKit"]),
    // The gold mails are read through #filePath, not through Bundle.module — declaring
    // them excluded keeps SwiftPM from warning about "unhandled files" on every build.
    .testTarget(name: "MailKeeperAITests", dependencies: ["MailKeeperAI", "MailKeeperKit"],
                exclude: ["Gold"]),
]

#if os(macOS)
products += [
    // Not named "MailKeeper": a case-only clash with "mailkeeper" paths breaks builds on
    // case-insensitive file systems (LaunchKeeper lesson).
    .executable(name: "MailKeeperGUI", targets: ["MailKeeperGUI"]),
    // ADR-0009: PDF text extraction runs in this sandboxed XPC service, bundled with the app.
    .executable(name: "MailKeeperPDFService", targets: ["MailKeeperPDFService"]),
]
dependencies += [
    // Phase 8: self-updates outside the App Store (ADR-0013). Only the GUI depends on it;
    // Kit, IMAP, AI and mkctl stay free of it. Sandboxed operation verified in spike S4.
    .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
]
targets += [
    .executableTarget(name: "MailKeeperGUI", dependencies: [
        "MailKeeperKit", "MailKeeperIMAP", "MailKeeperAI",
        .product(name: "Sparkle", package: "Sparkle"),
    ]),
    // PDFKit lives here and is linked only into the service, never into the app.
    .target(name: "MailKeeperPDF", dependencies: ["MailKeeperKit"]),
    .executableTarget(name: "MailKeeperPDFService", dependencies: ["MailKeeperKit", "MailKeeperPDF"]),
    .testTarget(name: "MailKeeperPDFTests", dependencies: ["MailKeeperPDF", "MailKeeperKit"]),
    // Only the parts of the GUI that are plain logic — the tour's state machine. SwiftPM
    // can link an executable target into a test bundle; views are not tested here.
    .testTarget(name: "MailKeeperGUITests", dependencies: ["MailKeeperGUI"]),
]
#endif

let package = Package(
    name: "MailKeeper",
    defaultLocalization: "de",
    platforms: [.macOS("26.0")],
    products: products,
    dependencies: dependencies,
    targets: targets
)
