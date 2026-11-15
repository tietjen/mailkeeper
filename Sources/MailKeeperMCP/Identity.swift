import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Who is asking, and whose archive they read (ADR-0017 §3).
public struct Principal: Sendable, Equatable {
    public enum Path: String, Sendable { case broker, direct }
    public var path: Path
    /// The LLDAP user (broker) or the configured direct person.
    public var user: String
    /// The person whose archive is read — always the asker's own.
    public var person: String
    public var runID: String?
}

/// Identity per path, fail-closed: an assertion wins; else the direct token; else nobody.
public struct IdentityResolver: Sendable {
    let verifier: AssertionVerifier
    let users: [String: String]
    let directTokenDigest: [UInt8]
    let directPerson: String

    public static let minimumTokenLength = 32

    public init(verifier: AssertionVerifier, users: [String: String], directToken: String, directPerson: String) throws {
        // an empty secret is a master key: compare("", "") is true (klartext lesson)
        guard directToken.count >= Self.minimumTokenLength, !directToken.contains(where: \.isWhitespace) else {
            throw Refusal("misconfigured", "direct token shorter than \(Self.minimumTokenLength) characters or with whitespace")
        }
        self.verifier = verifier
        self.users = users
        directTokenDigest = Array(SHA256.hash(data: Data(directToken.utf8)))
        self.directPerson = directPerson
    }

    /// `assertion`: `params._meta.kastelain.assertion`; `authorization`: the HTTP header.
    public func resolve(assertion: JSONValue?, authorization: String?) async throws -> Principal {
        if let assertion, !assertion.isNull {
            let claims = try await verifier.verify(assertion)
            guard let person = users[claims.user] else {
                throw Refusal("unknown_user", "this user has no mail archive here")
            }
            return Principal(path: .broker, user: claims.user, person: person, runID: claims.runID)
        }
        if let authorization {
            let parts = authorization.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "bearer", !parts[1].isEmpty else {
                throw Refusal("unauthorized", "Authorization must be a bearer token")
            }
            let got = Array(SHA256.hash(data: Data(parts[1].utf8)))
            // equal-length digests, compared without an early exit
            var diff: UInt8 = 0
            for (a, b) in zip(got, directTokenDigest) { diff |= a ^ b }
            guard diff == 0 else { throw Refusal("unauthorized", "bearer token not accepted") }
            return Principal(path: .direct, user: directPerson, person: directPerson, runID: nil)
        }
        throw Refusal("missing_assertion", "this call identifies nobody: no broker assertion and no bearer token")
    }
}
