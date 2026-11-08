import Foundation

extension ActionJob {
    /// Keys that tie a server item to an archive item of the same mail: the Message-ID, and the
    /// blob (a server item carries its location's blob, an archive item the message's primary one,
    /// so the Message-ID is what usually matches).
    public static func mailKeys(_ item: ActionItem) -> [String] {
        [item.messageID.map { "mid:" + $0 }, item.sha256.isEmpty ? nil : "sha:" + item.sha256].compactMap { $0 }
    }

    /// "Komplett entfernen": the archive half (`self`), with every mail the server half did not
    /// verifiably take off its server skipped — failed, skipped or left open there, or found gone
    /// already (it may have moved to another folder since the last fetch: fetch first). The
    /// writer checks the server state again; this keeps the moved ones out, which it cannot see.
    public func archiveHalf(after server: ActionJob) -> ActionJob {
        var staying: Set<String> = []
        var moved: Set<String> = []
        for item in server.items {
            if item.state != .done {
                staying.formUnion(Self.mailKeys(item))
            } else if item.reason == ServerDeleteExecutor.alreadyGone {
                moved.formUnion(Self.mailKeys(item))
            }
        }
        var job = self
        for i in job.items.indices where job.items[i].state == .planned {
            let keys = Self.mailKeys(job.items[i])
            if keys.contains(where: staying.contains) {
                job.items[i].state = .skipped
                job.items[i].reason = ArchiveReader.stillOnServer
            } else if keys.contains(where: moved.contains) {
                job.items[i].state = .skipped
                job.items[i].reason = Self.notThereAnyMore
            }
        }
        return job
    }

    public static let notThereAnyMore = String(localized: "lag auf dem Server nicht mehr dort – erst neu abrufen")
}

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
            // checked when it happens: a message back on a server since planning stays (review 4.7)
            let outcome = try await writer.trashDetailed(batch.compactMap(\.identity))  // idempotent: already trashed stays
            for item in batch {
                let (state, reason): (ActionItem.State, String?) = switch item.identity {
                case nil: (.failed, String(localized: "keine Archiv-Identität"))
                case let id? where outcome.onServer.contains(id): (.skipped, ArchiveReader.stillOnServer)
                case let id? where outcome.missing.contains(id): (.failed, String(localized: "nicht (mehr) im Archiv"))
                default: (.done, nil)
                }
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
