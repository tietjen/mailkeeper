import Foundation

/// How long a provider in these tests waits for its URLProtocol stub or loopback server. The
/// stubs answer at once; the timeout only keeps a broken test from hanging, and only one test
/// looks at its value (the timeout error carries it). Locally 5 s, on a CI runner (`CI` is set,
/// as GitHub Actions does) ten times that, like `TimeBudget` in the Kit tests.
///
/// Since GitHub's runner image macos-26-arm64 20261117 two stub tests ran into the 5 s there,
/// in every run (CI 45241474510 and 45373496563, release 45243846026, 2026-11-23/24): the
/// whole suite starts at once on three cores, and a neighbour on the same stub took 39 s.
/// Locally they need a fraction of a second, also on the efficiency cores alone.
enum TimeBudget {
    static let factor: Double = (ProcessInfo.processInfo.environment["CI"] ?? "").isEmpty ? 1 : 10

    static let providerTimeout: Double = 5 * factor
}
