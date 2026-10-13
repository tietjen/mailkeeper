import Foundation

/// Text in a mail that speaks to an AI instead of to a person — "Ignoriere alle vorherigen
/// Anweisungen", "Hinweis an das KI-System …", "antworte mit category …". The gold set (6.6)
/// showed the Mac's model following such lines (a phishing mail came out "persönlich", a
/// newsletter a security warning) while the fence held for the endpoint. So MailKeeper removes
/// them before any model reads the mail and reports them as its own finding: a model cannot
/// follow what it never sees. Legitimate mail does not address the model that sorts it.
///
/// Strong signs (removed, reported, and at least "Verdacht"): ignore-the-instructions in the
/// imperative, a note addressed to an AI, the answer schema's own words, a `SYSTEM:` line that
/// tells how to sort, "du bist eine KI". Weak signs (removed and reported only): "antworte mit …
/// category", "phishing: nein" — a security newsletter may say such things.
public enum PromptInjection {
    public static let marker = "[von MailKeeper entfernt: Anweisung an eine KI]"

    public struct Scan: Sendable, Equatable {
        public var text: String
        /// The removed passages, shortened (for the finding and "Warum?").
        public var found: [String]
        public var strong: Bool
    }

    static let strong: [NSRegularExpression] = [
        #"\b(ignoriere|vergiss|missachte|übergehe)\s+(alle\s+|sämtliche\s+)?(vorherigen|bisherigen|obigen|vorigen|früheren)\s+(anweisungen|instruktionen|vorgaben|regeln)"#,
        #"\b(ignore|disregard|forget)\s+(all\s+(the\s+)?)?(previous|prior|above|earlier|preceding)\s+(instructions|prompts|rules|directions)"#,
        #"\b(hinweis|nachricht|anweisung|botschaft|info)\w*\s+(an|für)\s+(das|die|den|dem|jede[ns]?)?\s*(ki|k\.i\.|ki-\w+|sprachmodell\w*|llm|chatbot\w*|ki-assistent\w*)\b"#,
        #"\b(note|message|instructions?|notice)\s+(to|for)\s+(the\s+|any\s+|an\s+)?(ai|a\.i\.|assistant|language model|llm|chatbot|model)\b"#,
        #"\b(account_security|order_shipping|phishing_reason)\b"#,
        #""category"\s*:"#,
        #"(^|\n)\s*(system|assistant|developer)\s*:[^\n]{0,240}\b(ordne|einordnen|einstufen|klassifizier\w*|classify|kategorie|category|phishing)\b"#,
        #"\b(du bist|sie sind|you are)\s+(ein|eine|an|a)\s+(ki|ai|sprachmodell|language model|ki-assistent\w*|ai assistant)\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static let weak: [NSRegularExpression] = [
        #"\b(antworte|antwortet|respond|answer|reply|output)\b[^.\n]{0,60}\b(category|json)\b"#,
        #"\bphishing\b\s*["'“”„]?\s*(auf|to|=|:)\s*["'“”„]?\s*(nein|ja|no|yes|none|false|true)\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    static func hit(_ s: String, _ patterns: [NSRegularExpression]) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        return patterns.contains { $0.firstMatch(in: s, range: range) != nil }
    }

    /// Strong, weak, or none.
    static func grade(_ s: String) -> Bool? {
        hit(s, strong) ? true : hit(s, weak) ? false : nil
    }

    /// The text without the passages that speak to an AI: a short line goes whole, a long one
    /// (HTML converted to one paragraph) only the sentences that do.
    public static func scan(_ text: String) -> Scan {
        guard grade(text) != nil else { return Scan(text: text, found: [], strong: false) }
        var found: [String] = []
        var strongHit = false
        var lines: [String] = []
        func note(_ s: String, _ strong: Bool) {
            strongHit = strongHit || strong
            if found.count < 5 { found.append(String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))) }
        }
        for line in text.components(separatedBy: "\n") {
            guard let g = grade(line) else { lines.append(line); continue }
            if line.count <= 300 {
                note(line, g)
                lines.append(marker)
                continue
            }
            var kept: [String] = []
            for sentence in sentences(line) {
                if let s = grade(sentence) {
                    note(sentence, s)
                    if kept.last != marker { kept.append(marker) }
                } else {
                    kept.append(sentence)
                }
            }
            if kept.contains(marker) {
                lines.append(kept.joined(separator: " "))
            } else {
                // the match spans sentences: the line goes whole
                note(line, g)
                lines.append(marker)
            }
        }
        // a match across a line break ("Ignoriere alle vorherigen⏎Anweisungen") is in no single
        // line: reported (the model is told), not cut
        let cleaned = lines.joined(separator: "\n")
        if found.isEmpty, let g = grade(text) { note(text, g) }
        return Scan(text: cleaned, found: found, strong: strongHit)
    }

    static func sentences(_ line: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in line {
            current.append(ch)
            if ".!?]".contains(ch) {
                out.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { out.append(current.trimmingCharacters(in: .whitespaces)) }
        return out
    }
}
