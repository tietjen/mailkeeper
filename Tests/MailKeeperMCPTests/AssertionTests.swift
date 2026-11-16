import Foundation
import Testing
@testable import MailKeeperMCP

@Suite("mailkeeper-mcp: JSON und kanonische Form")
struct JSONTests {
    @Test func theCanonicalFormIsByteEqualToKastelains() throws {
        let f = try fixture()
        for (body, expected) in [("valid", "canonical_plain_b64"), ("tricky", "canonical_tricky_b64")] {
            let bytes = try #require(f[body]?["body"]).serialized(canonical: true)
            let encoded = try #require(f[expected]?.string)
            let want = try #require(base64URL(encoded))
            #expect(bytes == want, "\(body): \(String(decoding: bytes, as: UTF8.self))")
        }
    }

    @Test func numbersStayWhatTheyWere() throws {
        let v = try JSONValue.parse(Data(#"{"a":3,"b":3.5,"c":-0,"d":1e3,"e":"\u00fc\ud83d\ude00"}"#.utf8))
        #expect(v["a"] == .int(3) && v["b"] == .double(3.5) && v["c"] == .int(0) && v["d"] == .double(1000))
        #expect(v["e"]?.string == "ü😀")
        #expect(String(decoding: v.serialized(), as: UTF8.self) == #"{"a":3,"b":3.5,"c":0,"d":1000.0,"e":"ü😀"}"#)
    }

    @Test func malformedJSONIsRefused() {
        for bad in ["{", "[1,]", "{\"a\":1,}", "01", "\"\\ud800\"", "nul", "{} {}", "\"a\u{01}\"", String(repeating: "[", count: 70) + String(repeating: "]", count: 70)] {
            #expect(throws: JSONError.self, "\(bad.prefix(20))") { try JSONValue.parse(Data(bad.utf8)) }
        }
    }

    @Test func controlCharactersAreEscapedLikePython() {
        let s: JSONValue = .string("a\u{01}b\u{2028}c\"\\\n")
        #expect(String(decoding: s.serialized(canonical: true), as: UTF8.self) == "\"a\\u0001b\u{2028}c\\\"\\\\\\n\"")
    }
}

@Suite("mailkeeper-mcp: Assertion des Brokers")
struct AssertionTests {
    /// The fixture's own moment: issued 10:00:00, expires 10:01:00 (2026-08-17 UTC).
    static let fixtureNow = AssertionVerifier.date("2026-08-17T10:00:30+00:00")!

    func verifier(_ f: JSONValue, audience: String = "metrics", now: Date = fixtureNow) throws -> AssertionVerifier {
        AssertionVerifier(audience: audience, keys: StaticKeys(set: try JWKSKeySource.parse(f["jwks"]!.serialized())), now: { now })
    }

    @Test func theFixtureVerifiesAsInWikiMCPAndPaperlessMCP() async throws {
        let f = try fixture()
        let claims = try await verifier(f).verify(f["valid"])
        #expect(claims.user == "jan" && claims.groups == ["familie", "admins"] && claims.runID == "run-0197f1b2")
        let tricky = try await verifier(f).verify(f["tricky"])  // escapes, NFC, sort order, U+2028
        #expect(tricky.user == "jörg")
        await #expect(throws: Refusal("bad_signature", "signature does not match the body")) { try await verifier(f).verify(f["wrong_key"]) }
        await #expect(throws: Refusal("key_unavailable", "no usable public key for this kid")) { try await verifier(f).verify(f["unknown_kid"]) }
    }

    /// v2.2 §14.1 as a contract case: `nfc_replay_variant` is `nfc_replay` with U+212A KELVIN SIGN for the "K" of
    /// the nonce, under the very same signature (it covers the NFC form). Signed by kastelain.signing like the rest of
    /// the fixture, so every verifier checks the attack against the same key. Both orders: a store normalising only
    /// one side of the comparison would pass one of them. NonceStore keys are Strings, which Swift hashes and compares
    /// canonically, so today this guards against a later switch to byte keys; "variant first" also shows that the
    /// canonical form accepts the KELVIN spelling under Kastelain's key.
    @Test func aUnicodeVariantOfTheFixtureNonceIsAReplay() async throws {
        let f = try fixture()
        let variant = try #require(f["nfc_replay_variant"]?["body"]?["nonce"]?.string)
        let original = try #require(f["nfc_replay"]?["body"]?["nonce"]?.string)
        // unicodeScalars, not Characters: String.contains compares canonically and would find "K" either way.
        // Only the variant may carry it: lost there, or present in both, this is an ordinary replay.
        let kelvin = Unicode.Scalar(UInt32(0x212A))!
        #expect(variant.unicodeScalars.contains(kelvin), "the parser normalised the variant away")
        #expect(!original.unicodeScalars.contains(kelvin), "the original carries a KELVIN SIGN too")
        for (first, second) in [("nfc_replay", "nfc_replay_variant"), ("nfc_replay_variant", "nfc_replay")] {
            let v = try verifier(f)
            #expect(try await v.verify(f[first]).user == "jan")
            await #expect(throws: Refusal("replay", "nonce has already been redeemed"), "\(first) then \(second)") {
                try await v.verify(f[second])
            }
        }
    }

    @Test func everyCheckRefusesWithItsCode() async throws {
        let s = TestSigner()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func check(_ envelope: JSONValue?, at time: Date = now, audience: String = "mail") async -> String? {
            do { _ = try await AssertionVerifier(audience: audience, keys: s.keys, now: { time }).verify(envelope); return nil }
            catch let r as Refusal { return r.code } catch { return "\(error)" }
        }
        #expect(await check(try s.envelope(TestSigner.body(issued: now))) == nil)
        #expect(await check(nil) == "missing_assertion")
        #expect(await check(["kid": "x", "body": ["user": "jan"]]) == "malformed")
        #expect(await check(try s.envelope(TestSigner.body(issued: now), alg: "RS256")) == "bad_algorithm")
        #expect(await check(try s.envelope(TestSigner.body(issued: now - 120))) == "expired")
        #expect(await check(try s.envelope(TestSigner.body(issued: now - 63)), at: now) == nil)  // within the 5 s leeway
        #expect(await check(try s.envelope(TestSigner.body(issued: now, lifetime: 600))) == "lifetime_too_long")
        #expect(await check(try s.envelope(TestSigner.body(issued: now + 3_600))) == "lifetime_too_long")  // valid far ahead
        #expect(await check(try s.envelope(TestSigner.body(audience: "paperless", issued: now))) == "wrong_audience")
        #expect(await check(try s.envelope(TestSigner.body(issued: now, nonce: ""))) == "missing_nonce")
        #expect(await check(try s.envelope(TestSigner.body(user: "", issued: now))) == "malformed")
        #expect(await check(try s.envelope(TestSigner.body(issued: now), kid: "other")) == "key_unavailable")
        var tampered = try s.envelope(TestSigner.body(issued: now))
        if case .object(var o) = tampered, case .object(var b) = o["body"]! { b["user"] = "katja"; o["body"] = .object(b); tampered = .object(o) }
        #expect(await check(tampered) == "bad_signature")
        #expect(await check(try s.envelope(TestSigner.body(issued: now)), audience: "") == "misconfigured")
    }

    @Test func aNonceIsRedeemedOnce() async throws {
        let s = TestSigner()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let v = AssertionVerifier(audience: "mail", keys: s.keys, now: { now })
        let envelope = try s.envelope(TestSigner.body(issued: now, nonce: "once"))
        _ = try await v.verify(envelope)
        await #expect(throws: Refusal("replay", "nonce has already been redeemed")) { try await v.verify(envelope) }
        let small = AssertionVerifier(audience: "mail", keys: s.keys, nonces: NonceStore(capacity: 1), now: { now })
        _ = try await small.verify(try s.envelope(TestSigner.body(issued: now)))
        await #expect(throws: Refusal("nonce_store_full", "too many unexpired nonces in flight")) {
            try await small.verify(try s.envelope(TestSigner.body(issued: now)))
        }
    }

    @Test func theJWKSIsRefetchedAtMostEvery30Seconds() async throws {
        actor Counter { var n = 0; func next() -> Int { n += 1; return n } }
        let counter = Counter()
        let jwks = Data(#"{"keys":[{"kty":"OKP","crv":"Ed25519","kid":"a","x":"Kay64UG8yvCyLhqU000LxzYeUm0L_hLIl5S8kyKWbdc","use":"sig"}]}"#.utf8)
        let source = JWKSKeySource(url: URL(string: "http://gateway/jwks")!) { _ in _ = await counter.next(); return jwks }
        _ = try await source.keys(refresh: false)
        _ = try await source.keys(refresh: true)  // within 30 s: from the cache
        _ = try await source.keys(refresh: false)
        #expect(await counter.n == 1)
        #expect(try await source.keys(refresh: false).keys.sorted() == ["a"])
    }
}

@Suite("mailkeeper-mcp: Ausweis je Weg")
struct IdentityTests {
    @Test func eachPathActsAsItsPersonAndNobodyElse() async throws {
        let s = TestSigner()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let r = try IdentityResolver(verifier: AssertionVerifier(audience: "mail", keys: s.keys, now: { now }),
                                     users: ["katja": "katja"], directToken: directToken, directPerson: "jan")
        #expect(try await r.resolve(assertion: nil, authorization: "Bearer \(directToken)") == Principal(path: .direct, user: "jan", person: "jan", runID: nil))
        let broker = try await r.resolve(assertion: try s.envelope(TestSigner.body(user: "katja", issued: now)), authorization: "Bearer \(directToken)")
        #expect(broker.path == .broker && broker.person == "katja")  // an assertion wins over the bearer
        await #expect(throws: Refusal("unknown_user", "this user has no mail archive here")) {
            try await r.resolve(assertion: try s.envelope(TestSigner.body(user: "jan", issued: now)), authorization: nil)
        }
        await #expect(throws: Refusal("unauthorized", "bearer token not accepted")) { try await r.resolve(assertion: nil, authorization: "Bearer wrong") }
        await #expect(throws: Refusal("unauthorized", "Authorization must be a bearer token")) { try await r.resolve(assertion: nil, authorization: "Bearer ") }
        await #expect(throws: Refusal("missing_assertion", "this call identifies nobody: no broker assertion and no bearer token")) {
            try await r.resolve(assertion: nil, authorization: nil)
        }
        // a bad assertion is never rescued by the bearer
        await #expect(throws: Refusal.self) { try await r.resolve(assertion: ["kid": "x"], authorization: "Bearer \(directToken)") }
    }

    @Test func anEmptyOrShortTokenIsRefusedAtStart() {
        let v = AssertionVerifier(audience: "mail", keys: StaticKeys(set: [:]))
        for bad in ["", "short", String(repeating: "x", count: 31), String(repeating: "x", count: 20) + " " + String(repeating: "y", count: 20)] {
            #expect(throws: Refusal.self) { try IdentityResolver(verifier: v, users: [:], directToken: bad, directPerson: "jan") }
        }
    }
}
