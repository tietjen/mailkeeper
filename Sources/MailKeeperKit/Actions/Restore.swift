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

/// The server said no to one message: that item fails, the job goes on. When the refusal came
/// before the message was sent, swift-nio-imap drops the connection (`connectionClosed`), and the
/// executor reconnects for the rest.
public struct ServerRefusal: Error, Sendable, CustomStringConvertible {
    public var message: String
    public var connectionClosed: Bool

    public init(_ message: String, connectionClosed: Bool = false) {
        self.message = message
        self.connectionClosed = connectionClosed
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
    /// Gmail: adds labels to a message appended on this connection. `ServerRefusal` on NO.
    func addLabels(_ labels: [String], uid: UInt32) async throws
    /// Sets or clears system flags on a message appended on this connection (a server that
    /// changed them on the way in — Proton marks uploads as read). `ServerRefusal` on NO.
    func correctFlags(add: [String], remove: [String], uid: UInt32) async throws
    /// Full messages without setting \Seen.
    func fetch(_ uids: [UInt32]) async throws -> [RemoteMessage]
    func close() async
}

/// Runs a planned restore job (ADR-0006 §5): per account and mailbox, one message at a time —
/// verify the archive copy, look for it in the target (same Message-ID, sender and subject:
/// nothing lands twice, a re-run is harmless), mark claimed, APPEND with flags and date, add the
/// Gmail labels that still exist, fetch it back and compare (same bytes; Proton rewrites headers,
/// so there the same Message-ID), put back flags the server changed, then record the new
/// location in the archive (journalled, like a sync) and in the audit log.
/// The target is checked again against the account's current sync selection: MailKeeper only
/// writes where it also looks — whatever the queue file says. It never creates a mailbox or a
/// label and never writes into Trash or Junk. Resumable: a claimed item is looked up again
/// first; without a Message-ID its outcome cannot be checked, so it fails with a hint instead
/// of risking a duplicate.
public struct RestoreExecutor: Sendable {
    public let writer: ArchiveWriter
    public let store: ActionStore
    public let audit: AuditLog

    public init(writer: ArchiveWriter, store: ActionStore, audit: AuditLog) {
        self.writer = writer
        self.store = store
        self.audit = audit
    }

    public func run(_ jobID: UUID, accounts: [AccountConfig], connect: @Sendable (String) async throws -> any ServerRestoreActions,
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
            guard let config = accounts.first(where: { $0.id == account }) else {
                for item in byAccount[account]! { try finish(&job, item.id, .failed, String(localized: "Konto ist hier nicht eingerichtet"), &p) }
                continue
            }
            p.account = account
            progress(p)
            var server = try await connect(account)
            do {
                try await run(items: byAccount[account]!, policy: config.policy, server: &server,
                              reconnect: { try await connect(account) }, job: &job, progress: &p, notify: progress)
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

    private func run(items accountItems: [ActionItem], policy: SyncPolicy, server: inout any ServerRestoreActions,
                     reconnect: () async throws -> any ServerRestoreActions, job: inout ActionJob,
                     progress p: inout ServerDeleteProgress, notify progress: @Sendable (ServerDeleteProgress) -> Void) async throws {
        var boxes = try await server.mailboxes()
        let gmail = await server.capabilities().gmail
        let synced = Set(policy.select(boxes).map(\.name))
        let roles = boxes.contains { !$0.specialUse.isDisjoint(with: [.trash, .junk]) }
        var refusedInARow = 0
        let byMailbox = Dictionary(grouping: accountItems, by: { $0.target!.mailbox })
        for mailbox in byMailbox.keys.sorted() {
            let items = byMailbox[mailbox]!
            let refusal: String? = if let box = boxes.first(where: { $0.name == mailbox }), box.selectable {
                !box.specialUse.isDisjoint(with: [.trash, .junk]) || (!roles && RemoteMailbox.looksLikeTrashOrJunk(mailbox))
                    ? String(localized: "Ziel ist Papierkorb oder Spam")
                    : !synced.contains(mailbox) ? ArchiveReader.restoreNotSynced : nil
            } else {
                String(localized: "Ordner gibt es auf dem Server nicht – MailKeeper legt keine Ordner an")
            }
            if let refusal {
                for item in items { try finish(&job, item.id, .failed, refusal, &p) }
                progress(p)
                continue
            }
            var validity: UInt32
            do {
                validity = try await server.selectForChange(mailbox)
            } catch let refusal as ServerRefusal {
                for item in items { try finish(&job, item.id, .failed, String(localized: "vom Server abgelehnt: \(refusal.message)"), &p) }
                progress(p)
                continue
            }
            for item in items {
                try Task.checkCancellation()
                if refusedInARow >= Self.maxRefusalsInARow {  // a full mailbox refuses everything: no login storm
                    try finish(&job, item.id, .failed, String(localized: "nicht versucht: der Server lehnt jedes Hochladen ab (Postfach voll?)"), &p)
                    continue
                }
                let lost = try await restore(item, validity: validity, gmail: gmail, boxes: boxes, server: server, job: &job, progress: &p)
                progress(p)
                refusedInARow = lost ? refusedInARow + 1 : 0
                if lost, refusedInARow < Self.maxRefusalsInARow {  // refused before the bytes went out: the connection is gone
                    await server.close()
                    server = try await reconnect()
                    boxes = try await server.mailboxes()
                    validity = try await server.selectForChange(mailbox)
                }
            }
        }
    }

    static let maxRefusalsInARow = 3

    /// One message. Returns true when the connection was lost to a refusal and must be renewed.
    private func restore(_ item: ActionItem, validity: UInt32, gmail: Bool, boxes: [RemoteMailbox], server: any ServerRestoreActions,
                         job: inout ActionJob, progress p: inout ServerDeleteProgress) async throws -> Bool {
        let target = item.target!
        // 1. what goes up is the archive copy, and only intact
        guard let data = try? writer.layout.blobs.read(item.sha256) else {
            try finish(&job, item.id, .failed, String(localized: "Archivkopie fehlt"), &p)
            return false
        }
        guard sha256Hex(data) == item.sha256 else {
            try finish(&job, item.id, .failed, String(localized: "Archivkopie beschädigt"), &p)
            return false
        }
        let original = MIMEParser.parse(data)
        // 2. already there (an earlier run, the user, Gmail's dedupe)? Then nothing goes up twice.
        if let messageID = item.messageID {
            if let found = try await find(messageID, like: original, server: server) {
                try await learn(found, item: item, validity: validity, job: &job, progress: &p, notes: [String(localized: "lag bereits dort")])
                return false
            }
        } else if item.state == .claimed {
            try finish(&job, item.id, .failed, String(localized: "Ausgang unbekannt (Mail ohne Message-ID) – bitte im Ordner nachsehen"), &p)
            return false
        }
        // 3. claim, append
        try store.record(job: job.id, item: item.id, state: .claimed)
        let appended: AppendedMessage?
        do {
            appended = try await server.append(data, to: target.mailbox, flags: target.flags, internalDate: target.internalDate)
        } catch let refusal as ServerRefusal {
            try finish(&job, item.id, .failed, String(localized: "vom Server abgelehnt: \(refusal.message)"), &p)
            return refusal.connectionClosed
        }
        var uid = appended.flatMap { $0.uidValidity == validity ? $0.uid : nil }
        // Labels and flags may only touch this upload, known by its APPENDUID; found by search
        // instead (no UIDPLUS), it is left as the server stored it.
        let own = uid != nil
        var fetched: RemoteMessage?
        if uid == nil, let messageID = item.messageID {
            fetched = try await find(messageID, like: original, server: server)
            uid = fetched?.uid
        }
        guard let uid else {
            try finish(&job, item.id, .done, String(localized: "hochgeladen; der Ort erscheint beim nächsten Abruf"), &p)
            return false
        }
        var notes: [String] = []
        // 4. Gmail labels — only those that still exist (Gmail would create the others)
        if !own, gmail, !target.labels.isEmpty {
            notes.append(String(localized: "Labels nicht gesetzt: der Server meldet keine UID (kein UIDPLUS)"))
        } else if gmail, !target.labels.isEmpty {
            let names = Set(boxes.map(\.name))
            let (existing, missing) = target.labels.partitioned { $0.hasPrefix("\\") || names.contains($0) }
            if !missing.isEmpty { notes.append(String(localized: "Labels gibt es nicht mehr: \(missing.joined(separator: ", "))")) }
            if !existing.isEmpty {
                do {
                    try await server.addLabels(existing, uid: uid)
                    fetched = nil  // fetch again: with the labels
                } catch let refusal as ServerRefusal {
                    notes.append(String(localized: "Labels abgelehnt: \(refusal.message)"))
                }
            }
        }
        // 5. fetch it back: same bytes, or (Proton rewrites headers) the same Message-ID
        if fetched == nil { fetched = try await server.fetch([uid]).first }
        guard var remote = fetched else {
            try finish(&job, item.id, .failed, String(localized: "nach dem Hochladen nicht wiedergefunden"), &p)
            return false
        }
        let same = sha256Hex(remote.data) == item.sha256 || (item.messageID != nil && Self.same(original, MIMEParser.parse(remote.data)))
        guard same else {
            try finish(&job, item.id, .failed, String(localized: "Mail auf dem Server stimmt nicht mit dem Archiv überein"), &p)
            return false
        }
        // 6. flags the server changed on the way in (Proton marks uploads as read) go back
        let wanted = Set(target.flags), have = Set(RestoreTarget.restorableFlags(remote.flags))
        let add = wanted.subtracting(have).sorted(), remove = have.subtracting(wanted).sorted()
        if !own, !add.isEmpty || !remove.isEmpty {
            notes.append(String(localized: "Status weicht ab und bleibt so: der Server meldet keine UID (kein UIDPLUS)"))
        } else if !add.isEmpty || !remove.isEmpty {
            do {
                try await server.correctFlags(add: add, remove: remove, uid: uid)
                remote.flags = remote.flags.filter { f in !remove.contains { $0.caseInsensitiveCompare(f) == .orderedSame } } + add
            } catch let refusal as ServerRefusal {
                notes.append(String(localized: "Status nicht übernommen: \(refusal.message)"))
            }
        }
        try await learn(remote, item: item, validity: validity, job: &job, progress: &p, notes: notes)
        return false
    }

    /// Same Message-ID, and — like the archive's own identity rule — same sender and subject:
    /// a reused Message-ID must not pass for the message.
    static func same(_ a: ParsedMessage, _ b: ParsedMessage) -> Bool {
        a.messageID == b.messageID && ArchiveWriter.sameMessage(from: a.from.first?.address, subject: a.subject, as: b)
    }

    /// The message in the selected mailbox that is this one (SEARCH HEADER matches substrings,
    /// so the hits are fetched and compared).
    private func find(_ messageID: String, like original: ParsedMessage, server: any ServerRestoreActions) async throws -> RemoteMessage? {
        let uids = try await server.search(messageID: messageID)
        guard !uids.isEmpty else { return nil }
        return try await server.fetch(Array(uids.prefix(20))).first { Self.same(original, MIMEParser.parse($0.data)) }
    }

    /// The archive learns the new location (journalled, exactly as a sync would record it).
    private func learn(_ remote: RemoteMessage, item: ActionItem, validity: UInt32, job: inout ActionJob,
                       progress p: inout ServerDeleteProgress, notes: [String]) async throws {
        let target = item.target!
        _ = try await writer.ingest(remote.data, at: LocationInfo(account: target.account, mailbox: target.mailbox,
                                                                  uidValidity: validity, uid: remote.uid,
                                                                  providerID: remote.providerID, internalDate: remote.internalDate,
                                                                  flags: remote.flags, labels: remote.labels))
        try finish(&job, item.id, .done, notes.isEmpty ? nil : notes.joined(separator: "; "), &p,
                   at: ServerLocation(account: target.account, mailbox: target.mailbox, uidValidity: validity, uid: remote.uid))
    }

    private func finish(_ job: inout ActionJob, _ id: Int, _ state: ActionItem.State, _ reason: String?,
                        _ p: inout ServerDeleteProgress, at location: ServerLocation? = nil) throws {
        try store.record(job: job.id, item: id, state: state, reason: reason)
        job.items[id].state = state
        job.items[id].reason = reason
        try? audit.append(job: job, item: job.items[id], at: location)
        switch state {
        case .done: p.done += 1
        case .failed: p.failed += 1
        case .skipped: p.skipped += 1
        default: break
        }
    }
}
