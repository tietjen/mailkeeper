import Foundation

/// Settings that belong to one archive, not to the Mac: another archive, opened on the same Mac,
/// has its own trash and its own period (TJ switches between archives).
public struct ArchiveSettings: Codable, Equatable, Sendable {
    /// Days a message stays in the archive trash before it is purged; nil = only by hand
    /// ("Papierkorb leeren", "Endgültig löschen").
    public var trashDays: Int?

    public static let defaultTrashDays = 30
    /// What the trash view offers. A period outside these (an edited file) is still honoured.
    public static let trashDayChoices = [7, 14, 30, 60, 90, 180, 365]
    static let trashDayRange = 1...3650

    public init(trashDays: Int? = ArchiveSettings.defaultTrashDays) {
        self.trashDays = trashDays.map { min(max($0, Self.trashDayRange.lowerBound), Self.trashDayRange.upperBound) }
    }

    private enum CodingKeys: String, CodingKey { case trashDays }

    /// A missing key is the default (an older file), an explicit null is "only by hand".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.trashDays) {
            self.init(trashDays: try c.decodeNil(forKey: .trashDays) ? nil : c.decode(Int.self, forKey: .trashDays))
        } else {
            self.init()
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let trashDays { try c.encode(trashDays, forKey: .trashDays) } else { try c.encodeNil(forKey: .trashDays) }
    }
}

/// `<archive>/settings.json`, replaced atomically. Missing = the defaults (the trash empties
/// after 30 days, as it always did). There but unreadable = the trash empties only by hand: a
/// file that cannot be read (a share that is away, a broken copy) must not turn "only by hand"
/// into 30 days and purge months of trash unasked (review: fail closed).
public struct ArchiveSettingsStore: Sendable {
    public let url: URL

    public init(layout: ArchiveLayout) {
        url = layout.root.appending(path: "settings.json")
    }

    public func load() -> (settings: ArchiveSettings, unreadable: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (ArchiveSettings(), false) }
        guard let data = try? readFile(url.path, limit: 1 << 16),
              let settings = try? JSONDecoder().decode(ArchiveSettings.self, from: data) else {
            return (ArchiveSettings(trashDays: nil), true)
        }
        return (settings, false)
    }

    public func save(_ settings: ArchiveSettings) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let staging = url.deletingLastPathComponent().appending(path: ".settings-\(UUID().uuidString).part")
        do { try writeDurably(try encoder.encode(settings), to: staging) } catch {
            unlink(staging.path)
            throw error
        }
        guard rename(staging.path, url.path) == 0 else {
            unlink(staging.path)
            throw ArchiveError.io("rename settings.json", path: url.path)
        }
    }
}
