import Foundation

/// Which mailboxes an account syncs.
public struct SyncPolicy: Sendable, Codable, Equatable {
    public enum Mode: String, Sendable, Codable {
        /// Every selectable mailbox except Junk/Trash (and a server-side virtual "All").
        case standard
        /// Gmail: only All Mail (labels arrive as X-GM-LABELS); folders would duplicate it.
        case gmail
        /// Proton Mail Bridge: real folders; "All Mail" and Labels/* would duplicate them.
        case protonBridge
    }

    public var mode: Mode
    /// When set, only these mailboxes (by display name). Required for test runs against
    /// real accounts.
    public var include: [String]?
    public var exclude: [String]
    public var includeJunkAndTrash: Bool
    /// The spam/junk folder too (5.5 Spam-Prüfung), not the trash. With an `include` list the
    /// folder must be on it as well — Proton stays inside its test folder.
    public var includeJunk: Bool

    public init(mode: Mode, include: [String]? = nil, exclude: [String] = [], includeJunkAndTrash: Bool = false, includeJunk: Bool = false) {
        self.mode = mode
        self.include = include
        self.exclude = exclude
        self.includeJunkAndTrash = includeJunkAndTrash
        self.includeJunk = includeJunk
    }

    enum CodingKeys: String, CodingKey { case mode, include, exclude, includeJunkAndTrash, includeJunk }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decode(Mode.self, forKey: .mode)
        include = try c.decodeIfPresent([String].self, forKey: .include)
        exclude = try c.decodeIfPresent([String].self, forKey: .exclude) ?? []
        includeJunkAndTrash = try c.decodeIfPresent(Bool.self, forKey: .includeJunkAndTrash) ?? false
        includeJunk = try c.decodeIfPresent(Bool.self, forKey: .includeJunk) ?? false  // accounts.json before 5.5
    }

    /// What can be told by name alone (include and exclude lists) — the planner's check; the
    /// executor applies `select` to the server's list.
    public func mayContain(_ name: String) -> Bool {
        (include?.contains(name) ?? true) && !exclude.contains(name)
    }

    public func select(_ boxes: [RemoteMailbox]) -> [RemoteMailbox] {
        var chosen = boxes.filter(\.selectable)
        if let include { chosen = chosen.filter { include.contains($0.name) } }
        let wanted = { (b: RemoteMailbox) -> Bool in
            if b.specialUse.contains(.trash) { return includeJunkAndTrash }
            if b.specialUse.contains(.junk) { return includeJunkAndTrash || includeJunk }
            return true
        }
        switch mode {
        case .gmail:
            let extra = { (b: RemoteMailbox) in !b.specialUse.isDisjoint(with: [.junk, .trash]) && wanted(b) }
            chosen = chosen.filter { $0.specialUse.contains(.all) || extra($0) }
        case .protonBridge:
            chosen = chosen.filter { !$0.specialUse.contains(.all) && !$0.name.hasPrefix("Labels/") && wanted($0) }
        case .standard:
            chosen = chosen.filter { !$0.specialUse.contains(.all) && wanted($0) }
        }
        return chosen.filter { !exclude.contains($0.name) }
    }
}

public struct SyncProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case listing, examining, fetching, flags, deletions, done
    }

    public var account: String
    public var phase: Phase = .listing
    public var mailbox: String?
    public var mailboxIndex = 0
    public var mailboxCount = 0
    /// New messages to fetch in the current mailbox, and fetched so far.
    public var toFetch = 0
    public var fetched = 0
    public var newMessages = 0
    public var newLocations = 0
    public var bytes: Int64 = 0
    public var flagChanges = 0
    public var gone = 0

    public init(account: String) {
        self.account = account
    }
}

public struct SyncReport: Sendable, Equatable {
    public var mailboxes = 0
    public var fetched = 0
    public var newMessages = 0
    public var newLocations = 0
    public var bytes: Int64 = 0
    public var flagChanges = 0
    public var gone = 0
    /// Locations gone earlier that the server lists again.
    public var back = 0
    /// Messages deleted from the archive for good earlier: not fetched into it again.
    public var deletedBefore = 0
    /// Mailboxes that failed, with the error; the others were synced.
    public var failures: [String] = []

    public init() {}
}

/// Pulls mail from a source into the archive, read-only and incremental:
/// 1. new messages above the highest known UID, in size-bounded batches (resumable: an
///    interrupted run continues where it stopped);
/// 2. flags/labels of known messages (CONDSTORE: only changes);
/// 3. messages gone from the server → `on_server = 0` (they stay in the archive).
/// A changed UIDVALIDITY retires all locations of the old one.
public struct SyncEngine: Sendable {
    public let writer: ArchiveWriter
    public let account: AccountInfo
    public let policy: SyncPolicy
    public var batchBytes = 16 << 20
    public var batchCount = 100

    public init(writer: ArchiveWriter, account: AccountInfo, policy: SyncPolicy) {
        self.writer = writer
        self.account = account
        self.policy = policy
    }

    public func run(source: some MailboxSource, progress: @escaping @Sendable (SyncProgress) -> Void = { _ in }) async throws -> SyncReport {
        try await writer.register(account)
        var p = SyncProgress(account: account.id)
        progress(p)
        let listed = try await source.mailboxes()
        let plan = policy.select(listed)
        try await writer.setMailboxRoles(account: account.id, listed)  // \Junk, \Sent … for is:junk / is:sent
        let caps = await source.capabilities()
        var report = SyncReport()
        // Mailboxes that vanished from the server (renamed or deleted folder, Gmail language
        // switch): their locations are gone. Only when LIST looks sane.
        if listed.contains(where: \.selectable) {
            let names = Set(listed.map(\.name))
            for vanished in try await writer.activeMailboxes(account: account.id) where !names.contains(vanished) {
                for validity in try await writer.mailboxState(account: account.id, mailbox: vanished).validities {
                    let n = try await writer.markGone(account: account.id, mailbox: vanished, uidValidity: validity, uids: nil)
                    report.gone += n
                    p.gone += n
                }
            }
        }
        report.mailboxes = plan.count
        p.mailboxCount = plan.count
        for (i, box) in plan.enumerated() {
            try Task.checkCancellation()
            p.mailbox = box.name
            p.mailboxIndex = i
            p.toFetch = 0
            p.fetched = 0
            p.phase = .examining
            progress(p)
            do {
                try await sync(box, source: source, caps: caps, progress: &p, report: &report, notify: progress)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                report.failures.append("\(box.name): \(error)")
            }
        }
        p.phase = .done
        p.mailbox = nil
        progress(p)
        return report
    }

    private func sync(_ box: RemoteMailbox, source: some MailboxSource, caps: SourceCapabilities,
                      progress p: inout SyncProgress, report: inout SyncReport,
                      notify: @Sendable (SyncProgress) -> Void) async throws {
        let id = account.id
        let status = try await source.examine(box)
        let validity = status.uidValidity
        let state = try await writer.mailboxState(account: id, mailbox: box.name)

        // UIDVALIDITY changed: every location of the old validity is gone; messages that still
        // exist come back under their new UIDs (identical bytes: no new blobs).
        for old in state.validities where old != validity {
            let n = try await writer.markGone(account: id, mailbox: box.name, uidValidity: old, uids: nil)
            report.gone += n
            p.gone += n
        }

        // 1. new messages
        let known = try await writer.knownUIDs(account: id, mailbox: box.name, uidValidity: validity)
        let maxKnown = known.max() ?? 0
        // "UID n:*" returns the last message even when n > max UID — filter.
        let candidates = try await source.messageSizes(fromUID: maxKnown == .max ? maxKnown : maxKnown + 1)
            .filter { $0.uid > maxKnown && !known.contains($0.uid) }
            .sorted { $0.uid < $1.uid }
        p.phase = .fetching
        p.toFetch = candidates.count
        notify(p)
        var batch: [UInt32] = []
        var batchSize = 0
        func flush() async throws {
            guard !batch.isEmpty else { return }
            let wanted = Set(batch)
            let messages = try await source.fetch(batch).filter { wanted.contains($0.uid) }
            let items = messages.map { m in
                (data: m.data, location: LocationInfo(account: id, mailbox: box.name, uidValidity: validity, uid: m.uid,
                                                      providerID: m.providerID, internalDate: m.internalDate,
                                                      flags: m.flags, labels: m.labels))
            }
            let results = try await writer.ingest(items)
            for r in results {
                switch r {
                case .newMessage: report.newMessages += 1; p.newMessages += 1
                case .newLocation: report.newLocations += 1; p.newLocations += 1
                case .unchanged: break
                case .tombstoned: report.deletedBefore += 1
                }
            }
            let bytes = Int64(messages.reduce(0) { $0 + $1.data.count })
            report.fetched += messages.count
            report.bytes += bytes
            p.fetched += batch.count
            p.bytes += bytes
            notify(p)
            batch.removeAll(keepingCapacity: true)
            batchSize = 0
        }
        for c in candidates {
            try Task.checkCancellation()
            if !batch.isEmpty, batchSize + c.size > batchBytes || batch.count >= batchCount { try await flush() }
            batch.append(c.uid)
            batchSize += c.size
        }
        try await flush()

        guard !known.isEmpty else {
            if let m = status.highestModSeq { try await writer.setSyncState(account: id, mailbox: box.name, uidValidity: validity, highestModSeq: m) }
            return
        }

        // 2. flags and labels of known messages
        p.phase = .flags
        notify(p)
        let since = caps.condstore && state.modSeqValidity == validity ? state.highestModSeq : nil
        let updates = try await source.flags(changedSince: since).filter { known.contains($0.uid) }
        let changed = try await writer.updateFlags(account: id, mailbox: box.name, uidValidity: validity, updates)
        report.flagChanges += changed
        p.flagChanges += changed

        // 3. messages gone from the server
        p.phase = .deletions
        notify(p)
        let present = Set(try await source.allUIDs())
        // An empty answer for a non-empty mailbox is a glitch, not a mass deletion.
        if !(present.isEmpty && status.exists > 0) {
            let onServer = try await writer.onServerUIDs(account: id, mailbox: box.name, uidValidity: validity)
            let gone = onServer.subtracting(present)
            if !gone.isEmpty {
                let n = try await writer.markGone(account: id, mailbox: box.name, uidValidity: validity, uids: gone)
                report.gone += n
                p.gone += n
            }
            // ... and known messages marked gone that are listed again (review 4.7)
            report.back += try await writer.markPresent(account: id, mailbox: box.name, uidValidity: validity,
                                                        uids: present.intersection(known).subtracting(onServer))
        }
        if let m = status.highestModSeq {
            try await writer.setSyncState(account: id, mailbox: box.name, uidValidity: validity, highestModSeq: m)
        }
    }
}
