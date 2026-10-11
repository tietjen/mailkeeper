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

/// What a connection may change on the server.
public enum IMAPAccess: Sendable, Equatable {
    /// Phase 2: nothing (EXAMINE, BODY.PEEK, the read-only allowlist).
    case readOnly
    /// Phase 4 server delete (ADR-0006): additionally SELECT, and moving messages into the
    /// SPECIAL-USE \Trash — UID MOVE, or UID COPY + STORE +FLAGS (\Deleted) + UID EXPUNGE on
    /// exactly those UIDs. Never a bare EXPUNGE or CLOSE (they would purge every \Deleted
    /// message in the mailbox, including other clients'), never another destination.
    case moveToTrash
    /// Phase 4 restore (ADR-0006 §5): additionally SELECT, APPEND into an existing mailbox that is
    /// neither Trash nor Junk (never CREATE), and — on Gmail — adding labels to a message
    /// appended on this connection. Nothing that removes, moves or changes flags.
    case restore
}

/// One IMAP connection, read-only unless opened with `access: .moveToTrash`: mailboxes are opened
/// with EXAMINE, bodies fetched with BODY.PEEK, and every command passes an allowlist.
/// Commands are serialised; the session is not meant for concurrent use.
public actor IMAPSession: MailboxSource, ServerTrashActions, ServerRestoreActions {
    public let endpoint: IMAPEndpoint
    public let access: IMAPAccess
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
    /// The SPECIAL-USE \Trash mailbox, once looked up: the only destination a move may name.
    private var trash: MailboxName?
    /// Special-use roles by display name, from the last LIST (restore never writes into Trash/Junk).
    private var mailboxUses: [String: Set<SpecialUse>] = [:]
    /// The mailbox opened with SELECT, and the UIDs this connection appended per mailbox: the
    /// only messages a restore may label.
    private var selectedMailbox: String?
    private var appendedUIDs: [String: Set<UInt32>] = [:]

    private init(endpoint: IMAPEndpoint, access: IMAPAccess, channel: Channel, responses: AsyncThrowingStream<Response, Error>) {
        self.endpoint = endpoint
        self.access = access
        self.channel = channel
        self.responses = responses.makeAsyncIterator()
    }

    /// Connects, secures and logs in. `readTimeout` closes the connection when the server goes
    /// silent while a command is outstanding (and between commands).
    public static func connect(_ endpoint: IMAPEndpoint, username: String, password: String,
                               access: IMAPAccess = .readOnly, readTimeout: TimeAmount = .seconds(120)) async throws -> IMAPSession {
        let session: IMAPSession
        let clock = ContinuousClock(), start = clock.now
        do {
            session = try await open(endpoint, access: access, readTimeout: readTimeout)
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

    private static func open(_ endpoint: IMAPEndpoint, access: IMAPAccess, readTimeout: TimeAmount) async throws -> IMAPSession {
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
        let session = IMAPSession(endpoint: endpoint, access: access, channel: channel, responses: stream)
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
        mailboxUses = [:]
        for payload in result.untagged {
            guard case .mailboxData(.list(let info)) = payload else { continue }
            let attributes = Set(info.attributes.map { String($0).lowercased() })
            let separator = info.path.pathSeparator.map(String.init) ?? "/"
            let display = info.path.displayStringComponents(omittingEmptySubsequences: false).joined(separator: separator)
            var special = Set<SpecialUse>()
            for use in SpecialUse.allCases where attributes.contains("\\\(use.rawValue)") { special.insert(use) }
            let selectable = !attributes.contains("\\noselect") && !attributes.contains("\\nonexistent")
            mailboxNames[display] = info.path.name
            mailboxUses[display] = special
            out.append(RemoteMailbox(name: display, specialUse: special, selectable: selectable))
        }
        return out
    }

    public func examine(_ mailbox: RemoteMailbox) async throws -> MailKeeperKit.MailboxStatus {
        guard let name = mailboxNames[mailbox.name] else { throw IMAPError.protocolError("unbekanntes Postfach \(mailbox.name)") }
        let params: [SelectParameter] = condstore ? [.basic(KeyValue(key: "CONDSTORE", value: nil))] : []
        return try status(of: try await run(.examine(name, params)), mailbox: mailbox.name)
    }

    private func status(of result: Result, mailbox: String) throws -> MailKeeperKit.MailboxStatus {
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
        guard let validity else { throw IMAPError.protocolError("keine UIDVALIDITY für \(mailbox)") }
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

    // MARK: Server delete (Phase 4, access .moveToTrash)

    public func trashMailbox() async throws -> String? {
        let boxes = try await mailboxes()
        guard let box = boxes.first(where: { $0.specialUse.contains(.trash) && $0.selectable }) else { return nil }
        trash = mailboxNames[box.name]
        return box.name
    }

    public func selectForChange(_ mailbox: String) async throws -> UInt32 {
        guard access != .readOnly else { throw IMAPError.readOnlyViolation("SELECT") }
        if mailboxNames[mailbox] == nil { _ = try await mailboxes() }
        guard let name = mailboxNames[mailbox] else { throw IMAPError.protocolError("unbekanntes Postfach \(mailbox)") }
        selectedMailbox = nil
        let validity = try status(of: try await run(.select(name, [])), mailbox: mailbox).uidValidity
        selectedMailbox = mailbox
        return validity
    }

    public func identities(_ uids: [UInt32]) async throws -> [UInt32: RemoteIdentity] {
        guard !uids.isEmpty else { return [:] }
        let header = FetchAttribute.bodySection(peek: true, SectionSpecifier(kind: .headerFields(["Message-ID"])), nil)
        let result = try await run(.uidFetch(Self.uidSet(uids), [.uid, .flags, .rfc822Size, header], []))
        var out: [UInt32: RemoteIdentity] = [:]
        for f in result.fetches {
            guard let uid = f.uid else { continue }
            out[uid] = RemoteIdentity(messageID: f.body.flatMap(MIMEParser.messageID(ofHeader:)), size: f.size, flags: f.flags)
        }
        return out
    }

    public func bodies(_ uids: [UInt32]) async throws -> [UInt32: Data] {
        Dictionary(try await fetch(uids).map { ($0.uid, $0.data) }, uniquingKeysWith: { a, _ in a })
    }

    public func moveToTrash(_ uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        guard let trash else { throw IMAPError.protocolError("kein Papierkorb (\\Trash) bestimmt") }
        let set = Self.uidSet(uids)
        if serverCapabilities.contains("MOVE") {
            try await run(.uidMove(set, trash))
        } else if serverCapabilities.contains("UIDPLUS") {
            try await run(.uidCopy(set, trash))
            try await run(.uidStore(set, [], .flags(.add(silent: true, list: [.deleted]))))
            try await run(.uidExpunge(set))
        } else {
            throw IMAPError.command("MOVE", "der Server kann weder MOVE noch UIDPLUS – gezieltes Löschen nicht möglich")
        }
    }

    public func present(_ uids: [UInt32]) async throws -> Set<UInt32> {
        guard !uids.isEmpty else { return [] }
        return Set(try await run(.uidFetch(Self.uidSet(uids), [.uid], [])).fetches.compactMap(\.uid))
    }

    // MARK: Restore (Phase 4, access .restore)

    public func search(messageID: String) async throws -> [UInt32] {
        let result = try await run(.uidSearch(key: .header("Message-ID", ByteBuffer(string: messageID))))
        return result.untagged.flatMap { payload -> [UInt32] in
            if case .mailboxData(.search(let ids, _)) = payload { return ids.map { UInt32($0.rawValue) } }
            return []
        }
    }

    public func append(_ data: Data, to mailbox: String, flags: [String], internalDate: Date?) async throws -> AppendedMessage? {
        guard access == .restore else { throw IMAPError.readOnlyViolation("APPEND") }
        if mailboxNames[mailbox] == nil { _ = try await mailboxes() }
        guard let name = mailboxNames[mailbox] else { throw IMAPError.protocolError("unbekanntes Postfach \(mailbox)") }
        guard (mailboxUses[mailbox] ?? []).isDisjoint(with: [.trash, .junk]) else { throw IMAPError.readOnlyViolation("APPEND \(mailbox)") }
        guard data.count <= Self.maxMessageBytes else { throw ServerRefusal("Nachricht zu groß") }
        let options = AppendOptions(flagList: RestoreTarget.restorableFlags(flags).map { Flag($0) },
                                    internalDate: internalDate.flatMap(Self.serverDate), extensions: [:])
        let result: Result
        do {
            result = try await perform(name: "APPEND") { tag in [
                .append(.start(tag: tag, appendingTo: name)),
                .append(.beginMessage(message: AppendMessage(options: options, data: AppendData(byteCount: data.count)))),
                .append(.messageBytes(ByteBuffer(bytes: data))),
                .append(.endMessage),
                .append(.finish),
            ] }
        } catch IMAPError.command(_, let message) {
            throw ServerRefusal(message)
        }
        guard case .uidAppend(let code)? = result.code, let uid = code.uids.set.first else { return nil }
        let appended = AppendedMessage(uidValidity: UInt32(code.uidValidity), uid: UInt32(uid.rawValue))
        appendedUIDs[mailbox, default: []].insert(appended.uid)
        return appended
    }

    public func addLabels(_ labels: [String], uid: UInt32) async throws {
        guard access == .restore, gmail else { throw IMAPError.readOnlyViolation("STORE X-GM-LABELS") }
        guard let mailbox = selectedMailbox, appendedUIDs[mailbox]?.contains(uid) == true else {
            throw IMAPError.readOnlyViolation("STORE X-GM-LABELS auf eine fremde Mail")
        }
        let encoded = try RestoreTarget.restorableLabels(labels).map { label in
            label.hasPrefix("\\") ? GmailLabel(ByteBuffer(string: label))
                                  : GmailLabel(mailboxName: try MailboxPath.makeRootMailbox(displayName: label).name)
        }
        guard !encoded.isEmpty else { return }
        try await run(.uidStore(Self.uidSet([uid]), [], .gmailLabels(.add(silent: true, gmailLabels: encoded))))
    }

    /// APPEND's date argument, in UTC.
    static func serverDate(_ date: Date) -> ServerMessageDate? {
        var t = time_t(date.timeIntervalSince1970.rounded(.down))
        var tm = tm()
        guard gmtime_r(&t, &tm) != nil,
              let c = ServerMessageDate.Components(year: Int(tm.tm_year) + 1900, month: Int(tm.tm_mon) + 1, day: Int(tm.tm_mday),
                                                   hour: Int(tm.tm_hour), minute: Int(tm.tm_min), second: Int(tm.tm_sec),
                                                   timeZoneMinutes: 0)
        else { return nil }
        return ServerMessageDate(c)
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

    /// Phase 4: the few changes a `.moveToTrash` connection may make (only toward \Trash), and
    /// those of a `.restore` connection (SELECT, adding Gmail labels; APPEND has its own checks).
    static func isAllowedChange(_ command: Command, access: IMAPAccess, trash: MailboxName?) -> Bool {
        switch (access, command) {
        case (.moveToTrash, .select(_, let params)), (.restore, .select(_, let params)):
            return params.allSatisfy { if case .basic(let kv) = $0 { kv.key.uppercased() == "CONDSTORE" } else { false } }
        case (.moveToTrash, .uidMove(_, let destination)), (.moveToTrash, .uidCopy(_, let destination)):
            return trash != nil && destination == trash
        case (.moveToTrash, .uidStore(_, let modifiers, .flags(let store))):
            return modifiers.isEmpty && store.operation == .add && store.flags == [.deleted]
        case (.moveToTrash, .uidExpunge):
            return true  // explicit UIDs only (UIDPLUS); bare EXPUNGE and CLOSE stay refused
        case (.restore, .uidStore(_, let modifiers, .gmailLabels(let store))):
            return modifiers.isEmpty && store.operation == .add
        default:
            return false
        }
    }

    @discardableResult
    func run(_ command: Command, failure: (String) -> IMAPError = { _ in IMAPError.closed }) async throws -> Result {
        guard Self.isReadOnly(command) || Self.isAllowedChange(command, access: access, trash: trash) else {
            throw IMAPError.readOnlyViolation(Self.name(of: command))
        }
        return try await perform(name: Self.name(of: command), isLogin: { if case .login = command { true } else { false } }(),
                                 failure: failure) { tag in [.tagged(TaggedCommand(tag: tag, command: command))] }
    }

    /// Sends the parts of one tagged command (a plain command, or APPEND's stream) and collects
    /// the responses up to its tagged reply. Writes complete once the server has asked for a
    /// literal, so they are awaited after the reply.
    private func perform(name: String, isLogin: Bool = false, failure: (String) -> IMAPError = { _ in IMAPError.closed },
                         _ parts: (String) -> [CommandStreamPart]) async throws -> Result {
        guard !busy else { throw IMAPError.protocolError("gleichzeitige Befehle auf einer Verbindung") }
        busy = true
        defer { busy = false }
        tag += 1
        let t = "M\(tag)"
        let writes = parts(t).map { channel.write(IMAPClientHandler.Message.part($0)) }
        channel.flush()
        let result = try await collect(tag: t, name: name, isLogin: isLogin, failure: failure)
        for w in writes {
            do { try await w.get() } catch { throw Self.mapped(error) }
        }
        return result
    }

    private func collect(tag t: String, name: String, isLogin: Bool, failure: (String) -> IMAPError) async throws -> Result {
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
                    if isLogin { throw failure(message) }
                    throw IMAPError.command(name, message)
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
