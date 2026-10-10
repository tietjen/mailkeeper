import Foundation

/// HTML → plain text for indexing and snippets. A linear scanner, not a renderer: drops
/// script/style/head, turns block elements into line breaks, decodes entities. Never executes
/// or loads anything (rendering for the reader happens in a locked-down WKWebView).
enum HTMLText {
    private static let blockTags: Set<String> = [
        "br", "p", "div", "tr", "li", "ul", "ol", "table", "blockquote", "hr", "section", "article",
        "h1", "h2", "h3", "h4", "h5", "h6", "pre", "header", "footer", "dt", "dd",
    ]
    private static let skipTags: Set<String> = ["script", "style", "head", "title", "noscript", "template", "svg"]
    private static let entities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "shy": "", "zwnj": "", "zwj": "",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "eacute": "é", "egrave": "è", "agrave": "à", "aacute": "á", "ccedil": "ç", "ntilde": "ñ",
        "euro": "€", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "middot": "·", "bull": "•",
        "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»",
        "bdquo": "„", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "sbquo": "‚", "times": "×",
    ]

    static func toText(_ html: String, limit: Int = 1_000_000) -> String {
        let s = Array(html.unicodeScalars.prefix(limit * 4))
        var out = String.UnicodeScalarView()
        var i = 0
        while i < s.count {
            let c = s[i]
            if c == "<" {
                // comment
                if i + 3 < s.count, s[i + 1] == "!", s[i + 2] == "-", s[i + 3] == "-" {
                    i = indexAfter("-->", in: s, from: i + 4)
                    continue
                }
                var j = i + 1
                var closing = false
                if j < s.count, s[j] == "/" { closing = true; j += 1 }
                var name = ""
                while j < s.count, s[j].properties.isAlphabetic || ("0"..."9").contains(s[j]) {
                    name.unicodeScalars.append(s[j])
                    j += 1
                }
                name = name.lowercased()
                let tagEnd = indexAfter(">", in: s, from: j)
                if !closing, skipTags.contains(name) {
                    i = indexAfter("</\(name)", in: s, from: tagEnd, caseInsensitive: true)
                    i = indexAfter(">", in: s, from: i)
                    continue
                }
                if blockTags.contains(name) { out.append("\n") }
                else if name == "td" || name == "th" { out.append(" ") }
                i = tagEnd
                continue
            }
            if c == "&" {
                var j = i + 1
                var entity = ""
                while j < s.count, j - i <= 10, s[j] != ";", s[j] != " ", s[j] != "&", s[j] != "<" {
                    entity.unicodeScalars.append(s[j])
                    j += 1
                }
                if j < s.count, s[j] == ";", let decoded = decodeEntity(entity) {
                    out.append(contentsOf: decoded.unicodeScalars)
                    i = j + 1
                    continue
                }
            }
            out.append(c)
            i += 1
        }
        return tidy(String(out))
    }

    private static func decodeEntity(_ e: String) -> String? {
        if e.hasPrefix("#") {
            let body = e.dropFirst()
            let value = body.first == "x" || body.first == "X" ? UInt32(body.dropFirst(), radix: 16) : UInt32(body)
            guard let v = value, let scalar = Unicode.Scalar(v) else { return nil }
            return String(Character(scalar))
        }
        return entities[e]
    }

    private static func indexAfter(_ needle: String, in s: [Unicode.Scalar], from: Int, caseInsensitive: Bool = false) -> Int {
        let n = Array(needle.unicodeScalars)
        guard !n.isEmpty, from < s.count else { return s.count }
        var i = from
        while i + n.count <= s.count {
            var match = true
            for k in 0..<n.count {
                let a = s[i + k], b = n[k]
                if caseInsensitive ? (a.properties.lowercaseMapping != b.properties.lowercaseMapping) : (a != b) {
                    match = false
                    break
                }
            }
            if match { return i + n.count }
            i += 1
        }
        return s.count
    }

    /// Collapse runs of spaces within lines, trim lines, at most one empty line in a row.
    static func tidy(_ s: String) -> String {
        var lines: [String] = []
        var emptyRun = 0
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = collapseWhitespace(String(raw))
            if line.isEmpty {
                emptyRun += 1
                if emptyRun > 1 || lines.isEmpty { continue }
            } else {
                emptyRun = 0
            }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines.joined(separator: "\n")
    }
}
