#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto  // swift-crypto, same API (Package.swift)
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux
#endif

/// Google sign-in for Gmail's IMAP (ADR-0012): the authorization code flow with PKCE and a
/// loopback redirect, as RFC 8252 asks of a native app. MailKeeper never sees the password;
/// what it keeps is a refresh token in the keychain.
///
/// The client belongs to whoever runs MailKeeper: today each Gmail account carries the client id
/// of a Google Cloud project its owner made (`AccountConfig.oauth`). `https://mail.google.com/`
/// is a restricted scope, so a client shipped with the app would need Google's verification with
/// a yearly CASA assessment — the day MailKeeper has one, `builtInClientID` holds it and the
/// account's own id becomes the exception, not the rule.
public enum GoogleOAuth: Sendable {
    /// Full IMAP access (restricted), plus the signed-in address so the app can tell the user
    /// when they picked a different Google account than the one being set up.
    public static let scope = "https://mail.google.com/ openid email"

    static let authorization = URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!
    static let token = URL(string: "https://oauth2.googleapis.com/token")!
    static let revocation = URL(string: "https://oauth2.googleapis.com/revoke")!

    /// The client MailKeeper ships with, from `Info.plist` (`MKGoogleClientID`/`MKGoogleClientSecret`).
    /// Empty in every build so far — see the note above.
    public static var builtInClient: (id: String, secret: String?)? {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "MKGoogleClientID") as? String, !id.isEmpty else { return nil }
        let secret = Bundle.main.object(forInfoDictionaryKey: "MKGoogleClientSecret") as? String
        return (id, (secret?.isEmpty ?? true) ? nil : secret)
    }

    /// Whether two Gmail addresses mean the same mailbox: Google ignores dots in the local
    /// part and treats googlemail.com as gmail.com, and the id token carries the canonical
    /// form — `t.j@gmail.com` and `tj@googlemail.com` are one account (review 7.1 S7).
    public static func sameMailbox(_ a: String, _ b: String) -> Bool {
        func folded(_ address: String) -> String {
            let parts = address.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "@")
            guard parts.count == 2 else { return address.lowercased() }
            let domain = parts[1] == "googlemail.com" ? "gmail.com" : String(parts[1])
            let local = domain == "gmail.com" ? parts[0].replacingOccurrences(of: ".", with: "") : String(parts[0])
            return "\(local)@\(domain)"
        }
        return folded(a) == folded(b)
    }

    /// A client id Google would recognise: `<digits>-<something>.apps.googleusercontent.com`.
    /// Checked when it is typed in, so a stray space or a pasted secret is caught before the browser.
    public static func isPlausibleClientID(_ id: String) -> Bool {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.count <= 200, id.hasSuffix(".apps.googleusercontent.com"),
              let dash = id.firstIndex(of: "-"), dash > id.startIndex else { return false }
        return id[id.startIndex..<dash].allSatisfy(\.isNumber)
            && id.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
    }
}

public struct OAuthTokens: Sendable, Equatable {
    public var accessToken: String
    /// Only the first exchange returns one; a refresh keeps the token it was given.
    public var refreshToken: String?
    public var expires: Date
    /// The address that signed in, from the id token (display only — it arrives over TLS from
    /// Google's token endpoint, but MailKeeper does not verify its signature).
    public var email: String?

    public init(accessToken: String, refreshToken: String?, expires: Date, email: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expires = expires
        self.email = email
    }

    /// Whether it has more than `slack` left — five minutes by default, so a sync that starts
    /// now does not run into a token expiring halfway through.
    public func isValid(at now: Date = Date(), slack: TimeInterval = 300) -> Bool {
        expires.timeIntervalSince(now) > slack
    }
}

public enum OAuthError: Error, CustomStringConvertible, Equatable {
    case denied(String)
    case noCode
    case stateMismatch
    case server(String)
    case listener(String)
    case timedOut
    case cancelled
    case noRefreshToken(String)
    case notConfigured(String)

    public var description: String {
        switch self {
        case .denied(let s): String(localized: "Google hat die Anmeldung abgelehnt: \(s)")
        case .noCode: String(localized: "Google hat keinen Anmelde-Code zurückgegeben")
        case .stateMismatch: String(localized: "Die Antwort im Browser gehört nicht zu dieser Anmeldung (state passt nicht)")
        case .server(let s): String(localized: "Google antwortete: \(s)")
        case .listener(let s): String(localized: "Rückkanal auf 127.0.0.1 nicht möglich: \(s)")
        case .timedOut: String(localized: "Die Anmeldung im Browser wurde nicht abgeschlossen")
        case .cancelled: String(localized: "Anmeldung abgebrochen")
        case .noRefreshToken(let id): String(localized: "Für Konto „\(id)“ ist keine Google-Anmeldung im Schlüsselbund – bitte neu anmelden")
        case .notConfigured(let id): String(localized: "Für Konto „\(id)“ fehlt die Google-Client-ID")
        }
    }
}

// MARK: - The flow

public extension GoogleOAuth {
    /// Signs in: opens `open` with Google's consent page and waits for the browser to come back
    /// to the loopback address. The verifier never leaves this process; the code is exchanged
    /// against Google directly.
    ///
    /// - Parameter open: hands the URL to the user's browser (the GUI uses `NSWorkspace`).
    static func signIn(clientID: String, clientSecret: String?, loginHint: String? = nil,
                       timeout: TimeInterval = 300, open: @Sendable (URL) -> Void) async throws -> OAuthTokens {
        let verifier = randomURLSafe(64)
        let state = randomURLSafe(24)
        let listener = try LoopbackReceiver(state: state)
        defer { listener.stop() }
        let redirect = "http://127.0.0.1:\(listener.port)"
        open(authorizationURL(clientID: clientID, redirect: redirect, verifier: verifier, state: state, loginHint: loginHint))
        let answer = try await listener.code(timeout: timeout)
        return try await exchange(code: answer, clientID: clientID, clientSecret: clientSecret,
                                  redirect: redirect, verifier: verifier)
    }

    static func authorizationURL(clientID: String, redirect: String, verifier: String, state: String,
                                 loginHint: String?) -> URL {
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            // offline + consent: Google hands out a refresh token on every run, not just the first
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
        ]
        if let loginHint, !loginHint.isEmpty { items.append(URLQueryItem(name: "login_hint", value: loginHint)) }
        var components = URLComponents(url: authorization, resolvingAgainstBaseURL: false)!
        components.queryItems = items
        return components.url!
    }

    static func exchange(code: String, clientID: String, clientSecret: String?, redirect: String,
                         verifier: String) async throws -> OAuthTokens {
        var form = ["client_id": clientID, "code": code, "code_verifier": verifier,
                    "redirect_uri": redirect, "grant_type": "authorization_code"]
        if let clientSecret, !clientSecret.isEmpty { form["client_secret"] = clientSecret }
        return try await post(form)
    }

    /// A fresh access token. Google keeps the refresh token; the answer carries none.
    static func refresh(_ refreshToken: String, clientID: String, clientSecret: String?) async throws -> OAuthTokens {
        var form = ["client_id": clientID, "refresh_token": refreshToken, "grant_type": "refresh_token"]
        if let clientSecret, !clientSecret.isEmpty { form["client_secret"] = clientSecret }
        var tokens = try await post(form)
        tokens.refreshToken = tokens.refreshToken ?? refreshToken
        return tokens
    }

    /// Tells Google the sign-in is over (best effort: a revoked or expired token answers 400).
    ///
    /// **Googles Widerruf gilt der Freigabe, nicht dem einzelnen Token**: ein `/revoke` nimmt der
    /// App die Zustimmung dieses Nutzers, und damit fallen auch die anderen Refresh-Tokens
    /// derselben Freigabe. Deshalb wird hier nur widerrufen, wenn die Anmeldung wirklich weg
    /// soll — nie, um ein ersetztes oder verworfenes Token aufzuräumen, solange eine gültige
    /// Anmeldung im Schlüsselbund liegt (Nachprüfung 7.1 B1).
    @discardableResult
    static func revoke(_ refreshToken: String) async -> Bool {
        var request = URLRequest(url: revocation)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(["token": refreshToken]).utf8)
        request.timeoutInterval = 10  // offline, this must not hold a window for a minute
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return status == 200 || status == 400  // 400: already revoked or expired — gone either way
    }

    private static func post(_ fields: [String: String]) async throws -> OAuthTokens {
        var request = URLRequest(url: token)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(fields).utf8)
        request.timeoutInterval = 30
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) } catch {
            throw OAuthError.server(clean("\(error)"))
        }
        return try tokens(from: data, status: (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// Google's answer to a token request. `invalid_grant` is the one worth naming: the sign-in
    /// was revoked or expired (in test mode after 7 days) and the user has to sign in again.
    static func tokens(from data: Data, status: Int, now: Date = Date()) throws -> OAuthTokens {
        struct Answer: Decodable {
            let access_token: String?
            let refresh_token: String?
            let expires_in: Double?
            let id_token: String?
            let error: String?
            let error_description: String?
        }
        guard let answer = try? JSONDecoder().decode(Answer.self, from: data) else {
            throw OAuthError.server("HTTP \(status)")
        }
        if let error = answer.error {
            let detail = clean([error, answer.error_description].compactMap { $0 }.joined(separator: " – "))
            throw OAuthError.server(error == "invalid_grant"
                ? "\(detail). Die Anmeldung gilt nicht mehr – bitte neu anmelden (im Testmodus läuft sie nach 7 Tagen ab)."
                : detail)
        }
        guard status == 200, let access = answer.access_token, !access.isEmpty else {
            throw OAuthError.server("HTTP \(status)")
        }
        // a server that promises nothing gets an hour; one that promises too much is capped
        let lifetime = min(max(answer.expires_in ?? 3600, 0), 86_400)
        return OAuthTokens(accessToken: access, refreshToken: answer.refresh_token,
                           expires: now.addingTimeInterval(lifetime),
                           email: answer.id_token.flatMap(email(inIDToken:)))
    }

    /// The `email` claim of an unverified id token (display only, see `OAuthTokens.email`).
    static func email(inIDToken idToken: String) -> String? {
        let parts = idToken.split(separator: ".")
        guard parts.count == 3, let payload = decodeBase64URL(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let email = json["email"] as? String, email.count <= 320 else { return nil }
        return email
    }

    private static func form(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
        }.joined(separator: "&")
    }

    /// Never let a token or a code reach a message (errors are shown and logged).
    private static func clean(_ text: String) -> String {
        String(text.replacingOccurrences(of: "\n", with: " ").prefix(200))
    }

    // MARK: PKCE

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func randomURLSafe(_ bytes: Int) -> String {
        var random = [UInt8](repeating: 0, count: bytes)
        #if canImport(Security)
        if SecRandomCopyBytes(kSecRandomDefault, bytes, &random) != errSecSuccess {
            random = (0..<bytes).map { _ in UInt8.random(in: .min ... .max) }
        }
        #else
        // SystemRandomNumberGenerator is the system's CSPRNG (getrandom on Linux).
        var generator = SystemRandomNumberGenerator()
        random = (0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        #endif
        return base64URL(Data(random))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ s: String) -> Data? {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
}

/// Hands out access tokens for signed-in accounts and keeps the last one until it is nearly
/// spent — one refresh per app start and hour, not per connection. The refresh token stays in
/// the keychain; a new one Google hands out on the way replaces it there.
public actor OAuthTokens2Go {
    public static let shared = OAuthTokens2Go()
    private var cache: [String: OAuthTokens] = [:]

    public init() {}

    /// The client of an account: its own, else the one the app ships with.
    public static func client(for account: AccountConfig, credentials: CredentialStore) -> (id: String, secret: String?)? {
        guard let oauth = account.oauth else { return nil }
        guard let id = oauth.clientID, !id.isEmpty else { return GoogleOAuth.builtInClient }
        return (id, (try? credentials.clientSecret(for: account)) ?? GoogleOAuth.builtInClient?.secret)
    }

    /// Which client a sign-in should use: what the user typed, else what the account already
    /// has (the secret from the keychain), else the one the app ships with. One place for the
    /// GUI and the CLI, so a build with a verified client of its own needs nothing typed in
    /// (review 7.1 S3).
    public static func clientForSignIn(typedID: String, typedSecret: String, account: AccountConfig?,
                                       credentials: CredentialStore = CredentialStore()) -> (id: String, secret: String?)? {
        let id = typedID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = typedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        let known = account.flatMap { client(for: $0, credentials: credentials) }
        guard !id.isEmpty else {
            guard let fallback = known ?? GoogleOAuth.builtInClient else { return nil }
            return (fallback.id, secret.isEmpty ? fallback.secret : secret)  // a typed secret wins
        }
        if !secret.isEmpty { return (id, secret) }
        // the same client as before (or the built-in one): its secret is already known
        if let known, known.id == id { return known }
        if let built = GoogleOAuth.builtInClient, built.id == id { return built }
        return (id, nil)
    }

    /// What to store in `accounts.json`: nothing, when it is the client the app ships with —
    /// then a later build may rotate it without stranding the account.
    public static func storedClientID(_ id: String) -> String? {
        let id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty || id == GoogleOAuth.builtInClient?.id ? nil : id
    }

    /// Only the access token and its expiry are kept — never the refresh token (ADR-0012 §5).
    private static func cacheable(_ tokens: OAuthTokens) -> OAuthTokens {
        OAuthTokens(accessToken: tokens.accessToken, refreshToken: nil, expires: tokens.expires)
    }

    public func accessToken(for account: AccountConfig, credentials: CredentialStore = CredentialStore()) async throws -> String {
        let key = CredentialStore.key(for: account)
        if let known = cache[key], known.isValid() { return known.accessToken }
        guard let client = Self.client(for: account, credentials: credentials) else {
            throw OAuthError.notConfigured(account.id)
        }
        guard let refreshToken = try credentials.refreshToken(for: account) else {
            throw OAuthError.noRefreshToken(account.id)
        }
        let fresh = try await GoogleOAuth.refresh(refreshToken, clientID: client.id, clientSecret: client.secret)
        // A rotated refresh token replaces the stored one; the old one is NOT revoked — that
        // would take the whole grant with it, the new token included.
        if let new = fresh.refreshToken, new != refreshToken { try credentials.saveRefreshToken(new, for: account) }
        cache[key] = Self.cacheable(fresh)
        return fresh.accessToken
    }

    /// After signing in or signing out, so the next connection does not use a stale token.
    public func forget(_ account: AccountConfig) {
        cache[CredentialStore.key(for: account)] = nil
    }

    public func remember(_ tokens: OAuthTokens, for account: AccountConfig) {
        cache[CredentialStore.key(for: account)] = Self.cacheable(tokens)
    }
}

// MARK: - The loopback redirect

/// A one-shot HTTP server on 127.0.0.1 with a port the system picks: it takes the one redirect
/// Google sends the browser to and then stops. It binds the loopback address only — nothing on
/// the network can reach it (RFC 8252 §7.3) — serves that single answer and nothing else, and
/// reads at most 8 KiB of the request.
final class LoopbackReceiver: @unchecked Sendable {
    private let socketFD: Int32
    private let queue = DispatchQueue(label: "de.paranoidsecurity.MailKeeper.oauth")
    private var waiting: CheckedContinuation<[String: String], Error>?
    /// What the browser brought, kept until someone asks: the redirect may arrive before the
    /// caller awaits, and a dropped answer would hang the sign-in until it times out.
    private var answer: Result<[String: String], Error>?
    private var closed = false
    /// The `state` of this sign-in — known before the socket exists, so a redirect can never
    /// arrive before the listener knows what it is waiting for.
    private let expected: String
    /// Something answered on this port that did not belong to the sign-in.
    private var foreign = false
    private let lock = NSLock()
    let port: UInt16

    init(state: String) throws {
        expected = state
        let fd = socket(AF_INET, socketStream, 0)
        guard fd >= 0 else { throw OAuthError.listener(Self.reason()) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // the kernel picks a free one
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        #if !canImport(Glibc)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)  // BSD only
        #endif
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else {
            let reason = Self.reason()
            close(fd)
            throw OAuthError.listener(reason)
        }
        var bound4 = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound4) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0, bound4.sin_port != 0 else {
            let reason = Self.reason()
            close(fd)
            throw OAuthError.listener(reason)
        }
        socketFD = fd
        port = UInt16(bigEndian: bound4.sin_port)
        queue.async { [weak self] in self?.accept() }
    }

    private static func reason() -> String { String(cString: strerror(errno)) }

    /// The redirect of this sign-in. Requests with another `state` are answered and ignored:
    /// the port is visible to every process on this Mac, and a stray `?error=…` must not be
    /// able to end a sign-in or put its text in front of the user (review 7.1 C1).
    func code(timeout: TimeInterval) async throws -> String {
        let query: [String: String] = try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await self.firstRequest() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw OAuthError.timedOut
            }
            defer { group.cancelAll() }
            do {
                guard let first = try await group.next() else { throw OAuthError.cancelled }
                return first
            } catch OAuthError.timedOut where sawForeignState {
                // something answered, but never this sign-in: say that, not "nothing happened"
                throw OAuthError.stateMismatch
            }
        }
        if let error = query["error"] { throw OAuthError.denied(Self.readable(error)) }
        guard let code = query["code"], !code.isEmpty else { throw OAuthError.noCode }
        return code
    }

    private func noteForeignState() {
        lock.lock()
        foreign = true
        lock.unlock()
    }

    private var sawForeignState: Bool {
        lock.lock()
        defer { lock.unlock() }
        return foreign
    }

    /// Text that came in over the wire, fit to show: printable, short, one line.
    static func readable(_ text: String) -> String {
        String(text.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && $0 != "\n" && $0 != "\r"
                                            && !CharacterSet.controlCharacters.contains($0) }
            .map(Character.init).prefix(100))
    }

    private func firstRequest() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let answer {
                    lock.unlock()
                    continuation.resume(with: answer)
                    return
                }
                waiting = continuation
                lock.unlock()
            }
        } onCancel: {
            stop()
        }
    }

    /// Serves until a request carries a query (a browser may ask for /favicon.ico first) or the
    /// socket is closed from `stop()`.
    private func accept() {
        while true {
            #if canImport(Glibc)
            let connection = Glibc.accept(socketFD, nil, nil)
            #else
            let connection = Darwin.accept(socketFD, nil, nil)
            #endif
            guard connection >= 0 else { return }  // closed: stop() had its say
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 8192)
            let read = recv(connection, &buffer, buffer.count, 0)
            let request = read > 0 ? String(decoding: buffer[0..<read], as: UTF8.self) : ""
            let query = Self.query(inRequest: request)
            // ours only when it carries this sign-in's state; anything else gets a 404 and the
            // listener keeps waiting (a browser asks for /favicon.ico, other processes may knock)
            let mine = !query.isEmpty && query["state"] == expected
            if !mine, !query.isEmpty { noteForeignState() }
            Self.answer(connection, found: mine, ok: mine && query["code"] != nil)
            close(connection)
            if mine {
                finish(.success(query))
                return
            }
        }
    }

    private static func answer(_ connection: Int32, found: Bool, ok: Bool) {
        let page = page(ok: ok)
        let status = found ? "200 OK" : "404 Not Found"
        var out = Data("HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(page)
        out.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let n = send(connection, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if n <= 0 { return }
                sent += n
            }
        }
    }

    /// `GET /?code=…&state=… HTTP/1.1` → the query as a dictionary.
    static func query(inRequest request: String) -> [String: String] {
        guard let line = request.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first else { return [:] }
        let fields = line.split(separator: " ")
        guard fields.count >= 2, fields[0] == "GET",
              let components = URLComponents(string: "http://127.0.0.1" + fields[1]) else { return [:] }
        return Dictionary(components.queryItems?.compactMap { item in
            item.value.map { (item.name, $0) }
        } ?? [], uniquingKeysWith: { a, _ in a })
    }

    private static func page(ok: Bool) -> Data {
        let title = ok ? "Angemeldet" : "Nicht angemeldet"
        let text = ok ? "MailKeeper hat die Anmeldung erhalten. Du kannst dieses Fenster schließen."
                      : "MailKeeper hat keine Anmeldung erhalten. Zurück in der App kannst du es erneut versuchen."
        return Data("""
            <!doctype html><html lang="de"><head><meta charset="utf-8"><title>MailKeeper</title>
            <style>body{font:16px -apple-system,system-ui,sans-serif;margin:16vh auto;max-width:28rem;padding:0 1.5rem;color:#1d1d1f}
            h1{font-size:1.3rem}@media(prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}}</style>
            </head><body><h1>\(title)</h1><p>\(text)</p></body></html>
            """.utf8)
    }

    /// The first answer wins — a later `stop()` must not cancel a sign-in that already arrived.
    private func finish(_ result: Result<[String: String], Error>) {
        lock.lock()
        guard answer == nil else { return lock.unlock() }
        answer = result
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume(with: result)
    }

    func stop() {
        finish(.failure(OAuthError.cancelled))
        lock.lock()
        let first = !closed
        closed = true
        lock.unlock()
        if first { close(socketFD) }  // breaks accept()
    }

    deinit { stop() }
}
