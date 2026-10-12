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

    /// A person's name as a set of words: "Tietjen, Jan" and "Jan Tietjen" alike.
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

    /// Per account, the server that adds `Authentication-Results` to its incoming mail: the
    /// authserv-id of most of the account's mails that carry one (at least half, at least five).
    public func ownAuthServers() throws -> [String: String] {
        var byAccount: [String: [(String, Int)]] = [:]
        try db.forEach("""
            SELECT l.account_id, m.auth_server, count(DISTINCT m.id) FROM messages m JOIN locations l ON l.message_id = m.id
            WHERE m.auth_server IS NOT NULL GROUP BY 1, 2
            """) { r in
            if let account = r.text(0), let server = r.text(1) { byAccount[account, default: []].append((server, Int(r.int(2)))) }
        }
        var out: [String: String] = [:]
        for (account, servers) in byAccount {
            let total = servers.reduce(0) { $0 + $1.1 }
            if let best = servers.max(by: { $0.1 < $1.1 }), best.1 >= 5, best.1 * 2 >= total { out[account] = best.0 }
        }
        return out
    }

    /// The own server's verdict on a message: its results, and whether they come from the server
    /// of an account the message lies in (only then do they count).
    public func authentication(of messageID: Int64, servers: [String: String]? = nil) throws -> (results: AuthResults, trusted: Bool)? {
        let own = try servers ?? ownAuthServers()
        guard let row = try db.queryOne("SELECT auth_server, auth_dkim, auth_spf, auth_dmarc, auth_from FROM messages WHERE id = ?",
                                        [.int(messageID)], { r in
                                            AuthResults(server: r.text(0), dkim: r.text(1), spf: r.text(2), dmarc: r.text(3), fromDomain: r.text(4))
                                        }) ?? nil, row.server != nil || row.summary != nil else { return nil }
        let accounts = try db.query("SELECT DISTINCT account_id FROM locations WHERE message_id = ?", [.int(messageID)]) { $0.text(0) ?? "" }
        let trusted = row.server.map { server in accounts.contains { own[$0] == server } } ?? false
        return (row, trusted)
    }

    /// Relationships the history suggests (ADR-0010 §6): domains with positive evidence — the
    /// user wrote to them, said "kein Spam" or gave a category, or sent authenticated
    /// transactional mail (DMARC pass at the own server). Not freemail, not the user's own
    /// domains, not domains already in a relation (or rejected), not where spam and phishing
    /// outweigh the evidence. Same name → one suggestion with several domains.
    public func relationSuggestions(limit: Int = 200) throws -> [RelationSuggestion] {
        let servers = Set(try ownAuthServers().values)
        let serverList = servers.map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }.joined(separator: ",")
        let authenticated = servers.isEmpty ? "0" : "m.auth_dmarc = 'pass' AND m.auth_server IN (\(serverList))"
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
            """) { r in
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
        let taken = Set(try relations(includeRejected: true).flatMap(\.domains))

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
    public var lines: [String] {
        var out: [String] = []
        if let r = lookAlike, let domain = senderDomain {
            out.append(String(localized: "Gibt sich als „\(r.name)“ aus, kommt aber von \(domain) – \(r.name) schreibt von \(r.domains.joined(separator: ", ")).", comment: "look-alike"))
        }
        if let r = known {
            let since = r.since.map { String(localized: " seit \($0.formatted(.dateTime.year()))") } ?? ""
            out.append(r.ended ? String(localized: "Bekannte Beziehung „\(r.name)“ – beendet \(r.until!.formatted(.dateTime.month().year())); Vertrauen geringer.")
                               : String(localized: "Bekannte Beziehung „\(r.name)“\(since)."))
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
    /// the name: a relation named after a person ("Michelle Schindler") would flag every Michelle.
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
        try memoryItems().filter { $0.subject.hasPrefix("public:") }.map { String($0.subject.dropFirst("public:".count)) }
    }

    /// The register's and the own server's word on a message.
    public func relationCheck(of messageID: Int64, relations: [Relation]? = nil, servers: [String: String]? = nil,
                              publicAddresses: [String]? = nil) throws -> RelationCheck {
        var check = RelationCheck()
        guard let row = try db.queryOne("SELECT lower(from_addr), from_name, delivered_to, lower(to_addrs), lower(cc_addrs) FROM messages WHERE id = ?",
                                        [.int(messageID)], { ($0.text(0), $0.text(1), $0.text(2), $0.text(3), $0.text(4)) }) else { return check }
        if let auth = try authentication(of: messageID, servers: servers) {
            if !auth.trusted {
                check.server = .foreign
            } else {
                let r = auth.results
                let summary = r.summary ?? ""
                if r.dmarc == "pass" { check.server = .passed(summary) }
                else if r.dmarc == "fail" || (r.dkim == "fail" && r.spf == "fail") { check.server = .failed(summary) }
                else { check.server = .neutral(summary) }
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
