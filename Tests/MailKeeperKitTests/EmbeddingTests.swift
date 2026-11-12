import Foundation
import Testing
@testable import MailKeeperKit

@Suite("Embeddings und ähnliche Mails (5.7)")
struct EmbeddingTests {
    @Test func vectorsAreNormalisedStoredAsHalfAndRanked() {
        let v = VectorMath.normalized([3, 4])
        #expect(abs(v[0] - 0.6) < 1e-6 && abs(v[1] - 0.8) < 1e-6)
        let back = VectorMath.decode(VectorMath.encode(v))
        #expect(abs(back[0] - 0.6) < 1e-3 && abs(back[1] - 0.8) < 1e-3)
        let index = VectorIndex(ids: [1, 2, 3, 4], dim: 2, matrix: [1, 0, 0.8, 0.6, 0, 1, -1, 0])
        #expect(index.nearest(to: [1, 0], k: 2).map(\.id) == [1, 2])
        #expect(index.nearest(to: [1, 0], k: 2, excluding: 1).map(\.id) == [2, 3])
        #expect(index.nearest(to: [1, 0], k: 3, allowed: [3, 4]).map(\.id) == [3, 4])
        let queries = index.subset { $0 == 1 || $0 == 3 }
        let batch = index.nearestBatch(queries, k: 2, block: 1)
        #expect(batch[1]?.map(\.id) == [2, 3] && batch[3]?.map(\.id) == [2, 1])  // never itself
    }

    /// The loops that stand in for Accelerate on Linux score like the index does — on macOS that
    /// is Accelerate against the loops; on Linux both sides are the loops (a smoke test there).
    @Test func portableVectorMathScoresLikeTheIndex() {
        let dim = 37, rows = 40
        let matrix = (0..<(rows * dim)).map { Float(($0 * 7919) % 101 - 50) / 50 }
        let query = (0..<dim).map { Float(($0 * 31) % 17 - 8) / 8 }
        let index = VectorIndex(ids: (1...Int64(rows)).map { $0 }, dim: dim, matrix: matrix)

        let single = matrix.withUnsafeBufferPointer { VectorMath.products($0, rows: rows, with: query) }
        for hit in index.nearest(to: query, k: rows) {
            #expect(abs(hit.score - single[Int(hit.id) - 1]) < 1e-3, "row \(hit.id)")
        }

        let pairs = matrix.withUnsafeBufferPointer { m in VectorMath.products(m, rows: rows, with: m, rows: rows, dim: dim) }
        let batch = index.nearestBatch(index, k: rows - 1, block: 7)
        for (query, hits) in batch {
            for hit in hits {
                #expect(abs(hit.score - pairs[Int(query - 1) * rows + Int(hit.id - 1)]) < 1e-3, "\(query)·\(hit.id)")
            }
        }
        #expect(abs(VectorMath.normalized([3, 4]).reduce(0) { $0 + $1 * $1 } - 1) < 1e-6)
    }

    @Test func similarMailsDecideOnlyWhenTheyClearlyAgree() {
        let n = { (c: MailCategory, s: Float) in (category: c, score: s, domain: Optional("news.example")) }
        let decide = { (v: [(category: MailCategory, score: Float, domain: String?)]) in SimilarVote.decide(v, domain: "other.example") }
        #expect(decide([n(.newsletter, 0.95), n(.newsletter, 0.9), n(.newsletter, 0.88), n(.newsletter, 0.85), n(.invoice, 0.82)])?.category == .newsletter)
        #expect(decide([n(.newsletter, 0.95), n(.newsletter, 0.9), n(.invoice, 0.9), n(.invoice, 0.88)]) == nil)  // split
        #expect(decide([n(.newsletter, 0.95), n(.newsletter, 0.9), n(.newsletter, 0.7), n(.newsletter, 0.6)]) == nil)  // too few close ones
        #expect(decide([]) == nil)
    }

    @Test("Review 5.9 S3: similarity lends no lure credibility")
    func similarityNeverVouchesForALookAlike() {
        let n = { (c: MailCategory, d: String) in (category: c, score: Float(0.9), domain: Optional(d)) }
        // a phishing mail near real security mails: never "Konto/Sicherheit" (nor personal, work, spam)
        for c in [MailCategory.accountSecurity, .personal, .work, .spam] {
            #expect(SimilarVote.decide(Array(repeating: n(c, "bank.example"), count: 6), domain: "bank.example") == nil, "\(c)")
        }
        // an invoice look-alike from another domain stays open; from the senders' own domain it is decided
        let invoices = [n(.invoice, "stadtwerke.example"), n(.invoice, "stadtwerke.example"), n(.invoice, "stadtwerke.example"), n(.invoice, "other.example")]
        #expect(SimilarVote.decide(invoices, domain: "stadtwerke-rechnung.example") == nil)
        #expect(SimilarVote.decide(invoices, domain: nil) == nil)
        #expect(SimilarVote.decide(invoices, domain: "stadtwerke.example")?.category == .invoice)
        // newsletters need no sender match: the label vouches for nothing
        #expect(SimilarVote.decide(Array(repeating: n(.newsletter, "a.example"), count: 4), domain: "b.example")?.category == .newsletter)
    }

    @Test func storedVectorsAndSimilarityNeverOverrideDecisions() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "emb"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        _ = try await writer.ingest([
            (sampleMessage(id: "<a@t.test>", subject: "Offen A"), LocationInfo(account: "x", mailbox: "INBOX", providerID: "1")),
            (sampleMessage(id: "<b@t.test>", subject: "Offen B"), LocationInfo(account: "x", mailbox: "INBOX", providerID: "2")),
        ])
        _ = try await writer.classifyHeuristically()
        let r = try ArchiveReader(layout: layout)
        #expect(try r.embeddingPending(model: "m", limit: 10).count == 2)
        let ids = try r.openMessageIDs().sorted()
        try await writer.setEmbeddings([(ids[0], [1, 2, 2]), (ids[1], [0, 0, 5])], model: "m")
        #expect(try r.embeddingCounts(model: "m") == (2, 2) && r.embeddingPending(model: "m", limit: 10).isEmpty)
        let index = try r.vectorIndex(model: "m")
        #expect(index.count == 2 && index.dim == 3)
        #expect(abs((index.vector(of: ids[1])?[2] ?? 0) - 1) < 1e-3)
        try await writer.setClassification(messageID: ids[1], category: .personal, source: .endpoint, model: "x", reason: "x")
        try await writer.setSimilarClassification([(ids[0], .newsletter, "4 von 4"), (ids[1], .newsletter, "4 von 4")])
        #expect(try r.classification(of: ids[0])?.source == .similar && r.classification(of: ids[0])?.category == .newsletter)
        #expect(try r.classification(of: ids[1])?.category == .personal)  // a model's answer stays
        #expect(try r.labelledCategories()[ids[0]] == nil)  // similarity is never a label itself

        // an older vote is decided again; a rule change looks at the row again (review 5.9 S3, N5)
        #expect(try r.staleSimilarCount() == 0)
        let raw = try Database(path: layout.indexURL.path)
        try raw.run("UPDATE classifications SET rule = 'similar-v1' WHERE message_id = ?", [.int(ids[0])])
        #expect(try r.staleSimilarCount() == 1)
        #expect(try await writer.reopenStaleSimilar() == 1)
        #expect(try r.classification(of: ids[0])?.category == nil && r.openMessageIDs().contains(ids[0]))
        try await writer.setSimilarClassification([(ids[0], .newsletter, "4 von 4")])
        try raw.run("UPDATE classifications SET version = 1 WHERE message_id = ?", [.int(ids[0])])
        #expect(try r.heuristicPendingCount() == 1)
        _ = try await writer.classifyHeuristically()
        #expect(try r.classification(of: ids[0])?.source == .heuristic)
    }
}
