import CryptoKit
import Foundation
import MailKeeperKit
import NIOCore
import NIOIMAP
import NIOPosix
import NIOSSL
import Synchronization

public enum IMAPSecurity: Sendable, Codable, Equatable {
    /// Implicit TLS (port 993), full certificate and hostname verification.
    case tls
    /// STARTTLS with full verification.
    case startTLS
    /// STARTTLS to a local bridge with a self-signed certificate: the leaf certificate is
    /// pinned. `nil` = learn mode (accept and report the fingerprint for the user to confirm).
    case startTLSPinned(fingerprint: String?)
}

public struct IMAPEndpoint: Sendable, Codable, Equatable {
    public var host: String
    public var port: Int
    public var security: IMAPSecurity

    public init(host: String, port: Int, security: IMAPSecurity) {
        self.host = host
        self.port = port
        self.security = security
    }
}

public enum IMAPError: Error, CustomStringConvertible, Equatable {
    case connection(String)
    case pinMismatch(expected: String, actual: String)
    case authentication(String)
    case command(String, String)
    case readOnlyViolation(String)
    case closed
    case protocolError(String)

    public var description: String {
        switch self {
        case .connection(let s): "Verbindung fehlgeschlagen: \(s)"
        case .pinMismatch(let e, let a): "Zertifikat der Bridge hat sich geändert (erwartet \(e.prefix(16))…, erhalten \(a.prefix(16))…)"
        case .authentication(let s): "Anmeldung abgelehnt: \(s)"
        case .command(let c, let s): "\(c) abgelehnt: \(s)"
        case .readOnlyViolation(let c): "\(c) ist im Nur-Lese-Modus nicht erlaubt"
        case .closed: "Verbindung geschlossen oder Zeitüberschreitung"
        case .protocolError(let s): "Protokollfehler: \(s)"
        }
    }
}

/// One IMAP connection, read-only (Phase 2): mailboxes are opened with EXAMINE, bodies fetched
/// with BODY.PEEK, and every command passes an allowlist — nothing can change server state.
/// Commands are serialised; the session is not meant for concurrent use.
public actor IMAPSession: MailboxSource {
    public let endpoint: IMAPEndpoint
    public private(set) var serverCapabilities: [String] = []
    /// SHA-256 of the server's leaf certificate (STARTTLS pinned/learn mode).
    public private(set) var certificateFingerprint: String?

    private let channel: Channel
    private var responses: AsyncThrowingStream<Response, Error>.AsyncIterator
    private var tag = 0
    private var busy = false
    private var mailboxNames: [String: MailboxName] = [:]
    private var currentExists = 0
    private var gmail = false
    private var condstore = false

    private init(endpoint: IMAPEndpoint, channel: Channel, responses: AsyncThrowingStream<Response, Error>) {
        self.endpoint = endpoint
        self.channel = channel
        self.responses = responses.makeAsyncIterator()
    }

    /// Connects, secures and logs in. `readTimeout` closes the connection when the server goes
    /// silent while a command is outstanding (and between commands).
    public static func connect(_ endpoint: IMAPEndpoint, username: String, password: String,
                               readTimeout: TimeAmount = .seconds(120)) async throws -> IMAPSession {
        let session: IMAPSession
        let clock = ContinuousClock(), start = clock.now
        do {
            session = try await open(endpoint, readTimeout: readTimeout)
            debug("connect+TLS+greeting \(clock.now - start)")
        } catch let error as IMAPError {
            throw error
        } catch {
            throw IMAPError.connection(Self.clean("\(error)"))
        }
        do {
            let t = clock.now
            try await session.secureAndLogin(username: username, password: password)
            debug("starttls+login \(clock.now - t)")
        } catch {
            await session.close()
            throw error
        }
        return session
    }

    private static func open(_ endpoint: IMAPEndpoint, readTimeout: TimeAmount) async throws -> IMAPSession {
        let implicitTLS = endpoint.security == .tls
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        let context = try NIOSSLContext(configuration: tls)
        let (stream, continuation) = AsyncThrowingStream<Response, Error>.makeStream()
        let host = endpoint.host
        let tcp = ContinuousClock.now
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(20))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if implicitTLS {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: host))
                    }
                    try channel.pipeline.syncOperations.addHandlers([
                        IdleStateHandler(readTimeout: readTimeout),
                        IMAPClientHandler(),
                        ResponseForwarder(continuation),
                    ])
                }
            }
            .connect(host: endpoint.host, port: endpoint.port).get()
        debug("channel connected \(ContinuousClock.now - tcp)")
        let session = IMAPSession(endpoint: endpoint, channel: channel, responses: stream)
        let t = ContinuousClock.now
        try await session.readGreeting()
        debug("greeting after channel up \(ContinuousClock.now - t)")
        return session
    }

    private func readGreeting() async throws {
        var it = responses
        let first = try await it.next(isolation: self)
        responses = it
        guard let first else { throw IMAPError.closed }
        if case .untagged(.conditionalState(.bye(let text))) = first { throw IMAPError.connection(Self.clean(text.text)) }
    }

    private func secureAndLogin(username: String, password: String) async throws {
        if case .startTLS = endpoint.security { try await startTLS(pinned: nil, verifyChain: true) }
        if case .startTLSPinned(let fp) = endpoint.security { try await startTLS(pinned: fp, verifyChain: false) }
        let login = try await run(.login(username: username, password: password), failure: { IMAPError.authentication($0) })
        serverCapabilities = Self.capabilities(in: login)
        if serverCapabilities.isEmpty { serverCapabilities = Self.capabilities(in: try await run(.capability)) }
        gmail = serverCapabilities.contains("X-GM-EXT-1")
        condstore = serverCapabilities.contains("CONDSTORE") || serverCapabilities.contains("QRESYNC")
    }

    /// STARTTLS, then the TLS handler goes first in the pipeline (so LOGIN never travels in
    /// plain text). Pinned mode compares the leaf certificate's SHA-256 instead of the chain.
    private func startTLS(pinned expected: String?, verifyChain: Bool) async throws {
        _ = try await run(.startTLS)
        let seen = Fingerprint()
        let host = endpoint.host
        let pinMode = !verifyChain
        try await channel.eventLoop.submit { [channel] in
            var tls = TLSConfiguration.makeClientConfiguration()
            tls.minimumTLSVersion = .tlsv12
            if pinMode { tls.certificateVerification = .noHostnameVerification }
            let context = try NIOSSLContext(configuration: tls)
            let handler: NIOSSLClientHandler
            if pinMode {
                handler = try NIOSSLClientHandler(context: context, serverHostname: nil) { certificates, promise in
                    let fp = certificates.first.map { cert in
                        SHA256.hash(data: Data((try? cert.toDERBytes()) ?? [])).map { String(format: "%02x", $0) }.joined()
                    } ?? ""
                    seen.set(fp)
                    promise.succeed(expected == nil || expected == fp ? .certificateVerified : .failed)
                }
            } else {
                handler = try NIOSSLClientHandler(context: context, serverHostname: host)
            }
            try channel.pipeline.syncOperations.addHandler(handler, position: .first)
        }.get()
        // The first command over TLS surfaces a failed handshake.
        do {
            serverCapabilities = Self.capabilities(in: try await run(.capability))
        } catch {
            if let expected, let actual = seen.value, actual != expected {
                throw IMAPError.pinMismatch(expected: expected, actual: actual)
            }
            throw IMAPError.connection("TLS: \(error)")
        }
        certificateFingerprint = seen.value
    }

    public func close() async {
        if channel.isActive { _ = try? await run(.logout) }
        try? await channel.close().get()
    }

    // MARK: MailboxSource

    public func capabilities() async -> SourceCapabilities {
        SourceCapabilities(condstore: condstore, gmail: gmail)
    }

    public func mailboxes() async throws -> [RemoteMailbox] {
        let result = try await run(.list(nil, reference: MailboxName(ByteBuffer(string: "")), .mailbox(ByteBuffer(string: "*")), []))
        var out: [RemoteMailbox] = []
        mailboxNames = [:]
        for payload in result.untagged {
            guard case .mailboxData(.list(let info)) = payload else { continue }
            let attributes = Set(info.attributes.map { String($0).lowercased() })
            let separator = info.path.pathSeparator.map(String.init) ?? "/"
            let display = info.path.displayStringComponents(omittingEmptySubsequences: false).joined(separator: separator)
            var special = Set<SpecialUse>()
            for use in SpecialUse.allCases where attributes.contains("\\\(use.rawValue)") { special.insert(use) }
            let selectable = !attributes.contains("\\noselect") && !attributes.contains("\\nonexistent")
            mailboxNames[display] = info.path.name
            out.append(RemoteMailbox(name: display, specialUse: special, selectable: selectable))
        }
        return out
    }

    public func examine(_ mailbox: RemoteMailbox) async throws -> MailKeeperKit.MailboxStatus {
        guard let name = mailboxNames[mailbox.name] else { throw IMAPError.protocolError("unbekanntes Postfach \(mailbox.name)") }
        let params: [SelectParameter] = condstore ? [.basic(KeyValue(key: "CONDSTORE", value: nil))] : []
        let result = try await run(.examine(name, params))
        var validity: UInt32?, next: UInt32?, exists = 0, modseq: UInt64?
        for payload in result.untagged {
            if case .mailboxData(.exists(let n)) = payload { exists = n }
            if case .conditionalState(.ok(let text)) = payload, let code = text.code {
                switch code {
                case .uidValidity(let v): validity = UInt32(v)
                case .uidNext(let u): next = UInt32(u)
                case .highestModificationSequence(let m): modseq = UInt64(m)
                default: break
                }
            }
        }
        if case .uidValidity(let v)? = result.code { validity = UInt32(v) }
        guard let validity else { throw IMAPError.protocolError("keine UIDVALIDITY für \(mailbox.name)") }
        currentExists = exists
        return MailKeeperKit.MailboxStatus(uidValidity: validity, uidNext: next, exists: exists, highestModSeq: modseq)
    }

    public func messageSizes(fromUID: UInt32) async throws -> [UIDSize] {
        guard currentExists > 0 else { return [] }
        let set = MessageIdentifierSetNonEmpty(range: MessageIdentifierRange<UID>(UID(rawValue: max(1, fromUID))...))
        let result = try await run(.uidFetch(.set(set), [.uid, .rfc822Size], []))
        return result.fetches.compactMap { f in f.uid.map { UIDSize(uid: $0, size: f.size ?? 0) } }.sorted { $0.uid < $1.uid }
    }

    /// Every UID of the examined mailbox. Never plain `UID SEARCH ALL`: servers answer it with
    /// one line, and swift-nio-imap caps response lines at 8 KiB (~1 700 UIDs) — the
    /// connection would die. ESEARCH returns compact ranges; otherwise one short FETCH line
    /// per message.
    public func allUIDs() async throws -> [UInt32] {
        guard currentExists > 0 else { return [] }
        let esearch = serverCapabilities.contains("ESEARCH")
        let result = try await run(Self.presenceCommand(esearch: esearch))
        if esearch {
            var uids: [UInt32] = []
            var answered = false
            for payload in result.untagged {
                guard case .mailboxData(.extendedSearch(let response)) = payload else { continue }
                answered = true
                for data in response.returnData {
                    if case .all(.set(let set)) = data { uids.append(contentsOf: set.set.map { UInt32($0.rawValue) }) }
                }
            }
            if answered { return uids }
            return try await run(Self.presenceCommand(esearch: false)).fetches.compactMap(\.uid)
        }
        return result.fetches.compactMap(\.uid)
    }

    static func presenceCommand(esearch: Bool) -> Command {
        if esearch { return .uidSearch(key: .all, charset: nil, returnOptions: [.all]) }
        return .uidFetch(.set(MessageIdentifierSetNonEmpty(range: MessageIdentifierRange<UID>(UID(rawValue: 1)...))), [.uid], [])
    }

    public func flags(changedSince modseq: UInt64?) async throws -> [RemoteFlags] {
        guard currentExists > 0 else { return [] }
        var attributes: [FetchAttribute] = [.uid, .flags]
        if gmail { attributes.append(.gmailLabels) }
        let modifiers: [FetchModifier] = modseq.map { [.changedSince(ChangedSinceModifier(modificationSequence: ModificationSequenceValue($0)))] } ?? []
        let all = MessageIdentifierSetNonEmpty(range: MessageIdentifierRange<UID>(UID(rawValue: 1)...))
        let result = try await run(.uidFetch(.set(all), attributes, modifiers))
        return result.fetches.compactMap { f in f.uid.map { RemoteFlags(uid: $0, flags: f.flags, labels: f.labels) } }
    }

    public func fetch(_ uids: [UInt32]) async throws -> [RemoteMessage] {
        guard !uids.isEmpty else { return [] }
        var attributes: [FetchAttribute] = [.uid, .flags, .internalDate, .rfc822Size, .bodySection(peek: true, .complete, nil)]
        if gmail { attributes += [.gmailMessageID, .gmailLabels] }
        let result = try await run(.uidFetch(Self.uidSet(uids), attributes, []))
        return result.fetches.compactMap { f in
            guard let uid = f.uid, let body = f.body else { return nil }
            return RemoteMessage(uid: uid, flags: f.flags, labels: f.labels, internalDate: f.internalDate,
                                 providerID: f.gmailMessageID.map { "gm:\($0)" }, data: body)
        }
    }

    // MARK: Command plumbing

    struct Fetched {
        var uid: UInt32?
        var flags: [String] = []
        var labels: [String] = []
        var internalDate: Date?
        var size: Int?
        var gmailMessageID: UInt64?
        var body: Data?
    }

    struct Result {
        var untagged: [ResponsePayload] = []
        var fetches: [Fetched] = []
        var code: ResponseTextCode?
    }

    /// Phase 2 is read-only: only these commands, and no FETCH that would set \Seen.
    static func isReadOnly(_ command: Command) -> Bool {
        switch command {
        case .capability, .logout, .noop, .login, .authenticate, .startTLS, .enable, .id, .namespace,
             .list, .listIndependent, .lsub, .examine, .status, .unselect,
             .search, .uidSearch, .extendedSearch, .sort, .uidSort:
            return true
        case .fetch(_, let attributes, _), .uidFetch(_, let attributes, _):
            return attributes.allSatisfy { a in
                switch a {
                case .rfc822, .rfc822Text: return false
                case .bodySection(let peek, _, _), .binary(let peek, _, _): return peek
                default: return true
                }
            }
        default:
            return false
        }
    }

    @discardableResult
    func run(_ command: Command, failure: (String) -> IMAPError = { _ in IMAPError.closed }) async throws -> Result {
        guard Self.isReadOnly(command) else { throw IMAPError.readOnlyViolation(Self.name(of: command)) }
        guard !busy else { throw IMAPError.protocolError("gleichzeitige Befehle auf einer Verbindung") }
        busy = true
        defer { busy = false }
        tag += 1
        let t = "M\(tag)"
        do {
            try await channel.writeAndFlush(IMAPClientHandler.Message.part(.tagged(TaggedCommand(tag: t, command: command))))
        } catch {
            throw Self.mapped(error)
        }
        var result = Result()
        var current: Fetched?
        var it = responses
        defer { responses = it }
        while true {
            let next: Response?
            do { next = try await it.next(isolation: self) } catch { throw Self.mapped(error) }
            guard let response = next else { throw IMAPError.closed }
            switch response {
            case .untagged(let payload):
                result.untagged.append(payload)
            case .fetch(let part):
                switch part {
                case .start: current = Fetched()
                case .startUID(let uid): current = Fetched(uid: UInt32(uid))
                case .simpleAttribute(let attribute): if current != nil { Self.apply(attribute, to: &current!) }
                case .streamingBegin(_, let count):
                    // The announced size comes from the server: never trust it for allocation.
                    guard count <= Self.maxMessageBytes else {
                        try? await channel.close().get()
                        throw IMAPError.protocolError("Nachricht mit \(count) Bytes angekündigt (Grenze \(Self.maxMessageBytes))")
                    }
                    current?.body = Data()
                    current?.body?.reserveCapacity(min(count, 32 << 20))
                case .streamingBytes(let bytes):
                    current?.body?.append(contentsOf: bytes.readableBytesView)
                    if (current?.body?.count ?? 0) > Self.maxMessageBytes {
                        try? await channel.close().get()
                        throw IMAPError.protocolError("Nachricht überschreitet \(Self.maxMessageBytes) Bytes")
                    }
                case .streamingEnd: break
                case .finish:
                    if let c = current { result.fetches.append(c) }
                    current = nil
                }
            case .tagged(let tagged) where tagged.tag == t:
                switch tagged.state {
                case .ok(let text):
                    result.code = text.code
                    return result
                case .no(let text), .bad(let text):
                    let message = Self.clean(text.text)
                    if case .login = command { throw failure(message) }
                    throw IMAPError.command(Self.name(of: command), message)
                }
            case .fatal(let text):
                throw IMAPError.connection(Self.clean(text.text))
            default:
                continue
            }
        }
    }

    private static func apply(_ attribute: MessageAttribute, to m: inout Fetched) {
        switch attribute {
        case .uid(let uid): m.uid = UInt32(uid)
        case .flags(let flags): m.flags = flags.map { String($0) }
        case .internalDate(let date): m.internalDate = Self.date(date)
        case .rfc822Size(let n): m.size = n
        case .gmailMessageID(let id): m.gmailMessageID = id
        case .gmailLabels(let labels): m.labels = labels.map { $0.makeDisplayString() }
        default: break
        }
    }

    /// Timing diagnostics on stderr with MAILKEEPER_DEBUG=1 (no content, no credentials).
    static func debug(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["MAILKEEPER_DEBUG"] == "1" else { return }
        FileHandle.standardError.write(Data("[imap] \(message())\n".utf8))
    }

    /// Largest message accepted (mail providers cap far lower: Gmail 25 MB, mailcow default 50 MB).
    static let maxMessageBytes = 1 << 30

    /// Stream errors keep their cause (parser limits, TLS, NIO); `.closed` only for a plain end.
    static func mapped(_ error: Error) -> IMAPError {
        if let e = error as? IMAPError { return e }
        return .protocolError(clean("\(error)"))
    }

    static func date(_ d: ServerMessageDate) -> Date? {
        let c = d.components
        var tm = tm()
        tm.tm_year = Int32(c.year - 1900)
        tm.tm_mon = Int32(c.month - 1)
        tm.tm_mday = Int32(c.day)
        tm.tm_hour = Int32(c.hour)
        tm.tm_min = Int32(c.minute)
        tm.tm_sec = Int32(c.second)
        return Date(timeIntervalSince1970: TimeInterval(timegm(&tm)) - TimeInterval(c.zoneMinutes * 60))
    }

    static func capabilities(in result: Result) -> [String] {
        var caps = result.untagged.flatMap { payload -> [String] in
            if case .capabilityData(let c) = payload { return c.map { String($0).uppercased() } }
            return []
        }
        if caps.isEmpty, case .capability(let c)? = result.code { caps = c.map { String($0).uppercased() } }
        return caps
    }

    static func uidSet(_ uids: [UInt32]) -> LastCommandSet<UID> {
        var set = MessageIdentifierSet<UID>()
        for u in uids { set.formUnion(MessageIdentifierSet<UID>(UID(rawValue: u))) }
        return .set(MessageIdentifierSetNonEmpty(set: set)!)
    }

    static func name(of command: Command) -> String {
        String(describing: command).split(separator: "(").first.map { String($0).uppercased() } ?? "COMMAND"
    }

    /// Server text is untrusted: no control or bidi characters, bounded length.
    static func clean(_ s: String) -> String {
        let kept = DisplayText.safe(s).unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }
        return String(String(String.UnicodeScalarView(kept)).prefix(300))
    }
}

/// Bridges parsed responses from the NIO pipeline into the session; closes the connection
/// when the IdleStateHandler reports a silent server.
final class ResponseForwarder: ChannelInboundHandler {
    typealias InboundIn = Response
    private let continuation: AsyncThrowingStream<Response, Error>.Continuation

    init(_ continuation: AsyncThrowingStream<Response, Error>.Continuation) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        continuation.yield(unwrapInboundIn(data))
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is IdleStateHandler.IdleStateEvent {
            continuation.finish(throwing: IMAPError.closed)
            context.close(promise: nil)
            return
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        continuation.finish(throwing: error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        continuation.finish()
        context.fireChannelInactive()
    }
}

final class Fingerprint: Sendable {
    private let storage = Mutex<String?>(nil)
    var value: String? { storage.withLock { $0 } }
    func set(_ v: String) { storage.withLock { $0 = v } }
}
