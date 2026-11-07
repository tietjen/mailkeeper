import Foundation

/// Upper bounds for the "stays linear" tests. They are there to catch a quadratic regression,
/// not a slow machine: on their inputs linear code needs a fraction of the bound (locally
/// 0.02–0.27 s against bounds of 0.3–2 s, debug build, whole suite in parallel), quadratic
/// code takes far longer.
///
/// Locally the bound stays as written. On a CI runner (`CI` is set, as GitHub Actions does)
/// it is ten times wider: the hosted macOS runners are about six times slower and run the
/// suite in parallel on three cores. A bound of 1 s failed there at 1.11 s (CI run
/// 41858666372, 2026-11-04) for a check that takes 0.18 s locally.
enum TimeBudget {
    static let factor = (ProcessInfo.processInfo.environment["CI"] ?? "").isEmpty ? 1 : 10

    static func linear(_ local: Duration) -> Duration { local * factor }
}
