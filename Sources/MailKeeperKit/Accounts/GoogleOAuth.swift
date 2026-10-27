import CryptoKit
import Foundation

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

    /// Whether it still has a minute to live (a token refreshed just before connecting must not
    /// expire mid-sync).
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
        case .denied(let s): "Google hat die Anmeldung abgelehnt: \(s)"
        case .noCode: "Google hat keinen Anmelde-Code zurückgegeben"
        case .stateMismatch: "Die Antwort im Browser gehört nicht zu dieser Anmeldung (state passt nicht)"
        case .server(let s): "Google antwortete: \(s)"
        case .listener(let s): "Rückkanal auf 127.0.0.1 nicht möglich: \(s)"
        case .timedOut: "Die Anmeldung im Browser wurde nicht abgeschlossen"
        case .cancelled: "Anmeldung abgebrochen"
        case .noRefreshToken(let id): "Für Konto „\(id)“ ist keine Google-Anmeldung im Schlüsselbund – bitte neu anmelden"
        case .notConfigured(let id): "Für Konto „\(id)“ fehlt die Google-Client-ID"
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
        let listener = try LoopbackReceiver()
        defer { listener.stop() }
        let redirect = "http://127.0.0.1:\(listener.port)"
        open(authorizationURL(clientID: clientID, redirect: redirect, verifier: verifier, state: state, loginHint: loginHint))
        let answer = try await listener.code(state: state, timeout: timeout)
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

    /// Tells Google the refresh token is gone (best effort: a revoked or expired one answers 400).
    static func revoke(_ refreshToken: String) async {
        var request = URLRequest(url: revocation)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(["token": refreshToken]).utf8)
        _ = try? await URLSession.shared.data(for: request)
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
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
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
            throw OAuthError.server(clean([error, answer.error_description].compactMap { $0 }.joined(separator: " – ")))
        }
        guard status == 200, let access = answer.access_token else { throw OAuthError.server("HTTP \(status)") }
        return OAuthTokens(accessToken: access, refreshToken: answer.refresh_token,
                           expires: Date().addingTimeInterval(answer.expires_in ?? 3600),
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
        if SecRandomCopyBytes(kSecRandomDefault, bytes, &random) != errSecSuccess {
            random = (0..<bytes).map { _ in UInt8.random(in: .min ... .max) }
        }
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
        if let new = fresh.refreshToken, new != refreshToken { try credentials.saveRefreshToken(new, for: account) }
        cache[key] = fresh
        return fresh.accessToken
    }

    /// After signing in or signing out, so the next connection does not use a stale token.
    public func forget(_ account: AccountConfig) {
        cache[CredentialStore.key(for: account)] = nil
    }

    public func remember(_ tokens: OAuthTokens, for account: AccountConfig) {
        cache[CredentialStore.key(for: account)] = tokens
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
    private let lock = NSLock()
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw OAuthError.listener(Self.reason()) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0  // the kernel picks a free one
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
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

    /// The query of the first request that carries one, once `state` matches.
    func code(state: String, timeout: TimeInterval) async throws -> String {
        let query: [String: String] = try await withThrowingTaskGroup(of: [String: String].self) { group in
            group.addTask { try await self.firstRequest() }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw OAuthError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw OAuthError.cancelled }
            return first
        }
        if let error = query["error"] { throw OAuthError.denied(String(error.prefix(100))) }
        guard query["state"] == state else { throw OAuthError.stateMismatch }
        guard let code = query["code"], !code.isEmpty else { throw OAuthError.noCode }
        return code
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
            let connection = Darwin.accept(socketFD, nil, nil)
            guard connection >= 0 else { return }  // closed: stop() had its say
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var buffer = [UInt8](repeating: 0, count: 8192)
            let read = recv(connection, &buffer, buffer.count, 0)
            let request = read > 0 ? String(decoding: buffer[0..<read], as: UTF8.self) : ""
            let query = Self.query(inRequest: request)
            Self.answer(connection, found: !query.isEmpty, ok: query["code"] != nil)
            close(connection)
            if !query.isEmpty {
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
