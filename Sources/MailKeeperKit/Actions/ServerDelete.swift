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
/// checked again; cancelling stops after the current batch. A connection that drops mid-run
/// (`reconnectAfter` says which errors mean that) is opened again, up to `maxReconnects` times
/// per account, and the account's open items go on from there — the same re-check as a resume.
public struct ServerDeleteExecutor: Sendable {
    /// Done, but not by this delete: the UID was no longer there — deleted, or moved to another
    /// folder since the last fetch (then the mail still lives on the server).
    public static let alreadyGone = String(localized: "war bereits nicht mehr auf dem Server")
    /// Done by this delete, confirmed late: claimed in this run, the connection dropped before
    /// the server's answer, and on the re-check after reconnecting the UID is gone — seconds
    /// later, on the connection this run opened again. Unlike `alreadyGone`, "Komplett entfernen"
    /// takes the archive copy of these too. A claim from an earlier run (resumed by hand, maybe
    /// days later; the process may have died between claim and move) proves less: a UID gone
    /// then stays `alreadyGone`.
    public static let movedBeforeInterruption = String(localized: "beim unterbrochenen Lauf in den Papierkorb verschoben")

    public let writer: ArchiveWriter
    public let store: ActionStore
    public let audit: AuditLog
    public var batchSize = 50
    /// Smaller batches for some accounts (account id → size): Gmail answers a MOVE of 50
    /// messages out of All Mail in 1–3 s on a good day and in over two minutes on a bad one.
    public var batchSizes: [String: Int] = [:]
    public var maxReconnects = 2
    /// Lets a server finish what it was doing when the connection dropped (a MOVE it already
    /// started) before the re-check looks.
    public var reconnectPause: Duration = .seconds(5)

    public init(writer: ArchiveWriter, store: ActionStore, audit: AuditLog) {
        self.writer = writer
        self.store = store
        self.audit = audit
    }

    public func run(_ jobID: UUID, connect: @Sendable (String) async throws -> any ServerTrashActions,
                    reconnectAfter: @Sendable (Error) -> Bool = { _ in false },
                    progress: @escaping @Sendable (ServerDeleteProgress) -> Void = { _ in }) async throws -> ActionJob {
        var job = try store.load(jobID)
        guard job.kind == .serverDelete, !job.cancelled else { return job }
        var p = ServerDeleteProgress(total: job.open.count)
        progress(p)
        let accounts = Set(job.open.compactMap { $0.location?.account })
        var claimedThisRun: Set<Int> = []
        for account in accounts.sorted() {
            var reconnects = 0  // drops in a row without progress
            attempts: while true {
                try Task.checkCancellation()
                // what is still open for this account — after a dropped connection, the rest
                let items = job.open.filter { $0.location?.account == account }
                guard !items.isEmpty else { break }
                p.account = account
                progress(p)
                do {
                    // opening it again can fail the same way (the network is still away)
                    let server = try await connect(account)
                    do {
                        try await run(account: account, items: items, server: server, job: &job, claimed: &claimedThisRun,
                                      progress: &p, notify: progress)
                        await server.close()
                    } catch {
                        await server.close()
                        throw error
                    }
                    break attempts
                } catch {
                    // a long job may drop now and then: the budget is for drops without progress
                    if job.open.filter({ $0.location?.account == account }).count < items.count { reconnects = 0 }
                    guard !(error is CancellationError), reconnects < maxReconnects, reconnectAfter(error) else { throw error }
                    reconnects += 1
                    try await Task.sleep(for: reconnectPause)
                }
            }
        }
        p.account = nil
        progress(p)
        return job
    }

    private func run(account: String, items accountItems: [ActionItem], server: any ServerTrashActions, job: inout ActionJob,
                     claimed: inout Set<Int>,
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
                let validity: UInt32
                do {
                    validity = try await server.selectForChange(mailbox)
                } catch let refusal as ServerRefusal {
                    for item in items { try finish(&job, item.id, .failed, String(localized: "vom Server abgelehnt: \(refusal.message)"), &p) }
                    progress(p)
                    continue
                }
                let (current, stale) = items.partitioned { $0.location!.uidValidity == validity }
                for item in stale {
                    try finish(&job, item.id, .failed, String(localized: "Ordner wurde auf dem Server neu nummeriert (UIDVALIDITY) – erst neu abrufen"), &p)
                }
                let size = max(1, batchSizes[account] ?? batchSize)
                for start in stride(from: 0, to: current.count, by: size) {
                    try Task.checkCancellation()
                    try await batch(Array(current[start..<min(start + size, current.count)]), validity: validity,
                                    server: server, job: &job, claimed: &claimed, progress: &p)
                    progress(p)
                }
            }
    }

    private func batch(_ items: [ActionItem], validity: UInt32, server: any ServerTrashActions,
                       job: inout ActionJob, claimed: inout Set<Int>, progress p: inout ServerDeleteProgress) async throws {
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
        // Compared by bytes: mail without a Message-ID, and mail whose header did not come back
        // in this answer (seen on Gmail inside a batch — alone, the same UID answers in full).
        let needBodies = candidates.filter { item in
            remote[item.location!.uid].map { item.messageID == nil || $0.messageID == nil } ?? false
        }.map { $0.location!.uid }
        let bodies = needBodies.isEmpty ? [:] : try await server.bodies(needBodies)
        var alreadyGone: [ActionItem] = []
        var movedEarlier: [ActionItem] = []
        var go: [ActionItem] = []
        for item in candidates {
            let uid = item.location!.uid
            guard let r = remote[uid] else {
                // claimed in this run = this delete sent the move, the connection dropped before
                // the answer; an older claim (resumed by hand) proves less
                if item.state == .claimed && claimed.contains(item.id) { movedEarlier.append(item) } else { alreadyGone.append(item) }
                continue
            }
            if r.flags.contains(where: { $0.lowercased() == "\\flagged" }) {
                try finish(&job, item.id, .skipped, String(localized: "inzwischen markiert"), &p)
                continue
            }
            let same: Bool
            if let expected = item.messageID, let got = r.messageID {
                same = got == expected && (r.size == nil || r.size == item.size)
            } else {
                same = bodies[uid].map { sha256Hex($0) == item.sha256 } ?? false
            }
            if same { go.append(item) } else {
                try finish(&job, item.id, .failed, String(localized: "Mail auf dem Server stimmt nicht mit dem Archiv überein"), &p)
            }
        }
        // 3. claim, act, verify
        for item in go {
            try store.record(job: job.id, item: item.id, state: .claimed)
            job.items[item.id].state = .claimed  // a reconnect in this run re-checks it as claimed
            claimed.insert(item.id)
        }
        var refusal: String?
        if !go.isEmpty {
            do { try await server.moveToTrash(go.map { $0.location!.uid }) } catch let r as ServerRefusal { refusal = r.message }
        }
        // what is gone is done, whatever the server said; what is still there failed
        let stillThere = go.isEmpty ? [] : try await server.present(go.map { $0.location!.uid })
        var gone: Set<UInt32> = []
        for item in alreadyGone {
            gone.insert(item.location!.uid)
            try finish(&job, item.id, .done, ServerDeleteExecutor.alreadyGone, &p)
        }
        for item in movedEarlier {
            gone.insert(item.location!.uid)
            try finish(&job, item.id, .done, ServerDeleteExecutor.movedBeforeInterruption, &p)
        }
        for item in go {
            if stillThere.contains(item.location!.uid) {
                try finish(&job, item.id, .failed, refusal.map { String(localized: "vom Server abgelehnt: \($0)") }
                           ?? String(localized: "nach dem Verschieben noch auf dem Server"), &p)
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
