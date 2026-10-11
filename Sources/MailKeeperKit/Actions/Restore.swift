import Foundation

/// UIDVALIDITY and UID of a message the server took (APPENDUID, RFC 4315).
public struct AppendedMessage: Sendable, Equatable {
    public var uidValidity: UInt32
    public var uid: UInt32

    public init(uidValidity: UInt32, uid: UInt32) {
        self.uidValidity = uidValidity
        self.uid = uid
    }
}

/// The server said no to one message (NO/BAD to an APPEND): that item fails, the job goes on.
public struct ServerRefusal: Error, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}

/// The server side of "restore" (ADR-0006 §5) — IMAP with the narrow `.restore` access in the
/// app, a fake in tests. Calls after `selectForChange` refer to that mailbox.
public protocol ServerRestoreActions: Sendable {
    func capabilities() async -> SourceCapabilities
    func mailboxes() async throws -> [RemoteMailbox]
    /// Opens a mailbox for changes; returns its UIDVALIDITY.
    func selectForChange(_ mailbox: String) async throws -> UInt32
    /// UIDs whose Message-ID header contains `messageID` (a substring match: callers confirm).
    func search(messageID: String) async throws -> [UInt32]
    /// APPENDs the bytes with flags and arrival date (nil = now); the new UID when the server
    /// reports it. Never creates the mailbox. Throws `ServerRefusal` when the server says no.
    func append(_ data: Data, to mailbox: String, flags: [String], internalDate: Date?) async throws -> AppendedMessage?
    /// Gmail: adds labels to a message appended on this connection.
    func addLabels(_ labels: [String], uid: UInt32) async throws
    /// Full messages without setting \Seen.
    func fetch(_ uids: [UInt32]) async throws -> [RemoteMessage]
    func close() async
}

/// Runs a planned restore job (ADR-0006 §5): per account and mailbox, one message at a time —
/// verify the archive copy, look for it in the target by Message-ID (nothing lands twice, a
/// re-run is harmless), mark claimed, APPEND with flags and date, add Gmail labels, fetch it
/// back and compare (same bytes; Proton rewrites headers, so there the same Message-ID), then
/// record the new location in the archive (journalled, like a sync) and in the audit log.
/// MailKeeper never creates a mailbox and never writes into Trash or Junk. Resumable: a claimed
/// item is looked up again first; without a Message-ID its outcome cannot be checked, so it
/// fails with a hint instead of risking a duplicate.
public struct RestoreExecutor: Sendable {
    public let writer: ArchiveWriter
    public let store: ActionStore
    public let audit: AuditLog

    public init(writer: ArchiveWriter, store: ActionStore, audit: AuditLog) {
        self.writer = writer
        self.store = store
        self.audit = audit
    }

    public func run(_ jobID: UUID, connect: @Sendable (String) async throws -> any ServerRestoreActions,
                    progress: @escaping @Sendable (ServerDeleteProgress) -> Void = { _ in }) async throws -> ActionJob {
        var job = try store.load(jobID)
        guard job.kind == .restore, !job.cancelled else { return job }
        var p = ServerDeleteProgress(total: job.open.count)
        progress(p)
        for item in job.open where item.target == nil {
            try finish(&job, item.id, .failed, ArchiveReader.restoreNoOrigin, &p)
        }
        let byAccount = Dictionary(grouping: job.open.filter { $0.target != nil }, by: { $0.target!.account })
        for account in byAccount.keys.sorted() {
            try Task.checkCancellation()
            p.account = account
            progress(p)
            let server = try await connect(account)
            do {
                try await run(items: byAccount[account]!, server: server, job: &job, progress: &p, notify: progress)
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

    private func run(items accountItems: [ActionItem], server: any ServerRestoreActions, job: inout ActionJob,
                     progress p: inout ServerDeleteProgress, notify progress: @Sendable (ServerDeleteProgress) -> Void) async throws {
        let boxes = try await server.mailboxes()
        let gmail = await server.capabilities().gmail
        let byMailbox = Dictionary(grouping: accountItems, by: { $0.target!.mailbox })
        for mailbox in byMailbox.keys.sorted() {
            let items = byMailbox[mailbox]!
            guard let box = boxes.first(where: { $0.name == mailbox }), box.selectable else {
                for item in items {
                    try finish(&job, item.id, .failed, String(localized: "Ordner gibt es auf dem Server nicht – MailKeeper legt keine Ordner an"), &p)
                }
                progress(p)
                continue
            }
            guard box.specialUse.isDisjoint(with: [.trash, .junk]) else {
                for item in items { try finish(&job, item.id, .failed, String(localized: "Ziel ist Papierkorb oder Spam"), &p) }
                progress(p)
                continue
            }
            let validity = try await server.selectForChange(mailbox)
            for item in items {
                try Task.checkCancellation()
                try await restore(item, validity: validity, gmail: gmail, server: server, job: &job, progress: &p)
                progress(p)
            }
        }
    }

    private func restore(_ item: ActionItem, validity: UInt32, gmail: Bool, server: any ServerRestoreActions,
                         job: inout ActionJob, progress p: inout ServerDeleteProgress) async throws {
        let target = item.target!
        // 1. what goes up is the archive copy, and only intact
        guard let data = try? writer.layout.blobs.read(item.sha256) else {
            return try finish(&job, item.id, .failed, String(localized: "Archivkopie fehlt"), &p)
        }
        guard sha256Hex(data) == item.sha256 else {
            return try finish(&job, item.id, .failed, String(localized: "Archivkopie beschädigt"), &p)
        }
        // 2. already there (an earlier run, the user, Gmail's dedupe)? Then nothing goes up twice.
        if let messageID = item.messageID {
            if let found = try await find(messageID, server: server) {
                return try await learn(found, item: item, validity: validity, job: &job, progress: &p,
                                       reason: String(localized: "lag bereits dort"))
            }
        } else if item.state == .claimed {
            return try finish(&job, item.id, .failed,
                              String(localized: "Ausgang unbekannt (Mail ohne Message-ID) – bitte im Ordner nachsehen"), &p)
        }
        // 3. claim, append
        try store.record(job: job.id, item: item.id, state: .claimed)
        let appended: AppendedMessage?
        do {
            appended = try await server.append(data, to: target.mailbox, flags: target.flags, internalDate: target.internalDate)
        } catch let refusal as ServerRefusal {
            return try finish(&job, item.id, .failed, String(localized: "vom Server abgelehnt: \(refusal.message)"), &p)
        }
        var uid = appended.flatMap { $0.uidValidity == validity ? $0.uid : nil }
        var fetched: RemoteMessage?
        if uid == nil, let messageID = item.messageID {
            fetched = try await find(messageID, server: server)
            uid = fetched?.uid
        }
        guard let uid else {
            return try finish(&job, item.id, .done, String(localized: "hochgeladen; der Ort erscheint beim nächsten Abruf"), &p)
        }
        if gmail, !target.labels.isEmpty {
            try await server.addLabels(target.labels, uid: uid)
            fetched = nil  // fetch again: with the labels
        }
        // 4. fetch it back: same bytes, or (Proton rewrites headers) the same Message-ID
        if fetched == nil { fetched = try await server.fetch([uid]).first }
        guard let remote = fetched else {
            return try finish(&job, item.id, .failed, String(localized: "nach dem Hochladen nicht wiedergefunden"), &p)
        }
        let same = sha256Hex(remote.data) == item.sha256
            || (item.messageID != nil && MIMEParser.parse(remote.data).messageID == item.messageID)
        guard same else {
            return try finish(&job, item.id, .failed, String(localized: "Mail auf dem Server stimmt nicht mit dem Archiv überein"), &p)
        }
        try await learn(remote, item: item, validity: validity, job: &job, progress: &p, reason: nil)
    }

    /// The message in the selected mailbox with exactly this Message-ID (SEARCH HEADER matches
    /// substrings, so the hits are fetched and compared).
    private func find(_ messageID: String, server: any ServerRestoreActions) async throws -> RemoteMessage? {
        let uids = try await server.search(messageID: messageID)
        guard !uids.isEmpty else { return nil }
        return try await server.fetch(Array(uids.prefix(20))).first { MIMEParser.parse($0.data).messageID == messageID }
    }

    /// The archive learns the new location (journalled, exactly as a sync would record it).
    private func learn(_ remote: RemoteMessage, item: ActionItem, validity: UInt32, job: inout ActionJob,
                       progress p: inout ServerDeleteProgress, reason: String?) async throws {
        let target = item.target!
        _ = try await writer.ingest(remote.data, at: LocationInfo(account: target.account, mailbox: target.mailbox,
                                                                  uidValidity: validity, uid: remote.uid,
                                                                  providerID: remote.providerID, internalDate: remote.internalDate,
                                                                  flags: remote.flags, labels: remote.labels))
        try finish(&job, item.id, .done, reason, &p)
    }

    private func finish(_ job: inout ActionJob, _ id: Int, _ state: ActionItem.State, _ reason: String?,
                        _ p: inout ServerDeleteProgress) throws {
        try store.record(job: job.id, item: id, state: state, reason: reason)
        job.items[id].state = state
        job.items[id].reason = reason
        try? audit.append(job: job, item: job.items[id])
        switch state {
        case .done: p.done += 1
        case .failed: p.failed += 1
        case .skipped: p.skipped += 1
        default: break
        }
    }
}
