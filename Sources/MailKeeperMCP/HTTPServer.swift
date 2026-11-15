import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1

public struct HTTPRequest: Sendable {
    public var method: String
    public var path: String
    /// Lower-cased names; repeated headers joined with ", ".
    public var headers: [String: String]
    public var body: Data

    public init(method: String, path: String, headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [(String, String)]
    public var body: Data

    public static func json(_ status: Int, _ value: JSONValue) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: value.serialized())
    }

    public static func text(_ status: Int, _ text: String, extra: [(String, String)] = []) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "text/plain; charset=utf-8")] + extra, body: Data(text.utf8))
    }

    public static func empty(_ status: Int) -> HTTPResponse { HTTPResponse(status: status, headers: [], body: Data()) }
}

/// A small HTTP/1.1 server: one request at a time per connection, bodies bounded, the handler
/// asynchronous. No TLS — it listens on loopback (MCP) or answers only `/healthz`.
public enum HTTPServer {
    public static let maxBody = 1 << 20

    /// Binds, calls `bound` with the port, serves until cancelled. `idle`: a connection that
    /// sends nothing for this long is closed (above the longest answer, which sends nothing
    /// either); `maxConnections`: more at a time are closed at once — a flood must not take the
    /// process' file descriptors.
    public static func run(host: String, port: Int, group: any EventLoopGroup = MultiThreadedEventLoopGroup.singleton,
                           maxBody: Int = maxBody, idle: TimeAmount = .seconds(300), maxConnections: Int = 64,
                           bound: @Sendable (Int) -> Void = { _ in },
                           handler: @escaping @Sendable (HTTPRequest) async -> HTTPResponse) async throws {
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(.backlog, value: 64)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            // no `.socketOption(.tcp_nodelay)`: that sets it on SOL_SOCKET, which on Linux is
            // SO_DEBUG and needs CAP_NET_ADMIN (EACCES); NIO enables TCP_NODELAY on accepted channels itself
            .bind(host: host, port: port) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(IdleStateHandler(readTimeout: idle))
                    try channel.pipeline.syncOperations.addHandler(CloseWhenIdle())
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline(withErrorHandling: true)
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(wrappingChannelSynchronously: channel)
                }
            }
        bound(server.channel.localAddress?.port ?? port)
        let open = ConnectionCount()
        try await withThrowingDiscardingTaskGroup { tasks in
            try await server.executeThenClose { connections in
                for try await connection in connections {
                    guard await open.enter(max: maxConnections) else {
                        try? await connection.channel.close()
                        continue
                    }
                    tasks.addTask {
                        await serve(connection, maxBody: maxBody, handler: handler)
                        await open.leave()
                    }
                }
            }
        }
    }

    static func serve(_ connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, maxBody: Int,
                      handler: @Sendable (HTTPRequest) async -> HTTPResponse) async {
        do {
            try await connection.executeThenClose { inbound, outbound in
                var head: HTTPRequestHead?
                var body = ByteBuffer()
                var tooLarge = false
                for try await part in inbound {
                    switch part {
                    case .head(let h):
                        head = h
                        body.clear()
                        tooLarge = false
                        // announced too large: refuse before the body comes, then close
                        if let length = h.headers.first(name: "content-length").flatMap(Int.init), length > maxBody {
                            try await respond(outbound, version: h.version, .text(413, "body too large"), keepAlive: false)
                            return
                        }
                        // curl (URLSession on Linux) asks before sending a body above 1 KiB
                        if h.headers.first(name: "expect")?.lowercased() == "100-continue" {
                            try await outbound.write(.head(HTTPResponseHead(version: h.version, status: .continue)))
                        }
                    case .body(var chunk):
                        if tooLarge || body.readableBytes + chunk.readableBytes > maxBody { tooLarge = true } else { body.writeBuffer(&chunk) }
                    case .end:
                        guard let h = head else { continue }
                        head = nil
                        var headers: [String: String] = [:]
                        for (name, value) in h.headers {
                            let key = name.lowercased()
                            headers[key] = headers[key].map { $0 + ", " + value } ?? value
                        }
                        let path = String(h.uri.prefix(2_048))
                        let response = tooLarge ? .text(413, "body too large")
                            : await handler(HTTPRequest(method: h.method.rawValue, path: path, headers: headers,
                                                        body: Data(body.readableBytesView)))
                        let keepAlive = h.isKeepAlive && !tooLarge
                        try await respond(outbound, version: h.version, response, keepAlive: keepAlive)
                        if !keepAlive { return }
                    }
                }
            }
        } catch {
            // a client that went away mid-request: nothing to answer
        }
    }

    static func respond(_ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>, version: HTTPVersion,
                        _ response: HTTPResponse, keepAlive: Bool) async throws {
        var out = HTTPHeaders()
        for (n, v) in response.headers { out.add(name: n, value: v) }
        out.replaceOrAdd(name: "Content-Length", value: String(response.body.count))
        out.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        out.replaceOrAdd(name: "Cache-Control", value: "no-store")
        try await outbound.write(.head(HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: response.status), headers: out)))
        if !response.body.isEmpty { try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: response.body)))) }
        try await outbound.write(.end(nil))
    }
}

actor ConnectionCount {
    private var open = 0
    func enter(max: Int) -> Bool {
        guard open < max else { return false }
        open += 1
        return true
    }
    func leave() { open -= 1 }
}

/// Closes a connection on `IdleStateHandler`'s read timeout.
final class CloseWhenIdle: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent { context.close(promise: nil) } else { context.fireUserInboundEventTriggered(event) }
    }
}
