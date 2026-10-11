import Foundation

/// A filter the reader offers for one of a mail's attributes (TJ: click a sender, date, folder
/// in the reader to filter by it). `query` is ADR-0008 text, ready for the search field.
public struct FilterOption: Sendable, Hashable, Identifiable {
    public var title: String
    public var query: String
    public var id: String { query }

    public init(title: String, query: String) {
        self.title = title
        self.query = query
    }

    /// The same filter negated, for "Ausschließen".
    public var excluded: String { query.contains(" ") ? "-(\(query))" : "-" + query }
}

/// The filters a mail's attributes lead to. Each one matches the mail it came from (tested).
public enum MessageFilters {
    /// A sender: exactly this address, everyone at its domain, everyone using this name.
    public static func sender(_ a: MailAddress) -> [FilterOption] {
        var out = [FilterOption(title: String(localized: "Absender \(a.address)"), query: "sender:" + QueryParser.quote(a.address))]
        if let at = a.address.lastIndex(of: "@"), a.address.firstIndex(of: "@") == at {
            let domain = String(a.address[a.address.index(after: at)...])
            if !domain.isEmpty { out.append(FilterOption(title: String(localized: "Domain \(domain)"), query: "domain:" + QueryParser.quote(domain))) }
        }
        if let name = a.name?.trimmingCharacters(in: .whitespaces), name.contains(where: { $0.isLetter || $0.isNumber }) {
            out.append(FilterOption(title: String(localized: "Name „\(name)“"), query: "from:\"" + name.replacingOccurrences(of: "\"", with: "") + "\""))
        }
        return out
    }

    /// A recipient (To or Cc): words of the address in the recipient field.
    public static func recipient(_ a: MailAddress) -> [FilterOption] {
        [FilterOption(title: String(localized: "Empfänger \(a.address)"), query: "to:\"" + a.address.replacingOccurrences(of: "\"", with: "") + "\"")]
    }

    /// A date: that day, month and year, and from or before that day (local calendar).
    public static func date(_ d: Date, calendar: Calendar = .current) -> [FilterOption] {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        guard let y = c.year, let m = c.month, let day = c.day else { return [] }
        let dayText = String(format: "%04d-%02d-%02d", y, m, day), monthText = String(format: "%04d-%02d", y, m)
        return [
            FilterOption(title: String(localized: "An diesem Tag"), query: "date:" + dayText),
            FilterOption(title: String(localized: "In diesem Monat"), query: "date:" + monthText),
            FilterOption(title: String(localized: "In diesem Jahr"), query: "date:\(y)"),
            FilterOption(title: String(localized: "Ab diesem Tag"), query: "after:" + dayText),
            FilterOption(title: String(localized: "Bis zu diesem Tag"), query: "until:" + dayText),
        ]
    }

    /// A place: this folder of this account, or the whole account.
    public static func place(account: String, mailbox: String) -> [FilterOption] {
        [
            FilterOption(title: String(localized: "Ordner \(mailbox) (\(account))"),
                         query: "account:" + QueryParser.quote(account) + " folder:" + QueryParser.quote(mailbox)),
            FilterOption(title: String(localized: "Konto \(account)"), query: "account:" + QueryParser.quote(account)),
        ]
    }

    public static func list(_ id: String) -> [FilterOption] {
        [FilterOption(title: String(localized: "Liste \(id)"), query: "listid:" + QueryParser.quote(id))]
    }

    /// The subject without reply/forward prefixes, as a phrase.
    public static func subject(_ s: String) -> [FilterOption] {
        let core = baseSubject(s)
        guard core.contains(where: { $0.isLetter || $0.isNumber }) else { return [] }
        let short = core.count > 80 ? String(core.prefix(80)) : core
        return [FilterOption(title: String(localized: "Betreff „\(short)“"), query: "subject:\"" + short.replacingOccurrences(of: "\"", with: "") + "\"")]
    }

    /// "Re: AW: Fwd: [Liste] Thema" → "[Liste] Thema"
    static func baseSubject(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        let prefixes = ["re:", "aw:", "wg:", "fw:", "fwd:", "antw:", "sv:", "vs:"]
        var changed = true
        while changed {
            changed = false
            for p in prefixes where t.lowercased().hasPrefix(p) {
                t = String(t.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return t
    }
}
