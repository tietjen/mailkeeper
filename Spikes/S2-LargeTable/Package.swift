// swift-tools-version: 6.0
// Spike S2: can the message list show 200k rows from SQLite smoothly?
// Variants: SwiftUI Table over an in-memory array, SwiftUI Table over a lazy
// collection backed by a SQLite page cache, and NSTableView via NSViewRepresentable.
import PackageDescription

let package = Package(
    name: "S2LargeTable",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "S2LargeTable")
    ],
    swiftLanguageModes: [.v5]  // spike: keep concurrency checking out of the measurement code
)
