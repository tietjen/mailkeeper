import Foundation

/// Where a mailing list says to unsubscribe (RFC 2369, one-click RFC 8058). Only `https` and
/// `mailto` targets are kept: anything else (http, javascript:, data:) is dropped.
public struct UnsubscribeInfo: Sendable, Equatable {
    public var https: URL?
    public var mailto: URL?
    /// `List-Unsubscribe-Post: List-Unsubscribe=One-Click` was present (used in Phase 4).
    public var oneClick: Bool

    /// The target to open: the web page first, else a mail to the list.
    public var preferred: URL? { https ?? mailto }

    public static func parse(listUnsubscribe: String?, post: String?) -> UnsubscribeInfo? {
        guard let raw = listUnsubscribe, raw.count <= 4_096 else { return nil }
        var info = UnsubscribeInfo(https: nil, mailto: nil, oneClick: false)
        var rest = Substring(raw)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            let candidate = rest[rest.index(after: open)..<close].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: close)...]
            guard candidate.count <= 2_048, !candidate.contains(where: { $0.isWhitespace || $0.isNewline }),
                  let url = URL(string: candidate), let scheme = url.scheme?.lowercased() else { continue }
            if scheme == "https", url.host?.isEmpty == false, info.https == nil { info.https = url }
            if scheme == "mailto", info.mailto == nil { info.mailto = url }
        }
        info.oneClick = post.map { $0.lowercased().replacingOccurrences(of: " ", with: "") == "list-unsubscribe=one-click" } ?? false
        return info.preferred == nil ? nil : info
    }
}

/// Everything the cleanup view shows about one group (right-hand pane).
public struct GroupDetail: Sendable {
    public struct MonthCount: Sendable, Hashable {
        /// First day of the month, local time.
        public var month: Date
        public var count: Int
    }

    public struct Place: Sendable, Hashable {
        public var account: String
        public var mailbox: String
        public var count: Int
    }

    public struct Member: Sendable, Hashable {
        public var address: String
        public var name: String?
        public var count: Int
    }

    public var group: MessageGroup
    /// The last 24 months, oldest first, months without mail included.
    public var months: [MonthCount]
    /// Mails in the last 12 months.
    public var lastYear: Int
    public var places: [Place]
    public var onServer: Int
    public var onServerBytes: Int64
    public var withAttachments: Int
    public var largest: Int64
    /// The newest messages, newest first.
    public var recent: [MessageSummary]
    /// Senders inside a domain or list group (empty for a sender group).
    public var members: [Member]
    public var unsubscribe: UnsubscribeInfo?
    /// For a list: the description from `List-Id: description <id>` of the newest message.
    public var listDescription: String?

    public var read: Int { group.count - group.unread }
}

/// Totals for the right-hand pane when no group is selected: where cleaning up pays off.
public struct CleanupOverview: Sendable, Equatable {
    public struct Bucket: Sendable, Equatable {
        public var title: String
        /// Added to the search to show these messages (or their groups).
        public var query: String
        public var count: Int
        public var bytes: Int64
    }

    public var total: Bucket
    public var buckets: [Bucket]
}

extension ArchiveReader {
    /// Details of one group within the current scope and search.
    public func groupDetail(_ group: MessageGroup, within filter: MessageFilter, now: Date = Date(),
                            calendar: Calendar = .current) throws -> GroupDetail {
        var f = filter
        f.also.append(group.query)
        let (whereClause, params) = try Self.whereClause(f)
        let inGroup = "SELECT m.id FROM messages m" + whereClause

        // months: count per local yyyy-mm, then fill the 24-month window
        var perMonth: [String: Int] = [:]
        try db.forEach("SELECT strftime('%Y-%m', m.date, 'unixepoch', 'localtime'), count(*) FROM messages m\(whereClause) GROUP BY 1",
                       params) { row in if let k = row.text(0) { perMonth[k] = Int(row.int(1)) } }
        let thisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? now
        let months: [GroupDetail.MonthCount] = (0..<24).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .month, value: -back, to: thisMonth) else { return nil }
            let c = calendar.dateComponents([.year, .month], from: start)
            let key = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            return GroupDetail.MonthCount(month: start, count: perMonth[key] ?? 0)
        }
        let lastYear = months.suffix(12).reduce(0) { $0 + $1.count }

        let places = try db.query("""
            SELECT l.account_id, l.mailbox, count(DISTINCT l.message_id) FROM locations l
            WHERE l.message_id IN (\(inGroup)) GROUP BY 1, 2 ORDER BY 3 DESC, 1, 2 LIMIT 8
            """, params) { GroupDetail.Place(account: $0.text(0) ?? "", mailbox: $0.text(1) ?? "", count: Int($0.int(2))) }

        let (onServer, onServerBytes, withAttachments, largest) = try db.queryOne("""
            SELECT count(*) FILTER (WHERE m.id IN (SELECT l.message_id FROM locations l WHERE \(QuerySQL.serverLocation))),
                   coalesce(sum(m.size) FILTER (WHERE m.id IN (SELECT l.message_id FROM locations l WHERE \(QuerySQL.serverLocation))), 0),
                   count(*) FILTER (WHERE m.attachment_count > 0), coalesce(max(m.size), 0)
            FROM messages m\(whereClause)
            """, params) { (Int($0.int(0)), $0.int(1), Int($0.int(2)), $0.int(3)) } ?? (0, 0, 0, 0)

        let recentIDs = try db.query(inGroup + " ORDER BY m.date DESC NULLS LAST, m.id DESC LIMIT 5", params) { $0.int(0) }

        var members: [GroupDetail.Member] = []
        if group.mode != .sender {
            members = try db.query("""
                WITH base AS (
                    SELECT mk_lower(m.from_addr) AS k, m.from_name AS name, m.date AS date FROM messages m\(whereClause)
                    AND m.from_addr IS NOT NULL AND instr(m.from_addr, '"') = 0
                ), names AS (\(ArchiveReader.usualName(from: "base")))
                SELECT b.k, max(n.name), count(*) FROM base b LEFT JOIN names n ON n.k = b.k
                GROUP BY 1 ORDER BY 3 DESC, 1 LIMIT 8
                """, params) { GroupDetail.Member(address: $0.text(0) ?? "", name: $0.text(1), count: Int($0.int(2))) }
        }

        // The newest message that offers an unsubscribe link; its headers come from the blob.
        var unsubscribe: UnsubscribeInfo?
        if group.unsubscribe,
           let blob = try db.queryOne("SELECT m.primary_blob FROM messages m\(whereClause) AND m.list_unsubscribe = 1 ORDER BY m.date DESC NULLS LAST LIMIT 1",
                                      params, { $0.text(0) }) ?? nil {
            let headers = HeaderParser.parse(try layout.blobs.read(blob)).0
            unsubscribe = UnsubscribeInfo.parse(listUnsubscribe: headers["List-Unsubscribe"], post: headers["List-Unsubscribe-Post"])
        }
        var listDescription: String?
        if group.mode == .list, let newest = recentIDs.first,
           let blob = try db.queryOne("SELECT primary_blob FROM messages WHERE id = ?", [.int(newest)], { $0.text(0) }) ?? nil {
            listDescription = MIMEParser.listID(HeaderParser.parse(try layout.blobs.read(blob)).0["List-Id"]).description
        }

        return GroupDetail(group: group, months: months, lastYear: lastYear, places: places, onServer: onServer,
                           onServerBytes: onServerBytes, withAttachments: withAttachments, largest: largest,
                           recent: try summaries(recentIDs), members: members, unsubscribe: unsubscribe,
                           listDescription: listDescription)
    }

    /// Count and size of what the filter selects.
    public func totals(_ filter: MessageFilter) throws -> (count: Int, bytes: Int64) {
        let (whereClause, params) = try Self.whereClause(filter)
        return try db.queryOne("SELECT count(*), coalesce(sum(m.size), 0) FROM messages m" + whereClause, params) {
            (Int($0.int(0)), $0.int(1))
        } ?? (0, 0)
    }

    /// The overview's buckets. Exclusive in the app: choosing one replaces another.
    public static let cleanupBuckets: [(title: String, query: String)] = [
        ("Newsletter, nie geöffnet", "is:list is:unread"),
        ("Älter als zwei Jahre, noch auf dem Server", "before:2y on:server"),
        ("Größer als 10 MB", "larger:10M"),
        ("Nur noch im Archiv", "only:archive"),
    ]

    /// Where cleaning up pays off in the current scope: each bucket is a query to add. Pass the
    /// filter without an active bucket, so every count says what choosing that bucket gives.
    public func cleanupOverview(_ filter: MessageFilter) throws -> CleanupOverview {
        let all = try totals(filter)
        let buckets = try Self.cleanupBuckets.map { title, query in
            var f = filter
            f.also.append(query)
            let t = try totals(f)
            return CleanupOverview.Bucket(title: title, query: query, count: t.count, bytes: t.bytes)
        }
        return CleanupOverview(total: CleanupOverview.Bucket(title: "Alle", query: "", count: all.count, bytes: all.bytes),
                               buckets: buckets)
    }
}
