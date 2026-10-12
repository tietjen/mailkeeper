import Foundation

/// What a link really points to and whether it looks like a lure (TJ: show the target on hover;
/// 5.6: the model gets these findings for phishing). Deterministic, no network.
public struct LinkCheck: Sendable, Equatable {
    public enum Finding: String, Sendable, Equatable, CaseIterable {
        /// The visible text names another domain than the target.
        case textShowsOtherDomain
        /// The target host is a bare IP address.
        case ipAddress
        /// Internationalised host (xn--): may imitate another name.
        case punycode
        /// A URL shortener: the real target is hidden.
        case shortener
        /// Not http(s)/mailto: javascript:, data:, file: …
        case unusualScheme
        /// User info before the host (`https://paypal.com@evil.example`).
        case credentialsInURL

        public var text: String {
            switch self {
            case .textShowsOtherDomain: String(localized: "Linktext zeigt eine andere Adresse als das Ziel")
            case .ipAddress: String(localized: "Ziel ist eine nackte IP-Adresse")
            case .punycode: String(localized: "Adresse mit internationalen Zeichen (xn--) – kann einen bekannten Namen nachahmen")
            case .shortener: String(localized: "Kurzlink – das eigentliche Ziel ist verborgen")
            case .unusualScheme: String(localized: "ungewöhnliche Link-Art")
            case .credentialsInURL: String(localized: "Adresse mit „@“ vor dem Ziel – täuscht einen anderen Namen vor")
            }
        }
    }

    public var target: String
    public var host: String?
    /// The target's registrable domain ("bank.example" for "login.bank.example").
    public var domain: String?
    /// The domain the visible text names, when it names one.
    public var shownDomain: String?
    public var findings: [Finding]

    public var isSuspicious: Bool { !findings.isEmpty }

    public init(href: String, text: String?) {
        target = href
        let url = URL(string: href.trimmingCharacters(in: .whitespacesAndNewlines))
        let scheme = url?.scheme?.lowercased()
        host = url?.host()?.lowercased()
        domain = host.map(Self.registrableDomain)
        var findings: [Finding] = []
        if let scheme, !["http", "https", "mailto"].contains(scheme) { findings.append(.unusualScheme) }
        if url?.user() != nil, scheme == "http" || scheme == "https" { findings.append(.credentialsInURL) }
        if let host {
            if Self.isIPAddress(host) { findings.append(.ipAddress) }
            if host.split(separator: ".").contains(where: { $0.hasPrefix("xn--") }) { findings.append(.punycode) }
            if let d = domain, Self.shorteners.contains(d) { findings.append(.shortener) }
        }
        shownDomain = text.flatMap(Self.domainNamed(in:))
        if let shown = shownDomain, let d = domain, shown != d, scheme != "mailto" { findings.insert(.textShowsOtherDomain, at: 0) }
        self.findings = findings
    }

    /// A domain-looking token in visible text ("www.paypal.com", "https://paypal.com/login").
    static func domainNamed(in text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty, t.count < 300 else { return nil }
        let pattern = /(?:https?:\/\/)?(?:[a-z0-9-]+\.)+[a-z]{2,24}(?=[\/\s:?#]|$)/
        guard let match = t.firstMatch(of: pattern) else { return nil }
        var token = String(match.output)
        if let r = token.range(of: "://") { token = String(token[r.upperBound...]) }
        // "Datei.pdf" or "v1.2" are not domains: require a known-ish TLD length and a letter label
        guard token.contains("."), !token.hasSuffix(".pdf"), !token.hasSuffix(".png"), !token.hasSuffix(".jpg") else { return nil }
        return registrableDomain(token)
    }

    /// The last two labels, three for common second-level public suffixes (co.uk, com.au …).
    public static func registrableDomain(_ host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        return secondLevel.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }

    static func isIPAddress(_ host: String) -> Bool {
        host.contains(":") || host.split(separator: ".").count == 4 && host.split(separator: ".").allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    static let secondLevel: Set<String> = ["co.uk", "org.uk", "ac.uk", "gov.uk", "com.au", "net.au", "co.jp", "co.nz", "com.br",
                                           "com.tr", "co.at", "or.at", "co.za", "com.cn", "com.mx", "co.in", "com.sg"]
    static let shorteners: Set<String> = ["bit.ly", "tinyurl.com", "t.co", "goo.gl", "ow.ly", "is.gd", "buff.ly", "rebrand.ly",
                                          "cutt.ly", "shorturl.at", "rb.gy", "tiny.cc", "s.id", "t.ly", "lnkd.in"]
}

/// The links of a mail: anchors of the HTML part (target and visible text) and bare URLs in the
/// text — bounded, deduplicated by target. One pass over the bytes, no regex: hostile HTML (an
/// endless run of "<a href=") must not cost more than that. Tags are read the way a browser
/// tokenizes them — attribute names, then values; quotes open a value only after "=" — so an
/// "href=" inside another attribute's value cannot pose as the target (review 5.9 B1).
public enum LinkExtractor {
    public static func links(html: String?, text: String, limit: Int = 40) -> [(href: String, text: String?)] {
        var out: [(String, String?)] = []
        var seen = Set<String>()
        func add(_ href: String, _ shown: String?) {
            // browsers drop tabs and newlines inside a URL ("java\tscript:") and trim the ends
            let h = String(String.UnicodeScalarView(href.unicodeScalars.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }))
                .trimmingCharacters(in: .whitespaces)
            guard !h.isEmpty, !h.hasPrefix("#"), !h.lowercased().hasPrefix("cid:"), h.count < 4_000, out.count < limit,
                  seen.insert(h).inserted else { return }
            out.append((h, shown))
        }
        if let html { anchors(Array(html.utf8.prefix(1 << 20)), add) }
        bareURLs(Array(text.utf8.prefix(1 << 20)), add)
        return out
    }

    private static let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">"), slash = UInt8(ascii: "/"), eq = UInt8(ascii: "=")
    private static let dq = UInt8(ascii: "\""), sq = UInt8(ascii: "'")

    private static func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }
    private static func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 || b == 12 }
    private static func isLetter(_ b: UInt8) -> Bool { (65...90).contains(b) || (97...122).contains(b) }

    /// `<a … href=… …>text</a>`: the first href of the tag (as browsers take it), the visible
    /// text up to 4 KB with tags inside it as spaces. An anchor left open ends at the next one.
    static func anchors(_ b: [UInt8], _ add: (String, String?) -> Void) {
        let n = b.count
        var i = 0
        var open: String?
        var shown: [UInt8] = []
        func finish() {
            if let href = open { add(decodeEntities(href), collapseWhitespace(decodeEntities(String(decoding: shown, as: UTF8.self)))) }
            open = nil
            shown = []
        }
        while i < n {
            guard b[i] == lt, i + 1 < n else {
                if open != nil, shown.count < 4_096 { shown.append(b[i]) }
                i += 1
                continue
            }
            let next = b[i + 1]
            if next == slash || isLetter(next) {
                let closing = next == slash
                var j = i + (closing ? 2 : 1)
                let nameStart = j
                while j < n, !isSpace(b[j]), b[j] != gt, b[j] != slash { j += 1 }
                let isAnchor = j - nameStart == 1 && lower(b[nameStart]) == UInt8(ascii: "a")
                let (end, href) = tag(b, from: j, wantHref: isAnchor && !closing)
                if isAnchor {
                    finish()
                    if !closing, let href { open = href }
                } else if open != nil, shown.count < 4_096 {
                    shown.append(32)
                }
                i = end
            } else {
                if open != nil, shown.count < 4_096 { shown.append(b[i]) }  // "<" as text ("a < b")
                i += 1
            }
        }
        finish()
    }

    /// Reads a tag's attributes from `start` (just after its name) to after its closing ">" —
    /// quoted values may hold ">" — and returns that position and, if asked, the first href.
    static func tag(_ b: [UInt8], from start: Int, wantHref: Bool) -> (end: Int, href: String?) {
        let n = b.count
        var i = start
        var href: String?
        while i < n {
            while i < n, isSpace(b[i]) || b[i] == slash { i += 1 }
            guard i < n else { break }
            if b[i] == gt { return (i + 1, href) }
            // attribute name: anything up to space, "=", ">" or "/" (a stray quote belongs to the name)
            let nameStart = i
            i += 1
            while i < n, !isSpace(b[i]), b[i] != eq, b[i] != gt, b[i] != slash { i += 1 }
            let nameEnd = i
            while i < n, isSpace(b[i]) { i += 1 }
            var value: Range<Int>?
            if i < n, b[i] == eq {
                i += 1
                while i < n, isSpace(b[i]) { i += 1 }
                if i < n, b[i] == dq || b[i] == sq {
                    let quote = b[i]
                    let valueStart = i + 1
                    i = valueStart
                    while i < n, b[i] != quote { i += 1 }
                    value = valueStart..<i
                    if i < n { i += 1 }
                } else {
                    let valueStart = i
                    while i < n, !isSpace(b[i]), b[i] != gt { i += 1 }
                    value = valueStart..<i
                }
            }
            if wantHref, href == nil, nameEnd - nameStart == 4,
               lower(b[nameStart]) == UInt8(ascii: "h"), lower(b[nameStart + 1]) == UInt8(ascii: "r"),
               lower(b[nameStart + 2]) == UInt8(ascii: "e"), lower(b[nameStart + 3]) == UInt8(ascii: "f") {
                href = value.map { String(decoding: b[$0], as: UTF8.self) } ?? ""
            }
        }
        return (n, href)
    }

    /// `http://` or `https://` up to whitespace, quotes or brackets.
    static func bareURLs(_ b: [UInt8], _ add: (String, String?) -> Void) {
        let http = Array("http".utf8)
        let n = b.count
        var i = 0
        while i + 8 < n {
            guard lower(b[i]) == http[0], lower(b[i + 1]) == http[1], lower(b[i + 2]) == http[2], lower(b[i + 3]) == http[3] else { i += 1; continue }
            var j = i + 4
            if j < n, lower(b[j]) == UInt8(ascii: "s") { j += 1 }
            guard j + 3 <= n, b[j] == UInt8(ascii: ":"), b[j + 1] == UInt8(ascii: "/"), b[j + 2] == UInt8(ascii: "/") else { i += 1; continue }
            var k = j + 3
            let stop: Set<UInt8> = [32, 9, 10, 13, lt, gt, UInt8(ascii: "\""), UInt8(ascii: "'"), UInt8(ascii: ")"), UInt8(ascii: "]")]
            while k < n, k - i < 2_000, !stop.contains(b[k]) { k += 1 }
            if k > j + 3 { add(String(decoding: b[i..<k], as: UTF8.self), nil) }
            i = k
        }
    }

    /// Character references as a browser resolves them in an attribute or text: the common named
    /// ones and numeric ones (`javascript&#58;` is `javascript:`). One pass; unknown ones stay.
    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let named: [String: String] = ["amp": "&", "quot": "\"", "apos": "'", "lt": "<", "gt": ">", "nbsp": " ",
                                       "colon": ":", "sol": "/", "period": ".", "commat": "@", "tab": "\t", "newline": "\n"]
        var out = ""
        out.reserveCapacity(s.utf8.count)
        var rest = Substring(s)
        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest[rest.index(after: amp)...]
            if let semi = after.prefix(12).firstIndex(of: ";") {
                let name = after[..<semi]
                var replacement: String?
                if name.hasPrefix("#x") || name.hasPrefix("#X") {
                    replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if name.hasPrefix("#") {
                    replacement = UInt32(name.dropFirst(1)).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    replacement = named[String(name).lowercased()]
                }
                if let replacement {
                    out += replacement
                    rest = after[after.index(after: semi)...]
                    continue
                }
            }
            out += "&"
            rest = after
        }
        out += rest
        return out
    }
}
