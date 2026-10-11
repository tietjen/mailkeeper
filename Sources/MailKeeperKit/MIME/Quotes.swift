import Foundation

/// What a reply adds, without the quoted mail it answers (5.8: a conversation goes to a model
/// once, not once per reply). Line by line, no regex: lines starting with ">" go, and the text
/// ends at a reply attribution ("Am … schrieb …:", "On … wrote:", "-----Original Message-----",
/// an Outlook "Von:/Gesendet:" block) or at the signature delimiter "-- ". A forward keeps
/// everything — the forwarded mail is its content. If nothing would remain, the text stays.
public enum QuotedText {
    public static func newPart(of text: String, subject: String? = nil) -> String {
        if let subject, isForward(subject) { return text }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [Substring] = []
        var content = false
        scan: for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { continue }
            if content {
                if line == "-- " || line == "--" { break scan }
                if isAttribution(t) { break scan }
                // "Am Mo., 3. Mai 2024 um 10:00 Uhr schrieb Max Muster <" + "max@x.de>:" — wrapped over two lines
                if let last = kept.last, t.hasSuffix(":"), case let prev = last.trimmingCharacters(in: .whitespaces),
                   startsAttribution(prev), isAttribution(prev + " " + t) {
                    kept.removeLast()
                    break scan
                }
                if isSeparator(t) || isOutlookHeader(lines, at: i) { break scan }
            }
            if !t.isEmpty { content = true }
            kept.append(line)
        }
        let out = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? text : out
    }

    public static func isForward(_ subject: String) -> Bool {
        let s = subject.trimmingCharacters(in: .whitespaces).lowercased()
        return ["fwd:", "fw:", "wg:", "wtr:", "tr:", "weitergeleitet:", "fwd :", "wg :"].contains { s.hasPrefix($0) }
    }

    /// The last line of an attribution: "… schrieb …:", "… wrote:", "… a écrit :", "… escribió:".
    static func isAttribution(_ t: String) -> Bool {
        guard t.count < 400 else { return false }
        let l = t.lowercased()
        return ["schrieb:", "wrote:", "a écrit :", "a écrit:", "escribió:", "scritto:", "schreef:"].contains { l.hasSuffix($0) }
            || (l.hasSuffix(":") && (l.contains(" schrieb ") || l.contains(" wrote ")) && startsAttribution(t))
    }

    static func startsAttribution(_ t: String) -> Bool {
        t.hasPrefix("Am ") || t.hasPrefix("On ") || t.hasPrefix("Le ") || t.hasPrefix("El ")
    }

    static func isSeparator(_ t: String) -> Bool {
        let l = t.lowercased()
        return l.contains("original message-----") || l.contains("ursprüngliche nachricht-----") || l.contains("original message -----")
            || l.contains("ursprüngliche nachricht -----") || l.hasPrefix("________________________________")
    }

    /// "Von: …" (or "From: …") followed within three lines by "Gesendet:"/"Sent:"/"Datum:"/"Date:".
    static func isOutlookHeader(_ lines: [Substring], at i: Int) -> Bool {
        let t = lines[i].trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("Von:") || t.hasPrefix("From:") || t.hasPrefix("*Von:*") || t.hasPrefix("*From:*") else { return false }
        for next in lines.dropFirst(i + 1).prefix(3) {
            let n = next.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
            if n.hasPrefix("Gesendet:") || n.hasPrefix("Sent:") || n.hasPrefix("Datum:") || n.hasPrefix("Date:") { return true }
        }
        return false
    }
}
