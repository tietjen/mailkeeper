import Foundation

/// Text normalisation shared by indexing and querying. FTS5's `unicode61 remove_diacritics 2`
/// folds case and diacritics (ü→u) but leaves ß alone (spike S4), so ß→ss happens here.
public enum SearchText {
    public static func normalize(_ s: String) -> String {
        guard s.contains("ß") || s.contains("ẞ") else { return s }
        return s.replacingOccurrences(of: "ß", with: "ss").replacingOccurrences(of: "ẞ", with: "SS")
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
