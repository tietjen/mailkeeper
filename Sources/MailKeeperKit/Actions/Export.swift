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

/// Writes archived messages out. Not destructive (ADR-0006): no queue, nothing in the archive
/// changes, existing files are never overwritten (eml) — the mbox file is the one the user
/// chose to (re)place. Each blob is verified first; a damaged or missing copy is left out and
/// reported, never written. Files are 0600, eml files carry the message date as file date.
public struct ArchiveExporter: Sendable {
    public let blobs: BlobStore

    public init(blobs: BlobStore) {
        self.blobs = blobs
    }

    public func export(_ items: [ExportItem], format: ExportFormat, to destination: URL,
                       progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> ExportReport {
        var report = ExportReport(destination: destination)
        switch format {
        case .eml:
            var names = Set(((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).map { $0.lowercased() })
            for (n, item) in items.enumerated() {
                try Task.checkCancellation()
                guard let data = verified(item, &report) else { continue }
                let name = Self.uniqueName(Self.fileName(item), taken: &names)
                let url = destination.appending(path: name)
                try writeNew(data, to: url)
                if let date = item.date {
                    try? FileManager.default.setAttributes([.modificationDate: date, .creationDate: date], ofItemAtPath: url.path)
                }
                report.exported += 1
                report.bytes += Int64(data.count)
                if n % 50 == 0 { progress(n + 1, items.count) }
            }
        case .mbox:
            let fd = open(destination.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ArchiveError.io("open: \(String(cString: strerror(errno)))", path: destination.path) }
            var complete = false
            defer {
                close(fd)
                if !complete { unlink(destination.path) }  // no half mbox left behind
            }
            for (n, item) in items.enumerated() {
                try Task.checkCancellation()
                guard let data = verified(item, &report) else { continue }
                var entry = Data(Self.separatorLine(item.date).utf8)
                entry.append(Self.escapeFromLines(data))
                // One LF: the blank line before the next "From " (or, for a message without a final
                // line break, its end) — readers drop exactly this one, so the bytes come back as stored.
                entry.append(0x0A)
                try writeAll(fd, entry, path: destination.path)
                report.exported += 1
                report.bytes += Int64(data.count)
                if n % 50 == 0 { progress(n + 1, items.count) }
            }
            guard fsync(fd) == 0 else { throw ArchiveError.io("fsync", path: destination.path) }
            complete = true
        }
        progress(items.count, items.count)
        return report
    }

    private func verified(_ item: ExportItem, _ report: inout ExportReport) -> Data? {
        guard let data = try? blobs.read(item.sha256) else {
            report.problems[String(localized: "Archivkopie fehlt"), default: 0] += 1
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
        guard data.range(of: Data("From ".utf8)) != nil else { return data }
        var out = Data()
        out.reserveCapacity(data.count + 64)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            let from: [UInt8] = Array("From ".utf8)
            var lineStart = true
            for i in 0..<bytes.count {
                if lineStart {
                    var j = i
                    while j < bytes.count, bytes[j] == UInt8(ascii: ">") { j += 1 }
                    if j + from.count <= bytes.count, (0..<from.count).allSatisfy({ bytes[j + $0] == from[$0] }) {
                        out.append(UInt8(ascii: ">"))
                    }
                }
                out.append(bytes[i])
                lineStart = bytes[i] == 0x0A
            }
        }
        return out
    }

    /// A new file only (O_EXCL): an export never overwrites anything.
    private func writeNew(_ data: Data, to url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ArchiveError.io("open: \(String(cString: strerror(errno)))", path: url.path) }
        defer { close(fd) }
        try writeAll(fd, data, path: url.path)
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
