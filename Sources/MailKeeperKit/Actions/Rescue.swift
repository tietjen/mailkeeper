import Foundation

/// The server side of "Kein Spam → Posteingang" (5.5) — IMAP with the narrow `.rescueFromJunk`
/// access in the app, a fake in tests.
public protocol ServerRescueActions: Sendable {
    func mailboxes() async throws -> [RemoteMailbox]
    /// Opens a mailbox for changes; returns its UIDVALIDITY. `ServerRefusal` on NO.
    func selectForChange(_ mailbox: String) async throws -> UInt32
    func identities(_ uids: [UInt32]) async throws -> [UInt32: RemoteIdentity]
    func bodies(_ uids: [UInt32]) async throws -> [UInt32: Data]
    /// Moves UIDs of the selected spam mailbox to INBOX — nothing else. `ServerRefusal` on NO.
    func moveToInbox(_ uids: [UInt32]) async throws
    func present(_ uids: [UInt32]) async throws -> Set<UInt32>
    func search(messageID: String) async throws -> [UInt32]
    func fetch(_ uids: [UInt32]) async throws -> [RemoteMessage]
    func close() async
}

/// Runs a "Kein Spam" job (ADR-0006, 5.5): per account and spam mailbox — the mailbox must be
/// the server's \Junk (or, on a server without roles, carry a spam name), verify UIDVALIDITY and
/// that each UID is still the same message, claim, move to INBOX, check it left the spam
/// folder, find it in INBOX (Message-ID, sender, subject) and record that location like a sync,
/// mark the spam location gone, and note the user's decision ("Kein Spam", journalled).
public struct RescueExecutor: Sendable {
    public let writer: ArchiveWriter
    public let store: ActionStore
    public let audit: AuditLog

    public init(writer: ArchiveWriter, store: ActionStore, audit: AuditLog) {
        self.writer = writer
        self.store = store
        self.audit = audit
    }

    public func run(_ jobID: UUID, accounts: [AccountConfig], connect: @Sendable (String) async throws -> any ServerRescueActions,
                    progress: @escaping @Sendable (ServerDeleteProgress) -> Void = { _ in }) async throws -> ActionJob {
        var job = try store.load(jobID)
        guard job.kind == .moveToInbox, !job.cancelled else { return job }
        var p = ServerDeleteProgress(total: job.open.count)
        progress(p)
        let byAccount = Dictionary(grouping: job.open.filter { $0.location != nil }, by: { $0.location!.account })
        for account in byAccount.keys.sorted() {
            try Task.checkCancellation()
            guard let config = accounts.first(where: { $0.id == account }) else {
                for item in byAccount[account]! { try finish(&job, item.id, .failed, String(localized: "Konto ist hier nicht eingerichtet"), &p) }
                continue
            }
            p.account = account
            progress(p)
            let server = try await connect(account)
            do {
                try await run(items: byAccount[account]!, policy: config.policy, server: server, job: &job, progress: &p, notify: progress)
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

    private func run(items accountItems: [ActionItem], policy: SyncPolicy, server: any ServerRescueActions, job: inout ActionJob,
                     progress p: inout ServerDeleteProgress, notify progress: @Sendable (ServerDeleteProgress) -> Void) async throws {
        let boxes = try await server.mailboxes()
        // the INBOX location is recorded only where the account also syncs INBOX — otherwise no
        // sync would ever see it go (Gmail syncs All Mail; include lists)
        let inboxSynced = policy.select(boxes).contains { $0.name.uppercased() == "INBOX" }
        let roles = boxes.contains { $0.specialUse.contains(.junk) }
        guard let inbox = boxes.first(where: { $0.name.uppercased() == "INBOX" }) else {
            for item in accountItems { try finish(&job, item.id, .failed, String(localized: "Kein Posteingang (INBOX) auf dem Server"), &p) }
            return
        }
        let byMailbox = Dictionary(grouping: accountItems, by: { $0.location!.mailbox })
        for mailbox in byMailbox.keys.sorted() {
            let items = byMailbox[mailbox]!
            let box = boxes.first { $0.name == mailbox }
            let isJunk = box.map { $0.specialUse.contains(.junk) || (!roles && RemoteMailbox.looksLikeJunk($0.name)) } ?? false
            guard isJunk else {
                for item in items {
                    try finish(&job, item.id, .failed, box == nil ? String(localized: "Ordner gibt es auf dem Server nicht mehr")
                                                                  : String(localized: "Ordner ist auf dem Server kein Spam-Ordner"), &p)
                }
                progress(p)
                continue
            }
            let validity: UInt32
            do { validity = try await server.selectForChange(mailbox) } catch let refusal as ServerRefusal {
                for item in items { try finish(&job, item.id, .failed, String(localized: "vom Server abgelehnt: \(refusal.message)"), &p) }
                progress(p)
                continue
            }
            let (current, stale) = items.partitioned { $0.location!.uidValidity == validity }
            for item in stale {
                try finish(&job, item.id, .failed, String(localized: "Ordner wurde auf dem Server neu nummeriert (UIDVALIDITY) – erst neu abrufen"), &p)
            }
            guard !current.isEmpty else { continue }
            // still the same message under each UID?
            let uids = current.map { $0.location!.uid }
            let remote = try await server.identities(uids)
            let needBodies = current.filter { $0.messageID == nil && remote[$0.location!.uid] != nil }.map { $0.location!.uid }
            let bodies = needBodies.isEmpty ? [:] : try await server.bodies(needBodies)
            var go: [ActionItem] = []
            var gone: Set<UInt32> = []
            var resumed: [ActionItem] = []  // claimed before a crash and no longer in the spam folder
            for item in current {
                let uid = item.location!.uid
                guard let r = remote[uid] else {
                    gone.insert(uid)
                    if item.state == .claimed {
                        resumed.append(item)  // probably moved already: looked for in INBOX below
                    } else {
                        try finish(&job, item.id, .failed, String(localized: "liegt nicht mehr im Spam-Ordner – erst neu abrufen"), &p)
                    }
                    continue
                }
                let same = item.messageID.map { r.messageID == $0 && (r.size == nil || r.size == item.size) }
                    ?? (bodies[uid].map { sha256Hex($0) == item.sha256 } ?? false)
                if same { go.append(item) } else {
                    try finish(&job, item.id, .failed, String(localized: "Mail auf dem Server stimmt nicht mit dem Archiv überein"), &p)
                }
            }
            guard !go.isEmpty || !resumed.isEmpty else { continue }
            for item in go { try store.record(job: job.id, item: item.id, state: .claimed) }
            var refusal: String?
            if !go.isEmpty {
                do { try await server.moveToInbox(go.map { $0.location!.uid }) } catch let r as ServerRefusal { refusal = r.message }
            }
            let stillThere = go.isEmpty ? [] : try await server.present(go.map { $0.location!.uid })
            let moved = go.filter { !stillThere.contains($0.location!.uid) }
            for item in go where stillThere.contains(item.location!.uid) {
                try finish(&job, item.id, .failed, refusal.map { String(localized: "vom Server abgelehnt: \($0)") }
                           ?? String(localized: "nach dem Verschieben noch im Spam-Ordner"), &p)
            }
            gone.formUnion(moved.map { $0.location!.uid })
            if !gone.isEmpty {
                _ = try await writer.markGone(account: moved.first?.location?.account ?? items[0].location!.account, mailbox: mailbox,
                                              uidValidity: validity, uids: gone)
            }
            guard !moved.isEmpty || !resumed.isEmpty else { continue }
            // The server's state is final now: whatever fails from here, a moved mail is done.
            var inboxValidity: UInt32?
            do { inboxValidity = try await server.selectForChange(inbox.name) } catch is ServerRefusal {}
            for item in moved + resumed {
                let wasResumed = resumed.contains(item)
                var found: RemoteMessage?
                if inboxValidity != nil, let messageID = item.messageID {
                    found = try? await find(messageID, sha: item.sha256, server: server)
                }
                if wasResumed, found == nil {
                    try finish(&job, item.id, .failed, item.messageID == nil
                               ? String(localized: "Ausgang unbekannt (Mail ohne Message-ID) – bitte im Posteingang nachsehen")
                               : String(localized: "liegt weder im Spam-Ordner noch im Posteingang – erst neu abrufen"), &p)
                    continue
                }
                var note: String?
                var at: ServerLocation?
                if let found, let validity = inboxValidity, inboxSynced {
                    _ = try await writer.ingest(found.data, at: LocationInfo(account: item.location!.account, mailbox: inbox.name,
                                                                             uidValidity: validity, uid: found.uid,
                                                                             providerID: found.providerID, internalDate: found.internalDate,
                                                                             flags: found.flags, labels: found.labels))
                    at = ServerLocation(account: item.location!.account, mailbox: inbox.name, uidValidity: validity, uid: found.uid)
                } else if found != nil {
                    note = String(localized: "im Posteingang; diesen Ordner ruft MailKeeper für das Konto nicht ab")
                } else {
                    note = String(localized: "im Posteingang; der Ort erscheint beim nächsten Abruf")
                }
                if let identity = item.identity { try await writer.confirmNotSpam(identity: identity) }
                try finish(&job, item.id, .done, note, &p, at: at)
            }
            progress(p)
        }
    }

    /// The moved message in INBOX: the same bytes, or the same Message-ID with the same sender
    /// and subject (the archive's identity rule — a reused Message-ID is not the message).
    private func find(_ messageID: String, sha: String, server: any ServerRescueActions) async throws -> RemoteMessage? {
        let uids = try await server.search(messageID: messageID)
        guard !uids.isEmpty else { return nil }
        let candidates = try await server.fetch(Array(uids.suffix(20)))
        if let exact = candidates.first(where: { sha256Hex($0.data) == sha }) { return exact }
        guard let data = try? writer.layout.blobs.read(sha) else { return nil }
        let original = MIMEParser.parse(data)
        return candidates.first { c in
            let p = MIMEParser.parse(c.data)
            return p.messageID == messageID && ArchiveWriter.sameMessage(from: original.from.first?.address, subject: original.subject, as: p)
        }
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
