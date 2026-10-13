import Foundation

/// A real relationship (ADR-0010 §6): an organisation with the domains it really used, and when
/// it began and ended. Stored as a memory item of kind `relation`; confirmed ones are active,
/// rejected suggestions inactive (they keep their domains from being suggested again).
public struct Relation: Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var domains: [String]
    public var since: Date?
    public var until: Date?
    public var confirmed: Bool
    /// The user rejected it as a suggestion (forgotten ones may be suggested again).
    public var rejected: Bool

    /// Ended: trust fades (a final invoice, tax papers still come) — it is no spam signal.
    public var ended: Bool { until.map { $0 < .now } ?? false }

    init?(_ item: MemoryItem) {
        guard item.kind == .relation, let name = item.content.name, let domains = item.content.domains, !domains.isEmpty else { return nil }
        id = item.id
        self.name = name
        self.domains = domains
        since = item.content.since.map(Date.init(timeIntervalSince1970:))
        until = item.content.until.map(Date.init(timeIntervalSince1970:))
        confirmed = item.active
        rejected = !item.active && item.content.rejected == true
    }
}

/// What "Einschätzung korrigieren" proposes (6.4b): the mail's own domain and optional others.
public struct ProposedRelation: Sendable, Equatable {
    public struct Domain: Sendable, Equatable {
        public var domain: String
        public var mails: Int
        /// Pre-selected: positive evidence, no warning.
        public var evidence: Bool
        public var why: String
    }

    public var name: String
    public var domains: [Domain]

    public init(name: String, domains: [Domain]) {
        self.name = name
        self.domains = domains
    }
}

/// A relationship MailKeeper suggests from the history: positive evidence only.
public struct RelationSuggestion: Sendable, Equatable, Identifiable {
    public var id: String { domains.joined(separator: ",") }
    public var name: String
    public var domains: [String]
    public var first: Date?
    public var last: Date?
    public var mails = 0
    /// The user's own mails to the domain.
    public var youWrote = 0
    /// The user's "kein Spam" and own categories on its mails.
    public var yourDecisions = 0
    /// Invoices, orders, account and travel mails that passed DMARC at the own server.
    public var authenticated = 0

    public var score: Int { youWrote * 3 + yourDecisions * 2 + authenticated }

    public var evidence: String {
        var parts: [String] = []
        if youWrote > 0 { parts.append(String(localized: "du hast \(youWrote)× geschrieben")) }
        if yourDecisions > 0 { parts.append(String(localized: "\(yourDecisions) deiner Entscheidungen")) }
        if authenticated > 0 { parts.append(String(localized: "\(authenticated) echte Transaktionsmails")) }
        return parts.joined(separator: " · ")
    }
}

public enum Relations {
    /// Providers whose authserv-id lies in another domain than their IMAP host.
    static let providerAuthDomains: [String: Set<String>] = ["gmail.com": ["google.com"], "googlemail.com": ["google.com"]]

    /// Mail providers for everyone: a domain there is a person's, not an organisation's.
    public static let freemail: Set<String> = [
        "gmail.com", "googlemail.com", "gmx.de", "gmx.net", "gmx.at", "gmx.ch", "web.de", "outlook.com", "outlook.de", "hotmail.com",
        "hotmail.de", "live.com", "live.de", "msn.com", "yahoo.com", "yahoo.de", "ymail.com", "icloud.com", "me.com", "mac.com",
        "t-online.de", "freenet.de", "posteo.de", "posteo.net", "mailbox.org", "proton.me", "protonmail.com", "protonmail.ch", "pm.me",
        "aol.com", "aol.de", "arcor.de", "online.de", "email.de", "mail.de", "1und1.de", "vodafone.de", "kabelmail.de", "tutanota.com",
        "tuta.io", "zoho.com", "yandex.com", "mail.ru", "fastmail.com",
    ]

    static let transactional = ["invoice", "order_shipping", "account_security", "travel"]

    /// Registrable domains, lowercased, without duplicates; "info@x.de" and "https://x.de/" become "x.de".
    public static func normalize(_ domains: [String]) -> [String] {
        var seen: Set<String> = []
        return domains.compactMap { raw -> String? in
            var d = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let at = d.lastIndex(of: "@") { d = String(d[d.index(after: at)...]) }
            if let r = d.range(of: "://") { d = String(d[r.upperBound...]) }
            d = String(d.prefix { $0 != "/" && $0 != ":" && $0 != " " })
            guard d.contains("."), d.count < 120, d.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
            let reg = LinkCheck.registrableDomain(d)
            return seen.insert(reg).inserted ? reg : nil
        }
    }

    /// Sender names that say nothing about who writes: they neither name nor merge a suggestion.
    static let genericNames: Set<String> = [
        "mail delivery system", "mail delivery subsystem", "mailer daemon", "mailerdaemon", "postmaster", "noreply", "no reply",
        "donotreply", "do not reply", "info", "service", "support", "newsletter", "news", "team", "notification", "notifications",
        "kundenservice", "customer service", "admin", "office", "kontakt", "contact", "hello", "hallo", "mail", "system",
    ]

    static func isGeneric(_ name: String) -> Bool {
        let n = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        return n.isEmpty || genericNames.contains(n) || n.contains("@")
    }

    /// A person's name as a set of words: "Muster, Erika" and "Erika Muster" alike.
    static func personKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count > 1 }.sorted().joined(separator: " ")
    }

    /// For grouping suggestions: "Sparkasse KölnBonn" and "sparkasse koelnbonn" alike.
    static func nameKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}

extension ArchiveReader {
    /// Messages whose header fields (authentication, delivery) are not read yet.
    public func headerFieldsPending() throws -> Int {
        Int(try db.queryOne("SELECT count(*) FROM messages WHERE headers_v IS NULL OR headers_v < ?",
                            [.int(Int64(ArchiveWriter.headerFieldsVersion))]) { $0.int(0) } ?? 0)
    }

    public func relations(includeRejected: Bool = false) throws -> [Relation] {
        try memoryItems(includeForgotten: includeRejected).compactMap(Relation.init)
    }

    /// The confirmed relation a domain belongs to.
    public func relation(forDomain domain: String) throws -> Relation? {
        let reg = LinkCheck.registrableDomain(domain.lowercased())
        return try relations().first { $0.domains.contains(reg) }
    }

    /// Per account, the servers that add `Authentication-Results` to its incoming mail — only
    /// their results count. A server is the account's own when it stamped at least half of *all*
    /// the account's incoming mail, in the last year or ever (≥ 20 mails), or a fifth (≥ 5) when
    /// its host shares the account's registrable IMAP domain (mail.example.de checks for
    /// imap.example.de; Gmail's mx.google.com for imap.gmail.com). Review 6 B1: counting only
    /// mails that carry the header let a sender make itself "own" with five forged headers on a
    /// provider that adds none; the host alone let one forged header naming the provider's public
    /// MX do it. A share of all mail takes many forged mails, and the floor of 20 is what
    /// remains: a dormant account with few mails can still be outnumbered. Several servers: TJ's
    /// mail moved from one server to another (27,030 then 7,093 mails).
    public func ownAuthServers(now: Date = .now) throws -> [String: Set<String>] {
        struct Counts { var total = 0, recent = 0; var servers: [String: (all: Int, recent: Int)] = [:] }
        var byAccount: [String: Counts] = [:]
        try db.forEach("""
            SELECT l.account_id, m.auth_server, m.date >= ?, count(DISTINCT m.id) FROM messages m JOIN locations l ON l.message_id = m.id
            WHERE m.trashed IS NULL AND NOT \(QuerySQL.sentLocation)
            GROUP BY 1, 2, 3
            """, [.double(now.addingTimeInterval(-365 * 86_400).timeIntervalSince1970)]) { r in
            guard let account = r.text(0) else { return }
            let recent = r.bool(2), n = Int(r.int(3))
            var c = byAccount[account] ?? Counts()
            c.total += n
            if recent { c.recent += n }
            if let server = r.text(1) {
                var s = c.servers[server] ?? (0, 0)
                s.all += n
                if recent { s.recent += n }
                c.servers[server] = s
            }
            byAccount[account] = c
        }
        let hosts = Dictionary(((try? AccountStore(layout: layout).load()) ?? []).map { ($0.id, $0.host.lowercased()) }, uniquingKeysWith: { a, _ in a })
        var out: [String: Set<String>] = [:]
        for (account, c) in byAccount {
            var own: Set<String> = []
            let hostDomain = hosts[account].flatMap { $0.isEmpty || $0.first?.isNumber == true ? nil : LinkCheck.registrableDomain($0) }
            for (server, n) in c.servers {
                let serverDomain = LinkCheck.registrableDomain(server)
                let sameHost = hostDomain.map { $0 == serverDomain || (Relations.providerAuthDomains[$0]?.contains(serverDomain) ?? false) } ?? false
                // the host is a tie-breaker, never a free pass (review 6, second pass)
                let byHost = sameHost && ((n.all >= 5 && n.all * 5 >= c.total) || (n.recent >= 5 && n.recent * 5 >= c.recent))
                let byShare = (n.all >= 20 && n.all * 2 >= c.total) || (n.recent >= 20 && n.recent * 2 >= c.recent)
                if byHost || byShare { own.insert(server) }
            }
            if !own.isEmpty { out[account] = own }
        }
        // a server that is own in one account counts in another where it checked at least a
        // quarter of the mail (an imported account with older mail before the server added the
        // header: an archive's second account: 15 of 70, all recent)
        let known = Set(out.values.flatMap { $0 })
        for (account, c) in byAccount {
            for (server, n) in c.servers where known.contains(server) && !(out[account]?.contains(server) ?? false) {
                if (n.all >= 5 && n.all * 4 >= c.total) || (n.recent >= 5 && n.recent * 4 >= c.recent) { out[account, default: []].insert(server) }
            }
        }
        return out
    }

    /// The own server's verdict on a message: its results, and whether they come from a server
    /// of an account the message lies in (only then do they count).
    public func authentication(of messageID: Int64, servers: [String: Set<String>]? = nil) throws -> (results: AuthResults, trusted: Bool)? {
        let own = try servers ?? ownAuthServers()
        guard let row = try db.queryOne("SELECT auth_server, auth_dkim, auth_spf, auth_dmarc, auth_from FROM messages WHERE id = ?",
                                        [.int(messageID)], { r in
                                            AuthResults(server: r.text(0), dkim: r.text(1), spf: r.text(2), dmarc: r.text(3), fromDomain: r.text(4))
                                        }) ?? nil, row.server != nil || row.summary != nil else { return nil }
        let accounts = try db.query("SELECT DISTINCT account_id FROM locations WHERE message_id = ?", [.int(messageID)]) { $0.text(0) ?? "" }
        let trusted = row.server.map { server in accounts.contains { own[$0]?.contains(server) ?? false } } ?? false
        return (row, trusted)
    }

    /// `m.auth_dmarc = 'pass' AND m.auth_server IN (?, …)` with its parameters (review 6 S5:
    /// bound, not spliced).
    static func authenticatedCondition(_ servers: Set<String>) -> (String, [SQLValue]) {
        guard !servers.isEmpty else { return ("0", []) }
        let sorted = servers.sorted()
        return ("(m.auth_dmarc = 'pass' AND m.auth_server IN (" + Array(repeating: "?", count: sorted.count).joined(separator: ",") + "))",
                sorted.map { .text($0) })
    }

    /// Relationships the history suggests (ADR-0010 §6): domains with positive evidence — the
    /// user wrote to them, said "kein Spam" or gave a category, or sent authenticated
    /// transactional mail (DMARC pass at the own server). Not freemail, not the user's own
    /// domains, not domains already in a relation (or rejected), not where spam and phishing
    /// outweigh the evidence. Same name → one suggestion with several domains.
    public func relationSuggestions(limit: Int = 200) throws -> [RelationSuggestion] {
        let (authenticated, authParams) = Self.authenticatedCondition(Set(try ownAuthServers().values.flatMap { $0 }))
        let sent = "m.id IN (SELECT l.message_id FROM locations l WHERE \(QuerySQL.sentLocation))"
        let transactional = Relations.transactional.map { "'\($0)'" }.joined(separator: ",")

        struct Host { var mails = 0, ham = 0, decided = 0, bad = 0, auth = 0, wrote = 0, nameMails = 0; var first: Double?, last: Double?, name: String? }
        var hosts: [String: Host] = [:]
        try db.forEach("""
            WITH base AS (
                SELECT lower(substr(m.from_addr, instr(m.from_addr, '@') + 1)) AS k, m.from_name AS name, m.date AS date,
                       c.verdict AS verdict, c.source AS source, c.category AS category, c.phishing AS phishing,
                       (\(authenticated)) AS auth
                FROM messages m LEFT JOIN classifications c ON c.message_id = m.id
                WHERE m.trashed IS NULL AND instr(m.from_addr, '@') > 0 AND NOT (\(sent))
            ), names AS (
                SELECT k, name, n FROM (
                    SELECT k, name, count(*) AS n, row_number() OVER (PARTITION BY k ORDER BY count(*) DESC, max(date) DESC, name) AS r
                    FROM base WHERE name IS NOT NULL AND name != '' GROUP BY k, name
                ) WHERE r = 1
            )
            SELECT b.k, count(*), min(b.date), max(b.date),
                   sum(b.verdict = 'ham'), sum(b.source = 'user' AND b.category IS NOT NULL AND b.category != 'spam'),
                   sum(b.verdict = 'spam' OR (b.source = 'user' AND b.category = 'spam') OR b.phishing IN ('verdacht', 'ja')),
                   sum(b.auth AND b.category IN (\(transactional))), max(n.name), max(n.n)
            FROM base b LEFT JOIN names n ON n.k = b.k GROUP BY b.k
            """, authParams) { r in
            guard let k = r.text(0), !k.isEmpty else { return }
            hosts[k] = Host(mails: Int(r.int(1)), ham: Int(r.int(4)), decided: Int(r.int(5)), bad: Int(r.int(6)), auth: Int(r.int(7)),
                            nameMails: Int(r.optionalInt(9) ?? 0), first: r.optionalDouble(2), last: r.optionalDouble(3), name: r.text(8))
        }
        // the user's own mails: who they went to, and which domains the user writes from
        var own: Set<String> = []
        var ownNames: Set<String> = []
        try db.forEach("SELECT m.from_addr, m.to_addrs, m.cc_addrs, m.date, m.from_name FROM messages m WHERE \(sent) AND m.trashed IS NULL") { r in
            if let from = r.text(0), let at = from.lastIndex(of: "@") { own.insert(LinkCheck.registrableDomain(String(from[from.index(after: at)...]).lowercased())) }
            if let name = r.text(4) { ownNames.insert(Relations.personKey(name)) }
            for list in [r.text(1), r.text(2)].compactMap({ $0 }) {
                for address in list.split(separator: ",") {
                    let a = address.trimmingCharacters(in: .whitespaces).lowercased()
                    guard let at = a.lastIndex(of: "@") else { continue }
                    let host = String(a[a.index(after: at)...])
                    var h = hosts[host] ?? Host()
                    h.wrote += 1
                    if let d = r.optionalDouble(3) { h.first = min(h.first ?? d, d); h.last = max(h.last ?? d, d) }
                    hosts[host] = h
                }
            }
        }
        let taken = Set(try relations(includeRejected: true).filter { $0.confirmed || $0.rejected }.flatMap(\.domains))

        var byDomain: [String: RelationSuggestion] = [:]
        var badByDomain: [String: Int] = [:]
        var nameMails: [String: Int] = [:]
        for (host, h) in hosts {
            let domain = LinkCheck.registrableDomain(host)
            guard !Relations.freemail.contains(domain), !own.contains(domain), !taken.contains(domain) else { continue }
            var s = byDomain[domain] ?? RelationSuggestion(name: domain, domains: [domain])
            s.mails += h.mails
            s.youWrote += h.wrote
            s.yourDecisions += h.ham + h.decided
            s.authenticated += h.auth
            if let f = h.first { s.first = min(s.first ?? .distantFuture, Date(timeIntervalSince1970: f)) }
            if let l = h.last { s.last = max(s.last ?? .distantPast, Date(timeIntervalSince1970: l)) }
            // named after the domain's biggest sender, and only when that name stands for most of its
            // mails, says more than "Support" and is not the user's own (a person writing for a
            // company, the user's own address there)
            if h.mails > nameMails[domain, default: 0] {
                nameMails[domain] = h.mails
                if let name = h.name, h.nameMails * 2 >= h.mails, !Relations.isGeneric(name), !ownNames.contains(Relations.personKey(name)) {
                    s.name = String(Memory.cleanText(name).prefix(120))
                } else {
                    s.name = domain
                }
            }
            badByDomain[domain, default: 0] += h.bad
            byDomain[domain] = s
        }
        let candidates = byDomain.values.filter { s in
            let positive = s.youWrote > 0 || s.yourDecisions > 0 || s.authenticated >= 2
            return positive && badByDomain[s.domains[0], default: 0] <= s.youWrote + s.yourDecisions + s.authenticated / 2
        }
        // one organisation, several domains: merged by name
        var merged: [String: RelationSuggestion] = [:]
        for s in candidates.sorted(by: { $0.score > $1.score || ($0.score == $1.score && $0.domains[0] < $1.domains[0]) }) {
            let key = Relations.nameKey(s.name)
            guard !key.isEmpty, var m = merged[key] else { merged[Relations.nameKey(s.name).isEmpty ? s.domains[0] : key] = s; continue }
            m.domains += s.domains
            m.mails += s.mails
            m.youWrote += s.youWrote
            m.yourDecisions += s.yourDecisions
            m.authenticated += s.authenticated
            m.first = [m.first, s.first].compactMap { $0 }.min()
            m.last = [m.last, s.last].compactMap { $0 }.max()
            merged[key] = m
        }
        return Array(merged.values.sorted { $0.score > $1.score || ($0.score == $1.score && $0.name < $1.name) }.prefix(limit))
    }
}

/// What the register and the own server say about one mail (6.3b, ADR-0010 §6) — deterministic,
/// shown in the reader and given to the model. A warning raises caution; "known" lowers it only
/// together with a passing check of the own server (a From line can be forged).
public struct RelationCheck: Sendable, Equatable {
    public enum Server: Sendable, Equatable {
        /// DMARC passed at the own server.
        case passed(String)
        /// The own server's check failed (dmarc=fail, or dkim and spf both fail).
        case failed(String)
        /// The own server checked, neither clearly.
        case neutral(String)
        /// Results are in the mail, but not from the own server: they count for nothing.
        case foreign
        case none

        /// What the own server's results say: DMARC passed, failed (or DKIM and SPF both), or
        /// neither clearly.
        public static func verdict(_ r: AuthResults) -> Server {
            let summary = r.summary ?? ""
            if r.dmarc == "pass" { return .passed(summary) }
            if r.dmarc == "fail" || (r.dkim == "fail" && r.spf == "fail") { return .failed(summary) }
            return .neutral(summary)
        }
    }

    public var senderDomain: String?
    /// The confirmed relation the sender's domain belongs to.
    public var known: Relation?
    /// A relation the mail claims to be (by name or domain) while it comes from elsewhere.
    public var lookAlike: Relation?
    public var server: Server = .none
    /// A first contact at one of the user's public addresses (no mail before, never written to).
    public var firstContactAt: String?

    public var isWarning: Bool {
        if lookAlike != nil { return true }
        if case .failed = server { return true }
        return false
    }

    public var isEmpty: Bool {
        known == nil && lookAlike == nil && firstContactAt == nil && { if case .failed = server { return false }; return true }()
    }

    /// German lines for the reader and the model.
    public var lines: [String] { lines(naming: { $0 }) }

    /// `naming` may replace a relation's name (the model's prompt checks it first).
    public func lines(naming: (String) -> String) -> [String] {
        var out: [String] = []
        if let r = lookAlike, let domain = senderDomain {
            let name = naming(r.name)
            out.append(String(localized: "Gibt sich als „\(name)“ aus, kommt aber von \(domain) – \(name) schreibt von \(r.domains.joined(separator: ", ")).", comment: "look-alike"))
        }
        if let r = known {
            let name = naming(r.name)
            let since = r.since.map { String(localized: " seit \($0.formatted(.dateTime.year()))") } ?? ""
            out.append(r.ended ? String(localized: "Bekannte Beziehung „\(name)“ – beendet \(r.until!.formatted(.dateTime.month().year())); Vertrauen geringer.")
                               : String(localized: "Bekannte Beziehung „\(name)“\(since)."))
        }
        switch server {
        case .passed(let s): if known != nil || lookAlike != nil { out.append(String(localized: "Prüfung deines Servers bestanden (\(s)).")) }
        case .failed(let s): out.append(String(localized: "Prüfung deines Servers fehlgeschlagen (\(s)) – der Absender ist vermutlich gefälscht."))
        case .neutral(let s): if known != nil { out.append(String(localized: "Prüfung deines Servers ohne klares Ergebnis (\(s)).")) }
        case .foreign: if known != nil || lookAlike != nil { out.append(String(localized: "Die Prüfergebnisse in der Mail stammen nicht von deinem Server und zählen nicht.")) }
        case .none: break
        }
        if let address = firstContactAt {
            out.append(String(localized: "Erstkontakt an deine öffentliche Adresse \(address): unaufgefordert. Name oder Firma in der Mail sind kein Echtheitsbeweis – aber auch kein Spam-Beweis."))
        }
        return out
    }
}

extension Relations {
    /// Words of a relation that a look-alike would use: the name as a whole, and the words of its
    /// domains' first labels ("sparkasse-koelnbonn" → sparkasse, koelnbonn). Not single words of
    /// the name: a relation named after a person ("Erika Mustermann") would flag every Erika.
    static func claimTokens(_ r: Relation) -> Set<String> {
        let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
        var tokens: Set<String> = []
        let whole = nameKey(r.name)
        if whole.count >= 5, !claimStopWords.contains(whole) { tokens.insert(whole) }
        for domain in r.domains {
            let label = fold(domain.split(separator: ".").first.map(String.init) ?? "")
            for part in label.split(separator: "-") where part.count >= 5 && !claimStopWords.contains(String(part)) { tokens.insert(String(part)) }
        }
        return tokens
    }

    /// Words too common to tell an organisation by.
    static let claimStopWords: Set<String> = [
        "gmbh", "group", "gruppe", "service", "services", "online", "kundenservice", "support", "deutschland", "germany", "international",
        "newsletter", "konto", "account", "info", "mail", "versand", "shop", "store", "team", "verlag", "consulting", "solutions", "digital",
        "systems", "technology", "technologies", "kunden", "portal", "secure", "security", "login", "update", "noreply",
    ]
}

extension ArchiveReader {
    /// The user's public addresses (bait: the website's contact address), stored as notes with
    /// the subject "public:<address>".
    public func publicAddresses() throws -> [String] {
        try memoryItems(subjectPrefix: "public:").map { String($0.subject.dropFirst("public:".count)) }
    }

    /// The register's and the own server's word on a message.
    public func relationCheck(of messageID: Int64, relations: [Relation]? = nil, servers: [String: Set<String>]? = nil,
                              publicAddresses: [String]? = nil) throws -> RelationCheck {
        var check = RelationCheck()
        guard let row = try db.queryOne("SELECT lower(from_addr), from_name, delivered_to, lower(to_addrs), lower(cc_addrs) FROM messages WHERE id = ?",
                                        [.int(messageID)], { ($0.text(0), $0.text(1), $0.text(2), $0.text(3), $0.text(4)) }) else { return check }
        if let auth = try authentication(of: messageID, servers: servers) {
            if !auth.trusted {
                check.server = .foreign
            } else {
                check.server = .verdict(auth.results)
            }
        }
        guard let address = row.0, let at = address.lastIndex(of: "@") else { return check }
        let domain = LinkCheck.registrableDomain(String(address[address.index(after: at)...]))
        check.senderDomain = domain
        let all = try relations ?? self.relations()
        check.known = all.first { $0.confirmed && $0.domains.contains(domain) }
        if check.known == nil {
            let fold = { (s: String) in s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }
            let nameKey = Relations.nameKey(row.1 ?? "")
            let nameWords = Set(fold(row.1 ?? "").split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            let label = fold(domain.split(separator: ".").first.map(String.init) ?? "")
            check.lookAlike = all.first { r in
                guard r.confirmed, !r.domains.contains(domain) else { return false }
                return Relations.claimTokens(r).contains { token in
                    nameWords.contains(token) || (token.count >= 8 && nameKey.contains(token)) || label.contains(token)
                }
            }
        }
        // a first contact at a public address: nothing from this address before, never written to it
        let publics = try publicAddresses ?? self.publicAddresses()
        if !publics.isEmpty {
            let recipients = Set([row.2, row.3, row.4].compactMap { $0 }.flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
            if let hit = publics.first(where: { recipients.contains($0.lowercased()) }), let profile = try senderProfile(of: messageID),
               profile.mails == 0, profile.youWrote == 0 {
                check.firstContactAt = hit
            }
        }
        return check
    }
}

extension ArchiveReader {
    /// After "Einschätzung korrigieren" (6.4b): other mails from these registrable domains that a
    /// model holds for phishing or spam and the user has not decided — newest first.
    public func modelFlagged(fromDomains domains: Set<String>, excluding: Int64? = nil, limit: Int = 500) throws -> [Int64] {
        guard !domains.isEmpty else { return [] }
        var out: [Int64] = []
        try db.forEach("""
            SELECT m.id, lower(m.from_addr) FROM messages m JOIN classifications c ON c.message_id = m.id
            WHERE m.trashed IS NULL AND c.verdict IS NULL AND c.source IN ('endpoint', 'on-device')
              AND (c.phishing IN ('verdacht', 'ja') OR c.category = 'spam')
            ORDER BY m.date DESC
            """) { r in
            guard out.count < limit, r.int(0) != excluding, let address = r.text(1), let at = address.lastIndex(of: "@") else { return }
            if domains.contains(LinkCheck.registrableDomain(String(address[address.index(after: at)...]))) { out.append(r.int(0)) }
        }
        return out
    }
}

extension ArchiveReader {
    /// What "Einschätzung korrigieren" proposes as the relation for a sender (6.4b): its domain,
    /// and as options the "sister" domains the same sender name wrote from with a passing check
    /// of the own server (TJ: a school writing through two domains of its mail service) and a
    /// Reply-To domain — never freemail or the user's own. An option is pre-selected only with
    /// positive evidence and no warning (review 6 S2: DMARC pass proves a mail came from that
    /// domain, not that the domain belongs to the organisation — a look-alike's owner controls
    /// its DNS). Named like a suggestion: after the sender only when that name stands for most of
    /// the domain's mail and is not generic, else the domain.
    public func proposedRelation(for messageID: Int64, replyTo: String? = nil) throws -> ProposedRelation {
        guard let row = try db.queryOne("SELECT lower(from_addr), from_name FROM messages WHERE id = ?", [.int(messageID)], { ($0.text(0), $0.text(1)) }),
              let address = row.0, let at = address.lastIndex(of: "@") else { return ProposedRelation(name: "", domains: []) }
        let domain = LinkCheck.registrableDomain(String(address[address.index(after: at)...]))
        let servers = Set(try ownAuthServers().values.flatMap { $0 })
        let own = try ownDomains()
        var candidates: [String] = []
        let name = row.1?.trimmingCharacters(in: .whitespaces) ?? ""
        if !name.isEmpty, !Relations.isGeneric(name), !servers.isEmpty {
            let (auth, params) = Self.authenticatedCondition(servers)
            try db.forEach("SELECT DISTINCT lower(m.from_addr) FROM messages m WHERE m.from_name = ? AND \(auth) AND m.trashed IS NULL LIMIT 200",
                           [.text(name)] + params) { r in
                guard let a = r.text(0), let i = a.lastIndex(of: "@") else { return }
                let d = LinkCheck.registrableDomain(String(a[a.index(after: i)...]))
                if d != domain, !candidates.contains(d), candidates.count < 5, !Relations.freemail.contains(d), !own.contains(d) { candidates.append(d) }
            }
        }
        if let reply = replyTo?.lowercased(), let i = reply.lastIndex(of: "@") {
            let d = LinkCheck.registrableDomain(String(reply[reply.index(after: i)...]))
            if d != domain, !candidates.contains(d), !Relations.freemail.contains(d), !own.contains(d) { candidates.append(d) }
        }
        var domains = [ProposedRelation.Domain(domain: domain, mails: try mails(fromDomain: domain), evidence: true,
                                               why: String(localized: "die Domain dieser Mail"))]
        for d in candidates { domains.append(try evidence(for: d, servers: servers)) }
        // the name: the sender's only if it stands for most of the domain's mail
        var total = 0, same = 0
        try db.forEach("SELECT from_name FROM messages WHERE (lower(from_addr) LIKE ? OR lower(from_addr) LIKE ?) AND trashed IS NULL",
                       [.text("%@" + domain), .text("%." + domain)]) { r in
            total += 1
            if r.text(0) == row.1 { same += 1 }
        }
        let usable = !name.isEmpty && !name.contains("@") && !Relations.isGeneric(name) && same * 2 >= total
        return ProposedRelation(name: usable ? String(name.prefix(120)) : domain, domains: domains)
    }

    /// Mails from a registrable domain or its subdomains (never "notpaypal.com" for "paypal.com").
    func mails(fromDomain d: String) throws -> Int {
        Int(try db.queryOne("SELECT count(*) FROM messages WHERE (lower(from_addr) LIKE ? OR lower(from_addr) LIKE ?) AND trashed IS NULL",
                            [.text("%@" + d), .text("%." + d)]) { $0.int(0) } ?? 0)
    }

    /// Positive evidence that a domain is genuine — the user wrote to it, decided on its mails, or
    /// ≥ 2 authenticated transactional mails came from it — and no warning or phishing flag on it.
    func evidence(for d: String, servers: Set<String>) throws -> ProposedRelation.Domain {
        let from = "(lower(m.from_addr) LIKE ? OR lower(m.from_addr) LIKE ?)"
        let p: [SQLValue] = [.text("%@" + d), .text("%." + d)]
        let (auth, authParams) = Self.authenticatedCondition(servers)
        let transactional = Relations.transactional.map { "'\($0)'" }.joined(separator: ",")
        let (mails, decided, authed, warned) = try db.queryOne("""
            SELECT count(*), sum(c.verdict = 'ham' OR (c.source = 'user' AND c.category != 'spam')),
                   sum(\(auth) AND c.category IN (\(transactional))), sum(c.warning IS NOT NULL OR c.phishing IN ('verdacht', 'ja'))
            FROM messages m LEFT JOIN classifications c ON c.message_id = m.id WHERE \(from) AND m.trashed IS NULL
            """, authParams + p) { (Int($0.int(0)), Int($0.optionalInt(1) ?? 0), Int($0.optionalInt(2) ?? 0), Int($0.optionalInt(3) ?? 0)) } ?? (0, 0, 0, 0)
        let sent = "m.id IN (SELECT l.message_id FROM locations l WHERE \(QuerySQL.sentLocation))"
        let recipients = "', ' || lower(coalesce(m.to_addrs, '')) || ', ' || lower(coalesce(m.cc_addrs, '')) || ','"
        let wrote = Int(try db.queryOne("""
            SELECT count(*) FROM messages m WHERE \(sent) AND (instr(\(recipients), '@' || ? || ',') > 0 OR instr(\(recipients), '.' || ? || ',') > 0)
            """, [.text(d), .text(d)]) { $0.int(0) } ?? 0)
        let positive = wrote > 0 || decided > 0 || authed >= 2
        let why: String = warned > 0 ? String(localized: "Warnung oder Phishing-Verdacht an Mails dieser Domain")
            : wrote > 0 ? String(localized: "du hast \(wrote)× dorthin geschrieben")
            : decided > 0 ? String(localized: "\(decided) deiner Entscheidungen")
            : authed >= 2 ? String(localized: "\(authed) echte Transaktionsmails")
            : String(localized: "kein Beleg – nur gleicher Name oder Antwortadresse")
        return ProposedRelation.Domain(domain: d, mails: mails, evidence: positive && warned == 0, why: why)
    }

    /// Mails a model flagged that come from these domains or carry this sender name — the
    /// "alike" ones after a correction.
    public func modelFlagged(fromDomains domains: Set<String>, orName name: String?, excluding: Int64? = nil, limit: Int = 500) throws -> [Int64] {
        var out = Set(try modelFlagged(fromDomains: domains, excluding: excluding, limit: limit))
        if let name, !name.isEmpty, !Relations.isGeneric(name) {
            try db.forEach("""
                SELECT m.id FROM messages m JOIN classifications c ON c.message_id = m.id
                WHERE m.from_name = ? AND m.trashed IS NULL AND c.verdict IS NULL AND c.source IN ('endpoint', 'on-device')
                  AND (c.phishing IN ('verdacht', 'ja') OR c.category = 'spam') LIMIT ?
                """, [.text(name), .int(Int64(limit))]) { r in if r.int(0) != excluding { out.insert(r.int(0)) } }
        }
        return Array(out).sorted(by: >)
    }

    /// The domains the user writes from (sent mail).
    public func ownDomains() throws -> Set<String> {
        var out: Set<String> = []
        try db.forEach("SELECT DISTINCT lower(m.from_addr) FROM messages m WHERE m.id IN (SELECT l.message_id FROM locations l WHERE \(QuerySQL.sentLocation))") { r in
            if let a = r.text(0), let i = a.lastIndex(of: "@") { out.insert(LinkCheck.registrableDomain(String(a[a.index(after: i)...]))) }
        }
        return out
    }
}
