import CryptoKit
import Foundation
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL
import Synchronization

struct IMAPError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Bridges the NIO pipeline into an AsyncSequence of parsed responses.
final class ResponseStream: ChannelInboundHandler {
    typealias InboundIn = Response
    let continuation: AsyncThrowingStream<Response, Error>.Continuation
    init(_ c: AsyncThrowingStream<Response, Error>.Continuation) { continuation = c }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
    }
}

struct FetchedMessage {
    var uid: UInt32?
    var flags: [String] = []
    var internalDate: String?
    var size: Int?
    var body = Data()
    var gmailMessageID: UInt64?
    var gmailThreadID: UInt64?
    var gmailLabels: [String] = []
    var modseq: String?
}

struct CommandResult {
    var untagged: [ResponsePayload] = []
    var fetches: [FetchedMessage] = []
    var ok = false
    var text = ""
    var code: ResponseTextCode?
}

/// Records the leaf certificate fingerprint and enforces a pin (trust on first use).
final class PinBox: Sendable {
    private let value = Mutex<String?>(nil)
    var seen: String? { value.withLock { $0 } }
    func set(_ s: String) { value.withLock { $0 = s } }
}

final class IMAPConnection {
    let channel: Channel
    private var iterator: AsyncThrowingStream<Response, Error>.AsyncIterator
    private var tag = 0
    private(set) var greeting = ""

    private init(channel: Channel, stream: AsyncThrowingStream<Response, Error>) {
        self.channel = channel
        iterator = stream.makeAsyncIterator()
    }

    static func connect(host: String, port: Int, implicitTLS: Bool) async throws -> IMAPConnection {
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        tls.certificateVerification = .fullVerification
        let ctx = try NIOSSLContext(configuration: tls)
        let (stream, cont) = AsyncThrowingStream<Response, Error>.makeStream()
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    if implicitTLS {
                        try ch.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: ctx, serverHostname: host))
                    }
                    try ch.pipeline.syncOperations.addHandlers([IMAPClientHandler(), ResponseStream(cont)])
                }
            }
            .connect(host: host, port: port).get()
        let conn = IMAPConnection(channel: channel, stream: stream)
        // Greeting: first untagged OK/PREAUTH.
        if let first = try await conn.iterator.next() { conn.greeting = "\(first)" }
        return conn
    }

    /// STARTTLS, then pin the server's leaf certificate instead of chain/hostname checks
    /// (Proton Bridge serves a self-signed certificate on 127.0.0.1).
    func startTLSPinned(expected: String?, seen: PinBox) async throws {
        let r = try await run(.startTLS)
        guard r.ok else { throw IMAPError("STARTTLS refused: \(r.text)") }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        tls.certificateVerification = .noHostnameVerification
        let ctx = try NIOSSLContext(configuration: tls)
        let handler = try NIOSSLClientHandler(context: ctx, serverHostname: nil) { certs, promise in
            let fp = certs.first.map { leaf in
                SHA256.hash(data: Data((try? leaf.toDERBytes()) ?? [])).map { String(format: "%02x", $0) }.joined()
            } ?? ""
            seen.set(fp)
            promise.succeed(expected == nil || expected == fp ? .certificateVerified : .failed)
        }
        try await channel.pipeline.addHandler(handler, position: .first).get()
    }

    @discardableResult
    func run(_ command: Command, timeout: Double = 60) async throws -> CommandResult {
        tag += 1
        let t = "A\(tag)"
        try await channel.writeAndFlush(IMAPClientHandler.Message.part(.tagged(TaggedCommand(tag: t, command: command))))
        return try await collect(tag: t, timeout: timeout)
    }

    /// APPEND one message with flags and an explicit INTERNALDATE.
    func append(to mailbox: MailboxName, message: Data, flags: [Flag], date: ServerMessageDate?) async throws -> CommandResult {
        tag += 1
        let t = "A\(tag)"
        let parts: [CommandStreamPart] = [
            .append(.start(tag: t, appendingTo: mailbox)),
            .append(.beginMessage(message: AppendMessage(
                options: AppendOptions(flagList: flags, internalDate: date, extensions: [:]),
                data: AppendData(byteCount: message.count)))),
            .append(.messageBytes(ByteBuffer(bytes: message))),
            .append(.endMessage),
            .append(.finish),
        ]
        var writes: [EventLoopFuture<Void>] = []
        for p in parts { writes.append(channel.write(IMAPClientHandler.Message.part(p))) }
        channel.flush()
        let result = try await collect(tag: t, timeout: 120)
        for w in writes { try await w.get() }
        return result
    }

    func close() async {
        _ = try? await run(.logout, timeout: 10)
        try? await channel.close()
    }

    private func collect(tag t: String, timeout: Double) async throws -> CommandResult {
        let deadline = Date().addingTimeInterval(timeout)
        var result = CommandResult()
        var current: FetchedMessage?
        while true {
            if Date() > deadline { throw IMAPError("timeout waiting for \(t)") }
            guard let r = try await iterator.next() else { throw IMAPError("connection closed during \(t)") }
            switch r {
            case .untagged(let payload):
                result.untagged.append(payload)
            case .fetch(let f):
                switch f {
                case .start:
                    current = FetchedMessage()
                case .startUID(let uid):
                    current = FetchedMessage(uid: uid.rawValue)
                case .simpleAttribute(let a):
                    if current != nil { Self.apply(a, to: &current!) }
                case .streamingBegin(_, let count):
                    current?.body.reserveCapacity(count)
                case .streamingBytes(let bytes):
                    current?.body.append(contentsOf: bytes.readableBytesView)
                case .streamingEnd:
                    break
                case .finish:
                    if let c = current { result.fetches.append(c) }
                    current = nil
                }
            case .tagged(let tagged) where tagged.tag == t:
                switch tagged.state {
                case .ok(let text): result.ok = true; result.text = text.text; result.code = text.code
                case .no(let text), .bad(let text): result.ok = false; result.text = text.text; result.code = text.code
                }
                return result
            case .fatal(let text):
                throw IMAPError("BYE: \(text.text)")
            default:
                continue
            }
        }
    }

    private static func apply(_ a: MessageAttribute, to m: inout FetchedMessage) {
        switch a {
        case .uid(let uid): m.uid = uid.rawValue
        case .flags(let flags): m.flags = flags.map { String($0) }
        case .internalDate(let d):
            let c = d.components
            m.internalDate = String(format: "%04d-%02d-%02d %02d:%02d:%02d %+05d",
                                    c.year, c.month, c.day, c.hour, c.minute, c.second, c.zoneMinutes / 60 * 100 + c.zoneMinutes % 60)
        case .rfc822Size(let n): m.size = n
        case .gmailMessageID(let id): m.gmailMessageID = id
        case .gmailThreadID(let id): m.gmailThreadID = id
        case .gmailLabels(let labels): m.gmailLabels = labels.map { String(describing: $0) }
        case .fetchModificationSequence(let v): m.modseq = "\(v)"
        default: break
        }
    }
}

extension MailboxName {
    init(_ s: String) { self.init(ByteBuffer(string: s)) }
    var string: String { String(decoding: bytes, as: UTF8.self) }
}

func sha256(_ d: Data) -> String {
    SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
}
