import Foundation

/// How an export writes the messages.
public enum ExportFormat: String, Sendable, CaseIterable, Codable {
    /// One .eml file per message: exactly the archived bytes.
    case eml
    /// One mbox file (mboxrd): a "From " line before each message, lines starting with
    /// ">*From " get one more ">"; the messages keep their bytes (line endings included).
    case mbox
}

/// One message to export: its first stored bytes and what names the file.
public struct ExportItem: Sendable, Equatable {
    public var sha256: String
    public var size: Int
    public var date: Date?
    public var subject: String?

    public init(sha256: String, size: Int, date: Date?, subject: String?) {
        self.sha256 = sha256
        self.size = size
        self.date = date
        self.subject = subject
    }
}

public struct ExportReport: Sendable, Equatable {
    public var exported = 0
    public var bytes: Int64 = 0
    /// Messages left out, by reason ("Archivkopie beschädigt").
    public var problems: [String: Int] = [:]
    /// The folder (eml) or file (mbox) written.
    public var destination: URL

    public init(destination: URL) {
        self.destination = destination
    }
}

extension ArchiveReader {
    /// What an export of `filter` writes, oldest first.
    public func exportItems(_ filter: MessageFilter) throws -> [ExportItem] {
        let (whereClause, params) = try Self.whereClause(filter)
        return try db.query("""
            SELECT m.primary_blob, coalesce(b.size, m.size), m.date, m.subject
            FROM messages m LEFT JOIN blobs b ON b.sha256 = m.primary_blob\(whereClause)
            ORDER BY m.date NULLS FIRST, m.id
            """, params) { row in
            ExportItem(sha256: row.text(0) ?? "", size: Int(row.int(1)),
                       date: row.optionalDouble(2).map(Date.init(timeIntervalSince1970:)), subject: row.text(3))
        }
    }
}

/// Writes archived messages out. Not destructive (ADR-0006 §7): no queue, nothing in the archive
/// changes, existing files are never overwritten (eml: O_EXCL, the next free name on a clash).
/// An mbox goes to a new file, or — `replace`, the user confirmed it in the save panel — is
/// built beside it and swapped in only when complete: a stop or a full disk leaves the old file
/// as it was. Each blob is verified first; a damaged or missing copy is left out and reported,
/// never written. Files are 0600, eml files carry the message date as file date.
public struct ArchiveExporter: Sendable {
    public let blobs: BlobStore

    public init(blobs: BlobStore) {
        self.blobs = blobs
    }

    public func export(_ items: [ExportItem], format: ExportFormat, to destination: URL, replace: Bool = false,
                       progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> ExportReport {
        var report = ExportReport(destination: destination)
        switch format {
        case .eml:
            var names = Set(((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).map { $0.lowercased() })
            for (n, item) in items.enumerated() {
                try Task.checkCancellation()
                guard let data = verified(item, &report) else { continue }
                let url = try writeUnique(data, in: destination, name: Self.fileName(item), fallback: Self.plainName(item), taken: &names)
                if let date = item.date {
                    try? FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
                }
                report.exported += 1
                report.bytes += Int64(data.count)
                if n % 50 == 0 { progress(n + 1, items.count) }
            }
        case .mbox:
            // Replacing: build it in a temporary file on the same volume, swap in when complete.
            // Otherwise a new file only (O_EXCL, no symlink followed): what is removed on a stop is ours.
            let work = replace ? try Self.temporaryFile(beside: destination) : destination
            let fd = open(work.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ArchiveError.io("open: \(String(cString: strerror(errno)))", path: destination.path) }
            var complete = false
            defer {
                close(fd)
                if !complete { unlink(work.path) }  // no half mbox left behind; the replaced file stays
                if replace { try? FileManager.default.removeItem(at: work.deletingLastPathComponent()) }
            }
            for (n, item) in items.enumerated() {
                try Task.checkCancellation()
                guard let data = verified(item, &report) else { continue }
                try writeAll(fd, Data(Self.separatorLine(item.date).utf8), path: work.path)
                try Self.forEachEscapedSegment(data) { try writeAll(fd, $0, path: work.path) }
                // One LF: the blank line before the next "From " (or, for a message without a final
                // line break, its end) — readers drop exactly this one, so the bytes come back as stored.
                try writeAll(fd, Data([0x0A]), path: work.path)
                report.exported += 1
                report.bytes += Int64(data.count)
                if n % 50 == 0 { progress(n + 1, items.count) }
            }
            guard fsync(fd) == 0 else { throw ArchiveError.io("fsync", path: work.path) }
            guard report.exported > 0 else { progress(items.count, items.count); return report }  // nothing to show: keep what was there
            if replace {
                if FileManager.default.fileExists(atPath: destination.path) {
                    _ = try FileManager.default.replaceItemAt(destination, withItemAt: work)
                } else {
                    try FileManager.default.moveItem(at: work, to: destination)
                }
            }
            complete = true
        }
        progress(items.count, items.count)
        return report
    }

    private func verified(_ item: ExportItem, _ report: inout ExportReport) -> Data? {
        guard let data = try? blobs.read(item.sha256) else {
            let missing = !FileManager.default.fileExists(atPath: blobs.url(for: item.sha256).path)
            report.problems[missing ? String(localized: "Archivkopie fehlt") : String(localized: "Archivkopie nicht lesbar"), default: 0] += 1
            return nil
        }
        guard sha256Hex(data) == item.sha256 else {
            report.problems[String(localized: "Archivkopie beschädigt"), default: 0] += 1
            return nil
        }
        return data
    }

    /// "2019-03-14 1000 Ihre Rechnung Nr. 2019-0042.eml" — sortable, safe (no path separators,
    /// controls or bidi tricks), bounded.
    static func fileName(_ item: ExportItem) -> String {
        var prefix = "0000-00-00 0000"
        if let date = item.date {
            let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
            prefix = String(format: "%04d-%02d-%02d %02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
        }
        var subject = (item.subject ?? "").isEmpty ? String(localized: "(ohne Betreff)") : item.subject!
        subject = String(subject.prefix(120)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        return AttachmentSafety.sanitizedFilename("\(prefix) \(subject).eml", mimeType: "message/rfc822")
    }

    /// When a file system refuses the name (HFS+ length in NFD, exFAT's ? * " < > |): date and
    /// a hash prefix, plain ASCII.
    static func plainName(_ item: ExportItem) -> String {
        String(fileName(ExportItem(sha256: item.sha256, size: item.size, date: item.date, subject: "x")).dropLast(".x.eml".count))
            + " " + item.sha256.prefix(12) + ".eml"
    }

    /// A temporary file on the destination's volume (NSDocument's way; allowed in the sandbox).
    static func temporaryFile(beside destination: URL) throws -> URL {
        let dir = (try? FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                appropriateFor: destination, create: true))
            ?? FileManager.default.temporaryDirectory.appending(path: "mk-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appending(path: destination.lastPathComponent)
    }

    static func uniqueName(_ name: String, taken: inout Set<String>) -> String {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = name, n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(base) (\(n)).\(ext)"
            n += 1
        }
        taken.insert(candidate.lowercased())
        return candidate
    }

    /// "From MAILER-DAEMON Thu Mar 14 09:00:00 2019" (asctime, UTC).
    static func separatorLine(_ date: Date?) -> String {
        var t = time_t((date ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970.rounded(.down))
        var tm = tm()
        gmtime_r(&t, &tm)
        let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        return String(format: "From MAILER-DAEMON %@ %@ %2d %02d:%02d:%02d %d\n", days[Int(tm.tm_wday)], months[Int(tm.tm_mon)],
                      tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, Int(tm.tm_year) + 1900)
    }

    /// mboxrd: every line matching `^>*From ` gets one more ">" (reversible exactly).
    static func escapeFromLines(_ data: Data) -> Data {
        var out = Data()
        forEachEscapedSegment(data) { out.append($0) }
        return out
    }

    /// The escaped message as segments of the original plus inserted ">" — written straight out,
    /// no copy of a large message.
    static func forEachEscapedSegment(_ data: Data, _ body: (Data) throws -> Void) rethrows {
        guard data.range(of: Data("From ".utf8)) != nil else { return try body(data) }
        let from = Data("From ".utf8), quote = Data(">".utf8)
        var segmentStart = data.startIndex
        var lineStart = data.startIndex
        while lineStart < data.endIndex {
            var j = lineStart
            while j < data.endIndex, data[j] == UInt8(ascii: ">") { j += 1 }
            if data[j...].starts(with: from) {
                if segmentStart < lineStart { try body(data[segmentStart..<lineStart]) }
                try body(quote)
                segmentStart = lineStart
            }
            guard let lf = data[lineStart...].firstIndex(of: 0x0A) else { break }
            lineStart = lf + 1
        }
        if segmentStart < data.endIndex { try body(data[segmentStart...]) }
    }

    /// A new file only (O_EXCL): an export never overwrites anything. On a clash the file
    /// system saw and the name list did not (case folding, another program) the next name is
    /// tried; a name the file system refuses falls back to a plain ASCII one.
    private func writeUnique(_ data: Data, in dir: URL, name: String, fallback: String, taken: inout Set<String>) throws -> URL {
        var base = name
        for attempt in 0..<1_000 {
            let url = dir.appending(path: Self.uniqueName(base, taken: &taken))
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 {
                let code = errno
                if code == EEXIST { continue }
                if (code == ENAMETOOLONG || code == EINVAL || code == EILSEQ), base != fallback, attempt < 999 { base = fallback; continue }
                throw ArchiveError.io("open: \(String(cString: strerror(code)))", path: url.path)
            }
            defer { close(fd) }
            do {
                try writeAll(fd, data, path: url.path)
            } catch {
                unlink(url.path)  // ours, half written
                throw error
            }
            return url
        }
        throw ArchiveError.io("no free file name", path: dir.appending(path: name).path)
    }

    private func writeAll(_ fd: Int32, _ data: Data, path: String) throws {
        try data.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ArchiveError.io("write: \(String(cString: strerror(errno)))", path: path)
                }
                offset += n
            }
        }
    }
}
