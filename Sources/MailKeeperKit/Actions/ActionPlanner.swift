import Foundation

/// Totals a plan sheet shows before anything runs.
public struct ActionPlanSummary: Sendable, Equatable {
    /// Messages the filter selected.
    public var messages: Int
    /// Of those, messages without a server location MailKeeper knows (nothing to delete there).
    public var archiveOnly: Int
    /// Items that will run, per account.
    public var perAccount: [String: Int]

    public init(messages: Int, archiveOnly: Int, perAccount: [String: Int]) {
        self.messages = messages
        self.archiveOnly = archiveOnly
        self.perAccount = perAccount
    }
}

extension ArchiveReader {
    /// Skip reason of an archive delete for a message still on a server.
    public static let stillOnServer = String(localized: "liegt noch auf einem Server – erst dort löschen")

    /// Skip reason of a server delete inside the grace period. It counts from the arrival on the
    /// server (INTERNALDATE), not from the Date header: a 2019 mail appended yesterday is new
    /// there (TJ wondered why "Bulk 2500" from 14.3.2019 was "younger than 30 days").
    public static func graceReason(_ days: Int) -> String {
        days == 1 ? String(localized: "erst seit weniger als 1 Tag auf dem Server (Schonfrist)")
                  : String(localized: "erst seit weniger als \(days) Tagen auf dem Server (Schonfrist)")
    }

    /// Plans "delete on the server" for the messages of `filter` (ADR-0006 §2): one item per
    /// server location (fetched over IMAP, still present at the last fetch). Items whose
    /// preconditions fail are planned as skipped, with the reason:
    /// - the account is not set up here (no connection to act with);
    /// - the date is unknown, or the message arrived on the server within the grace period
    ///   (default 30 days; INTERNALDATE, the Date header only where no arrival is known);
    /// - the message is flagged on the server.
    /// The blob is verified and the Message-ID re-checked on the server when the item runs.
    public func planServerDelete(_ filter: MessageFilter, title: String, accounts: [AccountConfig],
                                 graceDays: Int = 30, now: Date = Date()) throws -> (ActionJob, ActionPlanSummary) {
        let (whereClause, params) = try Self.whereClause(filter)
        let configured = Set(accounts.map(\.id))
        let cutoff = now.addingTimeInterval(-Double(graceDays) * 86_400)
        var items: [ActionItem] = []
        var withLocation: Set<Int64> = []
        try db.forEach("""
            SELECT l.message_id, l.account_id, l.mailbox, l.uid_validity, l.uid, l.sha256, l.flags,
                   coalesce(l.internal_date, m.date), m.message_id, coalesce(b.size, m.size)
            FROM locations l JOIN messages m ON m.id = l.message_id LEFT JOIN blobs b ON b.sha256 = l.sha256
            WHERE \(QuerySQL.serverLocation) AND l.uid_validity IS NOT NULL
              AND l.message_id IN (SELECT m.id FROM messages m\(whereClause))
            ORDER BY coalesce(l.internal_date, m.date), l.id
            """, params) { row in
            withLocation.insert(row.int(0))
            let location = ServerLocation(account: row.text(1) ?? "", mailbox: row.text(2) ?? "",
                                          uidValidity: UInt32(truncatingIfNeeded: row.int(3)),
                                          uid: UInt32(truncatingIfNeeded: row.int(4)))
            let date = row.optionalDouble(7).map(Date.init(timeIntervalSince1970:))
            let flags = (row.text(6) ?? "").lowercased().split(separator: " ")
            var item = ActionItem(id: items.count, sha256: row.text(5) ?? "", messageID: row.text(8),
                                  size: Int(row.int(9)), date: date, location: location)
            if !configured.contains(location.account) {
                item.state = .skipped
                item.reason = String(localized: "Konto ist hier nicht eingerichtet")
            } else if date == nil {
                item.state = .skipped
                item.reason = String(localized: "Datum unbekannt")
            } else if let date, date > cutoff {
                item.state = .skipped
                item.reason = Self.graceReason(graceDays)
            } else if flags.contains("\\flagged") {
                item.state = .skipped
                item.reason = String(localized: "markiert")
            }
            items.append(item)
        }
        let total = try count(filter)
        var perAccount: [String: Int] = [:]
        for item in items where item.state == .planned { perAccount[item.location?.account ?? "", default: 0] += 1 }
        let job = ActionJob(kind: .serverDelete, title: title, query: filter.text, graceDays: graceDays, items: items)
        return (job, ActionPlanSummary(messages: total, archiveOnly: total - withLocation.count, perAccount: perAccount))
    }

    /// Plans "delete from the archive" (ADR-0006 4): one item per message, to the archive trash
    /// for 30 days. In the trash means on no server (TJ): a message still on a server is skipped
    /// ("delete it there first"). `summary.archiveOnly` counts those that can go.
    public func planArchiveDelete(_ filter: MessageFilter, title: String) throws -> (ActionJob, ActionPlanSummary) {
        let (whereClause, params) = try Self.whereClause(filter)
        var items: [ActionItem] = []
        var onServer = 0
        try db.forEach("""
            SELECT m.identity, m.primary_blob, m.message_id, m.size, m.date,
                   EXISTS (SELECT 1 FROM locations l WHERE l.message_id = m.id AND \(QuerySQL.serverLocation))
            FROM messages m\(whereClause) ORDER BY m.date, m.id
            """, params) { row in
            let stillOnServer = row.bool(5)
            if stillOnServer { onServer += 1 }
            items.append(ActionItem(id: items.count, sha256: row.text(1) ?? "", messageID: row.text(2), size: Int(row.int(3)),
                                    date: row.optionalDouble(4).map(Date.init(timeIntervalSince1970:)), location: nil,
                                    identity: row.text(0), state: stillOnServer ? .skipped : .planned,
                                    reason: stillOnServer ? Self.stillOnServer : nil))
        }
        let job = ActionJob(kind: .archiveDelete, title: title, query: filter.text, graceDays: nil, items: items)
        _ = onServer
        return (job, ActionPlanSummary(messages: items.count, archiveOnly: items.count - onServer, perAccount: [:]))
    }

    /// Skip reasons of a restore.
    public static let restoreNoOrigin = String(localized: "kein Server-Ort bekannt – Ziel wählen")
    public static let restoreStillOnServer = String(localized: "liegt noch auf dem Server")
    public static let restoreAlreadyThere = String(localized: "liegt dort schon")
    public static let restoreNotSynced = String(localized: "Ordner wird für dieses Konto nicht abgerufen")

    /// Plans "restore to the server" (ADR-0006 §5): one item per message and target mailbox.
    /// - `.original`: in each account the message was fetched from and is no longer in, back to
    ///   the mailbox it was last seen in. A message the user moved on the server is still in
    ///   that account: nothing to do (no duplicate).
    /// - `.mailbox`: one chosen mailbox for all — the way back for imported mail.
    /// The bytes are the ones fetched from that location (else the first stored), with their
    /// system flags, Gmail labels and — unless `keepDate` is off — the original arrival date.
    /// Skipped with reason: no server origin, still or already there, account not set up here,
    /// mailbox outside the account's sync selection (a restore never writes where MailKeeper
    /// does not look, e.g. Proton beyond its test folder).
    public func planRestore(_ filter: MessageFilter, title: String, accounts: [AccountConfig],
                            options: RestoreOptions) throws -> (ActionJob, ActionPlanSummary) {
        struct Loc {
            var account: String, mailbox: String, uid: Int64?, onServer: Bool
            var flags: [String], labels: [String], internalDate: Date?, sha: String?, size: Int?
        }
        struct Msg {
            var sha: String, messageID: String?, size: Int, date: Date?, identity: String?
            var locations: [Loc] = []
        }
        let (whereClause, params) = try Self.whereClause(filter)
        var messages: [Int64: Msg] = [:]
        var order: [Int64] = []
        try db.forEach("""
            SELECT m.id, m.primary_blob, m.message_id, coalesce(pb.size, m.size), m.date, m.identity,
                   l.account_id, l.mailbox, l.uid, l.on_server, l.flags, l.labels, l.internal_date, l.sha256, b.size
            FROM messages m
            LEFT JOIN blobs pb ON pb.sha256 = m.primary_blob
            LEFT JOIN locations l ON l.message_id = m.id
            LEFT JOIN blobs b ON b.sha256 = l.sha256
            WHERE m.id IN (SELECT m.id FROM messages m\(whereClause))
            ORDER BY m.date, m.id, l.last_seen DESC, l.id DESC
            """, params) { row in
            let id = row.int(0)
            if messages[id] == nil {
                order.append(id)
                messages[id] = Msg(sha: row.text(1) ?? "", messageID: row.text(2), size: Int(row.int(3)),
                                   date: row.optionalDouble(4).map(Date.init(timeIntervalSince1970:)), identity: row.text(5))
            }
            guard let account = row.text(6) else { return }
            messages[id]!.locations.append(Loc(
                account: account, mailbox: row.text(7) ?? "", uid: row.isNull(8) ? nil : row.int(8), onServer: row.bool(9),
                flags: (row.text(10) ?? "").split(separator: " ").map(String.init),
                labels: (row.text(11) ?? "").split(separator: "\u{1F}").map(String.init),
                internalDate: row.optionalDouble(12).map(Date.init(timeIntervalSince1970:)),
                sha: row.text(13), size: row.isNull(14) ? nil : Int(row.int(14))))
        }
        let configured = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [ActionItem] = []
        var archiveOnly = 0
        for id in order {
            let m = messages[id]!
            let imap = m.locations.filter { $0.uid != nil }
            if !imap.contains(where: \.onServer) { archiveOnly += 1 }
            func add(_ target: RestoreTarget?, sha: String, size: Int, skip reason: String? = nil) {
                var item = ActionItem(id: items.count, sha256: sha, messageID: m.messageID, size: size, date: m.date,
                                      location: nil, identity: m.identity, target: target)
                var reason = reason
                if reason == nil, let target {
                    if let account = configured[target.account] {
                        if !account.policy.mayContain(target.mailbox) { reason = Self.restoreNotSynced }
                        if account.kind != .gmail { item.target?.labels = [] }
                    } else {
                        reason = String(localized: "Konto ist hier nicht eingerichtet")
                    }
                }
                if let reason {
                    item.state = .skipped
                    item.reason = reason
                }
                items.append(item)
            }
            switch options.destination {
            case .original:
                guard !imap.isEmpty else { add(nil, sha: m.sha, size: m.size, skip: Self.restoreNoOrigin); continue }
                let present = Set(imap.filter(\.onServer).map(\.account))
                var gone: [String: Loc] = [:]  // rows come newest first: the first per account wins
                for l in imap where !l.onServer && !present.contains(l.account) && gone[l.account] == nil { gone[l.account] = l }
                guard !gone.isEmpty else { add(nil, sha: m.sha, size: m.size, skip: Self.restoreStillOnServer); continue }
                for (account, l) in gone.sorted(by: { $0.key < $1.key }) {
                    let target = RestoreTarget(account: account, mailbox: l.mailbox, flags: RestoreTarget.restorableFlags(l.flags),
                                               labels: RestoreTarget.restorableLabels(l.labels),
                                               internalDate: options.keepDate ? (l.internalDate ?? m.date) : nil)
                    add(target, sha: l.sha ?? m.sha, size: l.size ?? m.size)
                }
            case .mailbox(let account, let mailbox):
                let newest = m.locations.first
                let sameAccount = m.locations.first { $0.account == account }
                let target = RestoreTarget(account: account, mailbox: mailbox,
                                           flags: RestoreTarget.restorableFlags(newest?.flags ?? []),
                                           labels: RestoreTarget.restorableLabels(sameAccount?.labels ?? []),
                                           internalDate: options.keepDate ? (newest?.internalDate ?? m.date) : nil)
                let there = imap.contains { $0.onServer && $0.account == account && $0.mailbox == mailbox }
                add(target, sha: m.sha, size: m.size, skip: there ? Self.restoreAlreadyThere : nil)
            }
        }
        var perTarget: [String: Int] = [:]
        for item in items where item.state == .planned {
            if let t = item.target { perTarget["\(t.account) › \(t.mailbox)", default: 0] += 1 }
        }
        let job = ActionJob(kind: .restore, title: title, query: filter.text, graceDays: nil, restore: options, items: items)
        return (job, ActionPlanSummary(messages: order.count, archiveOnly: archiveOnly, perAccount: perTarget))
    }
}
