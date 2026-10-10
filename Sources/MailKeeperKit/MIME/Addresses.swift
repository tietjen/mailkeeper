import Foundation

public struct MailAddress: Sendable, Hashable, Codable {
    public var name: String?
    /// Lowercased addr-spec (`local@domain`); may lack "@" for odd legacy values.
    public var address: String

    public init(name: String?, address: String) {
        self.name = name
        self.address = address
    }

    public var display: String {
        if let name, !name.isEmpty { return "\(name) <\(address)>" }
        return address
    }
}

/// RFC 5322 address lists, tolerant: display names with quotes, commas and encoded words,
/// comments, groups (`team: a@x, b@y;`), route addresses, bare addresses.
enum AddressParser {
    static func parse(_ raw: String?) -> [MailAddress] {
        guard let raw, !raw.isEmpty else { return [] }
        return splitMailboxes(raw).compactMap(parseMailbox)
    }

    private static func splitMailboxes(_ s: String) -> [String] {
        var chunks: [String] = []
        var cur = ""
        var inQuote = false, escape = false
        var angle = 0, comment = 0
        for ch in s {
            if escape { cur.append(ch); escape = false; continue }
            if inQuote {
                if ch == "\\" { escape = true }
                if ch == "\"" { inQuote = false }
                cur.append(ch)
                continue
            }
            if comment > 0 {
                if ch == "(" { comment += 1 } else if ch == ")" { comment -= 1 }
                cur.append(ch)
                continue
            }
            switch ch {
            case "\"": inQuote = true; cur.append(ch)
            case "(": comment += 1; cur.append(ch)
            case "<": angle += 1; cur.append(ch)
            case ">": angle = max(0, angle - 1); cur.append(ch)
            case "," where angle == 0, ";" where angle == 0:
                chunks.append(cur)
                cur = ""
            case ":" where angle == 0:
                cur = ""  // group display name ends here; its members follow
            default: cur.append(ch)
            }
        }
        chunks.append(cur)
        return chunks
    }

    private static func parseMailbox(_ chunk: String) -> MailAddress? {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let lt = lastUnquoted("<", in: trimmed), let gt = trimmed[lt...].firstIndex(of: ">") {
            var addr = String(trimmed[trimmed.index(after: lt)..<gt]).trimmingCharacters(in: .whitespaces)
            if addr.hasPrefix("@"), let colon = addr.firstIndex(of: ":") {  // obsolete route
                addr = String(addr[addr.index(after: colon)...])
            }
            let name = cleanName(String(trimmed[..<lt]))
            guard !addr.isEmpty else { return name.map { MailAddress(name: $0, address: "") } }
            return MailAddress(name: name, address: addr.lowercased())
        }
        let (rest, comments) = stripComments(trimmed)
        let addr = rest.trimmingCharacters(in: .whitespaces)
        guard !addr.isEmpty, !addr.contains(" ") || addr.contains("@") else { return nil }
        let name = comments.first.flatMap { cleanName($0) }
        return MailAddress(name: name, address: addr.replacingOccurrences(of: " ", with: "").lowercased())
    }

    private static func lastUnquoted(_ target: Character, in s: String) -> String.Index? {
        var inQuote = false, escape = false
        var found: String.Index?
        var i = s.startIndex
        while i < s.endIndex {
            let ch = s[i]
            if escape { escape = false } else if ch == "\\" && inQuote { escape = true }
            else if ch == "\"" { inQuote.toggle() }
            else if ch == target && !inQuote { found = i }
            i = s.index(after: i)
        }
        return found
    }

    private static func stripComments(_ s: String) -> (String, [String]) {
        var out = "", current = "", comments: [String] = []
        var depth = 0
        for ch in s {
            if ch == "(" {
                if depth > 0 { current.append(ch) }
                depth += 1
            } else if ch == ")" && depth > 0 {
                depth -= 1
                if depth == 0 { comments.append(current); current = "" } else { current.append(ch) }
            } else if depth > 0 {
                current.append(ch)
            } else {
                out.append(ch)
            }
        }
        return (out, comments)
    }

    private static func cleanName(_ raw: String) -> String? {
        let (noComments, _) = stripComments(raw)
        var s = noComments.trimmingCharacters(in: .whitespacesAndNewlines)
        // Decode encoded words before unquoting: quoted encoded words are common (if invalid).
        if s.hasPrefix("\"") {
            s = ParameterizedValue.unquote(s)
        } else {
            s = s.replacingOccurrences(of: "\"", with: "")
        }
        s = collapseWhitespace(EncodedWords.decode(s))
        return s.isEmpty ? nil : s
    }
}

/// Message-ID style tokens `<…>`.
enum MessageIDs {
    static func all(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        var out: [String] = []
        var cur: String?
        for ch in raw {
            if ch == "<" { cur = "" }
            else if ch == ">", let c = cur {
                let t = c.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, !t.contains(" ") { out.append("<\(t)>") }
                cur = nil
            } else if cur != nil { cur!.append(ch) }
        }
        return out
    }

    /// The first plausible `<…>` token, or a bare token when a sender omitted the brackets.
    /// Degenerate ids (`<>`, `<unknown>`, `<1>`) count as missing: treated as identity they
    /// would merge unrelated mails.
    static func first(_ raw: String?) -> String? {
        if let id = all(raw).first(where: isPlausible) { return id }
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty,
              !t.contains(" "), !t.contains("<"), !t.contains(">") else { return nil }
        let id = "<\(t)>"
        return isPlausible(id) ? id : nil
    }

    static func isPlausible(_ id: String) -> Bool {
        let inner = id.dropFirst().dropLast()
        guard inner.count >= 4, inner.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return !["unknown", "none", "null", "nil", "undefined", "<none>"].contains(inner.lowercased())
    }
}
