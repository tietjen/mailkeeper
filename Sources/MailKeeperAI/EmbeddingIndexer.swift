import Foundation
import MailKeeperKit

/// Fills the archive's vectors in the background (5.7): batches of messages without one, sent
/// to the endpoint's embedding model, stored as normalised Float16. Then "similar mails" decide
/// open categories where they clearly agree. Stops quietly when the endpoint is away.
public struct EmbeddingIndexer: Sendable {
    public struct Progress: Sendable, Equatable {
        public var done: Int
        public var total: Int
    }

    public let router: AIRouter
    public let writer: ArchiveWriter
    public var batch = 64

    public init(router: AIRouter, writer: ArchiveWriter) {
        self.router = router
        self.writer = writer
    }

    /// Returns how many vectors it added.
    @discardableResult
    public func run(progress: @Sendable (Progress) -> Void = { _ in }) async throws -> Int {
        let model = router.config.model(for: .embed)
        let reader = try ArchiveReader(layout: writer.layout)
        var (done, total) = try reader.embeddingCounts(model: model)
        var added = 0
        while true {
            try Task.checkCancellation()
            let pending = try reader.embeddingPending(model: model, limit: batch)
            guard !pending.isEmpty else { break }
            let vectors = try await router.embed(pending.map(\.text))
            guard vectors.count == pending.count else { throw AIError.badAnswer(String(localized: "Embedding-Antwort unvollständig")) }
            try await writer.setEmbeddings(zip(pending, vectors).map { (id: $0.0.id, vector: $0.1) }, model: model)
            added += pending.count
            done += pending.count
            progress(Progress(done: min(done, total), total: total))
            if done > total { total = done }
        }
        return added
    }

    /// Open mails take the category their similar, labelled neighbours agree on (SimilarVote).
    @discardableResult
    public func decideOpenBySimilarity() async throws -> Int {
        let model = router.config.model(for: .embed)
        let reader = try ArchiveReader(layout: writer.layout)
        let open = Set(try reader.openMessageIDs())
        guard !open.isEmpty else { return 0 }
        let labels = try reader.labelledCategories()
        let index = try reader.vectorIndex(model: model)
        guard index.count > 0 else { return 0 }
        let labelled = index.subset { labels[$0] != nil }
        let queries = index.subset { open.contains($0) }
        guard labelled.count > 0, queries.count > 0 else { return 0 }
        var decided: [(id: Int64, category: MailCategory, reason: String)] = []
        for (id, neighbours) in labelled.nearestBatch(queries, k: 10) {
            let votes = neighbours.compactMap { n in labels[n.id].map { (category: $0, score: n.score) } }
            if let d = SimilarVote.decide(votes) {
                decided.append((id, d.category, String(localized: "\(d.agree) von \(d.of) ähnlichen Mails: \(d.category.label)")))
            }
        }
        try await writer.setSimilarClassification(decided)
        return decided.count
    }
}
