import Foundation

/// The user's private gold set (6.6, ADR-0005 §7): mails of the own archive labelled for
/// measuring — the category and whether it is phishing. Stored next to the archive
/// (`gold.json`), by message identity (stable across rebuilds), never journalled: a label is a
/// measurement, not a decision — it changes no classification and never reaches the memory, so
/// a run with memory cannot see its own answer. Real mail: it stays in the archive folder.
public struct GoldLabel: Sendable, Codable, Equatable {
    public var identity: String
    public var category: MailCategory
    public var phishing: Bool
    public var time: Date

    public init(identity: String, category: MailCategory, phishing: Bool, time: Date = .now) {
        self.identity = identity
        self.category = category
        self.phishing = phishing
        self.time = time
    }
}

public struct GoldLabels: Sendable, Codable, Equatable {
    public var labels: [GoldLabel] = []
    /// Shown and skipped ("weiß nicht"): not offered again.
    public var skipped: [String] = []

    public init() {}

    public func label(of identity: String) -> GoldLabel? { labels.first { $0.identity == identity } }

    public mutating func set(_ label: GoldLabel) {
        labels.removeAll { $0.identity == label.identity }
        skipped.removeAll { $0 == label.identity }
        labels.append(label)
    }

    public mutating func skip(_ identity: String) {
        labels.removeAll { $0.identity == identity }
        if !skipped.contains(identity) { skipped.append(identity) }
    }

    public mutating func remove(_ identity: String) {
        labels.removeAll { $0.identity == identity }
        skipped.removeAll { $0 == identity }
    }

    public var seen: Set<String> { Set(labels.map(\.identity) + skipped) }
}

/// `gold.json` and `gold-runs.jsonl` in the archive folder.
public struct GoldStore: Sendable {
    public let layout: ArchiveLayout

    public init(layout: ArchiveLayout) {
        self.layout = layout
    }

    public var labelsURL: URL { layout.root.appending(path: "gold.json") }
    public var runsURL: URL { layout.root.appending(path: "gold-runs.jsonl") }

    static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Empty when there is no file yet; an error when it is there and cannot be read — then
    /// nothing may be saved over it (review 6.6 S5: a label from a newer build, a truncated
    /// file must not turn into "0 gelabelt" and be overwritten by the next label).
    public func load() throws -> GoldLabels {
        guard FileManager.default.fileExists(atPath: labelsURL.path) else { return GoldLabels() }
        do {
            return try Self.decoder.decode(GoldLabels.self, from: try readFile(labelsURL.path, limit: 16 << 20))
        } catch {
            throw ArchiveError.invalid(String(localized: "gold.json lässt sich nicht lesen (\(error.localizedDescription)) – MailKeeper speichert keine Labels darüber. Datei prüfen oder beiseitelegen: \(labelsURL.path)"))
        }
    }

    /// Staged with 0600 from the start, synced, renamed over the old file.
    public func save(_ labels: GoldLabels) throws {
        let e = Self.encoder
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        let staging = layout.root.appending(path: ".gold-\(UUID().uuidString).part")
        do { try writeDurably(try e.encode(labels), to: staging) } catch {
            unlink(staging.path)
            throw error
        }
        guard rename(staging.path, labelsURL.path) == 0 else {
            unlink(staging.path)
            throw ArchiveError.io("rename gold.json", path: labelsURL.path)
        }
    }

    /// One JSON object per line, appended for real (O_APPEND: the GUI and mkctl may both write;
    /// review 6.6 S4) — a file that cannot be opened is an error, never replaced.
    public func appendRun<T: Encodable>(_ run: T) throws {
        var line = try Self.encoder.encode(run)
        line.append(0x0A)
        let fd = open(runsURL.path, O_RDWR | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ArchiveError.io("open: \(String(cString: strerror(errno)))", path: runsURL.path) }
        defer { close(fd) }
        // a torn last line (a crash mid-write) is ended first, or this run would be glued to it
        let end = lseek(fd, 0, SEEK_END)
        if end > 0 {
            var last: UInt8 = 0
            if pread(fd, &last, 1, end - 1) == 1, last != 0x0A { line.insert(0x0A, at: 0) }
        }
        try line.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw ArchiveError.io("write: \(String(cString: strerror(errno)))", path: runsURL.path)
                }
                offset += n
            }
        }
        _ = fsync(fd)
    }

    /// The runs, oldest first; a line that does not decode is left out (a torn write).
    public func runs<T: Decodable>(as type: T.Type) -> [T] {
        guard let data = try? readFile(runsURL.path, limit: 64 << 20) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? Self.decoder.decode(T.self, from: Data($0)) }
    }
}

extension ArchiveReader {
    /// Mails to offer for labelling, spread out: one per sender domain (the newest), taken in
    /// turn from every bucket — each category as MailKeeper has it today, the open ones, the
    /// spam folder — so a few big senders cannot fill the set. Not sent, drafts or trash; not
    /// what was labelled or skipped.
    public func goldCandidates(limit: Int, excluding seen: Set<String>) throws -> [Int64] {
        var buckets: [String: [(id: Int64, domain: String)]] = [:]
        // a domain labelled or skipped before is done (review 6.6: over several sessions the big
        // senders would come back with their next mail)
        var used = Set(try summaries(Array(try messageIDs(identities: Array(seen)).values)).compactMap { s in
            s.fromAddress.flatMap { a in a.lastIndex(of: "@").map { LinkCheck.registrableDomain(String(a[a.index(after: $0)...]).lowercased()) } }
        })
        try db.forEach("""
            SELECT m.id, m.identity, lower(m.from_addr), coalesce(c.category, 'open'),
                   EXISTS (SELECT 1 FROM locations l WHERE l.message_id = m.id AND \(QuerySQL.junkLocation))
            FROM messages m LEFT JOIN classifications c ON c.message_id = m.id
            WHERE m.trashed IS NULL AND instr(m.from_addr, '@') > 0
              AND NOT EXISTS (SELECT 1 FROM locations l WHERE l.message_id = m.id
                              AND (\(QuerySQL.sentLocation) OR \(QuerySQL.draftsLocation) OR \(QuerySQL.trashLocation)))
            ORDER BY m.date DESC NULLS LAST, m.id DESC LIMIT 60000
            """) { r in
            guard let identity = r.text(1), !seen.contains(identity), let from = r.text(2), let at = from.lastIndex(of: "@") else { return }
            let domain = LinkCheck.registrableDomain(String(from[from.index(after: at)...]))
            guard !domain.isEmpty, used.insert(domain).inserted else { return }  // the newest mail of each domain
            let bucket = r.bool(4) ? "junk" : (r.text(3) ?? "open")
            buckets[bucket, default: []].append((r.int(0), domain))
        }
        // in turn: the biggest bucket first, one each round
        let order = buckets.keys.sorted { (buckets[$0]?.count ?? 0, $0) > (buckets[$1]?.count ?? 0, $1) }
        var out: [Int64] = []
        var round = 0
        while out.count < limit {
            var any = false
            for key in order {
                guard let list = buckets[key], round < list.count else { continue }
                any = true
                out.append(list[round].id)
                if out.count == limit { break }
            }
            if !any { break }
            round += 1
        }
        return out
    }
}
