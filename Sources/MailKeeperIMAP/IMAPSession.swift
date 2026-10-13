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
    /// The server answered an APPEND with NO before the message was sent; swift-nio-imap then
    /// drops the reply (text lost) and the connection.
    case refusedBeforeData

    public var description: String {
        switch self {
        case .connection(let s): "Verbindung fehlgeschlagen: \(s)"
        case .pinMismatch(let e, let a): "Zertifikat der Bridge hat sich geändert (erwartet \(e.prefix(16))…, erhalten \(a.prefix(16))…)"
        case .authentication(let s): "Anmeldung abgelehnt: \(s)"
        case .command(let c, let s): "\(c) abgelehnt: \(s)"
        case .readOnlyViolation(let c): "\(c) ist im Nur-Lese-Modus nicht erlaubt"
        case .closed: "Verbindung geschlossen oder Zeitüberschreitung"
        case .protocolError(let s): "Protokollfehler: \(s)"
        case .refusedBeforeData: "Server hat vor dem Senden abgelehnt oder die Verbindung beendet (zu groß, kein Platz, keine Rechte?)"
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
    /// neither Trash nor Junk (never CREATE), and — only on messages appended on this connection —
    /// adding Gmail labels and setting/clearing the four client system flags (a server that
    /// changed them on the way in). Nothing that removes, moves, expunges or touches other mail.
    case restore
    /// 5.5 "Kein Spam": SELECT, and moving messages out of the spam mailbox (\Junk, or by name on
    /// a server without roles) back where they belong — INBOX, or (6.8) the mailbox they came
    /// from: one the server lists that is no spam, trash, sent or drafts mailbox (by role and by
    /// name), never created — UID MOVE, or UID COPY + STORE +\Deleted + UID EXPUNGE on exactly
    /// those UIDs. Never another source or destination.
    case rescueFromJunk
    /// 6.4 "Ist Spam": SELECT a mailbox that is no spam, trash, sent or drafts mailbox, and move
    /// messages from it into the spam mailbox (\Junk, or by name on a server without roles) —
    /// UID MOVE, or UID COPY + STORE +\Deleted + UID EXPUNGE on exactly those UIDs. Never
    /// another source or destination.
    case markAsJunk
    /// 6.9b "Ablage ändern": SELECT a mailbox that is no trash, sent, drafts or All Mail
    /// mailbox, and move messages from it into one other mailbox the server lists — INBOX or an
    /// ordinary folder (`RemoteMailbox.mayTakeRescued`; never spam, trash, sent, drafts, All Mail,
    /// Starred, Important; never created) — UID MOVE, or UID COPY + STORE +\Deleted + UID EXPUNGE
    /// on exactly those UIDs. Never another source or destination.
    case moveToFolder
}

/// One IMAP connection, read-only unless opened with `access: .moveToTrash`: mailboxes are opened
/// with EXAMINE, bodies fetched with BODY.PEEK, and every command passes an allowlist.
/// Commands are serialised; the session is not meant for concurrent use.
public actor IMAPSession: MailboxSource, ServerTrashActions, ServerRestoreActions, ServerRescueActions {
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
    /// INBOX from the last LIST: the only destination of a rescue.
    private var inbox: MailboxName?
    /// The spam mailbox, once looked up: the only destination of "Ist Spam".
    private var junk: MailboxName?
    /// The one mailbox a "Kein Spam" move may go to, set for the duration of that move (6.8).
    private var rescueTarget: MailboxName?
    /// Special-use roles by display name, from the last LIST (restore never writes into Trash/Junk).
    private var mailboxUses: [String: Set<SpecialUse>] = [:]
    private var mailboxSelectable: [String: Bool] = [:]
    /// The mailbox opened with SELECT, and the UIDs this connection appended per mailbox: the
    /// only messages a restore may label.
    private var selectedMailbox: String?
    private var appendedUIDs: [String: Set<UInt32>] = [:]
    /// What a delete connection copied to \Trash per mailbox: the only UIDs it may flag and expunge.
    private var copiedUIDs: [String: Set<UInt32>] = [:]

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
        mailboxSelectable = [:]
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
            mailboxSelectable[display] = selectable
            if display.uppercased() == "INBOX" { inbox = info.path.name }
            out.append(RemoteMailbox(name: display, specialUse: special, selectable: selectable))
        }
        return out
    }

    public func examine(_ mailbox: RemoteMailbox) async throws -> MailKeeperKit.MailboxStatus {
        guard let name = mailboxNames[mailbox.name] else { throw IMAPError.protocolError("unbekanntes Postfach \(mailbox.name)") }
        let params: [SelectParameter] = condstore ? [.basic(KeyValue(key: "CONDSTORE", value: nil))] : []
        selectedMailbox = nil  // read-only now: no change may refer to a previous SELECT
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
        let result = try await run(.uidFetch(try Self.uidSet(uids), attributes, []))
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
        let validity: UInt32
        do {
            validity = try status(of: try await run(.select(name, [])), mailbox: mailbox).uidValidity
        } catch IMAPError.command(_, let message) {
            throw ServerRefusal(message)  // e.g. no rights: that mailbox's messages fail, the job goes on
        }
        selectedMailbox = mailbox
        return validity
    }

    public func identities(_ uids: [UInt32]) async throws -> [UInt32: RemoteIdentity] {
        guard !uids.isEmpty else { return [:] }
        let header = FetchAttribute.bodySection(peek: true, SectionSpecifier(kind: .headerFields(["Message-ID"])), nil)
        let result = try await run(.uidFetch(try Self.uidSet(uids), [.uid, .flags, .rfc822Size, header], []))
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

    /// A NO from the server is a `ServerRefusal` (the executor fails those messages and goes on).
    public func moveToTrash(_ uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        guard let trash else { throw IMAPError.protocolError("kein Papierkorb (\\Trash) bestimmt") }
        let set = try Self.uidSet(uids)
        do {
            if serverCapabilities.contains("MOVE") {
                try await run(.uidMove(set, trash))
            } else if serverCapabilities.contains("UIDPLUS") {
                try await run(.uidCopy(set, trash))
                // \Deleted and EXPUNGE only on exactly what was just copied (checked in perform)
                if let mailbox = selectedMailbox { copiedUIDs[mailbox, default: []].formUnion(uids) }
                try await run(.uidStore(set, [], .flags(.add(silent: true, list: [.deleted]))))
                try await run(.uidExpunge(set))
            } else {
                throw ServerRefusal("der Server kann weder MOVE noch UIDPLUS – gezieltes Löschen nicht möglich")
            }
        } catch IMAPError.command(_, let message) {
            throw ServerRefusal(message)
        }
    }

    // MARK: Rescue from spam (5.5, access .rescueFromJunk)

    /// Whether the selected mailbox is the spam folder: the server's \Junk, or — on a server
    /// that marks no roles at all — a mailbox with a spam name.
    private var selectedIsJunk: Bool {
        guard let mailbox = selectedMailbox else { return false }
        if (mailboxUses[mailbox] ?? []).contains(.junk) { return true }
        let roles = mailboxUses.values.contains { $0.contains(.junk) }
        return !roles && RemoteMailbox.looksLikeJunk(mailbox)
    }

    /// Whether a listed mailbox may take mail back out of the spam folder (6.8): INBOX, or any
    /// selectable mailbox that is no spam, trash, sent or drafts mailbox — by role and by name.
    func mayTakeRescued(_ display: String) -> Bool {
        guard mailboxNames[display] != nil, let source = selectedMailbox else { return false }
        return RemoteMailbox.mayTakeRescued(name: display, uses: mailboxUses[display] ?? [], selectable: mailboxSelectable[display] ?? false, source: source)
    }

    /// Moves UIDs of the selected spam mailbox to `destination` (a mailbox the server listed:
    /// INBOX, or where the mail came from) — nothing else.
    public func moveOutOfJunk(_ uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        guard access == .rescueFromJunk, selectedIsJunk else { throw IMAPError.readOnlyViolation("MOVE aus einem Nicht-Spam-Ordner") }
        try await moveSelected(uids, to: destination)
    }

    /// 6.9b "Ablage ändern": moves UIDs of the selected mailbox (no trash, sent, drafts or All
    /// Mail) to `destination` — INBOX or an ordinary folder the server lists.
    public func moveToFolder(_ uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        if mailboxNames.isEmpty { _ = try await mailboxes() }
        guard access == .moveToFolder, selectedMayGive else {
            throw IMAPError.readOnlyViolation("MOVE aus einem Papierkorb-, Gesendet-, Entwurfs- oder Alle-Nachrichten-Ordner")
        }
        try await moveSelected(uids, to: destination)
    }

    /// Whether the selected mailbox may give mail to "Ablage ändern" (6.9b): no trash, sent,
    /// drafts or All Mail — by role and by name.
    private var selectedMayGive: Bool {
        guard let source = selectedMailbox else { return false }
        return RemoteMailbox.mayGiveForMove(name: source, uses: mailboxUses[source] ?? [], selectable: mailboxSelectable[source] ?? false)
    }

    /// The one move of `.rescueFromJunk` and `.moveToFolder`: the target admitted by
    /// `mayTakeRescued`, set for exactly this move (the allowlist admits nothing else).
    private func moveSelected(_ uids: [UInt32], to destination: String) async throws {
        if mailboxNames.isEmpty { _ = try await mailboxes() }
        guard mayTakeRescued(destination), let target = mailboxNames[destination] else {
            throw IMAPError.readOnlyViolation("MOVE nach „\(destination)“ – kein zulässiges Ziel")
        }
        rescueTarget = target
        defer { rescueTarget = nil }
        let set = try Self.uidSet(uids)
        do {
            if serverCapabilities.contains("MOVE") {
                try await run(.uidMove(set, target))
            } else if serverCapabilities.contains("UIDPLUS") {
                try await run(.uidCopy(set, target))
                if let mailbox = selectedMailbox { copiedUIDs[mailbox, default: []].formUnion(uids) }
                try await run(.uidStore(set, [], .flags(.add(silent: true, list: [.deleted]))))
                try await run(.uidExpunge(set))
            } else {
                throw ServerRefusal("der Server kann weder MOVE noch UIDPLUS – gezieltes Verschieben nicht möglich")
            }
        } catch IMAPError.command(_, let message) {
            throw ServerRefusal(message)
        }
    }

    // MARK: Mark as spam (6.4, access .markAsJunk)

    /// The server's spam mailbox: \Junk, or — on a server that marks no roles at all — a mailbox
    /// with a spam name. Nil when there is none (nothing is created).
    public func junkMailbox() async throws -> String? {
        let boxes = try await mailboxes()
        let roles = boxes.contains { $0.specialUse.contains(.junk) }
        guard let box = boxes.first(where: { $0.selectable && ($0.specialUse.contains(.junk) || (!roles && RemoteMailbox.looksLikeJunk($0.name))) })
        else { return nil }
        junk = mailboxNames[box.name]
        return box.name
    }

    /// Whether the selected mailbox may give mail to the spam folder: not spam, trash, sent or
    /// drafts (by role; by name where the server marks no roles).
    private var selectedMayMarkJunk: Bool {
        guard let mailbox = selectedMailbox, mailboxNames[mailbox] != junk else { return false }
        let uses = mailboxUses[mailbox] ?? []
        guard uses.isDisjoint(with: [.junk, .trash, .sent, .drafts]) else { return false }
        // the name vetoes as well, roles or not: a server that marks only \Junk and \Trash may
        // keep "Sent" without a role (review 6.7 S7)
        return !RemoteMailbox.looksLikeTrashOrJunk(mailbox) && !RemoteMailbox.looksLikeSentOrDrafts(mailbox)
    }

    public func moveToJunk(_ uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        guard access == .markAsJunk, selectedMayMarkJunk else { throw IMAPError.readOnlyViolation("MOVE aus einem Spam-, Papierkorb-, Gesendet- oder Entwurfsordner") }
        guard let junk else { throw IMAPError.protocolError("kein Spam-Ordner bestimmt") }
        let set = try Self.uidSet(uids)
        do {
            if serverCapabilities.contains("MOVE") {
                try await run(.uidMove(set, junk))
            } else if serverCapabilities.contains("UIDPLUS") {
                try await run(.uidCopy(set, junk))
                if let mailbox = selectedMailbox { copiedUIDs[mailbox, default: []].formUnion(uids) }
                try await run(.uidStore(set, [], .flags(.add(silent: true, list: [.deleted]))))
                try await run(.uidExpunge(set))
            } else {
                throw ServerRefusal("der Server kann weder MOVE noch UIDPLUS – gezieltes Verschieben nicht möglich")
            }
        } catch IMAPError.command(_, let message) {
            throw ServerRefusal(message)
        }
    }

    public func present(_ uids: [UInt32]) async throws -> Set<UInt32> {
        guard !uids.isEmpty else { return [] }
        return Set(try await run(.uidFetch(try Self.uidSet(uids), [.uid], [])).fetches.compactMap(\.uid))
    }

    // MARK: Restore (Phase 4, access .restore)

    /// ESEARCH where offered: a plain `* SEARCH` line is capped at 8 KiB by the parser (see
    /// `allUIDs`), and Gmail's header search is fuzzy enough to hit many messages.
    public func search(messageID: String) async throws -> [UInt32] {
        let esearch = serverCapabilities.contains("ESEARCH")
        let result = try await run(.uidSearch(key: .header("Message-ID", ByteBuffer(string: messageID)), charset: nil,
                                              returnOptions: esearch ? [.all] : []))
        return result.untagged.flatMap { payload -> [UInt32] in
            switch payload {
            case .mailboxData(.search(let ids, _)): return ids.map { UInt32($0.rawValue) }
            case .mailboxData(.extendedSearch(let response)):
                return response.returnData.flatMap { data -> [UInt32] in
                    if case .all(.set(let set)) = data { return set.set.map { UInt32($0.rawValue) } }
                    return []
                }
            default: return []
            }
        }
    }

    public func append(_ data: Data, to mailbox: String, flags: [String], internalDate: Date?) async throws -> AppendedMessage? {
        guard access == .restore else { throw IMAPError.readOnlyViolation("APPEND") }
        if mailboxNames[mailbox] == nil { _ = try await mailboxes() }
        guard let name = mailboxNames[mailbox] else { throw IMAPError.protocolError("unbekanntes Postfach \(mailbox)") }
        guard (mailboxUses[mailbox] ?? []).isDisjoint(with: [.trash, .junk]) else { throw IMAPError.readOnlyViolation("APPEND \(mailbox)") }
        // Without SPECIAL-USE roles a name veto (never a positive guess): no writing into "Trash".
        let roles = mailboxUses.values.contains { !$0.isDisjoint(with: [.trash, .junk]) }
        if !roles, RemoteMailbox.looksLikeTrashOrJunk(mailbox) { throw ServerRefusal("Ziel ist Papierkorb oder Spam") }
        if let limit = Self.appendLimit(serverCapabilities), data.count > limit {
            throw ServerRefusal("größer als die Grenze des Servers (\(limit / 1_048_576) MB)")
        }
        guard data.count <= Self.maxMessageBytes else { throw ServerRefusal("Nachricht zu groß") }
        let options = AppendOptions(flagList: RestoreTarget.restorableFlags(flags).map { Flag($0) },
                                    internalDate: internalDate.flatMap(Self.serverDate), extensions: [:])
        guard let appended = try await sendAppend(data, to: name, options: options) else { return nil }
        appendedUIDs[mailbox, default: []].insert(appended.uid)
        return appended
    }

    /// The APPEND itself, refusals mapped (tests use it to provoke a refusal).
    func sendAppend(_ data: Data, to name: MailboxName, options: AppendOptions) async throws -> AppendedMessage? {
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
        } catch IMAPError.refusedBeforeData {
            throw ServerRefusal(IMAPError.refusedBeforeData.description, connectionClosed: true)
        }
        guard case .uidAppend(let code)? = result.code, let uid = code.uids.set.first else { return nil }
        return AppendedMessage(uidValidity: UInt32(code.uidValidity), uid: UInt32(uid.rawValue))
    }

    /// RFC 7889 APPENDLIMIT=<bytes> (Gmail announces 35 651 584).
    static func appendLimit(_ capabilities: [String]) -> Int? {
        capabilities.lazy.compactMap { c in c.hasPrefix("APPENDLIMIT=") ? Int(c.dropFirst("APPENDLIMIT=".count)) : nil }.first
    }

    /// Only a message this connection appended, in the selected mailbox.
    private func requireOwn(_ uid: UInt32, _ what: String) throws {
        guard access == .restore, let mailbox = selectedMailbox, appendedUIDs[mailbox]?.contains(uid) == true else {
            throw IMAPError.readOnlyViolation("\(what) auf eine fremde Mail")
        }
    }

    public func correctFlags(add: [String], remove: [String], uid: UInt32) async throws {
        try requireOwn(uid, "STORE FLAGS")
        let add = RestoreTarget.restorableFlags(add).map { Flag($0) }, remove = RestoreTarget.restorableFlags(remove).map { Flag($0) }
        do {
            if !add.isEmpty { try await run(.uidStore(try Self.uidSet([uid]), [], .flags(.add(silent: true, list: add)))) }
            if !remove.isEmpty { try await run(.uidStore(try Self.uidSet([uid]), [], .flags(.remove(silent: true, list: remove)))) }
        } catch IMAPError.command(_, let message) {
            throw ServerRefusal(message)
        }
    }

    public func addLabels(_ labels: [String], uid: UInt32) async throws {
        guard gmail else { throw IMAPError.readOnlyViolation("STORE X-GM-LABELS") }
        try requireOwn(uid, "STORE X-GM-LABELS")
        let encoded = try RestoreTarget.restorableLabels(labels).map { label in
            label.hasPrefix("\\") ? GmailLabel(ByteBuffer(string: label))
                                  : GmailLabel(mailboxName: try MailboxPath.makeRootMailbox(displayName: label).name)
        }
        guard !encoded.isEmpty else { return }
        do {
            try await run(.uidStore(try Self.uidSet([uid]), [], .gmailLabels(.add(silent: true, gmailLabels: encoded))))
        } catch IMAPError.command(_, let message) {
            throw ServerRefusal(message)
        }
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
    /// those of a `.restore` connection (SELECT, adding Gmail labels, setting/clearing client
    /// system flags — never \Deleted; `requireOwn` limits both to its own uploads; APPEND has its
    /// own checks).
    /// `inbox`: for `.rescueFromJunk`, the one mailbox the current move may go to (INBOX, or 6.8
    /// the folder the mail came from) — nil outside such a move.
    static func isAllowedChange(_ command: Command, access: IMAPAccess, trash: MailboxName?, inbox: MailboxName? = nil,
                                junk: MailboxName? = nil) -> Bool {
        switch (access, command) {
        case (.moveToTrash, .select(_, let params)), (.restore, .select(_, let params)), (.rescueFromJunk, .select(_, let params)),
             (.markAsJunk, .select(_, let params)), (.moveToFolder, .select(_, let params)):
            return params.allSatisfy { if case .basic(let kv) = $0 { kv.key.uppercased() == "CONDSTORE" } else { false } }
        // explicit UID sets only: `$` (SEARCHRES, the last search's hits) never names the messages
        case (.moveToTrash, .uidMove(.set, let destination)), (.moveToTrash, .uidCopy(.set, let destination)):
            return trash != nil && destination == trash
        case (.moveToTrash, .uidStore(.set, let modifiers, .flags(let store))):
            return modifiers.isEmpty && store.operation == .add && store.flags == [.deleted]
        case (.moveToTrash, .uidExpunge(.set)):
            return true  // explicit UIDs only (UIDPLUS); bare EXPUNGE and CLOSE stay refused
        case (.rescueFromJunk, .uidMove(.set, let destination)), (.rescueFromJunk, .uidCopy(.set, let destination)),
             (.moveToFolder, .uidMove(.set, let destination)), (.moveToFolder, .uidCopy(.set, let destination)):
            return inbox != nil && destination == inbox  // the move's one target, checked by mayTakeRescued; the source per session
        case (.rescueFromJunk, .uidStore(.set, let modifiers, .flags(let store))), (.moveToFolder, .uidStore(.set, let modifiers, .flags(let store))):
            return modifiers.isEmpty && store.operation == .add && store.flags == [.deleted]
        case (.rescueFromJunk, .uidExpunge(.set)), (.moveToFolder, .uidExpunge(.set)):
            return true
        case (.markAsJunk, .uidMove(.set, let destination)), (.markAsJunk, .uidCopy(.set, let destination)):
            return junk != nil && destination == junk  // the source is checked per session (selectedMayMarkJunk)
        case (.markAsJunk, .uidStore(.set, let modifiers, .flags(let store))):
            return modifiers.isEmpty && store.operation == .add && store.flags == [.deleted]
        case (.markAsJunk, .uidExpunge(.set)):
            return true
        case (.restore, .uidStore(_, let modifiers, .gmailLabels(let store))):
            return modifiers.isEmpty && store.operation == .add
        case (.restore, .uidStore(_, let modifiers, .flags(let store))):
            let client: Set<Flag> = [.seen, .answered, .flagged, .draft]
            return modifiers.isEmpty && store.operation != .replace && !store.flags.isEmpty && Set(store.flags).isSubset(of: client)
        default:
            return false
        }
    }

    @discardableResult
    func run(_ command: Command, failure: (String) -> IMAPError = { _ in IMAPError.closed }) async throws -> Result {
        guard Self.isReadOnly(command) || Self.isAllowedChange(command, access: access, trash: trash, inbox: rescueTarget, junk: junk) else {
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
        let stream = parts(t)
        // Every part passes a check here as well: commands the allowlist, APPEND only on .restore.
        for part in stream {
            switch part {
            case .tagged(let tagged):
                guard Self.isReadOnly(tagged.command) || Self.isAllowedChange(tagged.command, access: access, trash: trash, inbox: rescueTarget, junk: junk) else {
                    throw IMAPError.readOnlyViolation(Self.name(of: tagged.command))
                }
                // a rescue moves only out of the spam folder, "Ist Spam" only out of an ordinary one,
                // "Ablage ändern" out of none of trash, sent, drafts or All Mail
                if access == .rescueFromJunk || access == .markAsJunk || access == .moveToFolder {
                    switch tagged.command {
                    case .uidMove, .uidCopy:
                        switch access {
                        case .rescueFromJunk:
                            guard selectedIsJunk else { throw IMAPError.readOnlyViolation("MOVE aus einem Nicht-Spam-Ordner") }
                        case .markAsJunk:
                            guard selectedMayMarkJunk else { throw IMAPError.readOnlyViolation("MOVE aus einem Spam-, Papierkorb-, Gesendet- oder Entwurfsordner") }
                        default:
                            guard selectedMayGive else { throw IMAPError.readOnlyViolation("MOVE aus einem Papierkorb-, Gesendet-, Entwurfs- oder Alle-Nachrichten-Ordner") }
                        }
                    default: break
                    }
                }
                // a restore connection changes only what it uploaded itself — checked here, not by convention
                if access == .restore, case .uidStore(.set(let set), _, _) = tagged.command {
                    let own = selectedMailbox.flatMap { appendedUIDs[$0] } ?? []
                    guard set.set.allSatisfy({ own.contains(UInt32($0.rawValue)) }) else {
                        throw IMAPError.readOnlyViolation("STORE auf eine fremde Mail")
                    }
                } else if access == .restore, case .uidStore = tagged.command {
                    throw IMAPError.readOnlyViolation("STORE ohne UID-Liste")
                }
                // a delete (or any move) connection flags and expunges only what it has just copied
                if access == .moveToTrash || access == .rescueFromJunk || access == .markAsJunk || access == .moveToFolder {
                    let uids: MessageIdentifierSetNonEmpty<UID>? = switch tagged.command {
                    case .uidStore(.set(let set), _, _), .uidExpunge(.set(let set)): set
                    default: nil
                    }
                    if let uids {
                        let copied = selectedMailbox.flatMap { copiedUIDs[$0] } ?? []
                        guard uids.set.allSatisfy({ copied.contains(UInt32($0.rawValue)) }) else {
                            throw IMAPError.readOnlyViolation("STORE/EXPUNGE auf nicht kopierte Mails")
                        }
                    }
                }
            case .append:
                guard access == .restore else { throw IMAPError.readOnlyViolation("APPEND") }
            default:
                throw IMAPError.readOnlyViolation("unbekannter Befehlsteil")
            }
        }
        let writes = stream.map { channel.write(IMAPClientHandler.Message.part($0)) }
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
            do { next = try await it.next(isolation: self) } catch {
                if Task.isCancelled { throw CancellationError() }
                throw Self.mapped(error)
            }
            // a cancelled task ends the stream: that is "stopped", not a lost connection
            if next == nil, Task.isCancelled { throw CancellationError() }
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
        if let u = error as? UnexpectedResponse, u.kind == .appendNotWaitingForTaggedResponse { return .refusedBeforeData }
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

    /// UIDs are 1…2³²−2 here: 0 is invalid (swift-nio-imap would trap) and 2³²−1 encodes as `*`
    /// ("the last message") — a damaged queue or index row must not turn into either.
    static func uidSet(_ uids: [UInt32]) throws -> LastCommandSet<UID> {
        var set = MessageIdentifierSet<UID>()
        for u in uids where u >= 1 && u < .max { set.formUnion(MessageIdentifierSet<UID>(UID(rawValue: u))) }
        guard let nonEmpty = MessageIdentifierSetNonEmpty(set: set) else { throw IMAPError.protocolError("keine gültige UID") }
        return .set(nonEmpty)
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
