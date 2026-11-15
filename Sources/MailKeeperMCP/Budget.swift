import Foundation

/// Token budgets for `fetch` (standard v1 §1): about 4 characters per token; with keywords the
/// best paragraphs, in document order, else the text from the front.
public enum Budget {
    public static let charsPerToken = 4
    public static let defaultTokens = 4_000
    public static let tokenRange = 200...20_000

    /// `keywords`: comma separated. Returns the text and whether something was left out.
    public static func select(_ text: String, maxChars: Int, keywords: String?) -> (text: String, truncated: Bool) {
        guard text.count > maxChars else { return (text, false) }
        let words = (keywords ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }.prefix(20)
        guard !words.isEmpty else { return (cut(text, maxChars), true) }
        let paragraphs = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .newlines) }.filter { !$0.isEmpty }
        let scored = paragraphs.enumerated().map { (index: $0.offset, score: score($0.element.lowercased(), Array(words)), text: $0.element) }
        var chosen = Set<Int>()
        var used = 0
        for p in scored.filter({ $0.score > 0 }).sorted(by: { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }) {
            let cost = p.text.count + 7
            if used + cost > maxChars { continue }
            chosen.insert(p.index)
            used += cost
        }
        if chosen.isEmpty { return (cut(text, maxChars), true) }  // no paragraph names a keyword
        var out: [String] = []
        var last = -1
        for p in scored where chosen.contains(p.index) {
            if p.index != last + 1 { out.append("[…]") }
            out.append(p.text)
            last = p.index
        }
        if last != paragraphs.count - 1 { out.append("[…]") }
        return (out.joined(separator: "\n\n"), true)
    }

    static func score(_ paragraph: String, _ words: [String]) -> Int {
        words.reduce(0) { total, word in
            var count = 0
            var range = paragraph.startIndex..<paragraph.endIndex
            while let found = paragraph.range(of: word, range: range) {
                count += 1
                range = found.upperBound..<paragraph.endIndex
            }
            return total + count
        }
    }

    static func cut(_ text: String, _ maxChars: Int) -> String {
        String(text.prefix(max(0, maxChars - 4))) + " […]"
    }
}
