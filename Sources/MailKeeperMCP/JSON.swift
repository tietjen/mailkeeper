import Foundation

/// JSON as the connector reads and writes it (ADR-0017). Own parser instead of
/// `JSONSerialization`: integers must stay integers for the canonical form of an assertion, and
/// depth and size are bounded before anything else looks at a request.
public enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s } else { return nil } }
    public var object: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
    public var bool: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var isNull: Bool { self == .null }
    /// An integer, also from a whole double (clients send `5.0` now and then).
    public var integer: Int64? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.rounded() == d && abs(d) < 9.0e15: return Int64(d)
        default: return nil
        }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
                     ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    public init(nilLiteral: ()) { self = .null }
}

public struct JSONError: Error, CustomStringConvertible, Equatable {
    public var description: String
    init(_ message: String) { description = message }
}

// MARK: Parsing

extension JSONValue {
    public static let maxDepth = 64

    /// Strict RFC 8259: one value, no trailing commas, no comments; duplicate keys keep the last
    /// (as Python's `json.loads`, which signs what the broker sends).
    public static func parse(_ data: Data) throws -> JSONValue {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipSpace()
        let value = try parser.value(depth: 0)
        parser.skipSpace()
        guard parser.i == parser.bytes.count else { throw JSONError("trailing characters at \(parser.i)") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipSpace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < JSONValue.maxDepth else { throw JSONError("nested too deep") }
            guard i < bytes.count else { throw JSONError("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object(depth: depth)
            case UInt8(ascii: "["): return try array(depth: depth)
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return try number()
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw JSONError("bad literal at \(i)") }
            i += w.count
        }

        mutating func object(depth: Int) throws -> JSONValue {
            i += 1
            var out: [String: JSONValue] = [:]
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
            while true {
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw JSONError("expected key at \(i)") }
                let key = try string()
                skipSpace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw JSONError("expected : at \(i)") }
                i += 1
                skipSpace()
                out[key] = try value(depth: depth + 1)
                skipSpace()
                guard i < bytes.count else { throw JSONError("unexpected end in object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(out) }
                throw JSONError("expected , or } at \(i)")
            }
        }

        mutating func array(depth: Int) throws -> JSONValue {
            i += 1
            var out: [JSONValue] = []
            skipSpace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
            while true {
                skipSpace()
                out.append(try value(depth: depth + 1))
                skipSpace()
                guard i < bytes.count else { throw JSONError("unexpected end in array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(out) }
                throw JSONError("expected , or ] at \(i)")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else {
                throw JSONError("bad \\u escape at \(i)")
            }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < bytes.count else { throw JSONError("unterminated string") }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { i += 1; break }
                guard b >= 0x20 else { throw JSONError("control character in string at \(i)") }
                if b != UInt8(ascii: "\\") { out.append(b); i += 1; continue }
                i += 1
                guard i < bytes.count else { throw JSONError("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar) {
                        guard i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                            throw JSONError("lone surrogate")
                        }
                        i += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw JSONError("bad surrogate pair") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(scalar) {
                        throw JSONError("lone surrogate")
                    }
                    guard let u = Unicode.Scalar(scalar) else { throw JSONError("bad scalar") }
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default: throw JSONError("bad escape at \(i)")
                }
            }
            guard let s = String(validating: out, as: UTF8.self) else { throw JSONError("invalid UTF-8 in string") }
            return s
        }

        mutating func number() throws -> JSONValue {
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw JSONError("bad value at \(start)") }
            if bytes[i] == 0x30 { i += 1 } else { while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 } }
            var isDouble = false
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                isDouble = true
                i += 1
                guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw JSONError("bad fraction at \(i)") }
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                isDouble = true
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw JSONError("bad exponent at \(i)") }
                while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
            }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if !isDouble, let v = Int64(text) { return .int(v) }
            guard let d = Double(text), d.isFinite else { throw JSONError("number out of range at \(start)") }
            return .double(d)
        }
    }
}

// MARK: Writing

extension JSONValue {
    /// Compact JSON with sorted keys. `canonical` also normalises every string to NFC first —
    /// together exactly Python's `json.dumps(_normalize(x), sort_keys=True,
    /// separators=(",", ":"), ensure_ascii=False)`, i.e. `kastelain.audit.canonical_json`.
    public func serialized(canonical: Bool = false) -> Data {
        var out = [UInt8]()
        write(&out, canonical: canonical)
        return Data(out)
    }

    public var text: String { String(decoding: serialized(), as: UTF8.self) }

    private func write(_ out: inout [UInt8], canonical: Bool) {
        switch self {
        case .null: out.append(contentsOf: Array("null".utf8))
        case .bool(let b): out.append(contentsOf: Array((b ? "true" : "false").utf8))
        case .int(let i): out.append(contentsOf: Array(String(i).utf8))
        case .double(let d): out.append(contentsOf: Array(Self.pythonFloat(d).utf8))
        case .string(let s): Self.writeString(canonical ? s.precomposedStringWithCanonicalMapping : s, into: &out)
        case .array(let a):
            out.append(UInt8(ascii: "["))
            for (n, v) in a.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                v.write(&out, canonical: canonical)
            }
            out.append(UInt8(ascii: "]"))
        case .object(let o):
            out.append(UInt8(ascii: "{"))
            // Python sorts str by code point; Swift's < on String is not that.
            let entries = o.map { (key: canonical ? $0.key.precomposedStringWithCanonicalMapping : $0.key, value: $0.value) }
                .sorted { $0.key.unicodeScalars.lexicographicallyPrecedes($1.key.unicodeScalars) { $0.value < $1.value } }
            for (n, e) in entries.enumerated() {
                if n > 0 { out.append(UInt8(ascii: ",")) }
                writeString(e.key, into: &out)
                out.append(UInt8(ascii: ":"))
                e.value.write(&out, canonical: canonical)
            }
            out.append(UInt8(ascii: "}"))
        }
    }

    private func writeString(_ s: String, into out: inout [UInt8]) { Self.writeString(s, into: &out) }

    /// Python's escaping with `ensure_ascii=False`: `"` `\` and the short escapes, other control
    /// characters as `\u00xx` (lower-case hex); everything else, U+2028/U+2029 included, as is.
    static func writeString(_ s: String, into out: inout [UInt8]) {
        out.append(UInt8(ascii: "\""))
        for u in s.unicodeScalars {
            switch u.value {
            case 0x22: out.append(contentsOf: [0x5C, 0x22])
            case 0x5C: out.append(contentsOf: [0x5C, 0x5C])
            case 0x0A: out.append(contentsOf: [0x5C, UInt8(ascii: "n")])
            case 0x0D: out.append(contentsOf: [0x5C, UInt8(ascii: "r")])
            case 0x09: out.append(contentsOf: [0x5C, UInt8(ascii: "t")])
            case 0x08: out.append(contentsOf: [0x5C, UInt8(ascii: "b")])
            case 0x0C: out.append(contentsOf: [0x5C, UInt8(ascii: "f")])
            case 0..<0x20: out.append(contentsOf: Array(String(format: "\\u%04x", u.value).utf8))
            default: out.append(contentsOf: Array(String(Character(u)).utf8))
            }
        }
        out.append(UInt8(ascii: "\""))
    }

    /// Python's `repr(float)` for the cases JSON can hold (shortest round-trip digits).
    static func pythonFloat(_ d: Double) -> String {
        let s = "\(d)"
        // Swift writes 1e+16 / 1e-05 like Python; whole values as 5.0 like Python.
        return s
    }
}
