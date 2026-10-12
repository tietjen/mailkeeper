import Foundation

/// The topmost `Authentication-Results` header (RFC 8601): who checked (the authserv-id) and what
/// came out for DKIM, SPF and DMARC, and which From domain DMARC vouched for. Only a header the
/// own server added counts (ADR-0010 §3, §6): a sender can write any results into its own mail,
/// so `ArchiveReader.ownAuthServers` learns per account which server that is.
public struct AuthResults: Sendable, Equatable {
    public var server: String?
    public var dkim: String?
    public var spf: String?
    public var dmarc: String?
    /// `header.from` of the DMARC result: the domain that passed (or failed).
    public var fromDomain: String?

    public init(server: String? = nil, dkim: String? = nil, spf: String? = nil, dmarc: String? = nil, fromDomain: String? = nil) {
        self.server = server
        self.dkim = dkim
        self.spf = spf
        self.dmarc = dmarc
        self.fromDomain = fromDomain
    }

    /// "dkim=pass spf=pass dmarc=fail" — what the model and the reader see.
    public var summary: String? {
        let parts = [("dkim", dkim), ("spf", spf), ("dmarc", dmarc)].compactMap { name, value in value.map { "\(name)=\($0)" } }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    public static func parse(_ header: String?) -> AuthResults? {
        guard let raw = header?.lowercased(), !raw.isEmpty else { return nil }
        let text = stripComments(String(raw.prefix(8_000)))
        let segments = text.split(separator: ";", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = segments.first else { return nil }
        var r = AuthResults()
        // authserv-id, optionally followed by a version number
        let id = first.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map(String.init) ?? ""
        if !id.isEmpty, !id.contains("=") { r.server = String(id.prefix(120)) }
        for segment in segments.dropFirst(r.server == nil ? 0 : 1) {
            let tokens = segment.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            guard let head = tokens.first, let eq = head.firstIndex(of: "=") else { continue }
            let method = head[..<eq]
            let result = String(head[head.index(after: eq)...].prefix { $0.isLetter })
            guard !result.isEmpty else { continue }
            switch method {
            case "dkim" where r.dkim == nil || r.dkim != "pass": r.dkim = result  // any passing signature counts
            case "spf" where r.spf == nil: r.spf = result
            case "dmarc" where r.dmarc == nil:
                r.dmarc = result
                for t in tokens.dropFirst() where t.hasPrefix("header.from=") {
                    let domain = t.dropFirst("header.from=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\"'<>"))
                    if !domain.isEmpty { r.fromDomain = String(domain.prefix(120)) }
                }
            default: continue
            }
        }
        return r.server == nil && r.summary == nil ? nil : r
    }

    /// RFC 5322 comments "( … )", nested, removed — "dkim=pass (2048-bit key)" → "dkim=pass".
    static func stripComments(_ s: String) -> String {
        var out = ""
        var depth = 0
        for ch in s {
            if ch == "(" { depth += 1; continue }
            if ch == ")" { depth = max(0, depth - 1); continue }
            if depth == 0 { out.append(ch) }
        }
        return out
    }
}

/// The address a mail was delivered to — `Delivered-To` (topmost: the final mailbox), else
/// `X-Original-To` — for the bait address (ADR-0010 §6).
public enum DeliveredTo {
    public static func address(_ headers: HeaderList) -> String? {
        for name in ["Delivered-To", "X-Original-To"] {
            if let value = headers[name], let address = AddressParser.parse(value).first?.address, address.contains("@") {
                return String(address.lowercased().prefix(200))
            }
        }
        return nil
    }
}
