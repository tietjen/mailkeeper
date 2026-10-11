import Foundation

/// What a message looks like on the server right before it is moved.
public struct RemoteIdentity: Sendable, Equatable {
    public var messageID: String?
    public var size: Int?
    public var flags: [String]

    public init(messageID: String?, size: Int?, flags: [String]) {
        self.messageID = messageID
        self.size = size
        self.flags = flags
    }
}

/// The server side of "delete on the server" (ADR-0006 §3): move to the SPECIAL-USE \Trash —
/// IMAP in the app (a connection opened for exactly this), a fake in tests.
public protocol ServerTrashActions: Sendable {
    /// The mailbox marked \Trash; nil when the server marks none (never guessed by name).
    func trashMailbox() async throws -> String?
    /// Opens a mailbox for changes; returns its UIDVALIDITY.
    func selectForChange(_ mailbox: String) async throws -> UInt32
    /// Message-ID, size and flags of the given UIDs; UIDs no longer there are absent.
    func identities(_ uids: [UInt32]) async throws -> [UInt32: RemoteIdentity]
    /// Raw bytes, for messages without a Message-ID (compared by SHA-256).
    func bodies(_ uids: [UInt32]) async throws -> [UInt32: Data]
    func moveToTrash(_ uids: [UInt32]) async throws
    /// Which of the UIDs still exist in the selected mailbox.
    func present(_ uids: [UInt32]) async throws -> Set<UInt32>
    func close() async
}

public struct ServerDeleteProgress: Sendable, Equatable {
    public var total: Int
    public var done = 0
    public var failed = 0
    public var skipped = 0
    public var account: String?
}

/// Runs a planned server-delete job (ADR-0006 §2–3): per account and mailbox, in batches —
/// verify the archived blob, check UIDVALIDITY, re-fetch Message-ID / size / flags for each UID
/// (a different message under that UID, or a flag set since planning, stops it), mark claimed,
/// move to \Trash, verify the UIDs are gone, then record the location as gone in the archive
/// (journalled) and in the audit log. Resumable: claimed items from an interrupted run are
/// checked again; cancelling stops after the current batch.
public struct ServerDeleteExecutor: Sendable {
    public let writer: ArchiveWriter
    public let store: ActionStore
    public let audit: AuditLog
    public var batchSize = 50

    public init(writer: ArchiveWriter, store: ActionStore, audit: AuditLog) {
        self.writer = writer
        self.store = store
        self.audit = audit
    }

    public func run(_ jobID: UUID, connect: @Sendable (String) async throws -> any ServerTrashActions,
                    progress: @escaping @Sendable (ServerDeleteProgress) -> Void = { _ in }) async throws -> ActionJob {
        var job = try store.load(jobID)
        guard job.kind == .serverDelete, !job.cancelled else { return job }
        var p = ServerDeleteProgress(total: job.open.count)
        progress(p)
        let byAccount = Dictionary(grouping: job.open.filter { $0.location != nil }, by: { $0.location!.account })
        for account in byAccount.keys.sorted() {
            try Task.checkCancellation()
            p.account = account
            progress(p)
            let server = try await connect(account)
            do {
                try await run(account: account, items: byAccount[account]!, server: server, job: &job, progress: &p, notify: progress)
                await server.close()
            } catch {
                await server.close()
                throw error
            }
        }
        p.account = nil
        progress(p)
        return job
    }

    private func run(account: String, items accountItems: [ActionItem], server: any ServerTrashActions, job: inout ActionJob,
                     progress p: inout ServerDeleteProgress, notify progress: @Sendable (ServerDeleteProgress) -> Void) async throws {
            guard let _ = try await server.trashMailbox() else {
                for item in accountItems {
                    try finish(&job, item.id, .failed, String(localized: "Kein Papierkorb (\\Trash) auf dem Server gefunden"), &p)
                }
                progress(p)
                return
            }
            let byMailbox = Dictionary(grouping: accountItems, by: { $0.location!.mailbox })
            for mailbox in byMailbox.keys.sorted() {
                let items = byMailbox[mailbox]!
                let validity = try await server.selectForChange(mailbox)
                let (current, stale) = items.partitioned { $0.location!.uidValidity == validity }
                for item in stale {
                    try finish(&job, item.id, .failed, String(localized: "Ordner wurde auf dem Server neu nummeriert (UIDVALIDITY) – erst neu abrufen"), &p)
                }
                for start in stride(from: 0, to: current.count, by: batchSize) {
                    try Task.checkCancellation()
                    try await batch(Array(current[start..<min(start + batchSize, current.count)]), validity: validity,
                                    server: server, job: &job, progress: &p)
                    progress(p)
                }
            }
    }

    private func batch(_ items: [ActionItem], validity: UInt32, server: any ServerTrashActions,
                       job: inout ActionJob, progress p: inout ServerDeleteProgress) async throws {
        // 1. the archive copy must be intact before the server copy may go
        var candidates: [ActionItem] = []
        for item in items {
            switch (try? writer.layout.blobs.verify(item.sha256)) {
            case true?: candidates.append(item)
            case false?: try finish(&job, item.id, .failed, String(localized: "Archivkopie beschädigt"), &p)
            case nil: try finish(&job, item.id, .failed, String(localized: "Archivkopie fehlt"), &p)
            }
        }
        guard !candidates.isEmpty else { return }
        // 2. is it still the same message, and still unflagged?
        let uids = candidates.map { $0.location!.uid }
        let remote = try await server.identities(uids)
        let needBodies = candidates.filter { $0.messageID == nil && remote[$0.location!.uid] != nil }.map { $0.location!.uid }
        let bodies = needBodies.isEmpty ? [:] : try await server.bodies(needBodies)
        var alreadyGone: [ActionItem] = []
        var go: [ActionItem] = []
        for item in candidates {
            let uid = item.location!.uid
            guard let r = remote[uid] else { alreadyGone.append(item); continue }
            if r.flags.contains(where: { $0.lowercased() == "\\flagged" }) {
                try finish(&job, item.id, .skipped, String(localized: "inzwischen markiert"), &p)
                continue
            }
            let same: Bool
            if let expected = item.messageID {
                same = r.messageID == expected && (r.size == nil || r.size == item.size)
            } else {
                same = bodies[uid].map { sha256Hex($0) == item.sha256 } ?? false
            }
            if same { go.append(item) } else {
                try finish(&job, item.id, .failed, String(localized: "Mail auf dem Server stimmt nicht mit dem Archiv überein"), &p)
            }
        }
        // 3. claim, act, verify
        for item in go { try store.record(job: job.id, item: item.id, state: .claimed) }
        if !go.isEmpty { try await server.moveToTrash(go.map { $0.location!.uid }) }
        let stillThere = go.isEmpty ? [] : try await server.present(go.map { $0.location!.uid })
        var gone: Set<UInt32> = []
        for item in alreadyGone {
            gone.insert(item.location!.uid)
            try finish(&job, item.id, .done, String(localized: "war bereits nicht mehr auf dem Server"), &p)
        }
        for item in go {
            if stillThere.contains(item.location!.uid) {
                try finish(&job, item.id, .failed, String(localized: "nach dem Verschieben noch auf dem Server"), &p)
            } else {
                gone.insert(item.location!.uid)
                try finish(&job, item.id, .done, nil, &p)
            }
        }
        // 4. the archive learns the location is gone (journalled, like a sync would)
        if let location = items.first?.location, !gone.isEmpty {
            _ = try await writer.markGone(account: location.account, mailbox: location.mailbox, uidValidity: validity, uids: gone)
        }
    }

    private func finish(_ job: inout ActionJob, _ id: Int, _ state: ActionItem.State, _ reason: String?,
                        _ p: inout ServerDeleteProgress) throws {
        try store.record(job: job.id, item: id, state: state, reason: reason)
        job.items[id].state = state
        job.items[id].reason = reason
        try? audit.append(job: job, item: job.items[id])  // the queue is the record; the log is a copy
        switch state {
        case .done: p.done += 1
        case .failed: p.failed += 1
        case .skipped: p.skipped += 1
        default: break
        }
    }
}

extension Array {
    func partitioned(_ isFirst: (Element) -> Bool) -> ([Element], [Element]) {
        var a: [Element] = [], b: [Element] = []
        for e in self { if isFirst(e) { a.append(e) } else { b.append(e) } }
        return (a, b)
    }
}
