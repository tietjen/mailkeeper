import Foundation

/// An HTTP server on 127.0.0.1 with one thread, for tests that need a real connection: a
/// URLProtocol stub skips exactly the transport under test (redirects, Content-Length). The same
/// file is in MailKeeperKitTests and MailKeeperAITests — test targets share no code.
final class LoopbackHTTPServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var lines: [String] = []

    /// Request lines seen so far ("POST /first HTTP/1.1").
    var requests: [String] { lock.withLock { lines } }

    /// `respond` gets the request line and a `send` that says whether the peer still listens.
    init(respond: @escaping @Sendable (_ requestLine: String, _ send: (Data) -> Bool) -> Void) throws {
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
        #if !canImport(Glibc)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let listening = withUnsafeMutablePointer(to: &address) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, length) == 0 && listen(fd, 8) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard listening else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in serve(respond) }
    }

    /// shutdown, not only close: on Linux a closed descriptor does not wake a blocked accept().
    func stop() {
        shutdown(listener, Int32(SHUT_RDWR))
        close(listener)
    }

    private func serve(_ respond: @Sendable (String, (Data) -> Bool) -> Void) {
        while true {
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            #if !canImport(Glibc)
            var on: Int32 = 1  // a client that hangs up must not end the test run with SIGPIPE
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var buffer = [UInt8](repeating: 0, count: 65_536)
            let count = recv(connection, &buffer, buffer.count, 0)
            let line = String(decoding: buffer.prefix(max(count, 0)), as: UTF8.self).components(separatedBy: "\r\n").first ?? ""
            lock.withLock { lines.append(line) }
            respond(line) { data in
                data.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        #if canImport(Glibc)
                        let sent = Glibc.send(connection, raw.baseAddress! + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                        #else
                        let sent = Darwin.send(connection, raw.baseAddress! + offset, raw.count - offset, 0)
                        #endif
                        guard sent > 0 else { return false }
                        offset += sent
                    }
                    return true
                }
            }
            close(connection)
        }
    }
}
