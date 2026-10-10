import Foundation

/// RFC 2047 encoded words (`=?charset?Q|B?text?=`) in header values. Whitespace between two
/// adjacent encoded words is dropped, as the RFC requires; malformed words stay literal.
enum EncodedWords {
    static func decode(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        var pendingGap = String.UnicodeScalarView()  // whitespace after an encoded word
        var lastWasEncoded = false
        var i = 0
        while i < scalars.count {
            if scalars[i] == "=", i + 1 < scalars.count, scalars[i + 1] == "?",
               let (decoded, next) = parseWord(scalars, at: i) {
                if !lastWasEncoded { out.append(contentsOf: pendingGap) }
                pendingGap.removeAll()
                out.append(contentsOf: decoded.unicodeScalars)
                lastWasEncoded = true
                i = next
                continue
            }
            let c = scalars[i]
            if lastWasEncoded, c == " " || c == "\t" || c == "\r" || c == "\n" {
                pendingGap.append(c)
            } else {
                out.append(contentsOf: pendingGap)
                pendingGap.removeAll()
                out.append(c)
                lastWasEncoded = false
            }
            i += 1
        }
        out.append(contentsOf: pendingGap)
        return String(out)
    }

    /// Parses one encoded word starting at `start` ("=?"). Returns decoded text and the index
    /// after the closing "?=".
    private static func parseWord(_ s: [Unicode.Scalar], at start: Int) -> (String, Int)? {
        var i = start + 2
        var charset = ""
        while i < s.count, s[i] != "?" {
            if s[i] == " " || charset.count > 40 { return nil }
            charset.unicodeScalars.append(s[i])
            i += 1
        }
        guard i + 2 < s.count, s[i] == "?" else { return nil }
        let enc = s[i + 1]
        guard s[i + 2] == "?", "QqBb".unicodeScalars.contains(enc) else { return nil }
        i += 3
        var text = ""
        while i + 1 < s.count, !(s[i] == "?" && s[i + 1] == "=") {
            if s[i] == " " || s[i] == "\t" { return nil }  // spaces are not allowed inside a word
            text.unicodeScalars.append(s[i])
            i += 1
        }
        guard i + 1 < s.count else { return nil }
        // RFC 2231 language suffix: charset*lang
        let cs = charset.split(separator: "*", maxSplits: 1).first.map(String.init) ?? charset
        let bytes: Data
        if enc == "B" || enc == "b" {
            bytes = TransferEncoding.base64(Data(text.utf8))
        } else {
            bytes = qDecode(text)
        }
        return (Charset.decode(bytes, charset: cs), i + 2)
    }

    /// "Q" encoding: like quoted-printable, plus "_" for space.
    private static func qDecode(_ text: String) -> Data {
        let b = Array(text.utf8)
        var out = Data(capacity: b.count)
        var i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "_") {
                out.append(0x20)
            } else if b[i] == UInt8(ascii: "="), i + 2 < b.count, let v = hexByte(b[i + 1], b[i + 2]) {
                out.append(v)
                i += 2
            } else {
                out.append(b[i])
            }
            i += 1
        }
        return out
    }
}

func hexValue(_ c: UInt8) -> UInt8? {
    switch c {
    case 0x30...0x39: c - 0x30
    case 0x41...0x46: c - 0x41 + 10
    case 0x61...0x66: c - 0x61 + 10
    default: nil
    }
}

func hexByte(_ a: UInt8, _ b: UInt8) -> UInt8? {
    guard let h = hexValue(a), let l = hexValue(b) else { return nil }
    return h << 4 | l
}
