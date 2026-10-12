import Foundation

/// What a `DKIM-Signature` header says it signs (RFC 6376 §3.5): the signing domain `d=` and the
/// header fields `h=`. No verification — whether a signature passed is the own server's word in
/// `Authentication-Results`; this says what a signature covers (review 6.5c B1: one-click only
/// when the sender signed its List-Unsubscribe headers, as RFC 8058 §4 requires).
public struct DKIMSignature: Sendable, Equatable {
    public var domain: String
    /// Lowercased, in order, repeats kept (a field listed twice also covers an added instance).
    public var signedFields: [String]

    public static func parse(_ value: String) -> DKIMSignature? {
        var domain: String?, fields: [String]?
        for tag in value.prefix(8_000).split(separator: ";") {
            let parts = tag.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let raw = parts[1].filter { !$0.isWhitespace }.lowercased()
            switch parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "d": domain = raw
            case "h": fields = raw.split(separator: ":").map(String.init)
            default: continue
            }
        }
        guard let domain, !domain.isEmpty, let fields, !fields.isEmpty else { return nil }
        return DKIMSignature(domain: domain, signedFields: fields)
    }

    /// Whether a signature of `domain` (relaxed: the same registrable domain, as DMARC aligns)
    /// covers every instance of each field: listed at least as often as the field occurs — an
    /// instance beyond that, put on top, would be unsigned.
    public static func covers(_ headers: HeaderList, fields: [String], domain: String) -> Bool {
        let aligned = LinkCheck.registrableDomain(domain.lowercased())
        return headers.all("DKIM-Signature").prefix(10).compactMap(parse).contains { signature in
            LinkCheck.registrableDomain(signature.domain) == aligned && fields.allSatisfy { field in
                let occurs = headers.all(field).count
                return occurs > 0 && signature.signedFields.filter { $0 == field.lowercased() }.count >= occurs
            }
        }
    }
}
