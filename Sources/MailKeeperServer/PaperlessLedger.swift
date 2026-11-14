import Foundation
import MailKeeperKit

/// The Paperless dry run (ADR-0016): for every message with attachments, once, what would be
/// handed to Paperless and why the rest stays out — one JSON line per message in the person's
/// ledger. Nothing is uploaded; the archive is only read.
///
/// The ledger holds subjects, senders and file names — the same data as the archive beside it,
/// on the same volume; the log and the status file get counts only.
public struct LedgerRecord: Codable, Sendable, Equatable {
    public static let version = 1

    public var v = LedgerRecord.version
    /// The settings' fingerprint this decision was made under (also in the file name).
    public var settings: String
    /// When this message was decided.
    public var decided: Date
    public var identity: String
    public var messageId: String?
    public var date: Date?
    public var from: String?
    public var fromName: String?
    public var subject: String?
    public var places: [String]
    public var sent: Bool
    /// The rule matched the message.
    public var rule: Bool
    /// The message could not be read, or not completely.
    public var problem: Problem?
    public var attachments: [LedgerAttachment]

    public enum Problem: String, Codable, Sendable {
        /// The archive has no copy (yet): tried again next run, written down once.
        case missing
        /// The copy does not match its checksum: tried again next run, written down once.
        case damaged
        /// Above `maxMessageBytes`: not read; decided, since its size will not change.
        case tooLarge
        /// The MIME tree is deeper or larger than the parser follows: what it read is decided.
        case truncated

        /// Missing and damaged copies may come back (a restore, a repair); the rest is final.
        var isFinal: Bool { self == .tooLarge || self == .truncated }
    }
}

public struct LedgerAttachment: Codable, Sendable, Equatable {
    public enum Decision: String, Codable, Sendable { case upload, skip }
    /// Checked in this order; the first that applies is the reason.
    public enum Reason: String, Codable, Sendable, CaseIterable {
        /// The part could not be found again in the parsed message.
        case unreadable
        /// No bytes after decoding.
        case empty
        /// An image the HTML shows (cid:) — part of the message, not a document.
        case inline
        /// Program, macro document, web page or link file.
        case risky
        /// Extension not in the list.
        case type
        /// Below `minBytes`.
        case small
        /// Would have gone, but the rule does not match the message (newsletter, spam …).
        case rule
        /// The same bytes were handed over before (Paperless refuses duplicates by checksum).
        case duplicate
    }

    /// Sanitised, as it would be uploaded.
    public var filename: String
    public var mime: String
    public var size: Int
    public var sha256: String
    /// `Content-Disposition` as the sender wrote it ("attachment", "inline" or none).
    public var disposition: String?
    public var decision: Decision
    public var reason: Reason?
    /// What the document would be in Paperless — for `upload` only.
    public var paperless: PaperlessDocument?
}

/// The person model for one document (plan mailkeeper-server, decision 6).
public struct PaperlessDocument: Codable, Sendable, Equatable {
    /// The file name without extension — not the subject, which every attachment of a mail shares.
    public var title: String
    /// The mail's day in the configured time zone, YYYY-MM-DD.
    public var created: String
    public var owner: String
    public var tags: [String]
    public var storagePath: String?
    /// The sender's address; none for mail the person sent.
    public var correspondent: String?
    /// The mail it came from, as an RFC 2392 `mid:` URL.
    public var sourceMail: String?
}

/// Counts for the log and the status file — no mail content.
public struct LedgerCounts: Codable, Sendable, Equatable {
    /// Messages decided (a final problem included).
    public var messages = 0
    public var upload = 0
    public var skipped: [String: Int] = [:]
    /// Messages not or not completely read.
    public var problems = 0

    mutating func add(_ record: LedgerRecord) {
        if record.problem != nil { problems += 1 }
        guard record.problem?.isFinal ?? true else { return }
        messages += 1
        for a in record.attachments {
            if a.decision == .upload { upload += 1 } else { skipped[a.reason?.rawValue ?? "?", default: 0] += 1 }
        }
    }
}

public struct LedgerError: Error, CustomStringConvertible {
    public let description: String
}

/// One person's ledger file: read once per run (what is decided, which bytes went), appended to.
final class Ledger {
    let url: URL
    /// Decided for good — a missing or damaged copy is not.
    private(set) var decided = Set<String>()
    /// Messages whose copy was missing or damaged when last tried, written down once.
    private(set) var openProblems = Set<String>()
    private(set) var uploaded = Set<String>()
    private var counts = LedgerCounts()

    /// Decided messages, and as problems the final ones plus those still unreadable.
    var totals: LedgerCounts {
        var t = counts
        t.problems += openProblems.subtracting(decided).count
        return t
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Reads what is there. A last line without newline is what a kill left mid-write: cut off,
    /// so the message is decided again. Any other unreadable line — or one of another version —
    /// stops the export of this person; deleting the ledger decides everything again.
    init(url: URL) throws {
        self.url = url
        guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else { return }
        // Not through a symbolic link — append() would refuse it anyway (O_NOFOLLOW).
        guard type == .typeRegular else { throw LedgerError(description: "Ledger \(url.lastPathComponent): keine gewöhnliche Datei") }
        var data = try Data(contentsOf: url)
        if let last = data.last, last != UInt8(ascii: "\n") {
            let keep = (data.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 }) ?? data.startIndex
            guard truncate(url.path, off_t(keep - data.startIndex)) == 0 else {
                throw LedgerError(description: "Ledger \(url.lastPathComponent): unvollständige letzte Zeile nicht abschneidbar")
            }
            data = data[data.startIndex..<keep]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for (n, line) in data.split(separator: UInt8(ascii: "\n")).enumerated() {
            guard let record = try? decoder.decode(LedgerRecord.self, from: Data(line)), record.v == LedgerRecord.version else {
                throw LedgerError(description: "Ledger \(url.lastPathComponent): Zeile \(n + 1) unlesbar oder andere Version")
            }
            note(record)
        }
    }

    private func note(_ record: LedgerRecord) {
        guard record.problem?.isFinal ?? true else {
            openProblems.insert(record.identity)
            return
        }
        decided.insert(record.identity)
        for a in record.attachments where a.decision == .upload { uploaded.insert(a.sha256) }
        counts.add(record)
    }

    /// Appends records, one line each, then flushes them to disk. A kill leaves at most one
    /// incomplete last line, which the next read cuts off. Created 0600 in one step, appended
    /// with O_APPEND, never through a symbolic link.
    func append(_ records: [LedgerRecord]) throws {
        guard !records.isEmpty else { return }
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw LedgerError(description: "Ledger \(url.lastPathComponent): öffnen: \(String(cString: strerror(errno)))")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        for record in records {
            var line = try Self.encoder.encode(record)
            line.append(UInt8(ascii: "\n"))
            try handle.write(contentsOf: line)
            note(record)
        }
        try handle.synchronize()
        try handle.close()
    }
}

/// Decides the attachments of one message. Pure: the same message and settings, the same result.
struct AttachmentDecider {
    let settings: PaperlessExport
    let person: PaperlessPerson
    let fingerprint: String
    let extensions: Set<String>
    let calendar: Calendar

    init(settings: PaperlessExport, person: PaperlessPerson) throws {
        self.settings = settings
        self.person = person
        fingerprint = settings.fingerprint(for: person)
        extensions = Set(settings.extensions)
        calendar = try settings.calendar()
    }

    func record(_ message: AttachmentMessage, now: Date) -> LedgerRecord {
        LedgerRecord(settings: fingerprint, decided: now, identity: message.identity, messageId: message.messageID, date: message.date,
                     from: message.fromAddress, fromName: message.fromName, subject: message.subject,
                     places: message.places, sent: message.sent, rule: message.matchesRule, attachments: [])
    }

    /// `raw`: the stored message, or nil if the archive has no copy. `uploaded`: bytes handed
    /// over before (this run included); updated with what goes now.
    func decide(_ message: AttachmentMessage, raw: Data?, uploaded: inout Set<String>, now: Date) -> LedgerRecord {
        var record = record(message, now: now)
        guard let raw else {
            record.problem = .missing
            return record
        }
        guard sha256Hex(raw) == message.primaryBlob else {
            record.problem = .damaged
            return record
        }
        let parsed = MIMEParser.parse(raw)
        if parsed.truncated { record.problem = .truncated }
        for info in parsed.attachments {
            let data = parsed.data(of: info)
            let bytes = data ?? Data()
            let filename = AttachmentSafety.sanitizedFilename(info.filename, mimeType: info.mimeType)
            let sha = sha256Hex(bytes)
            var attachment = LedgerAttachment(filename: filename, mime: info.mimeType, size: bytes.count, sha256: sha,
                                              disposition: parsed.root.part(at: info.partPath)?.disposition,
                                              decision: .skip, reason: nil, paperless: nil)
            let ext = (filename as NSString).pathExtension.lowercased()
            if data == nil { attachment.reason = .unreadable }
            else if bytes.isEmpty { attachment.reason = .empty }
            else if info.isInline { attachment.reason = .inline }
            else if AttachmentSafety.isRisky(filename: filename, mimeType: info.mimeType) { attachment.reason = .risky }
            else if !extensions.contains(ext) { attachment.reason = .type }
            else if bytes.count < settings.minBytes { attachment.reason = .small }
            else if !message.matchesRule { attachment.reason = .rule }
            else if uploaded.contains(sha) { attachment.reason = .duplicate }
            else {
                attachment.decision = .upload
                attachment.paperless = document(for: message, filename: filename)
                uploaded.insert(sha)
            }
            record.attachments.append(attachment)
        }
        return record
    }

    func document(for message: AttachmentMessage, filename: String) -> PaperlessDocument {
        let base = (filename as NSString).deletingPathExtension
        let day = calendar.dateComponents([.year, .month, .day], from: message.date ?? message.firstSeen)
        let created = String(format: "%04d-%02d-%02d", day.year ?? 0, day.month ?? 0, day.day ?? 0)
        let mid = message.messageID
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")) }
            .flatMap { $0.isEmpty ? nil : $0.addingPercentEncoding(withAllowedCharacters: Self.midAllowed) }
            .map { "mid:" + $0 }  // RFC 2392: the addr-spec without angle brackets, percent-encoded
        return PaperlessDocument(title: base.isEmpty ? filename : base, created: created, owner: person.owner, tags: person.tags,
                                 storagePath: person.storagePath, correspondent: message.sent ? nil : message.fromAddress,
                                 sourceMail: mid)
    }

    /// RFC 2392 / RFC 3986: unreserved plus "@" and sub-delims that need no escaping in a path.
    static let midAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~!$&'*+=@")
}

/// One dry-run pass over a person's archive: every message with attachments not yet decided,
/// in the order the archive first saw them. Returns this pass's counts and the ledger's totals.
struct PaperlessDryRun {
    let settings: PaperlessExport
    let person: PaperlessPerson
    let personID: String

    var ledgerURL: URL {
        URL(fileURLWithPath: settings.ledgerDirectory).appending(path: "\(personID)-\(settings.fingerprint(for: person)).jsonl")
    }

    func run(layout: ArchiveLayout, now: Date = Date()) throws -> (pass: LedgerCounts, totals: LedgerCounts) {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: settings.ledgerDirectory), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let ledger = try Ledger(url: ledgerURL)
        let decider = try AttachmentDecider(settings: settings, person: person)
        // Reads only: the daemon already holds the archive's lock and migrated the index, so the
        // reader's own setup (WAL mode, migrations) finds nothing to do.
        let reader = try ArchiveReader(layout: layout)
        let messages = try reader.attachmentMessages(rule: settings.rule, since: try settings.sinceDate(), now: now)
        var uploaded = ledger.uploaded, pass = LedgerCounts(), batch: [LedgerRecord] = []
        for message in messages where !ledger.decided.contains(message.identity) {
            let record: LedgerRecord
            if message.size > settings.maxMessageBytes {
                record = with(decider.record(message, now: now)) { $0.problem = .tooLarge }
            } else if !layout.blobs.contains(message.primaryBlob) {
                record = decider.decide(message, raw: nil, uploaded: &uploaded, now: now)
            } else {
                // A copy that is there but cannot be read now (EIO, too many files) ends the pass:
                // the next run carries on, nothing is decided on an error of the moment.
                let raw = try layout.blobs.read(message.primaryBlob)
                record = decider.decide(message, raw: raw, uploaded: &uploaded, now: now)
            }
            pass.add(record)
            // A missing or damaged copy is tried every run but written down once.
            if record.problem?.isFinal == false, ledger.openProblems.contains(message.identity) { continue }
            batch.append(record)
            if batch.count >= 200 {  // a kill costs at most one batch of work, never a decision twice
                try ledger.append(batch)
                batch.removeAll(keepingCapacity: true)
            }
        }
        try ledger.append(batch)
        return (pass, ledger.totals)
    }

    private func with(_ record: LedgerRecord, _ change: (inout LedgerRecord) -> Void) -> LedgerRecord {
        var r = record
        change(&r)
        return r
    }
}
