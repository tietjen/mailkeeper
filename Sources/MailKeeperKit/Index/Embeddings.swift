import Accelerate
import Foundation

/// What a message's vector is made of: subject, sender, attachment names and the snippet — all
/// in the index already, no message is read (Phase 5.7).
public enum EmbeddingText {
    public static func make(subject: String?, fromName: String?, fromAddr: String?, attachments: String?, snippet: String?) -> String {
        var lines: [String] = []
        if let subject, !subject.isEmpty { lines.append("Betreff: \(subject)") }
        let sender = [fromName, fromAddr.map { "<\($0)>" }].compactMap { $0 }.joined(separator: " ")
        if !sender.isEmpty { lines.append("Von: \(sender)") }
        if let attachments, !attachments.isEmpty { lines.append("Anhänge: \(attachments)") }
        if let snippet, !snippet.isEmpty { lines.append(snippet) }
        return String(lines.joined(separator: "\n").prefix(2_000))
    }
}

extension ArchiveWriter {
    /// Vectors for messages (normalised, stored as Float16): derived data, not journalled.
    public func setEmbeddings(_ items: [(id: Int64, vector: [Float])], model: String) throws {
        try setEmbeddingRows(items.map { ($0.id, VectorMath.encode(VectorMath.normalized($0.vector))) }, model: model)
    }
}

extension ArchiveReader {
    /// Messages without a vector of this model (outside the trash), newest first, with their text.
    public func embeddingPending(model: String, limit: Int) throws -> [(id: Int64, text: String)] {
        try db.query("""
            SELECT m.id, m.subject, m.from_name, m.from_addr,
                   (SELECT group_concat(a.filename, ', ') FROM attachments a WHERE a.message_id = m.id AND a.is_inline = 0),
                   m.snippet
            FROM messages m LEFT JOIN embeddings e ON e.message_id = m.id AND e.model = ?
            WHERE e.message_id IS NULL AND m.trashed IS NULL
            ORDER BY m.date DESC LIMIT ?
            """, [.text(model), .int(Int64(limit))]) { r in
            (r.int(0), EmbeddingText.make(subject: r.text(1), fromName: r.text(2), fromAddr: r.text(3), attachments: r.text(4), snippet: r.text(5)))
        }
    }

    public func embeddingCounts(model: String) throws -> (done: Int, total: Int) {
        try db.queryOne("""
            SELECT (SELECT count(*) FROM embeddings e JOIN messages m ON m.id = e.message_id WHERE e.model = ? AND m.trashed IS NULL),
                   (SELECT count(*) FROM messages WHERE trashed IS NULL)
            """, [.text(model)]) { (Int($0.int(0)), Int($0.int(1))) } ?? (0, 0)
    }

    /// All vectors of a model in memory, for search and for sorting the open mails.
    public func vectorIndex(model: String) throws -> VectorIndex {
        var ids: [Int64] = []
        var matrix: [Float] = []
        var dim = 0
        try db.forEach("""
            SELECT e.message_id, e.dim, e.vector FROM embeddings e JOIN messages m ON m.id = e.message_id
            WHERE e.model = ? AND m.trashed IS NULL
            """, [.text(model)]) { r in
            let d = Int(r.int(1))
            guard let blob = r.data(2), d > 0, blob.count == d * 2, dim == 0 || d == dim else { return }
            dim = d
            ids.append(r.int(0))
            matrix.append(contentsOf: VectorMath.decode(blob))
        }
        return VectorIndex(ids: ids, dim: dim, matrix: matrix)
    }

    /// Categories that count as labels for "similar mails": the rules', the models' and the
    /// user's — never one decided by similarity itself (no echo).
    public func labelledCategories() throws -> [Int64: MailCategory] {
        var out: [Int64: MailCategory] = [:]
        try db.forEach("SELECT message_id, category FROM classifications WHERE category IS NOT NULL AND source != 'similar'") { r in
            if let c = r.text(1).flatMap(MailCategory.init(rawValue:)) { out[r.int(0)] = c }
        }
        return out
    }

    /// Each message's registrable sender domain ("bank.example" for "info@mail.bank.example").
    public func senderDomains() throws -> [Int64: String] {
        var out: [Int64: String] = [:]
        try db.forEach("SELECT id, from_addr FROM messages WHERE trashed IS NULL AND from_addr LIKE '%@%'") { r in
            if let addr = r.text(1), let at = addr.lastIndex(of: "@") {
                let host = addr[addr.index(after: at)...].trimmingCharacters(in: CharacterSet(charactersIn: " >")).lowercased()
                if !host.isEmpty { out[r.int(0)] = LinkCheck.registrableDomain(host) }
            }
        }
        return out
    }

    /// Rows "similar mails" decided under an older vote.
    public func staleSimilarCount() throws -> Int {
        Int(try db.queryOne("SELECT count(*) FROM classifications WHERE source = 'similar' AND coalesce(rule, '') != ?",
                            [.text(SimilarVote.ruleTag)]) { $0.int(0) } ?? 0)
    }

    /// Messages the rules left open and no model or user has decided.
    public func openMessageIDs() throws -> [Int64] {
        try db.query("""
            SELECT c.message_id FROM classifications c JOIN messages m ON m.id = c.message_id
            WHERE c.category IS NULL AND c.verdict IS NULL AND m.trashed IS NULL
            """) { $0.int(0) }
    }
}

/// Normalised vectors in one row-major matrix; cosine = dot product (Accelerate).
public struct VectorIndex: Sendable {
    public let ids: [Int64]
    public let dim: Int
    let matrix: [Float]

    public var count: Int { ids.count }

    public init(ids: [Int64], dim: Int, matrix: [Float]) {
        self.ids = ids
        self.dim = dim
        self.matrix = matrix
    }

    /// The rows whose id passes `keep`.
    public func subset(_ keep: (Int64) -> Bool) -> VectorIndex {
        var ids: [Int64] = []
        var rows: [Float] = []
        for (i, id) in self.ids.enumerated() where keep(id) {
            ids.append(id)
            rows.append(contentsOf: matrix[(i * dim)..<((i + 1) * dim)])
        }
        return VectorIndex(ids: ids, dim: dim, matrix: rows)
    }

    public func vector(of id: Int64) -> [Float]? {
        guard let i = ids.firstIndex(of: id) else { return nil }
        return Array(matrix[(i * dim)..<((i + 1) * dim)])
    }

    /// The `k` most similar messages to a (normalised) query, best first; `allowed` narrows.
    public func nearest(to query: [Float], k: Int, allowed: Set<Int64>? = nil, excluding: Int64? = nil) -> [(id: Int64, score: Float)] {
        guard count > 0, query.count == dim else { return [] }
        var scores = [Float](repeating: 0, count: count)
        matrix.withUnsafeBufferPointer { m in
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(count), Int32(dim), 1, m.baseAddress, Int32(dim), query, 1, 0, &scores, 1)
        }
        var hits: [(Int64, Float)] = []
        hits.reserveCapacity(min(count, 4 * k))
        for i in 0..<count where ids[i] != excluding && (allowed?.contains(ids[i]) ?? true) { hits.append((ids[i], scores[i])) }
        return Array(hits.sorted { $0.1 > $1.1 }.prefix(k)).map { (id: $0.0, score: $0.1) }
    }

    /// For many queries at once (rows of `queries`), the `k` best of `self` each — sgemm in
    /// blocks, so memory stays bounded.
    public func nearestBatch(_ queries: VectorIndex, k: Int, block: Int = 512) -> [Int64: [(id: Int64, score: Float)]] {
        guard count > 0, queries.count > 0, queries.dim == dim else { return [:] }
        var out: [Int64: [(id: Int64, score: Float)]] = [:]
        var start = 0
        while start < queries.count {
            let rows = min(block, queries.count - start)
            var scores = [Float](repeating: 0, count: rows * count)
            queries.matrix.withUnsafeBufferPointer { q in
                matrix.withUnsafeBufferPointer { m in
                    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(rows), Int32(count), Int32(dim), 1,
                                q.baseAddress! + start * dim, Int32(dim), m.baseAddress, Int32(dim), 0, &scores, Int32(count))
                }
            }
            for r in 0..<rows {
                let qid = queries.ids[start + r]
                var best: [(Int64, Float)] = []
                for c in 0..<count where ids[c] != qid {
                    let s = scores[r * count + c]
                    if best.count < k { best.append((ids[c], s)); if best.count == k { best.sort { $0.1 > $1.1 } } }
                    else if s > best[k - 1].1 { best[k - 1] = (ids[c], s); best.sort { $0.1 > $1.1 } }
                }
                out[qid] = best.sorted { $0.1 > $1.1 }.map { (id: $0.0, score: $0.1) }
            }
            start += rows
        }
        return out
    }
}

public enum VectorMath {
    public static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    static func encode(_ v: [Float]) -> Data {
        var halves = v.map { Float16($0) }
        return Data(bytes: &halves, count: halves.count * 2)
    }

    static func decode(_ data: Data) -> [Float] {
        data.withUnsafeBytes { raw in raw.bindMemory(to: Float16.self).map { Float($0) } }
    }
}

/// "Similar mails" decide an open mail's category when they agree clearly (ADR-0004 §1, step 2):
/// at least `minNeighbours` labelled neighbours above `minScore`, and one category with
/// `minShare` of their weight. Never phishing — that stays with a model. And never what would
/// lend a lure credibility (review 5.9 S3, like the rules): account/security, personal, work and
/// spam stay with a model; notifications, invoices, orders and travel only when the mail comes
/// from the sender domain most of the agreeing neighbours come from — it extends a known
/// sender's pattern instead of vouching for a look-alike.
public enum SimilarVote {
    public static let minScore: Float = 0.80
    public static let minShare: Float = 0.70
    public static let minNeighbours = 4
    /// Stored as the row's `rule`: rows of an older vote are decided again.
    public static let version = 2
    public static var ruleTag: String { "similar-v\(version)" }
    public static let allowed: Set<MailCategory> = [.newsletter, .notification, .invoice, .orderShipping, .travel]
    public static let needsSameSender: Set<MailCategory> = [.notification, .invoice, .orderShipping, .travel]

    public static func decide(_ neighbours: [(category: MailCategory, score: Float, domain: String?)], domain: String?)
        -> (category: MailCategory, agree: Int, of: Int)? {
        let strong = neighbours.filter { $0.score >= minScore }
        guard strong.count >= minNeighbours else { return nil }
        var weight: [MailCategory: Float] = [:]
        var votes: [MailCategory: Int] = [:]
        for n in strong {
            weight[n.category, default: 0] += n.score
            votes[n.category, default: 0] += 1
        }
        let total = weight.values.reduce(0, +)
        guard let (best, w) = weight.max(by: { $0.value < $1.value }), total > 0, w / total >= minShare, allowed.contains(best) else { return nil }
        if needsSameSender.contains(best) {
            let agreeing = strong.filter { $0.category == best }
            let same = agreeing.filter { $0.domain != nil && $0.domain == domain }.count
            guard domain != nil, same * 2 > agreeing.count else { return nil }
        }
        return (best, votes[best] ?? 0, strong.count)
    }
}
