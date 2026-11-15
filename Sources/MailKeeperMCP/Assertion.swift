import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto  // swift-crypto, same API (Package.swift)
#endif

/// A refusal with a house code (MCP connector standard v2.2 §14.5): `[code] message`.
public struct Refusal: Error, Equatable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var hint: String?
    public var limit: JSONValue?
    public var got: JSONValue?

    public init(_ code: String, _ message: String, hint: String? = nil, limit: JSONValue? = nil, got: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
        self.limit = limit
        self.got = got
    }

    public var description: String { "[\(code)] \(message)" }
}

/// What a verified assertion says.
public struct AssertionClaims: Sendable, Equatable {
    public var user: String
    public var groups: [String]
    public var runID: String?
    public var approvalID: String?
    public var issuedAt: Date?
    public var expiresAt: Date
    public var nonce: String
}

/// Ed25519 public keys by `kid`.
public protocol KeySource: Sendable {
    /// `refresh`: the cached set did not know a kid — fetch again (rate limited by the source).
    func keys(refresh: Bool) async throws -> [String: Data]
}

/// The gateway's JWKS (`OKP`/`Ed25519`): fetched at most once per `minInterval` — failed
/// attempts included, so a dead gateway is not hammered by every forged call — replaced as a
/// whole (a revoked key disappears), and refetched after `maxAge` even for known kids. A set
/// without usable keys does not replace a good one.
public actor JWKSKeySource: KeySource {
    let url: URL
    let fetch: @Sendable (URL) async throws -> Data
    let minInterval: Duration
    let maxAge: Duration
    private var cached: [String: Data]?
    private var cachedAt: ContinuousClock.Instant?
    private var lastAttempt: ContinuousClock.Instant?
    /// The fetch under way: concurrent callers wait for it instead of being refused.
    private var inFlight: Task<[String: Data], Error>?

    public init(url: URL, minInterval: Duration = .seconds(30), maxAge: Duration = .seconds(3_600),
                fetch: @escaping @Sendable (URL) async throws -> Data = JWKSKeySource.httpGet) {
        self.url = url
        self.fetch = fetch
        self.minInterval = minInterval
        self.maxAge = maxAge
    }

    public func keys(refresh: Bool) async throws -> [String: Data] {
        let now = ContinuousClock.now
        let fresh = cachedAt.map { now - $0 < maxAge } ?? false
        if let cached, fresh, !refresh { return cached }
        if let inFlight {
            _ = try? await inFlight.value
            if let cached, isFresh { return cached }
            throw JSONError("JWKS unavailable")
        }
        if let last = lastAttempt, now - last < minInterval {
            if let cached, fresh { return cached }
            throw JSONError("JWKS fetch throttled")  // → key_unavailable: fail-closed
        }
        lastAttempt = now
        let (fetch, url) = (self.fetch, self.url)
        let task = Task { try Self.parse(try await fetch(url)) }
        inFlight = task
        defer { inFlight = nil }
        let set = try await task.value
        guard !set.isEmpty else {
            if let cached, isFresh { return cached }
            throw JSONError("JWKS without usable keys")
        }
        cached = set
        cachedAt = .now
        return set
    }

    private var isFresh: Bool { cachedAt.map { ContinuousClock.now - $0 < maxAge } ?? false }

    static func parse(_ data: Data) throws -> [String: Data] {
        guard let keys = try JSONValue.parse(data)["keys"]?.array else { throw JSONError("JWKS without keys") }
        var out: [String: Data] = [:]
        for key in keys {
            guard key["kty"]?.string == "OKP", key["crv"]?.string == "Ed25519",
                  key["use"].map({ $0.string == "sig" }) ?? true,
                  let kid = key["kid"]?.string, let x = key["x"]?.string, let raw = base64URL(x), raw.count == 32 else { continue }
            out[kid] = raw
        }
        return out
    }

    public static let httpGet: @Sendable (URL) async throws -> Data = { url in
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw JSONError("JWKS answered \((response as? HTTPURLResponse)?.statusCode ?? 0)") }
        guard data.count <= 256 << 10 else { throw JSONError("JWKS too large") }
        return data
    }
}

/// Nonces seen, kept until their assertion expires (§14.1); bounded, refused when full.
/// Swift compares String keys by canonical equivalence, so an NFC/NFD variant of a nonce is the
/// same key — a replay cannot slip through by re-spelling it (tested; a byte-wise store would).
public actor NonceStore {
    let capacity: Int
    private var seen: [String: Date] = [:]

    public init(capacity: Int = 10_000) { self.capacity = capacity }

    func redeem(_ nonce: String, until expiry: Date, now: Date) throws {
        if seen.count >= capacity { seen = seen.filter { $0.value > now } }
        if let exp = seen[nonce], exp > now { throw Refusal("replay", "nonce has already been redeemed") }
        guard seen.count < capacity else { throw Refusal("nonce_store_full", "too many unexpired nonces in flight") }
        seen[nonce] = expiry
    }
}

func base64URL(_ text: String) -> Data? {
    var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while s.count % 4 != 0 { s += "=" }  // unpadded is the norm (RFC 7515), padded is accepted
    return Data(base64Encoded: s)
}

/// The broker's assertion, checked like wiki-mcp's `Verifier.Verify` and paperless-mcp's
/// `verify_assertion`: same order, same codes, fail-closed.
public struct AssertionVerifier: Sendable {
    public let audience: String
    let keys: any KeySource
    let nonces: NonceStore
    let now: @Sendable () -> Date
    public static let leeway: TimeInterval = 5
    public static let maxLifetime: TimeInterval = 300

    public init(audience: String, keys: any KeySource, nonces: NonceStore = NonceStore(), now: @escaping @Sendable () -> Date = Date.init) {
        self.audience = audience
        self.keys = keys
        self.nonces = nonces
        self.now = now
    }

    public func verify(_ envelope: JSONValue?) async throws -> AssertionClaims {
        guard !audience.isEmpty else { throw Refusal("misconfigured", "connector has no audience configured") }
        guard let envelope, !envelope.isNull else { throw Refusal("missing_assertion", "no broker assertion on the call") }
        guard let kid = envelope["kid"]?.string, !kid.isEmpty, let body = envelope["body"], body.object != nil,
              let sigText = envelope["sig"]?.string, !sigText.isEmpty else {
            throw Refusal("malformed", "assertion is incomplete (kid, body and sig are required)")
        }
        if let alg = envelope["alg"]?.string, !alg.isEmpty, alg != "EdDSA" {
            throw Refusal("bad_algorithm", "unsupported algorithm, expected EdDSA")
        }
        guard let sig = base64URL(sigText), sig.count == 64 else {
            throw Refusal("malformed", "signature is not a base64url Ed25519 signature")
        }
        let payload = body.serialized(canonical: true)
        let raw: Data
        do {
            var set = try await keys.keys(refresh: false)
            if set[kid] == nil { set = try await keys.keys(refresh: true) }
            guard let found = set[kid] else { throw JSONError("unknown kid") }
            raw = found
        } catch {
            // "could not look" is a denial too, never an anonymous pass (§14.1)
            throw Refusal("key_unavailable", "no usable public key for this kid")
        }
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw), key.isValidSignature(sig, for: payload) else {
            throw Refusal("bad_signature", "signature does not match the body")
        }
        // as wiki-mcp and paperless-mcp: a name, nothing more — the user map is the access control
        guard let user = body["user"]?.string, !user.isEmpty, user.count <= 64,
              !user.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Refusal("malformed", "assertion names no user")
        }
        guard let expires = body["expires_at"]?.string.flatMap(Self.date) else {
            throw Refusal("malformed", "expires_at missing or unreadable")
        }
        let issued = body["issued_at"]?.string.flatMap(Self.date)
        let now = now()
        guard now <= expires.addingTimeInterval(Self.leeway) else { throw Refusal("expired", "assertion expired") }
        if let issued, expires.timeIntervalSince(issued) > Self.maxLifetime {
            throw Refusal("lifetime_too_long", "assertion claims a lifetime above 5 minutes")
        }
        // a forged or mis-set clock: an assertion valid far into the future (klartext lesson)
        guard expires.timeIntervalSince(now) <= Self.maxLifetime + Self.leeway else {
            throw Refusal("lifetime_too_long", "assertion expires more than 5 minutes from now")
        }
        guard body["audience"]?.string == audience else { throw Refusal("wrong_audience", "assertion was issued for another connector") }
        guard let nonce = body["nonce"]?.string, !nonce.isEmpty else { throw Refusal("missing_nonce", "assertion carries no nonce") }
        try await nonces.redeem(nonce, until: expires.addingTimeInterval(Self.leeway), now: now)
        return AssertionClaims(user: user, groups: body["groups"]?.array?.compactMap(\.string) ?? [],
                               runID: body["run_id"]?.string, approvalID: body["approval_id"]?.string,
                               issuedAt: issued, expiresAt: expires, nonce: nonce)
    }

    /// RFC 3339 with offset, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }
}
