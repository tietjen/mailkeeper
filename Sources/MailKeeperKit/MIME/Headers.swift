import Foundation

public struct HeaderField: Sendable, Equatable {
    public let name: String
    /// Unfolded, still RFC 2047-encoded value.
    public let rawValue: String
}

public struct HeaderList: Sendable, Equatable {
    public var fields: [HeaderField] = []

    /// First raw value for a header name (case-insensitive).
    public subscript(name: String) -> String? {
        fields.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.rawValue
    }

    public func all(_ name: String) -> [String] {
        fields.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.rawValue)
    }

    /// RFC 2047-decoded value with whitespace collapsed (for display and indexing).
    public func text(_ name: String) -> String? {
        self[name].map { collapseWhitespace(EncodedWords.decode($0)) }
    }
}

enum HeaderParser {
    /// Splits `data` into its header block and the offset where the body starts.
    /// A message without an empty line is all headers.
    static func parse(_ data: Data) -> (HeaderList, bodyOffset: Int) {
        let bytes = [UInt8](data.prefix(1 << 20))  // headers beyond 1 MiB are not plausible
        var lines: [ArraySlice<UInt8>] = []
        var lineStart = 0
        var bodyOffset = data.count
        var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0A {
                var line = bytes[lineStart..<i]
                if line.last == 0x0D { line = line.dropLast() }
                if line.isEmpty {
                    bodyOffset = i + 1
                    break
                }
                lines.append(line)
                lineStart = i + 1
            }
            i += 1
        }
        if bodyOffset == data.count, lineStart < bytes.count, i >= bytes.count {
            var line = bytes[lineStart..<bytes.count]
            if line.last == 0x0D { line = line.dropLast() }
            if !line.isEmpty { lines.append(line) }
        }

        var fields: [HeaderField] = []
        var name: String?
        var value = ""
        func flush() {
            if let n = name { fields.append(HeaderField(name: n, rawValue: value.trimmingCharacters(in: .whitespaces))) }
            name = nil
            value = ""
        }
        for (index, line) in lines.enumerated() {
            let text = decodeHeaderBytes(line)
            if let first = line.first, first == 0x20 || first == 0x09 {
                if name != nil { value += text }  // continuation: keep the leading whitespace
                continue
            }
            // mbox "From " separator or other junk before the first header
            if index == 0, text.hasPrefix("From ") { continue }
            guard let colon = text.firstIndex(of: ":") else { continue }
            let n = text[..<colon].trimmingCharacters(in: .whitespaces)
            guard !n.isEmpty, !n.contains(" ") else { continue }
            flush()
            name = n
            value = String(text[text.index(after: colon)...])
        }
        flush()
        return (HeaderList(fields: fields), bodyOffset)
    }

    /// Raw 8-bit header bytes: UTF-8 if valid, else Windows-1252.
    static func decodeHeaderBytes(_ bytes: ArraySlice<UInt8>) -> String {
        String(validating: bytes, as: UTF8.self) ?? Charset.windows1252(Data(bytes))
    }
}

/// `type/subtype; a=b; c="d"` including RFC 2231 continuations and charset/language
/// (`filename*0*=utf-8''%C3%A4…`). Keys are lowercased; values are decoded.
struct ParameterizedValue: Sendable, Equatable {
    var value: String
    var params: [String: String]

    init(_ raw: String) {
        let segments = Self.splitSegments(raw)
        value = segments.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        var simple: [String: String] = [:]
        var sections: [String: [(index: Int, extended: Bool, value: String)]] = [:]
        for seg in segments.dropFirst() {
            guard let eq = seg.firstIndex(of: "=") else { continue }
            var key = seg[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let rawVal = seg[seg.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            let val = Self.unquote(rawVal)
            guard !key.isEmpty else { continue }
            var extended = false
            if key.hasSuffix("*") {
                extended = true
                key.removeLast()
            }
            if let star = key.lastIndex(of: "*"), let idx = Int(key[key.index(after: star)...]) {
                sections[String(key[..<star]), default: []].append((idx, extended, val))
            } else if extended {
                sections[key, default: []].append((0, true, val))
            } else {
                simple[key] = val
            }
        }
        for (key, parts) in sections {
            var charset: String?
            var bytes = Data()
            for (n, part) in parts.sorted(by: { $0.index < $1.index }).enumerated() {
                var v = part.value
                if part.extended, n == 0 {
                    // charset'language'value
                    let pieces = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if pieces.count == 3 {
                        charset = String(pieces[0])
                        v = String(pieces[2])
                    }
                }
                bytes.append(part.extended ? Self.percentDecode(v) : Data(v.utf8))
            }
            simple[key] = Charset.decode(bytes, charset: charset ?? "utf-8")
        }
        // Non-standard but common: RFC 2047 words inside quoted parameters (filenames).
        params = simple.mapValues { EncodedWords.decode($0) }
    }

    private static func splitSegments(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var inQuote = false
        var escape = false
        for ch in s {
            if escape { cur.append(ch); escape = false; continue }
            if ch == "\\", inQuote { cur.append(ch); escape = true; continue }
            if ch == "\"" { inQuote.toggle() }
            if ch == ";", !inQuote {
                out.append(cur)
                cur = ""
                continue
            }
            cur.append(ch)
        }
        out.append(cur)
        return out
    }

    static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), s.count >= 2 else { return s }
        var out = ""
        var escape = false
        for ch in s.dropFirst() {
            if escape { out.append(ch); escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { break }
            out.append(ch)
        }
        return out
    }

    private static func percentDecode(_ s: String) -> Data {
        let b = Array(s.utf8)
        var out = Data(capacity: b.count)
        var i = 0
        while i < b.count {
            if b[i] == UInt8(ascii: "%"), i + 2 < b.count, let v = hexByte(b[i + 1], b[i + 2]) {
                out.append(v)
                i += 3
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return out
    }
}

func collapseWhitespace(_ s: String) -> String {
    var out = ""
    out.reserveCapacity(s.count)
    var lastSpace = true
    for ch in s {
        if ch.isWhitespace {
            if !lastSpace { out.append(" ") }
            lastSpace = true
        } else {
            out.append(ch)
            lastSpace = false
        }
    }
    if out.last == " " { out.removeLast() }
    return out
}
