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
/// text — bounded, deduplicated by target. A linear byte scanner, no regex: hostile HTML (an
/// endless run of "<a href=") must not cost more than a pass over the bytes.
public enum LinkExtractor {
    public static func links(html: String?, text: String, limit: Int = 40) -> [(href: String, text: String?)] {
        var out: [(String, String?)] = []
        var seen = Set<String>()
        func add(_ href: String, _ shown: String?) {
            let h = href.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !h.isEmpty, !h.hasPrefix("#"), !h.lowercased().hasPrefix("cid:"), h.count < 4_000, out.count < limit,
                  seen.insert(h).inserted else { return }
            out.append((h, shown))
        }
        if let html { anchors(Array(html.utf8.prefix(1 << 20)), add) }
        bareURLs(Array(text.utf8.prefix(1 << 20)), add)
        return out
    }

    private static let lt = UInt8(ascii: "<"), gt = UInt8(ascii: ">")

    private static func lower(_ b: UInt8) -> UInt8 { b >= 65 && b <= 90 ? b + 32 : b }
    private static func isSpace(_ b: UInt8) -> Bool { b == 32 || b == 9 || b == 10 || b == 13 || b == 12 }

    /// `<a … href=… …>text</a>`: the tag up to 4 KB, the text up to 4 KB, tags inside the text dropped.
    static func anchors(_ b: [UInt8], _ add: (String, String?) -> Void) {
        let n = b.count
        var i = 0
        while i + 2 < n {
            guard b[i] == lt, lower(b[i + 1]) == UInt8(ascii: "a"), isSpace(b[i + 2]) else { i += 1; continue }
            var end = i + 2
            let tagLimit = min(n, i + 4_096)
            while end < tagLimit, b[end] != gt { end += 1 }
            guard end < tagLimit else { i += 2; continue }  // no tag end nearby: not a usable anchor
            guard let href = attribute("href", in: b[(i + 2)..<end]) else { i = end + 1; continue }
            var textEnd = end + 1
            let textLimit = min(n, end + 1 + 4_096)
            while textEnd + 2 < textLimit,
                  !(b[textEnd] == lt && b[textEnd + 1] == UInt8(ascii: "/") && lower(b[textEnd + 2]) == UInt8(ascii: "a")) {
                textEnd += 1
            }
            let shown = stripTags(b[(end + 1)..<min(textEnd, textLimit)])
            add(decodeEntities(href), collapseWhitespace(decodeEntities(shown)))
            i = max(textEnd, end + 1)
        }
    }

    /// The value of one attribute in a tag's bytes (quoted or not), case-insensitive name.
    static func attribute(_ name: String, in tag: ArraySlice<UInt8>) -> String? {
        let key = Array(name.utf8)
        var i = tag.startIndex
        while i + key.count < tag.endIndex {
            let before = i == tag.startIndex ? UInt8(32) : tag[i - 1]
            if isSpace(before) || before == UInt8(ascii: "\"") || before == UInt8(ascii: "'"),
               (0..<key.count).allSatisfy({ lower(tag[i + $0]) == key[$0] }) {
                var j = i + key.count
                while j < tag.endIndex, isSpace(tag[j]) { j += 1 }
                if j < tag.endIndex, tag[j] == UInt8(ascii: "=") {
                    j += 1
                    while j < tag.endIndex, isSpace(tag[j]) { j += 1 }
                    guard j < tag.endIndex else { return nil }
                    let quote = tag[j]
                    if quote == UInt8(ascii: "\"") || quote == UInt8(ascii: "'") {
                        var k = j + 1
                        while k < tag.endIndex, tag[k] != quote { k += 1 }
                        return String(decoding: tag[(j + 1)..<k], as: UTF8.self)
                    }
                    var k = j
                    while k < tag.endIndex, !isSpace(tag[k]), tag[k] != gt { k += 1 }
                    return String(decoding: tag[j..<k], as: UTF8.self)
                }
            }
            i += 1
        }
        return nil
    }

    static func stripTags(_ b: ArraySlice<UInt8>) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var inTag = false
        for c in b {
            if c == lt { inTag = true; out.append(32); continue }
            if c == gt { inTag = false; continue }
            if !inTag { out.append(c) }
        }
        return String(decoding: out, as: UTF8.self)
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

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        return s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}
