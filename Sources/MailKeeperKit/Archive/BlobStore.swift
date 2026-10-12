import CryptoKit
import Foundation

public enum ArchiveError: Error, CustomStringConvertible, Sendable {
    case io(String, path: String)
    case integrity(sha256: String, actual: String)
    case locked(path: String)
    case notAnArchive(path: String)
    case unsupportedFormat(Int)
    /// Input the archive refuses (a message for the user, German like the UI).
    case invalid(String)

    public var description: String {
        switch self {
        case .io(let what, let path): "I/O error (\(what)) at \(path)"
        case .integrity(let sha, let actual): "blob \(sha) has content hash \(actual)"
        case .locked(let path): "archive is in use by another process (\(path)) — the MailKeeper app may be importing, fetching or indexing PDFs"
        case .notAnArchive(let path): "\(path) is not a MailKeeper archive"
        case .unsupportedFormat(let v): "archive format \(v) is newer than this version supports"
        case .invalid(let message): message
        }
    }
}

public func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Largest file the archive reads into memory (IMAP caps literals the same way).
let maxFileBytes = 1 << 30

/// A whole regular file via read(2) into Swift-owned memory. Foundation's
/// `Data(contentsOf:)` can hand back autoreleased storage that threads of the concurrency
/// pool do not drain: importing large mails grew to 4–5× their size.
func readFile(_ path: String, limit: Int = maxFileBytes) throws -> Data {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw ArchiveError.io("open: \(String(cString: strerror(errno)))", path: path) }
    defer { close(fd) }
    var st = stat()
    guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { throw ArchiveError.io("not a regular file", path: path) }
    let size = Int(st.st_size)
    guard size <= limit else { throw ArchiveError.io("file too large (\(size) bytes)", path: path) }
    var data = Data(count: size)
    let got = try data.withUnsafeMutableBytes { buf -> Int in
        var offset = 0
        while offset < size {
            let n = read(fd, buf.baseAddress! + offset, size - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw ArchiveError.io("read: \(String(cString: strerror(errno)))", path: path)
            }
            if n == 0 { break }  // the file shrank meanwhile
            offset += n
        }
        return offset
    }
    if got < size { data.removeSubrange(got...) }
    return data
}

/// SHA-256 of a file, streamed through one 1 MiB buffer.
func sha256OfFile(_ path: String) throws -> String {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw ArchiveError.io("open: \(String(cString: strerror(errno)))", path: path) }
    defer { close(fd) }
    var hasher = SHA256()
    var buffer = [UInt8](repeating: 0, count: 1 << 20)
    while true {
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
        if n < 0 {
            if errno == EINTR { continue }
            throw ArchiveError.io("read: \(String(cString: strerror(errno)))", path: path)
        }
        if n == 0 { break }
        buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Content-addressed store of raw messages: `<root>/<aa>/<bb>/<sha256>.eml`, written once,
/// never modified (ADR-0001). Files and directories are private to the user (0600/0700).
public struct BlobStore: Sendable {
    public let root: URL
    let tmp: URL

    init(root: URL, tmp: URL) {
        self.root = root
        self.tmp = tmp
    }

    /// 64 lowercase hex digits. Hashes also come from the journal and the index; a forged value
    /// must not become a path like "../../x".
    public static func isValidSHA(_ s: String) -> Bool {
        s.utf8.count == 64 && s.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    public func url(for sha: String) -> URL {
        let a = sha.prefix(2), b = sha.dropFirst(2).prefix(2)
        return root.appending(path: "\(a)/\(b)/\(sha).eml", directoryHint: .notDirectory)
    }

    public func contains(_ sha: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: sha).path)
    }

    /// Stores `data` unless an identical blob exists. The blob is visible under its final name
    /// only after it was fsync'ed and re-read with a matching hash.
    @discardableResult
    public func put(_ data: Data) throws -> (sha256: String, isNew: Bool) {
        let sha = sha256Hex(data)
        let dest = url(for: sha)
        if FileManager.default.fileExists(atPath: dest.path) { return (sha, false) }

        try makePrivateDirectory(dest.deletingLastPathComponent())
        let tmpFile = tmp.appending(path: "\(sha).\(UUID().uuidString).part")
        try writeDurably(data, to: tmpFile)
        let onDisk = try sha256OfFile(tmpFile.path)  // what actually landed, streamed
        guard onDisk == sha else {
            try? FileManager.default.removeItem(at: tmpFile)
            throw ArchiveError.integrity(sha256: sha, actual: onDisk)
        }
        if rename(tmpFile.path, dest.path) != 0 {
            let err = errno
            try? FileManager.default.removeItem(at: tmpFile)
            // A concurrent writer may have stored the same content first.
            if FileManager.default.fileExists(atPath: dest.path) { return (sha, false) }
            throw ArchiveError.io("rename: \(String(cString: strerror(err)))", path: dest.path)
        }
        fsyncDirectory(dest.deletingLastPathComponent())
        return (sha, true)
    }

    public func read(_ sha: String) throws -> Data {
        guard Self.isValidSHA(sha) else { throw ArchiveError.io("invalid blob id", path: sha) }
        do { return try readFile(url(for: sha).path) } catch {
            throw ArchiveError.io("read", path: url(for: sha).path)
        }
    }

    /// Re-hashes a stored blob (streamed: verifying a 7 GB archive stays small).
    public func verify(_ sha: String) throws -> Bool {
        guard Self.isValidSHA(sha) else { throw ArchiveError.io("invalid blob id", path: sha) }
        return try sha256OfFile(url(for: sha).path) == sha
    }
}

// MARK: - File helpers

func makePrivateDirectory(_ url: URL) throws {
    do {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch {
        throw ArchiveError.io("mkdir", path: url.path)
    }
}

/// O_CREAT|O_EXCL with 0600 from the start (no window with wider permissions), then fsync.
func writeDurably(_ data: Data, to url: URL) throws {
    let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw ArchiveError.io("open: \(String(cString: strerror(errno)))", path: url.path) }
    defer { close(fd) }
    try data.withUnsafeBytes { buf in
        var offset = 0
        while offset < buf.count {
            let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
            if n < 0 {
                if errno == EINTR { continue }
                throw ArchiveError.io("write: \(String(cString: strerror(errno)))", path: url.path)
            }
            offset += n
        }
    }
    guard fsync(fd) == 0 else { throw ArchiveError.io("fsync", path: url.path) }
}

func fsyncDirectory(_ url: URL) {
    let fd = open(url.path, O_RDONLY | O_CLOEXEC)
    if fd >= 0 {
        fsync(fd)
        close(fd)
    }
}
