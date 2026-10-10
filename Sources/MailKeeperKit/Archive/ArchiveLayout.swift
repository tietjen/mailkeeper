import Foundation

/// The on-disk archive (ADR-0001):
///
///     <root>/archive.json      format marker
///     <root>/blobs/aa/bb/<sha256>.eml
///     <root>/journal/<account>/<yyyy-mm>.jsonl
///     <root>/index.sqlite      rebuildable projection
///     <root>/tmp/              staging for atomic writes
///     <root>/.lock             held by the one writing process
public struct ArchiveLayout: Sendable {
    public static let formatVersion = 1

    public let root: URL
    public var blobsURL: URL { root.appending(path: "blobs", directoryHint: .isDirectory) }
    public var journalURL: URL { root.appending(path: "journal", directoryHint: .isDirectory) }
    public var tmpURL: URL { root.appending(path: "tmp", directoryHint: .isDirectory) }
    public var indexURL: URL { root.appending(path: "index.sqlite") }
    var markerURL: URL { root.appending(path: "archive.json") }
    var lockURL: URL { root.appending(path: ".lock") }

    public var blobs: BlobStore { BlobStore(root: blobsURL, tmp: tmpURL) }

    private struct Marker: Codable {
        var format: Int
        var created: Double
        var app: String
    }

    /// Opens an archive, creating it when `create` is set and the folder holds no archive yet.
    public static func open(at root: URL, create: Bool) throws -> ArchiveLayout {
        let layout = ArchiveLayout(root: root)
        let fm = FileManager.default
        if let data = try? Data(contentsOf: layout.markerURL) {
            guard let marker = try? JSONDecoder().decode(Marker.self, from: data) else {
                throw ArchiveError.notAnArchive(path: root.path)
            }
            guard marker.format <= formatVersion else { throw ArchiveError.unsupportedFormat(marker.format) }
        } else {
            guard create else { throw ArchiveError.notAnArchive(path: root.path) }
            // Refuse to turn an unrelated, non-empty folder into an archive.
            let existing = (try? fm.contentsOfDirectory(atPath: root.path))?.filter { !$0.hasPrefix(".") } ?? []
            guard existing.isEmpty else { throw ArchiveError.notAnArchive(path: root.path) }
            try makePrivateDirectory(root)
            let marker = Marker(format: formatVersion, created: Date().timeIntervalSince1970, app: "MailKeeper")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try writeDurably(try enc.encode(marker), to: layout.markerURL)
        }
        for dir in [layout.blobsURL, layout.journalURL, layout.tmpURL] { try makePrivateDirectory(dir) }
        // Leftovers of interrupted writes are never referenced; drop them.
        for item in (try? fm.contentsOfDirectory(at: layout.tmpURL, includingPropertiesForKeys: nil)) ?? [] {
            try? fm.removeItem(at: item)
        }
        return layout
    }

    /// Whether the archive's volume is encrypted (FileVault/APFS encryption). nil = unknown.
    public var volumeIsEncrypted: Bool? {
        (try? root.resourceValues(forKeys: [.volumeIsEncryptedKey]))?.volumeIsEncrypted
    }
}

/// Exclusive advisory lock (flock) on `<root>/.lock` for the writing process. Released when the
/// object is deallocated or the process exits.
public final class ArchiveLock: Sendable {
    private let fd: Int32

    public init(_ layout: ArchiveLayout) throws {
        let fd = open(layout.lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ArchiveError.io("lock open", path: layout.lockURL.path) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ArchiveError.locked(path: layout.root.path)
        }
        self.fd = fd
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}
