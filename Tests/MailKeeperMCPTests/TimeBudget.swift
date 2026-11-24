import Foundation

/// Upper bounds for "ends at its deadline" checks: they catch a deadline that does not fire,
/// not a slow machine. Locally the bound stays as written; on a CI runner (`CI` is set, as
/// GitHub Actions does) it is ten times wider, like `TimeBudget` in the Kit tests — the hosted
/// macOS runners start the whole suite at once on three cores. A test that uses it must keep
/// the wider bound below the time a missing deadline would take.
///
/// `summariesEndAtTheirDeadline` failed on the 5 s bound there (CI 45241474510, 2026-11-23).
enum TimeBudget {
    static let factor = (ProcessInfo.processInfo.environment["CI"] ?? "").isEmpty ? 1 : 10

    static func linear(_ local: Duration) -> Duration { local * factor }
}
