// swift-tools-version: 6.0
// Spike S4: App Sandbox + Sparkle + keychain + network/ATS for MailKeeper.
// S4Spike is assembled into a signed, sandboxed .app by build.sh; s4tool (unsandboxed CLI)
// creates a throwaway EdDSA key, signs the update archive and writes the appcast.
import PackageDescription

let package = Package(
    name: "S4Sandbox",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(name: "S4Spike", dependencies: [.product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(name: "s4tool"),
    ],
    swiftLanguageModes: [.v5]
)
