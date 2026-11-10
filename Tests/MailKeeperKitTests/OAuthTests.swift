import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux
#endif
import Testing
@testable import MailKeeperKit

@Suite("Google-Anmeldung (7.1, ADR-0012)")
struct OAuthTests {
    @Test("PKCE: the challenge is the S256 of the verifier, base64url without padding (RFC 7636 A.1/B)")
    func pkceMatchesTheRFCVector() {
        #expect(GoogleOAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
                == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let verifier = GoogleOAuth.randomURLSafe(64)
        #expect((43...128).contains(verifier.count))
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        #expect(GoogleOAuth.randomURLSafe(64) != verifier)  // a fresh one every time
    }

    @Test("The consent URL asks for a refresh token, carries the challenge — and never a secret")
    func authorizationURLIsComplete() throws {
        let url = GoogleOAuth.authorizationURL(clientID: "123-abc.apps.googleusercontent.com",
                                               redirect: "http://127.0.0.1:52101", verifier: "v".padding(toLength: 43, withPad: "v", startingAt: 0),
                                               state: "s-t-a-t-e", loginHint: "tj@gmail.example")
        let items = Dictionary(try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
            .compactMap { i in i.value.map { (i.name, $0) } }, uniquingKeysWith: { a, _ in a })
        #expect(url.host == "accounts.google.com" && url.scheme == "https")
        #expect(items["client_id"] == "123-abc.apps.googleusercontent.com")
        #expect(items["redirect_uri"] == "http://127.0.0.1:52101" && items["response_type"] == "code")
        #expect(items["code_challenge_method"] == "S256" && items["state"] == "s-t-a-t-e")
        #expect(items["code_challenge"] == GoogleOAuth.challenge(for: "v".padding(toLength: 43, withPad: "v", startingAt: 0)))
        #expect(items["access_type"] == "offline" && items["prompt"] == "consent")  // else: a refresh token only the first time
        #expect(items["scope"]?.contains("https://mail.google.com/") == true)
        #expect(items["login_hint"] == "tj@gmail.example")
        #expect(!url.absoluteString.contains("code_verifier"))  // the verifier stays here
    }

    @Test("A client id is checked before the browser opens")
    func clientIDIsChecked() {
        #expect(GoogleOAuth.isPlausibleClientID("123456789012-abcdefg.apps.googleusercontent.com"))
        #expect(!GoogleOAuth.isPlausibleClientID(""))
        #expect(!GoogleOAuth.isPlausibleClientID("abc.apps.googleusercontent.com"))  // no numeric prefix
        #expect(!GoogleOAuth.isPlausibleClientID("123-abc.example.com"))
        #expect(!GoogleOAuth.isPlausibleClientID("123-abc.apps.googleusercontent.com extra"))
        #expect(!GoogleOAuth.isPlausibleClientID("GOCSPX-asecret"))  // a pasted secret is no client id
    }

    @Test("The address of the signed-in account comes out of the id token; nonsense does not")
    func emailFromIDToken() {
        let payload = Data(#"{"email":"tj@gmail.example","email_verified":true}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        #expect(GoogleOAuth.email(inIDToken: "header.\(payload).signature") == "tj@gmail.example")
        #expect(GoogleOAuth.email(inIDToken: "nope") == nil)
        #expect(GoogleOAuth.email(inIDToken: "a.b.c") == nil)
        #expect(GoogleOAuth.email(inIDToken: "") == nil)
    }

    @Test("A token is spent before it expires, so a long sync does not run into it")
    func expiryHasSlack() {
        let token = OAuthTokens(accessToken: "x", refreshToken: nil, expires: Date().addingTimeInterval(3600))
        #expect(token.isValid())
        #expect(!OAuthTokens(accessToken: "x", refreshToken: nil, expires: Date().addingTimeInterval(60)).isValid())
        #expect(!OAuthTokens(accessToken: "x", refreshToken: nil, expires: Date().addingTimeInterval(-1)).isValid())
    }

    @Test("Google's answer: tokens out of it, a revoked sign-in named, nonsense refused")
    func tokenAnswers() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let good = try GoogleOAuth.tokens(from: Data(#"{"access_token":"ya29.x","refresh_token":"1//r","expires_in":3599}"#.utf8),
                                          status: 200, now: now)
        #expect(good.accessToken == "ya29.x" && good.refreshToken == "1//r")
        #expect(good.expires == now.addingTimeInterval(3599))

        // a refresh brings no refresh token: the caller keeps the one it had
        let refreshed = try GoogleOAuth.tokens(from: Data(#"{"access_token":"ya29.y","expires_in":3600}"#.utf8), status: 200, now: now)
        #expect(refreshed.refreshToken == nil)

        // no lifetime: an hour; an absurd one is capped, so a stale token is not kept for a year
        #expect(try GoogleOAuth.tokens(from: Data(#"{"access_token":"a"}"#.utf8), status: 200, now: now).expires
                == now.addingTimeInterval(3600))
        #expect(try GoogleOAuth.tokens(from: Data(#"{"access_token":"a","expires_in":99999999}"#.utf8), status: 200, now: now).expires
                == now.addingTimeInterval(86_400))

        #expect(throws: OAuthError.self) {
            try GoogleOAuth.tokens(from: Data(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#.utf8), status: 400)
        }
        // the revoked case says what to do about it
        do {
            _ = try GoogleOAuth.tokens(from: Data(#"{"error":"invalid_grant"}"#.utf8), status: 400)
            Issue.record("should have thrown")
        } catch let error as OAuthError {
            #expect("\(error)".contains("neu anmelden"))
        }
        #expect(throws: OAuthError.self) { try GoogleOAuth.tokens(from: Data("<html>502</html>".utf8), status: 502) }
        #expect(throws: OAuthError.self) { try GoogleOAuth.tokens(from: Data(#"{"access_token":""}"#.utf8), status: 200) }
        #expect(throws: OAuthError.self) { try GoogleOAuth.tokens(from: Data(#"{"token_type":"Bearer"}"#.utf8), status: 200) }
    }

    @Test("The redirect's query is read from the request line — and only from a GET")
    func requestLineParsing() {
        #expect(LoopbackReceiver.query(inRequest: "GET /?code=4/abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
                == ["code": "4/abc", "state": "xyz"])
        #expect(LoopbackReceiver.query(inRequest: "GET /?error=access_denied&state=xyz HTTP/1.1\r\n\r\n")
                == ["error": "access_denied", "state": "xyz"])
        #expect(LoopbackReceiver.query(inRequest: "GET /favicon.ico HTTP/1.1\r\n\r\n").isEmpty)
        #expect(LoopbackReceiver.query(inRequest: "POST /?code=4/abc HTTP/1.1\r\n\r\n").isEmpty)
        #expect(LoopbackReceiver.query(inRequest: "").isEmpty)
    }

    /// The whole redirect leg against the real listener: a browser's GET on 127.0.0.1 hands the
    /// code over, the page comes back, and a reply from somewhere else is refused.
    @Test("The loopback listener takes the code — and refuses an answer with another state")
    func loopbackTakesTheCode() async throws {
        let listener = try LoopbackReceiver(state: "the-state")
        defer { listener.stop() }
        // the browser may be there before anyone awaits: the answer must not be lost
        let answer = try await get("http://127.0.0.1:\(listener.port)/?code=4%2Fthe-code&state=the-state")
        #expect(try await listener.code(timeout: 10) == "4/the-code")
        #expect(answer.contains("MailKeeper"))

        // and the other way round: awaiting first, the browser arriving later
        let later = try LoopbackReceiver(state: "s")
        defer { later.stop() }
        let waiting = Task { try await later.code(timeout: 10) }
        _ = try await get("http://127.0.0.1:\(later.port)/favicon.ico")  // browsers ask for this first
        _ = try await get("http://127.0.0.1:\(later.port)/?code=4%2Flate&state=s")
        #expect(try await waiting.value == "4/late")  // the favicon did not end the wait

        // a redirect with another state is not this sign-in: answered, ignored, still waiting —
        // the port is open to every process on this Mac (review 7.1 C1)
        let other = try LoopbackReceiver(state: "the-state")
        defer { other.stop() }
        let still = Task { try await other.code(timeout: 10) }
        _ = try? await get("http://127.0.0.1:\(other.port)/?code=4%2Fforged&state=forged")
        _ = try await get("http://127.0.0.1:\(other.port)/?code=4%2Fmine&state=the-state")
        #expect(try await still.value == "4/mine")

        // nothing but foreign answers: that is said as such, not as "nothing happened"
        let onlyForeign = try LoopbackReceiver(state: "the-state")
        defer { onlyForeign.stop() }
        let timeout = Task { try await onlyForeign.code(timeout: 1) }
        _ = try? await get("http://127.0.0.1:\(onlyForeign.port)/?code=4%2Fx&state=forged")
        await #expect(throws: OAuthError.stateMismatch) { try await timeout.value }

        let denied = try LoopbackReceiver(state: "s")
        defer { denied.stop() }
        let declined = Task { try await denied.code(timeout: 10) }
        _ = try? await get("http://127.0.0.1:\(denied.port)/?error=access_denied&state=s")
        await #expect(throws: OAuthError.self) { try await declined.value }
    }

    @Test("The listener answers on the loopback only")
    func listenerIsLocalOnly() async throws {
        let listener = try LoopbackReceiver(state: "the-state")
        defer { listener.stop() }
        #expect(listener.port > 0)
        // the machine's own address is not it: nothing listens there
        let outside = URL(string: "http://\(Host.current().address ?? "127.0.0.1"):\(listener.port)/?code=x")
        if let outside, outside.host != "127.0.0.1" {
            var request = URLRequest(url: outside)
            request.timeoutInterval = 3
            await #expect(throws: (any Error).self) { try await URLSession.shared.data(for: request) }
        }
    }

    private func get(_ url: String) async throws -> String {
        var request = URLRequest(url: try #require(URL(string: url)))
        request.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: request)
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite("Konten mit Google-Anmeldung (7.1)")
struct OAuthAccountTests {
    @Test("An accounts.json from before 7.1 still reads, and a signed-in account round-trips")
    func accountsFileStaysReadable() throws {
        let old = Data("""
            [{"id":"gmail","kind":"gmail","displayName":"tj@gmail.example","username":"tj@gmail.example",
              "host":"imap.gmail.com","port":993,"security":{"tls":{}},"created":"2026-10-10T10:00:00Z",
              "policy":{"mode":"gmail","exclude":[],"includeJunk":false,"includeJunkAndTrash":false}}]
            """.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let accounts = try decoder.decode([AccountConfig].self, from: old)
        #expect(accounts.count == 1 && accounts[0].oauth == nil)  // no key = password, as before

        var signedIn = accounts[0]
        signedIn.oauth = AccountConfig.OAuth(clientID: "123-abc.apps.googleusercontent.com")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let again = try decoder.decode([AccountConfig].self, from: try encoder.encode([signedIn]))
        #expect(again[0].oauth?.clientID == "123-abc.apps.googleusercontent.com" && again[0].oauth?.provider == .google)
        // the file never holds a secret or a token
        let text = String(decoding: try encoder.encode([signedIn]), as: UTF8.self)
        #expect(!text.lowercased().contains("secret") && !text.lowercased().contains("token"))
    }

    @Test("Keychain keys: one mailbox, three separate entries, shared across archives")
    func keychainKeys() {
        var account = AccountConfig.gmail(id: "gmail", address: "tj@gmail.example")
        account.oauth = AccountConfig.OAuth(clientID: "123-abc.apps.googleusercontent.com")
        let other = AccountConfig.gmail(id: "zweitarchiv", address: "tj@gmail.example")
        #expect(CredentialStore.key(for: account) == "tj@gmail.example@imap.gmail.com:993")
        #expect(CredentialStore.refreshTokenKey(for: account) == "oauth-refresh:tj@gmail.example@imap.gmail.com:993")
        #expect(CredentialStore.clientSecretKey(for: account) == "oauth-client-secret:tj@gmail.example@imap.gmail.com:993")
        #expect(CredentialStore.refreshTokenKey(for: other) == CredentialStore.refreshTokenKey(for: account))
        #expect(CredentialStore.refreshTokenKey(for: account) != CredentialStore.clientSecretKey(for: account))
    }

    @Test("7.1 review S1: a pasted client id is trimmed before it is stored, not after")
    func clientIDIsTrimmedOnce() throws {
        #expect(AccountConfig.OAuth(clientID: " 123-abc.apps.googleusercontent.com\n").clientID
                == "123-abc.apps.googleusercontent.com")
        #expect(AccountConfig.OAuth(clientID: "   ").clientID == nil)  // empty = the app's own client
        #expect(AccountConfig.OAuth(clientID: nil).clientID == nil)
        // and through the file as well, so an older archive cannot smuggle one in
        let raw = Data(#"[{"id":"g","kind":"gmail","displayName":"d","username":"u@gmail.example","host":"imap.gmail.com","port":993,"security":{"tls":{}},"created":"2026-10-10T10:00:00Z","policy":{"mode":"gmail","exclude":[],"includeJunk":false,"includeJunkAndTrash":false},"oauth":{"provider":"google","clientID":"  123-x.apps.googleusercontent.com  "}}]"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([AccountConfig].self, from: raw)[0].oauth?.clientID == "123-x.apps.googleusercontent.com")
    }

    @Test("7.1 review S3: which client signs in — typed, then the account's, then the app's")
    func clientResolution() {
        let store = CredentialStore(service: "de.paranoidsecurity.MailKeeper.tests")
        var account = AccountConfig.gmail(id: "g", address: "tj@gmail.example")
        account.oauth = AccountConfig.OAuth(clientID: "111-known.apps.googleusercontent.com")
        // typed wins, and is trimmed
        #expect(OAuthTokens2Go.clientForSignIn(typedID: " 222-typed.apps.googleusercontent.com ", typedSecret: " s ",
                                               account: account, credentials: store)?.id == "222-typed.apps.googleusercontent.com")
        #expect(OAuthTokens2Go.clientForSignIn(typedID: "222-typed.apps.googleusercontent.com", typedSecret: " s ",
                                               account: account, credentials: store)?.secret == "s")
        // nothing typed: the account's own client
        #expect(OAuthTokens2Go.clientForSignIn(typedID: "", typedSecret: "", account: account, credentials: store)?.id
                == "111-known.apps.googleusercontent.com")
        // no account, nothing typed, no client in the build: nothing to sign in with
        #expect(OAuthTokens2Go.clientForSignIn(typedID: "", typedSecret: "", account: nil, credentials: store) == nil)
        // what gets written down: never the app's own client, so a later build may rotate it
        #expect(OAuthTokens2Go.storedClientID(" 123-x.apps.googleusercontent.com ") == "123-x.apps.googleusercontent.com")
        #expect(OAuthTokens2Go.storedClientID("  ") == nil)
    }

    @Test("Nachprüfung 7.1 B1: a typed secret counts even when the client id comes from elsewhere")
    func typedSecretWins() {
        let store = CredentialStore(service: "de.paranoidsecurity.MailKeeper.tests")
        var account = AccountConfig.gmail(id: "g", address: "tj@gmail.example")
        account.oauth = AccountConfig.OAuth(clientID: "111-known.apps.googleusercontent.com")
        let resolved = OAuthTokens2Go.clientForSignIn(typedID: "", typedSecret: " GOCSPX-typed ",
                                                      account: account, credentials: store)
        #expect(resolved?.id == "111-known.apps.googleusercontent.com" && resolved?.secret == "GOCSPX-typed")
    }

    @Test("7.1 review S7: Gmail ignores dots and googlemail.com — the same mailbox is not refused")
    func gmailAddressesAreFolded() {
        #expect(GoogleOAuth.sameMailbox("t.j@gmail.com", "tj@gmail.com"))
        #expect(GoogleOAuth.sameMailbox("tj@googlemail.com", "t.j@gmail.com"))
        #expect(GoogleOAuth.sameMailbox("TJ@Gmail.com", " tj@gmail.com "))
        #expect(!GoogleOAuth.sameMailbox("tj@gmail.com", "jemand@gmail.com"))
        // dots matter everywhere else
        #expect(!GoogleOAuth.sameMailbox("t.j@example.com", "tj@example.com"))
        #expect(GoogleOAuth.sameMailbox("t.j@example.com", "T.J@example.com"))
        #expect(!GoogleOAuth.sameMailbox("kaputt", "auch-kaputt"))
    }

    @Test("Text that came in over the wire is cut down before it is shown")
    func foreignTextIsTamed() {
        #expect(LoopbackReceiver.readable("access_denied") == "access_denied")
        #expect(LoopbackReceiver.readable("zeile\neins\r\u{7}") == "zeileeins")
        #expect(LoopbackReceiver.readable(String(repeating: "x", count: 500)).count == 100)
    }

    @Test("Without a client id there is no sign-in: a build without one says so instead of guessing")
    func clientMustBeKnown() {
        var account = AccountConfig.gmail(id: "gmail", address: "tj@gmail.example")
        account.oauth = AccountConfig.OAuth(clientID: nil)
        #expect(GoogleOAuth.builtInClient == nil)  // no verified client ships with MailKeeper yet
        #expect(OAuthTokens2Go.client(for: account, credentials: CredentialStore(service: "de.paranoidsecurity.MailKeeper.tests")) == nil)
        let password = AccountConfig.gmail(id: "alt", address: "tj@gmail.example")
        #expect(OAuthTokens2Go.client(for: password, credentials: CredentialStore(service: "de.paranoidsecurity.MailKeeper.tests")) == nil)
    }
}
