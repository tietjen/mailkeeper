import Foundation

/// Bytes → String for a declared MIME charset, with the fallbacks real mail needs:
/// "us-ascii" and broken UTF-8 carrying 8-bit bytes, ISO-8859-1 that is really Windows-1252.
enum Charset {
    static func decode(_ data: Data, charset raw: String?) -> String {
        let cs = normalize(raw)
        switch cs {
        case "", "us-ascii", "ascii", "utf-8", "utf8", "unicode-1-1-utf-8", "x-unknown", "unknown-8bit":
            if let s = String(data: data, encoding: .utf8) { return s }
            return windows1252(data)
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1", "l1", "windows-1252", "cp1252", "x-cp1252":
            return windows1252(data)
        default:
            let cfe = CFStringConvertIANACharSetNameToEncoding(cs as CFString)
            if cfe != kCFStringEncodingInvalidId {
                let enc = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfe))
                if let s = String(data: data, encoding: enc) { return s }
            }
            if let s = String(data: data, encoding: .utf8) { return s }
            return windows1252(data)
        }
    }

    /// Windows-1252 is a superset of ISO-8859-1 for printable text (WHATWG treats the labels as
    /// one). Bytes undefined in 1252 fall back to Latin-1, which never fails.
    static func windows1252(_ data: Data) -> String {
        String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    static func normalize(_ raw: String?) -> String {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return "" }
        if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 { s = String(s.dropFirst().dropLast()) }
        return s
    }
}
