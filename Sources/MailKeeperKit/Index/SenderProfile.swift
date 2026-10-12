import Foundation

/// What the archive knows about a mail's sender address (ADR-0005 `sender_profile`, 6.2) —
/// computed when asked, from the index alone, so it is never stale and costs no storage. Counts
/// leave the mail in question out. Facts, not verdicts: a known address can be forged, which is
/// why the model is told to weigh it against the own server's check.
public struct SenderProfile: Sendable, Equatable {
    public var address: String
    public var domain: String?
    /// Other mails from this address in the archive (not in the trash).
    public var mails: Int
    public var first: Date?
    public var last: Date?
    public var byRules: [MailCategory: Int] = [:]
    public var byModel: [MailCategory: Int] = [:]
    public var byUser: [MailCategory: Int] = [:]
    public var spamVerdicts = 0
    public var hamVerdicts = 0
    public var phishingFlags = 0
    /// The user's own sent mails to this address, and to anyone at its domain.
    public var youWrote = 0
    public var youWroteToDomain = 0

    /// The pseudo id "Warum?" names it by (profiles are not stored).
    public var sourceID: String { "profile:sender:\(address)" }

    /// German lines for a prompt and for "Warum?".
    public var lines: [String] {
        var out: [String] = []
        if mails == 0 {
            out.append(String(localized: "Erste Mail von dieser Adresse im Archiv."))
        } else {
            let years = [first, last].compactMap { $0.map { Calendar.current.component(.year, from: $0) } }
            let span = years.count == 2 ? (years[0] == years[1] ? " (\(years[0]))" : " (\(years[0])–\(years[1]))") : ""
            out.append(String(localized: "Von dieser Adresse \(mails) weitere Mails\(span)."))
        }
        let list = { (counts: [MailCategory: Int]) in
            counts.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key.label) \($0.value)" }.joined(separator: ", ")
        }
        if !byUser.isEmpty { out.append(String(localized: "Deine Einordnung: \(list(byUser)).")) }
        if !byRules.isEmpty { out.append(String(localized: "Nach Regeln: \(list(byRules)).")) }
        if !byModel.isEmpty { out.append(String(localized: "Nach KI: \(list(byModel)).")) }
        if spamVerdicts > 0 || hamVerdicts > 0 {
            out.append(String(localized: "Deine Urteile: \(spamVerdicts)× Spam, \(hamVerdicts)× kein Spam."))
        }
        if phishingFlags > 0 { out.append(String(localized: "KI-Phishing-Verdacht bei \(phishingFlags) Mails dieser Adresse.")) }
        if youWrote > 0 {
            out.append(String(localized: "Du hast \(youWrote) Mails an diese Adresse geschrieben."))
        } else if youWroteToDomain > 0, let domain {
            out.append(String(localized: "An diese Adresse hast du nie geschrieben, an \(domain) \(youWroteToDomain)-mal."))
        } else {
            out.append(String(localized: "Du hast nie an diese Adresse oder ihre Domain geschrieben."))
        }
        return out
    }
}

extension ArchiveReader {
    /// The profile of `messageID`'s sender, or nil when it has no usable address.
    public func senderProfile(of messageID: Int64) throws -> SenderProfile? {
        guard let address = try db.queryOne("SELECT lower(from_addr) FROM messages WHERE id = ?", [.int(messageID)], { $0.text(0) }) ?? nil,
              let at = address.lastIndex(of: "@"), at != address.startIndex, address.index(after: at) != address.endIndex else { return nil }
        let host = String(address[address.index(after: at)...])
        var p = SenderProfile(address: address, domain: host, mails: 0)
        try db.forEach("""
            SELECT m.date, c.source, c.category, c.verdict, c.phishing FROM messages m
            LEFT JOIN classifications c ON c.message_id = m.id
            WHERE lower(m.from_addr) = ? AND m.id != ? AND m.trashed IS NULL
            """, [.text(address), .int(messageID)]) { r in
            p.mails += 1
            if let d = r.optionalDouble(0).map(Date.init(timeIntervalSince1970:)) {
                p.first = min(p.first ?? d, d)
                p.last = max(p.last ?? d, d)
            }
            if let category = r.text(2).flatMap(MailCategory.init(rawValue:)) {
                switch r.text(1) {
                case "user": p.byUser[category, default: 0] += 1
                case "heuristic": p.byRules[category, default: 0] += 1
                case "endpoint", "on-device": p.byModel[category, default: 0] += 1
                default: break  // "similar": only an echo of the others
                }
            }
            if r.text(3) == "spam" { p.spamVerdicts += 1 }
            if r.text(3) == "ham" { p.hamVerdicts += 1 }
            if r.text(4) == "verdacht" || r.text(4) == "ja" { p.phishingFlags += 1 }
        }
        // the user's own sent mails: recipients are stored as "a@b.de, c@d.de"
        let recipients = "', ' || lower(coalesce(m.to_addrs, '')) || ', ' || lower(coalesce(m.cc_addrs, '')) || ','"
        let sent = "m.id IN (SELECT l.message_id FROM locations l WHERE \(QuerySQL.sentLocation))"
        (p.youWrote, p.youWroteToDomain) = try db.queryOne("""
            SELECT count(*) FILTER (WHERE instr(\(recipients), ', ' || ? || ',') > 0),
                   count(*) FILTER (WHERE instr(\(recipients), '@' || ? || ',') > 0)
            FROM messages m WHERE \(sent) AND m.trashed IS NULL
            """, [.text(address), .text(host)]) { (Int($0.int(0)), Int($0.int(1))) } ?? (0, 0)
        return p
    }
}
