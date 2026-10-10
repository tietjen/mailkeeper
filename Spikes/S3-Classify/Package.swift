// swift-tools-version: 6.0
// Spike S3: mail classification quality and latency — Apple Foundation Models (on-device)
// vs. an OpenAI-compatible endpoint (homelab LiteLLM). Synthetic cases only.
import PackageDescription

let package = Package(
    name: "S3Classify",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(name: "S3Classify")
    ]
)
