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

    public func load() -> GoldLabels {
        guard let data = try? Data(contentsOf: labelsURL) else { return GoldLabels() }
        return (try? Self.decoder.decode(GoldLabels.self, from: data)) ?? GoldLabels()
    }

    public func save(_ labels: GoldLabels) throws {
        var e = Self.encoder
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        try e.encode(labels).write(to: labelsURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: labelsURL.path)
    }

    /// Runs are appended as one JSON object per line, whatever type the caller measures with.
    public func appendRun<T: Encodable>(_ run: T) throws {
        var line = try Self.encoder.encode(run)
        line.append(0x0A)
        if let handle = try? FileHandle(forWritingTo: runsURL) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: runsURL, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runsURL.path)
        }
    }

    public func runs<T: Decodable>(as type: T.Type) -> [T] {
        guard let text = try? String(contentsOf: runsURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? Self.decoder.decode(T.self, from: Data($0.utf8)) }
    }
}

extension ArchiveReader {
    /// Mails to offer for labelling, spread out: one per sender domain (the newest), taken in
    /// turn from every bucket — each category as MailKeeper has it today, the open ones, the
    /// spam folder — so a few big senders cannot fill the set. Not sent, drafts or trash; not
    /// what was labelled or skipped.
    public func goldCandidates(limit: Int, excluding seen: Set<String>) throws -> [Int64] {
        var buckets: [String: [(id: Int64, domain: String)]] = [:]
        var used: Set<String> = []
        try db.forEach("""
            SELECT m.id, m.identity, lower(m.from_addr), coalesce(c.category, 'open'),
                   EXISTS (SELECT 1 FROM locations l WHERE l.message_id = m.id AND \(QuerySQL.junkLocation))
            FROM messages m LEFT JOIN classifications c ON c.message_id = m.id
            WHERE m.trashed IS NULL AND instr(m.from_addr, '@') > 0
              AND NOT EXISTS (SELECT 1 FROM locations l WHERE l.message_id = m.id AND (\(QuerySQL.sentLocation) OR \(QuerySQL.draftsLocation)))
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
