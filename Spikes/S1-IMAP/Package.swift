// swift-tools-version: 6.0
// Spike S1: is apple/swift-nio-imap usable as MailKeeper's IMAP layer?
// Network.framework (NIOTS) cannot upgrade a connection with STARTTLS, which Proton Bridge
// requires, so the transport is NIOPosix + NIOSSL.
// Probed against mailcow (IMAPS), Gmail (IMAPS + X-GM-EXT-1) and Proton Mail Bridge (STARTTLS on loopback).
import PackageDescription

let package = Package(
    name: "S1IMAP",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-imap.git", exact: "0.4.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.30.0"),
    ],
    targets: [
        .executableTarget(name: "S1IMAP", dependencies: [
            .product(name: "NIOIMAP", package: "swift-nio-imap"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "NIOSSL", package: "swift-nio-ssl"),
        ])
    ],
    swiftLanguageModes: [.v5]
)
