import Foundation

/// Runs a planned archive-delete job: messages go to the archive trash (journalled), in batches;
/// each item is recorded in the queue and the audit log. Reversible until purged.
public struct ArchiveDeleteExecutor: Sendable {
    public let writer: ArchiveWriter
    public let store: ActionStore
    public let audit: AuditLog
    public var batchSize = 500

    public init(writer: ArchiveWriter, store: ActionStore, audit: AuditLog) {
        self.writer = writer
        self.store = store
        self.audit = audit
    }

    public func run(_ jobID: UUID, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> ActionJob {
        var job = try store.load(jobID)
        guard job.kind == .archiveDelete, !job.cancelled else { return job }
        let open = job.open
        var done = 0
        for start in stride(from: 0, to: open.count, by: batchSize) {
            try Task.checkCancellation()
            let batch = Array(open[start..<min(start + batchSize, open.count)])
            for item in batch { try store.record(job: job.id, item: item.id, state: .claimed) }
            _ = try await writer.trash(batch.compactMap(\.identity))  // idempotent: already trashed stays
            for item in batch {
                let state: ActionItem.State = item.identity == nil ? .failed : .done
                let reason = item.identity == nil ? String(localized: "keine Archiv-Identität") : nil
                try store.record(job: job.id, item: item.id, state: state, reason: reason)
                job.items[item.id].state = state
                job.items[item.id].reason = reason
                try? audit.append(job: job, item: job.items[item.id])
            }
            done += batch.count
            progress(done, open.count)
        }
        return job
    }
}
