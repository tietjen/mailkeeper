import Foundation

/// What kind of mail it is (Phase 5.4, the categories of spike S3).
public enum MailCategory: String, Codable, Sendable, CaseIterable {
    case newsletter, notification, invoice
    case orderShipping = "order_shipping"
    case accountSecurity = "account_security"
    case personal, work, travel, spam

    public var label: String {
        switch self {
        case .newsletter: String(localized: "Newsletter")
        case .notification: String(localized: "Benachrichtigung")
        case .invoice: String(localized: "Rechnung/Beleg")
        case .orderShipping: String(localized: "Bestellung/Versand")
        case .accountSecurity: String(localized: "Konto/Sicherheit")
        case .personal: String(localized: "Persönlich")
        case .work: String(localized: "Arbeit")
        case .travel: String(localized: "Reise")
        case .spam: String(localized: "Spam")
        }
    }

    public var icon: String {
        switch self {
        case .newsletter: "newspaper"
        case .notification: "bell"
        case .invoice: "doc.text"
        case .orderShipping: "shippingbox"
        case .accountSecurity: "lock.shield"
        case .personal: "person"
        case .work: "briefcase"
        case .travel: "airplane"
        case .spam: "exclamationmark.octagon"
        }
    }

    /// The word for `kategorie:` (German first).
    public var queryWord: String {
        switch self {
        case .newsletter: "newsletter"
        case .notification: "benachrichtigung"
        case .invoice: "rechnung"
        case .orderShipping: "bestellung"
        case .accountSecurity: "konto"
        case .personal: "persönlich"
        case .work: "arbeit"
        case .travel: "reise"
        case .spam: "spam"
        }
    }

    static let aliases: [String: MailCategory] = {
        var map: [String: MailCategory] = [:]
        for c in allCases { map[c.rawValue] = c; map[c.queryWord] = c }
        let extra: [String: MailCategory] = [
            "notification": .notification, "benachrichtigungen": .notification, "info": .notification,
            "invoice": .invoice, "rechnungen": .invoice, "beleg": .invoice, "belege": .invoice, "quittung": .invoice,
            "order": .orderShipping, "versand": .orderShipping, "lieferung": .orderShipping, "shipping": .orderShipping,
            "sicherheit": .accountSecurity, "security": .accountSecurity, "account": .accountSecurity,
            "persoenlich": .personal, "personal": .personal, "privat": .personal,
            "work": .work, "beruf": .work, "beruflich": .work,
            "travel": .travel, "reisen": .travel, "newsletters": .newsletter, "werbung": .spam, "phishing": .spam,
        ]
        map.merge(extra) { a, _ in a }
        return map
    }()

    /// A category word; nil for an unknown one. `offen` (not yet decided) is handled by the parser.
    public static func parse(_ word: String) -> MailCategory? { aliases[word.lowercased()] }
}

/// A model's (or the link checks') view on phishing, apart from the category (TJ, 5.6).
public enum PhishingLevel: String, Codable, Sendable, CaseIterable {
    case none = "nein"
    case suspicious = "verdacht"
    case likely = "ja"

    public var label: String {
        switch self {
        case .none: String(localized: "kein Phishing")
        case .suspicious: String(localized: "Phishing-Verdacht")
        case .likely: String(localized: "Phishing")
        }
    }
}

/// Who decided a message's category.
public enum ClassificationSource: String, Codable, Sendable {
    /// MailKeeper's rules over the headers (deterministic, ADR-0004 §1).
    case heuristic
    /// The configured endpoint's model.
    case endpoint
    /// Apple's model on this Mac.
    case onDevice = "on-device"
    /// The user decided ("Ist Spam" / "Kein Spam") — journalled, never overwritten.
    case user
    /// Similar mails agreed (5.7, embeddings) — a model answer replaces it.
    case similar
}

public struct Classification: Sendable, Equatable {
    /// nil: the rules left it open and no model has looked at it yet.
    public var category: MailCategory?
    public var source: ClassificationSource
    /// Which rule (heuristic) — for "Warum?".
    public var rule: String?
    public var model: String?
    /// The model's one-line reason (display-safe, bounded).
    public var reason: String?
    public var created: Date
    /// The user's spam verdict: "spam" ("Ist Spam") or "ham" ("Kein Spam").
    public var verdict: String?
    public var phishing: PhishingLevel?
    public var phishingReason: String?
}

/// What the rules look at — all of it already in the index, no message is read.
public struct HeuristicFeatures: Sendable, Equatable {
    public var from: String?
    public var subject: String?
    public var listID: String?
    public var listUnsubscribe: Bool
    public var precedence: String?
    public var autoSubmitted: String?
    public var hasPDF: Bool

    public init(from: String?, subject: String?, listID: String? = nil, listUnsubscribe: Bool = false,
                precedence: String? = nil, autoSubmitted: String? = nil, hasPDF: Bool = false) {
        self.from = from
        self.subject = subject
        self.listID = listID
        self.listUnsubscribe = listUnsubscribe
        self.precedence = precedence
        self.autoSubmitted = autoSubmitted
        self.hasPDF = hasPDF
    }
}

/// The rules first (ADR-0004 §1): they settle the large, structural classes — newsletters,
/// notifications, and invoices/orders/travel with clear signs — for every message, in seconds.
/// Personal, work, account and spam are left to a model: a rule that calls a phishing mail
/// "Konto/Sicherheit" would lend it credibility (S3).
public enum Heuristics {
    /// Raise when the rules change: older heuristic results are computed again.
    /// 2: a sender named for notifications or alerts wins over list headers (GitHub, LinkedIn).
    public static let version = 2

    public static func classify(_ f: HeuristicFeatures) -> (category: MailCategory, rule: String)? {
        let subject = (f.subject ?? "").lowercased()
        let local = (f.from ?? "").lowercased().split(separator: "@").first.map(String.init) ?? ""
        let precedence = (f.precedence ?? "").lowercased()
        let auto = (f.autoSubmitted ?? "").lowercased()
        let list = f.listID != nil

        if ["mailer-daemon", "postmaster"].contains(local) || bounceWords.contains(where: subject.contains) {
            return (.notification, String(localized: "Zustellbericht"))
        }
        if auto.hasPrefix("auto-replied") {
            return (.notification, String(localized: "automatische Antwort (Auto-Submitted)"))
        }
        if !list, f.hasPDF, invoiceWords.contains(where: subject.contains) {
            return (.invoice, String(localized: "Betreff nennt eine Rechnung, PDF im Anhang"))
        }
        if !list, orderWords.contains(where: subject.contains) {
            return (.orderShipping, String(localized: "Betreff nennt Bestellung oder Versand"))
        }
        if !list, travelWords.contains(where: subject.contains) {
            return (.travel, String(localized: "Betreff nennt Buchung oder Ticket"))
        }
        if notifierWords.contains(where: local.contains) { return (.notification, String(localized: "Absender „\(local)“")) }
        if list { return (.newsletter, String(localized: "Mailingliste (List-Id)")) }
        if ["bulk", "list", "junk"].contains(precedence) { return (.newsletter, String(localized: "Massenversand (Precedence: \(precedence))")) }
        if f.listUnsubscribe { return (.newsletter, String(localized: "Abmeldelink (List-Unsubscribe)")) }
        if auto.hasPrefix("auto-") { return (.notification, String(localized: "automatisch erzeugt (Auto-Submitted)")) }
        if robotWords.contains(where: local.contains) { return (.notification, String(localized: "Absender „\(local)“")) }
        return nil
    }

    static let bounceWords = ["undelivered mail", "delivery status notification", "unzustellbar", "returned mail",
                              "mail delivery failed", "delivery failure", "nicht zustellbar"]
    static let invoiceWords = ["rechnung", "invoice", "beleg", "quittung", "receipt", "zahlungsbestätigung",
                               "payment confirmation", "abrechnung", "gutschrift", "kontoauszug"]
    static let orderWords = ["bestellung", "bestellbestätigung", "versandbestätigung", "ihr paket", "ihre sendung",
                             "sendungsverfolgung", "lieferung", "zustellung", "your order", "order confirmation",
                             "has shipped", "wurde versandt", "out for delivery", "versendet"]
    static let travelWords = ["buchungsbestätigung", "reservierungsbestätigung", "ihre buchung", "ihre reservierung",
                              "fahrkarte", "online-ticket", "boarding", "check-in", "reiseplan", "itinerary",
                              "booking confirmation", "flugbestätigung", "ihre reise"]
    /// Senders that announce themselves as notifications — stronger than list headers, which
    /// notification services (GitHub, LinkedIn) send as well.
    static let notifierWords = ["notification", "notifications", "notify", "alert", "benachrichtigung"]
    static let robotWords = ["noreply", "no-reply", "no_reply", "donotreply", "do-not-reply", "notification", "notify",
                             "alert", "automailer", "mailer", "system", "automat"]
}

extension ArchiveReader {
    public func classification(of id: Int64) throws -> Classification? {
        try db.queryOne("""
            SELECT category, source, rule, model, reason, created, verdict, phishing, phishing_reason FROM classifications WHERE message_id = ?
            """, [.int(id)]) { r in
            Classification(category: r.text(0).flatMap(MailCategory.init(rawValue:)),
                           source: r.text(1).flatMap(ClassificationSource.init(rawValue:)) ?? .heuristic,
                           rule: r.text(2), model: r.text(3), reason: r.text(4), created: Date(timeIntervalSince1970: r.double(5)),
                           verdict: r.text(6), phishing: r.text(7).flatMap(PhishingLevel.init(rawValue:)), phishingReason: r.text(8))
        }
    }

    /// Messages the rules have not looked at yet (or only older rules).
    public func heuristicPendingCount() throws -> Int {
        Int(try db.queryOne("""
            SELECT count(*) FROM messages m LEFT JOIN classifications c ON c.message_id = m.id
            WHERE c.message_id IS NULL OR (c.source IN ('heuristic', 'similar') AND c.version < ?)
            """, [.int(Int64(Heuristics.version))]) { $0.int(0) } ?? 0)
    }

    /// Of `filter`'s messages, those the rules left open (no model answer yet), newest first.
    public func openForClassification(_ filter: MessageFilter, limit: Int) throws -> [Int64] {
        let (whereClause, params) = try Self.whereClause(filter)
        return try db.query("""
            SELECT m.id FROM messages m JOIN classifications c ON c.message_id = m.id
            WHERE c.category IS NULL AND m.id IN (SELECT m.id FROM messages m\(whereClause))
            ORDER BY m.date DESC LIMIT ?
            """, params + [.int(Int64(limit))]) { $0.int(0) }
    }

    /// Which spam-folder mails to (re)check.
    public enum JunkCheck: Sendable {
        /// Not judged by a model yet.
        case unchecked
        /// Judged by the model on this Mac (TJ: re-check with the endpoint once it is set up).
        case onDevice
        /// Everything a model judged — never what the user decided.
        case all
    }

    /// Spam-folder mails to check, newest first; never one the user has decided.
    public func junkToCheck(limit: Int, _ which: JunkCheck = .unchecked) throws -> [Int64] {
        let (whereClause, params) = try Self.whereClause(MessageFilter(text: "is:junk "))
        let condition = switch which {
        case .unchecked: "(c.message_id IS NULL OR c.source IN ('heuristic', 'similar'))"  // similarity never judges phishing
        case .onDevice: "c.source = 'on-device'"
        case .all: "(c.message_id IS NULL OR c.source != 'user')"
        }
        return try db.query("""
            SELECT m.id FROM messages m LEFT JOIN classifications c ON c.message_id = m.id
            WHERE \(condition) AND c.verdict IS NULL AND m.id IN (SELECT m.id FROM messages m\(whereClause))
            ORDER BY m.date DESC LIMIT ?
            """, params + [.int(Int64(limit))]) { $0.int(0) }
    }

    public struct JunkReview: Sendable, Equatable {
        public var total = 0
        /// Not yet judged by a model or the user.
        public var unchecked = 0
        /// A model says: not spam — worth a look.
        public var notSpam = 0
        public var spam = 0
        /// The user decided.
        public var decided = 0
        /// A model sees phishing (suspicion or likely) — counted apart from spam (TJ, 5.6).
        public var phishing = 0
        /// Judged by the model on this Mac (worth a re-check with the endpoint).
        public var byMac = 0

        public init() {}
    }

    public func junkReview() throws -> JunkReview {
        let (whereClause, params) = try Self.whereClause(MessageFilter(text: "is:junk "))
        var r = JunkReview()
        try db.forEach("""
            SELECT c.source, c.category, c.verdict, c.phishing FROM messages m LEFT JOIN classifications c ON c.message_id = m.id
            WHERE m.id IN (SELECT m.id FROM messages m\(whereClause))
            """, params) { row in
            r.total += 1
            if ["verdacht", "ja"].contains(row.text(3) ?? "") { r.phishing += 1 }
            if row.text(2) != nil || row.text(0) == "user" { r.decided += 1; return }
            if row.text(0) == "on-device" { r.byMac += 1 }
            switch (row.text(0), row.text(1)) {
            case (nil, _), ("heuristic", _), ("similar", _): r.unchecked += 1
            case (_, "spam"): r.spam += 1
            default: r.notSpam += 1
            }
        }
        return r
    }

    /// Messages per category (nil = open), outside the trash.
    public func categoryCounts() throws -> [MailCategory?: Int] {
        var out: [MailCategory?: Int] = [:]
        try db.forEach("""
            SELECT c.category, count(*) FROM classifications c JOIN messages m ON m.id = c.message_id
            WHERE m.trashed IS NULL GROUP BY c.category
            """) { r in out[r.text(0).flatMap(MailCategory.init(rawValue:)), default: 0] += Int(r.int(1)) }
        return out
    }
}
