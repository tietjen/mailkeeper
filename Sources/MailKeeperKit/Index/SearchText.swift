import Foundation

/// Text normalisation shared by indexing and querying. FTS5's `unicode61 remove_diacritics 2`
/// folds case and diacritics (ü→u) but leaves ß alone (spike S4), so ß→ss happens here.
public enum SearchText {
    public static func normalize(_ s: String) -> String {
        guard s.contains("ß") || s.contains("ẞ") else { return s }
        return s.replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "ẞ", with: "SS")
    }

    /// User input → FTS5 MATCH expression. Every term is quoted (no FTS syntax injection);
    /// German spelling variants are OR-ed in both directions (Mueller ↔ Müller); the last term
    /// matches as prefix while typing. Returns nil for input without searchable terms.
    public static func ftsQuery(_ input: String, prefixLast: Bool = true) -> String? {
        let terms = input
            .split(whereSeparator: { $0.isWhitespace })
            .map { normalize(String($0)).replacingOccurrences(of: "\"", with: "") }
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        guard !terms.isEmpty else { return nil }
        return terms.enumerated().map { n, term in
            let prefix = prefixLast && n == terms.count - 1 && !input.hasSuffix(" ")
            let variants = spellingVariants(term).map { "\"\($0)\"" + (prefix ? "*" : "") }
            return variants.count == 1 ? variants[0] : "(" + variants.joined(separator: " OR ") + ")"
        }.joined(separator: " ")
    }

    static func spellingVariants(_ term: String) -> [String] {
        var out = [term]
        let lower = term.lowercased()
        let pairs = [("ae", "ä"), ("oe", "ö"), ("ue", "ü")]
        if pairs.contains(where: { lower.contains($0.0) }) {
            var v = lower
            for (a, b) in pairs { v = v.replacingOccurrences(of: a, with: b) }
            out.append(v)
        }
        if pairs.contains(where: { lower.contains($0.1) }) {
            var v = lower
            for (a, b) in pairs { v = v.replacingOccurrences(of: b, with: a) }
            out.append(v)
        }
        return out
    }

    /// First ~240 characters of readable text, skipping quoted reply lines.
    static func snippet(_ text: String) -> String {
        var out = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix(">") { continue }
            if !out.isEmpty { out += " " }
            out += t
            if out.count >= 240 { break }
        }
        return String(collapseWhitespace(out).prefix(240))
    }
}
