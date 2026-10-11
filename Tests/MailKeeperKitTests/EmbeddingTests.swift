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

    @Test func similarMailsDecideOnlyWhenTheyClearlyAgree() {
        let n = { (c: MailCategory, s: Float) in (category: c, score: s) }
        #expect(SimilarVote.decide([n(.newsletter, 0.95), n(.newsletter, 0.9), n(.newsletter, 0.88), n(.newsletter, 0.85), n(.invoice, 0.82)])?.category == .newsletter)
        #expect(SimilarVote.decide([n(.newsletter, 0.95), n(.newsletter, 0.9), n(.invoice, 0.9), n(.invoice, 0.88)]) == nil)  // split
        #expect(SimilarVote.decide([n(.newsletter, 0.95), n(.newsletter, 0.9), n(.newsletter, 0.7), n(.newsletter, 0.6)]) == nil)  // too few close ones
        #expect(SimilarVote.decide([]) == nil)
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
    }
}
