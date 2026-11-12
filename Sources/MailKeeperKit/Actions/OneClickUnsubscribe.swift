import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux
#endif

/// RFC 8058 one-click: one POST `List-Unsubscribe=One-Click` to the https target — no cookies, no
/// cache, no redirects (a redirect comes back as the answer; the caller opens the page instead),
/// 20 s at most, a plain user agent.
public enum OneClickUnsubscribe {
    /// The completion-handler form, not the async one: swift-corelibs-foundation knows only this
    /// one and follows redirects past an async method it does not see (review B2). On macOS
    /// both are the same Objective-C method.
    final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    /// The HTTP status. `protocolClasses` only for tests.
    public static func post(_ url: URL, protocolClasses: [AnyClass]? = nil) async throws -> Int {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        let session = makeSession(protocolClasses: protocolClasses)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("MailKeeper", forHTTPHeaderField: "User-Agent")  // no app version, no system details (review 6.5c C4)
        request.httpBody = Data("List-Unsubscribe=One-Click".utf8)
        let (_, response) = try await session.data(for: request)
        return (response as? HTTPURLResponse)?.statusCode ?? 0
    }

    /// No cookies, no cache, no redirects, 20 s. Separate so a test can hold it against a real
    /// server on loopback (`post` takes https only).
    static func makeSession(protocolClasses: [AnyClass]?) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }
}

/// Whether a host name leads into the public internet — not loopback, a private or link-local
/// network, carrier-grade NAT, unique-local IPv6, multicast or unspecified (review 6.5c S1: an
/// unsubscribe link must not make MailKeeper or the browser call into the user's own network).
/// Resolved right before the request; a resolver that answers differently a moment later
/// (DNS rebinding) is beyond this check.
public enum PublicHost {
    /// Nil when the name does not resolve.
    public static func resolvesPublicly(_ host: String) async -> Bool? {
        await Task.detached(priority: .userInitiated) { () -> Bool? in
            var hints = addrinfo()
            hints.ai_socktype = socketStream
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "443", &hints, &result) == 0, let first = result else { return nil }
            defer { freeaddrinfo(first) }
            var any = false
            var next: UnsafeMutablePointer<addrinfo>? = first
            while let entry = next {
                next = entry.pointee.ai_next
                guard let address = entry.pointee.ai_addr else { continue }
                switch Int32(address.pointee.sa_family) {
                case AF_INET:
                    let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { p in
                        withUnsafeBytes(of: p.pointee.sin_addr) { Array($0) }
                    }
                    guard isPublic(v4: bytes) else { return false }
                case AF_INET6:
                    let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { p in
                        withUnsafeBytes(of: p.pointee.sin6_addr) { Array($0) }
                    }
                    guard isPublic(v6: bytes) else { return false }
                default:
                    return false
                }
                any = true
            }
            return any
        }.value
    }

    static func isPublic(v4 b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        switch (b[0], b[1]) {
        case (0, _), (10, _), (127, _): return false
        case (100, 64...127): return false  // carrier-grade NAT
        case (169, 254): return false
        case (172, 16...31): return false
        case (192, 168): return false
        case (192, 0) where b[2] == 0: return false
        case (198, 18...19): return false
        default: return b[0] < 224  // multicast and reserved above
        }
    }

    static func isPublic(v6 b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPublic(v4: Array(b[12..<16])) }  // ::ffff:a.b.c.d
        if b[0..<15].allSatisfy({ $0 == 0 }) { return false }  // :: and ::1
        if b[0] & 0xfe == 0xfc { return false }  // fc00::/7 unique local
        if b[0] == 0xfe && b[1] & 0xc0 == 0x80 { return false }  // fe80::/10 link-local
        if b[0] == 0xfe && b[1] & 0xc0 == 0xc0 { return false }  // fec0::/10 site-local (old)
        if b[0] == 0xff { return false }  // multicast
        return true
    }
}
