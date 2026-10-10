import Foundation

enum TransferEncoding {
    static func decode(_ data: Data, encoding raw: String?) -> Data {
        switch Charset.normalize(raw) {
        case "base64": base64(data)
        case "quoted-printable": quotedPrintable(data)
        default: data  // 7bit, 8bit, binary, unknown
        }
    }

    /// Tolerant base64: ignores line breaks and junk, repairs missing padding, drops a
    /// trailing partial quantum instead of failing the whole part.
    static func base64(_ data: Data) -> Data {
        var clean = Data(capacity: data.count)
        for c in data {
            switch c {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
                clean.append(c)
            case UInt8(ascii: "-"): clean.append(UInt8(ascii: "+"))  // base64url seen in the wild
            case UInt8(ascii: "_"): clean.append(UInt8(ascii: "/"))
            default: continue  // whitespace, '=', junk
            }
        }
        let remainder = clean.count % 4
        if remainder == 1 { clean.removeLast() }  // cannot encode a byte; drop the stray char
        else if remainder > 1 { clean.append(contentsOf: Array(repeating: UInt8(ascii: "="), count: 4 - remainder)) }
        return Data(base64Encoded: clean) ?? Data()
    }

    static func quotedPrintable(_ data: Data) -> Data {
        let b = [UInt8](data)
        var out = Data(capacity: b.count)
        var i = 0
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "=") {
                // soft line break: "=" CRLF, "=" LF, possibly with trailing whitespace before it
                var j = i + 1
                while j < b.count, b[j] == 0x20 || b[j] == 0x09 { j += 1 }
                if j < b.count, b[j] == 0x0A { i = j + 1; continue }
                if j + 1 < b.count, b[j] == 0x0D, b[j + 1] == 0x0A { i = j + 2; continue }
                if j >= b.count { break }
                if i + 2 < b.count, let v = hexByte(b[i + 1], b[i + 2]) {
                    out.append(v)
                    i += 3
                    continue
                }
                out.append(c)  // literal "=" that is not an escape
                i += 1
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }
}
