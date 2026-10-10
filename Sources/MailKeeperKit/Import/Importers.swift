import Foundation

public struct ImportProgress: Sendable, Equatable {
    public var messages = 0
    public var newMessages = 0
    public var newLocations = 0
    public var unchanged = 0
    public var failed = 0
    public var bytes: Int64 = 0
    public var lastError: String?

    public init() {}

    mutating func count(_ results: [IngestResult]) {
        for r in results {
            switch r {
            case .newMessage: newMessages += 1
            case .newLocation: newLocations += 1
            case .unchanged: unchanged += 1
            }
        }
    }
}

/// Collects (bytes, location) pairs and hands them to the writer in transactions.
struct BatchFeeder {
    let writer: ArchiveWriter
    let progress: @Sendable (ImportProgress) -> Void
    var batch: [(data: Data, location: LocationInfo)] = []
    var batchBytes = 0
    var state = ImportProgress()

    init(writer: ArchiveWriter, progress: @escaping @Sendable (ImportProgress) -> Void) {
        self.writer = writer
        self.progress = progress
    }

    mutating func add(_ data: Data, _ location: LocationInfo) async throws {
        try Task.checkCancellation()
        batch.append((data, location))
        batchBytes += data.count
        state.messages += 1
        state.bytes += Int64(data.count)
        if batch.count >= 200 || batchBytes >= 32 << 20 { try await flush() }
    }

    mutating func flush() async throws {
        guard !batch.isEmpty else { return }
        do {
            state.count(try await writer.ingest(batch))
        } catch {
            // One bad message must not sink the batch: retry one by one, count failures.
            for item in batch {
                do { state.count([try await writer.ingest(item.data, at: item.location)]) } catch {
                    state.failed += 1
                    state.lastError = "\(error)"
                }
            }
        }
        batch.removeAll(keepingCapacity: true)
        batchBytes = 0
        progress(state)
    }
}

/// Path of `url` below `root`, robust against symlinked prefixes (/var → /private/var):
/// the directory enumerator returns resolved paths, the caller's root may not be.
func relativePath(of url: URL, to root: URL) -> String {
    let r = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let u = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    guard u.count >= r.count, Array(u.prefix(r.count)) == r else { return url.lastPathComponent }
    return u.dropFirst(r.count).joined(separator: "/")
}

/// Importing the archive's own blobs would register every stored message as a new location.
func refuseArchiveSource(_ source: URL, archive: URL) throws {
    let s = source.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    let a = archive.resolvingSymlinksInPath().standardizedFileURL.pathComponents
    if s.count >= a.count, Array(s.prefix(a.count)) == a {
        throw ArchiveError.io("import source lies inside the archive", path: source.path)
    }
}

// MARK: - Maildir

/// Imports Maildir trees (mbsync, offlineimap, Dovecot, Maildir++): every directory with
/// `cur/` and `new/` is a mailbox. Flags come from the `:2,` info suffix.
public struct MaildirImporter: Sendable {
    public let root: URL
    public let account: String

    public init(root: URL, account: String) {
        self.root = root
        self.account = account
    }

    public func mailboxes() -> [(name: String, url: URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = []
        func isMaildir(_ url: URL) -> Bool {
            var dir: ObjCBool = false
            return fm.fileExists(atPath: url.appending(path: "cur").path, isDirectory: &dir) && dir.boolValue
                && fm.fileExists(atPath: url.appending(path: "new").path)
        }
        if isMaildir(root) { out.append(("INBOX", root)) }
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) {
            for case let url as URL in e {
                let last = url.lastPathComponent
                if ["cur", "new", "tmp"].contains(last) { e.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, isMaildir(url) else { continue }
                out.append((Self.mailboxName(relative: relativePath(of: url, to: root)), url))
            }
        }
        return out.sorted { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
    }

    /// "Sent" stays "Sent"; Maildir++ ".Archive.2019" becomes "Archive/2019".
    static func mailboxName(relative: String) -> String {
        if relative.hasPrefix("."), !relative.contains("/") {
            return relative.dropFirst().replacingOccurrences(of: ".", with: "/")
        }
        return relative
    }

    static func flags(fromInfo info: Substring) -> [String] {
        var flags: [String] = []
        for c in info {
            switch c {
            case "D": flags.append("\\Draft")
            case "F": flags.append("\\Flagged")
            case "R": flags.append("\\Answered")
            case "S": flags.append("\\Seen")
            case "T": flags.append("\\Deleted")
            case "P": flags.append("$Forwarded")
            default: break
            }
        }
        return flags
    }

    public func run(writer: ArchiveWriter, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportProgress {
        try refuseArchiveSource(root, archive: writer.layout.root)
        try await writer.register(AccountInfo(id: account, kind: "maildir", name: account))
        var feeder = BatchFeeder(writer: writer, progress: progress)
        let fm = FileManager.default
        for (name, url) in mailboxes() {
            for sub in ["cur", "new"] {
                let dir = url.appending(path: sub)
                let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
                for file in files {
                    let path = dir.appending(path: file)
                    guard let data = try? Data(contentsOf: path, options: .mappedIfSafe) else {
                        feeder.state.failed += 1
                        continue
                    }
                    // "<time>.<unique>.<host>[,U=<uid>]:2,<flags>" (some systems use "!" for ":")
                    let sep = file.range(of: ":2,") ?? file.range(of: "!2,")
                    let base = sep.map { String(file[..<$0.lowerBound]) } ?? file
                    let info = sep.map { file[$0.upperBound...] } ?? ""
                    let delivered = Double(base.prefix(while: { $0.isNumber })).map(Date.init(timeIntervalSince1970:))
                        ?? (try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    let loc = LocationInfo(account: account, mailbox: name, providerID: base,
                                           internalDate: delivered, flags: Self.flags(fromInfo: info))
                    try await feeder.add(Data(data), loc)
                }
            }
        }
        try await feeder.flush()
        return feeder.state
    }
}

// MARK: - .eml folders

public struct EMLImporter: Sendable {
    public let root: URL
    public let account: String

    public init(root: URL, account: String) {
        self.root = root
        self.account = account
    }

    /// Directory enumeration is synchronous API (unavailable in async contexts).
    func emlFiles() -> [URL] {
        var files: [URL] = []
        if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in e where url.pathExtension.lowercased() == "eml" { files.append(url) }
        }
        return files.sorted { $0.path < $1.path }
    }

    public func run(writer: ArchiveWriter, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportProgress {
        try refuseArchiveSource(root, archive: writer.layout.root)
        try await writer.register(AccountInfo(id: account, kind: "eml", name: account))
        var feeder = BatchFeeder(writer: writer, progress: progress)
        for url in emlFiles() {
            guard let data = try? Data(contentsOf: url) else { feeder.state.failed += 1; continue }
            let relative = relativePath(of: url, to: root)
            let folder = (relative as NSString).deletingLastPathComponent
            let loc = LocationInfo(account: account, mailbox: folder.isEmpty ? "Import" : folder, providerID: relative,
                                   internalDate: try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            try await feeder.add(data, loc)
        }
        try await feeder.flush()
        return feeder.state
    }
}

// MARK: - mbox

/// Streams mbox files of any size (Google Takeout exports reach many GB). Messages are split at
/// lines starting with "From "; ">From " escaping (mboxrd/mboxo) is undone. Takeout's
/// separator carries the Gmail message id, its `X-Gmail-Labels` header the labels.
public struct MboxImporter: Sendable {
    public let file: URL
    public let account: String
    public let mailbox: String
    /// Read size; tests use tiny chunks to exercise every chunk-boundary case.
    var chunkSize = 8 << 20

    public init(file: URL, account: String, mailbox: String? = nil) {
        self.file = file
        self.account = account
        self.mailbox = mailbox ?? file.deletingPathExtension().lastPathComponent
    }

    public func run(writer: ArchiveWriter, progress: @escaping @Sendable (ImportProgress) -> Void = { _ in }) async throws -> ImportProgress {
        try await writer.register(AccountInfo(id: account, kind: "mbox", name: account))
        var feeder = BatchFeeder(writer: writer, progress: progress)
        guard let handle = FileHandle(forReadingAtPath: file.path) else { throw ArchiveError.io("open mbox", path: file.path) }
        defer { try? handle.close() }
        let fromPrefix = Data("From ".utf8)
        let separator = Data("\nFrom ".utf8)
        // A read cursor instead of slicing the buffer per message (that would copy the rest of
        // an 8 MiB chunk for every small message); consumed bytes are dropped once per refill.
        var buffer = Data()
        var pos = 0          // start of the unconsumed data
        var scanFrom = 0     // separator search resumes here (large messages are not rescanned)
        var eof = false
        func refill() throws {
            if pos > 0 {
                buffer.removeSubrange(0..<pos)
                scanFrom = max(0, scanFrom - pos)
                pos = 0
            }
            if let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty { buffer.append(chunk) } else { eof = true }
        }
        try refill()
        while true {
            if pos >= buffer.count {
                if eof { break }
                try refill()
                continue
            }
            if !buffer[pos...].starts(with: fromPrefix) {
                // junk before the first separator line: skip to it, keep at most a partial separator
                if let r = buffer.range(of: separator, in: pos..<buffer.count) {
                    pos = r.lowerBound + 1
                    continue
                }
                if eof { break }
                pos = max(pos, buffer.count - (separator.count - 1))
                try refill()
                continue
            }
            let searchStart = max(pos + fromPrefix.count, scanFrom)
            if searchStart < buffer.count, let next = buffer.range(of: separator, in: searchStart..<buffer.count) {
                let entry = buffer.subdata(in: pos..<(next.lowerBound + 1))
                pos = next.lowerBound + 1
                scanFrom = 0
                if let (data, loc) = parse(entry) { try await feeder.add(data, loc) }
            } else if eof {
                let entry = buffer.subdata(in: pos..<buffer.count)
                pos = buffer.count
                if let (data, loc) = parse(entry) { try await feeder.add(data, loc) }
            } else {
                scanFrom = max(searchStart, buffer.count - (separator.count - 1))
                try refill()
            }
        }
        try await feeder.flush()
        return feeder.state
    }

    /// One mbox entry (separator line + message) → message bytes and location.
    func parse(_ entry: Data) -> (Data, LocationInfo)? {
        guard let lineEnd = entry.firstIndex(of: 0x0A) else { return nil }
        let fromLine = String(decoding: entry[..<lineEnd], as: UTF8.self)
        var body = entry.subdata(in: (lineEnd + 1)..<entry.count)
        // the blank line before the next separator belongs to the separator
        if body.last == 0x0A { body.removeLast() }
        body = Self.unescapeFromLines(body)
        guard !body.isEmpty else { return nil }

        let parts = fromLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        let sender = parts.count > 1 ? String(parts[1]) : ""
        let date = parts.count > 2 ? MailDate.parse(String(parts[2])) : nil
        let headers = HeaderParser.parse(body).0
        let labels = headers.text("X-Gmail-Labels").map(Self.splitLabels) ?? []
        let gmailID = sender.split(separator: "@").first.flatMap { UInt64($0) }
        let providerID = gmailID.map { "gm:\($0)" } ?? "sha:" + sha256Hex(body)
        let loc = LocationInfo(account: account, mailbox: mailbox, providerID: providerID, internalDate: date,
                               flags: labels.contains("Geöffnet") || labels.contains("Opened") ? ["\\Seen"] : [], labels: labels)
        return (body, loc)
    }

    /// mboxrd: strip one ">" from lines matching ^>+From
    static func unescapeFromLines(_ data: Data) -> Data {
        guard data.range(of: Data(">From ".utf8)) != nil else { return data }
        var out = Data(capacity: data.count)
        var lineStart = true
        var i = data.startIndex
        while i < data.endIndex {
            if lineStart, data[i] == UInt8(ascii: ">") {
                var j = i
                while j < data.endIndex, data[j] == UInt8(ascii: ">") { j += 1 }
                if data[j...].starts(with: Data("From ".utf8)) {
                    i += 1  // drop one ">"
                }
            }
            let c = data[i]
            out.append(c)
            lineStart = c == 0x0A
            i += 1
        }
        return out
    }

    /// Takeout: `Inbox,Opened,"Label, with comma"`.
    static func splitLabels(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var quoted = false
        for ch in s {
            if ch == "\"" { quoted.toggle(); continue }
            if ch == ",", !quoted {
                let t = cur.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { out.append(t) }
                cur = ""
                continue
            }
            cur.append(ch)
        }
        let t = cur.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { out.append(t) }
        return out
    }
}
