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
    /// The spam mailbox (6.4): the server's \Junk, or by name on a server without roles; nil if none.
    func junkMailbox() async throws -> String?
    /// Moves UIDs of the selected ordinary mailbox into the spam mailbox. `ServerRefusal` on NO.
    func moveToJunk(_ uids: [UInt32]) async throws
    func present(_ uids: [UInt32]) async throws -> Set<UInt32>
    func search(messageID: String) async throws -> [UInt32]
    func fetch(_ uids: [UInt32]) async throws -> [RemoteMessage]
    func close() async
}

/// Runs a "Kein Spam" job (ADR-0006 §8, 5.5) or an "Ist Spam" job (§9, 6.4): per account and
/// source mailbox — for "Kein Spam" the server's \Junk (or, without roles, a spam name), for "Ist
/// Spam" an ordinary mailbox (no spam, trash, sent or drafts) — verify UIDVALIDITY and that each
/// UID is still the same message, claim, move (to INBOX, or to the spam mailbox), check it left,
/// find it at the target (Message-ID, sender, subject) and record that location like a sync
/// where the account fetches that mailbox, mark the old location gone, and note the user's
/// decision (journalled: "Kein Spam" / "Ist Spam").
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
        guard job.kind == .moveToInbox || job.kind == .moveToJunk, !job.cancelled else { return job }
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
        let toJunk = job.kind == .moveToJunk
        let boxes = try await server.mailboxes()
        let roles = boxes.contains { $0.specialUse.contains(.junk) }
        let anyRoles = boxes.contains { !$0.specialUse.isDisjoint(with: [.junk, .trash, .sent, .drafts]) }
        // the target: INBOX, or the spam mailbox
        let targetName: String?
        if toJunk {
            do { targetName = try await server.junkMailbox() } catch let refusal as ServerRefusal {
                for item in accountItems { try finish(&job, item.id, .failed, String(localized: "vom Server abgelehnt: \(refusal.message)"), &p) }
                return
            }
        } else {
            targetName = boxes.first(where: { $0.name.uppercased() == "INBOX" })?.name
        }
        guard let target = targetName else {
            for item in accountItems {
                try finish(&job, item.id, .failed, toJunk ? String(localized: "Kein Spam-Ordner auf dem Server") : String(localized: "Kein Posteingang (INBOX) auf dem Server"), &p)
            }
            return
        }
        // the target location is recorded only where the account also fetches that mailbox —
        // otherwise no sync would ever see it go (Gmail syncs All Mail; include lists; spam off)
        let targetSynced = policy.select(boxes).contains { $0.name == target }
        let byMailbox = Dictionary(grouping: accountItems, by: { $0.location!.mailbox })
        for mailbox in byMailbox.keys.sorted() {
            let items = byMailbox[mailbox]!
            let box = boxes.first { $0.name == mailbox }
            let isJunk = box.map { $0.specialUse.contains(.junk) || (!roles && RemoteMailbox.looksLikeJunk($0.name)) } ?? false
            let mayMarkJunk = box.map { b in
                b.name != target && b.specialUse.isDisjoint(with: [.junk, .trash, .sent, .drafts])
                    && (anyRoles || (!RemoteMailbox.looksLikeTrashOrJunk(b.name) && !RemoteMailbox.looksLikeSentOrDrafts(b.name)))
            } ?? false
            guard toJunk ? mayMarkJunk : isJunk else {
                for item in items {
                    try finish(&job, item.id, .failed, box == nil ? String(localized: "Ordner gibt es auf dem Server nicht mehr")
                               : toJunk ? String(localized: "aus diesem Ordner verschiebt MailKeeper nichts in den Spam-Ordner")
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
                        resumed.append(item)  // probably moved already: looked for at the target below
                    } else {
                        try finish(&job, item.id, .failed, toJunk ? String(localized: "liegt nicht mehr in diesem Ordner – erst neu abrufen")
                                   : String(localized: "liegt nicht mehr im Spam-Ordner – erst neu abrufen"), &p)
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
                do {
                    if toJunk { try await server.moveToJunk(go.map { $0.location!.uid }) } else { try await server.moveToInbox(go.map { $0.location!.uid }) }
                } catch let r as ServerRefusal { refusal = r.message }
            }
            let stillThere = go.isEmpty ? [] : try await server.present(go.map { $0.location!.uid })
            let moved = go.filter { !stillThere.contains($0.location!.uid) }
            for item in go where stillThere.contains(item.location!.uid) {
                try finish(&job, item.id, .failed, refusal.map { String(localized: "vom Server abgelehnt: \($0)") }
                           ?? String(localized: "nach dem Verschieben noch im alten Ordner"), &p)
            }
            gone.formUnion(moved.map { $0.location!.uid })
            if !gone.isEmpty {
                _ = try await writer.markGone(account: moved.first?.location?.account ?? items[0].location!.account, mailbox: mailbox,
                                              uidValidity: validity, uids: gone)
            }
            guard !moved.isEmpty || !resumed.isEmpty else { continue }
            // The server's state is final now: whatever fails from here, a moved mail is done.
            let place = toJunk ? String(localized: "im Spam-Ordner") : String(localized: "im Posteingang")
            var targetValidity: UInt32?
            do { targetValidity = try await server.selectForChange(target) } catch is ServerRefusal {}
            for item in moved + resumed {
                let wasResumed = resumed.contains(item)
                var found: RemoteMessage?
                if targetValidity != nil, let messageID = item.messageID {
                    found = try? await find(messageID, sha: item.sha256, server: server)
                }
                if wasResumed, found == nil {
                    try finish(&job, item.id, .failed, item.messageID == nil
                               ? String(localized: "Ausgang unbekannt (Mail ohne Message-ID) – bitte \(place) nachsehen")
                               : String(localized: "liegt weder im alten Ordner noch \(place) – erst neu abrufen"), &p)
                    continue
                }
                var note: String?
                var at: ServerLocation?
                if let found, let validity = targetValidity, targetSynced {
                    _ = try await writer.ingest(found.data, at: LocationInfo(account: item.location!.account, mailbox: target,
                                                                             uidValidity: validity, uid: found.uid,
                                                                             providerID: found.providerID, internalDate: found.internalDate,
                                                                             flags: found.flags, labels: found.labels))
                    at = ServerLocation(account: item.location!.account, mailbox: target, uidValidity: validity, uid: found.uid)
                } else if found != nil {
                    note = toJunk ? String(localized: "im Spam-Ordner; den ruft MailKeeper für das Konto nicht ab (Spam prüfen ist aus)")
                                  : String(localized: "im Posteingang; diesen Ordner ruft MailKeeper für das Konto nicht ab")
                } else {
                    note = String(localized: "\(place); der Ort erscheint beim nächsten Abruf")
                }
                if let identity = item.identity {
                    if toJunk { try await writer.setUserClassification(identity: identity, category: .spam) } else { try await writer.confirmNotSpam(identity: identity) }
                }
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
