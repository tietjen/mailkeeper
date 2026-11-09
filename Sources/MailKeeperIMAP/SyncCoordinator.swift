import Foundation
import MailKeeperKit
import NIOCore

public extension IMAPEndpoint {
    init(_ account: AccountConfig) {
        let security: IMAPSecurity
        switch account.security {
        case .tls: security = .tls
        case .startTLS: security = .startTLS
        case .startTLSPinned(let fp): security = .startTLSPinned(fingerprint: fp)
        }
        self.init(host: account.host, port: account.port, security: security)
    }
}

public enum SyncError: Error, CustomStringConvertible {
    case noPassword(String)
    case unconfirmedCertificate(String)
    case unknownAccount(String)

    public var description: String {
        switch self {
        case .noPassword(let id): String(localized: "Für Konto „\(id)“ ist kein Passwort im Schlüsselbund")
        case .unconfirmedCertificate(let id): String(localized: "Das Bridge-Zertifikat von „\(id)“ ist noch nicht bestätigt")
        case .unknownAccount(let id): String(localized: "Konto „\(id)“ ist hier nicht eingerichtet")
        }
    }
}

/// Connection test result for account setup.
public struct ConnectionCheck: Sendable {
    public var capabilities: [String]
    public var mailboxes: [RemoteMailbox]
    /// Mailboxes the account's policy would sync.
    public var selected: [RemoteMailbox]
    /// Leaf certificate fingerprint (pinned/learn mode) for the user to confirm.
    public var certificateFingerprint: String?
}

/// Glue for CLI and app: credential from the keychain, connect, sync, close.
public enum SyncCoordinator {
    /// How this account signs in: its password, or — for a signed-in account (7.1) — a fresh
    /// access token, refreshed here so a long sync does not run into an expiring one.
    public static func credential(for account: AccountConfig,
                                  credentials: CredentialStore = CredentialStore()) async throws -> IMAPCredential {
        guard account.oauth != nil else {
            guard let password = try credentials.password(for: account) else { throw SyncError.noPassword(account.id) }
            return .password(account.normalizedPassword(password))
        }
        return .oauth2(accessToken: try await OAuthTokens2Go.shared.accessToken(for: account, credentials: credentials))
    }

    /// Opens a connection for this account. A signed-in account that is refused once throws the
    /// cached access token away and tries again with a fresh one: revoking the sign-in at Google
    /// kills the token at once, and without this the account would fail for up to an hour with
    /// "Anmeldung abgelehnt" instead of asking to sign in again (review 7.1 S2).
    public static func connect(_ account: AccountConfig, access: IMAPAccess = .readOnly,
                               credentials: CredentialStore = CredentialStore(),
                               readTimeout: TimeAmount = .seconds(120)) async throws -> IMAPSession {
        if case .startTLSPinned(nil) = account.security { throw SyncError.unconfirmedCertificate(account.id) }
        do {
            return try await IMAPSession.connect(IMAPEndpoint(account), username: account.username,
                                                 credential: try await credential(for: account, credentials: credentials),
                                                 access: access, readTimeout: readTimeout)
        } catch let error as IMAPError {
            guard case .authentication = error, account.oauth != nil else { throw error }
            await OAuthTokens2Go.shared.forget(account)
            return try await IMAPSession.connect(IMAPEndpoint(account), username: account.username,
                                                 credential: try await credential(for: account, credentials: credentials),
                                                 access: access, readTimeout: readTimeout)
        }
    }

    /// Runs a planned server-delete job (ADR-0006): one connection per account, opened with the
    /// narrow `.moveToTrash` access; everything else stays refused by the allowlist.
    ///
    /// Gmail can be slow: a MOVE of 50 messages out of All Mail took 1–3 s one evening and, the
    /// next morning, over the old 120 s read timeout — the connection was closed under a move the
    /// server then carried out (2026-11-09). Hence the restore's 300 s, batches of
    /// `gmailBatchSize` on Gmail, and a dropped connection is opened again instead of stopping
    /// the job.
    public static func deleteOnServer(_ jobID: UUID, writer: ArchiveWriter, accounts: [AccountConfig],
                                      credentials: CredentialStore = CredentialStore(), audit: AuditLog = AuditLog(),
                                      progress: @escaping @Sendable (ServerDeleteProgress) -> Void = { _ in }) async throws -> ActionJob {
        var executor = ServerDeleteExecutor(writer: writer, store: ActionStore(layout: writer.layout), audit: audit)
        executor.batchSizes = Dictionary(accounts.filter { $0.kind == .gmail }.map { ($0.id, gmailBatchSize) },
                                         uniquingKeysWith: { a, _ in a })
        return try await executor.run(jobID, connect: { id in
            guard let account = accounts.first(where: { $0.id == id }) else { throw SyncError.unknownAccount(id) }
            return try await connect(account, access: .moveToTrash, credentials: credentials, readTimeout: .seconds(300))
        }, reconnectAfter: { connectionDropped($0) }, progress: progress)
    }

    static let gmailBatchSize = 20

    /// The connection is gone (closed, timed out, reset) — worth opening again. A refusal, a
    /// failed sign-in or a protocol violation is not: it would come back the same.
    static func connectionDropped(_ error: Error) -> Bool {
        switch error as? IMAPError {
        case .closed?, .connection?: true
        default: false
        }
    }

    /// Runs a planned restore job (ADR-0006 §5): one connection per account with the narrow
    /// `.restore` access (APPEND into existing mailboxes, Gmail labels on what it appended). A long
    /// read timeout: Proton's bridge encrypts and uploads each message (~1.5 s, more for large ones).
    public static func restoreOnServer(_ jobID: UUID, writer: ArchiveWriter, accounts: [AccountConfig],
                                       credentials: CredentialStore = CredentialStore(), audit: AuditLog = AuditLog(),
                                       progress: @escaping @Sendable (ServerDeleteProgress) -> Void = { _ in }) async throws -> ActionJob {
        let executor = RestoreExecutor(writer: writer, store: ActionStore(layout: writer.layout), audit: audit)
        return try await executor.run(jobID, accounts: accounts, connect: { id in
            guard let account = accounts.first(where: { $0.id == id }) else { throw SyncError.unknownAccount(id) }
            return try await connect(account, access: .restore, credentials: credentials,
                                     readTimeout: .seconds(300))
        }, progress: progress)
    }

    /// Runs a "Kein Spam" job (5.5): one connection per account with the narrow `.rescueFromJunk`
    /// access (out of the spam folder into INBOX, nothing else).
    public static func rescueToInbox(_ jobID: UUID, writer: ArchiveWriter, accounts: [AccountConfig],
                                     credentials: CredentialStore = CredentialStore(), audit: AuditLog = AuditLog(),
                                     progress: @escaping @Sendable (ServerDeleteProgress) -> Void = { _ in }) async throws -> ActionJob {
        let executor = RescueExecutor(writer: writer, store: ActionStore(layout: writer.layout), audit: audit)
        return try await executor.run(jobID, accounts: accounts, connect: { id in
            guard let account = accounts.first(where: { $0.id == id }) else { throw SyncError.unknownAccount(id) }
            return try await connect(account, access: .rescueFromJunk, credentials: credentials)
        }, progress: progress)
    }

    /// "Ist Spam → Spam-Ordner" (6.4): the same executor in the other direction, with the narrow
    /// `.markAsJunk` access.
    public static func moveToJunk(_ jobID: UUID, writer: ArchiveWriter, accounts: [AccountConfig],
                                  credentials: CredentialStore = CredentialStore(), audit: AuditLog = AuditLog(),
                                  progress: @escaping @Sendable (ServerDeleteProgress) -> Void = { _ in }) async throws -> ActionJob {
        let executor = RescueExecutor(writer: writer, store: ActionStore(layout: writer.layout), audit: audit)
        return try await executor.run(jobID, accounts: accounts, connect: { id in
            guard let account = accounts.first(where: { $0.id == id }) else { throw SyncError.unknownAccount(id) }
            return try await connect(account, access: .markAsJunk, credentials: credentials)
        }, progress: progress)
    }

    /// "Ablage ändern" on the server (6.9b): the same executor with the narrow `.moveToFolder` access.
    public static func moveToFolder(_ jobID: UUID, writer: ArchiveWriter, accounts: [AccountConfig],
                                    credentials: CredentialStore = CredentialStore(), audit: AuditLog = AuditLog(),
                                    progress: @escaping @Sendable (ServerDeleteProgress) -> Void = { _ in }) async throws -> ActionJob {
        let executor = RescueExecutor(writer: writer, store: ActionStore(layout: writer.layout), audit: audit)
        return try await executor.run(jobID, accounts: accounts, connect: { id in
            guard let account = accounts.first(where: { $0.id == id }) else { throw SyncError.unknownAccount(id) }
            return try await connect(account, access: .moveToFolder, credentials: credentials)
        }, progress: progress)
    }

    /// Connects with a credential the caller just obtained (setup: a typed password, or the
    /// token of a sign-in that has not been saved yet) and reports mailboxes and, for a bridge
    /// in learn mode, the certificate fingerprint to confirm.
    public static func check(_ account: AccountConfig, password: String) async throws -> ConnectionCheck {
        try await check(account, credential: .password(account.normalizedPassword(password)))
    }

    /// Tests an account the way a sync would open it — a signed-in account that was revoked
    /// gets a fresh token instead of a stale "Anmeldung abgelehnt" (Nachprüfung 7.1).
    public static func check(_ account: AccountConfig,
                             credentials: CredentialStore = CredentialStore()) async throws -> ConnectionCheck {
        try await report(on: try await connect(account, credentials: credentials, readTimeout: .seconds(30)), for: account)
    }

    public static func check(_ account: AccountConfig, credential: IMAPCredential) async throws -> ConnectionCheck {
        let session = try await IMAPSession.connect(IMAPEndpoint(account), username: account.username,
                                                    credential: credential, readTimeout: .seconds(30))
        return try await report(on: session, for: account)
    }

    private static func report(on session: IMAPSession, for account: AccountConfig) async throws -> ConnectionCheck {
        do {
            let boxes = try await session.mailboxes()
            let check = ConnectionCheck(capabilities: await session.serverCapabilities, mailboxes: boxes,
                                        selected: account.policy.select(boxes), certificateFingerprint: await session.certificateFingerprint)
            await session.close()
            return check
        } catch {
            await session.close()
            throw error
        }
    }

    public static func sync(_ account: AccountConfig, writer: ArchiveWriter, credentials: CredentialStore = CredentialStore(),
                            progress: @escaping @Sendable (SyncProgress) -> Void = { _ in }) async throws -> SyncReport {
        let session = try await connect(account, credentials: credentials)
        do {
            let report = try await SyncEngine(writer: writer, account: account.info, policy: account.policy)
                .run(source: session, progress: progress)
            await session.close()
            return report
        } catch {
            await session.close()
            throw error
        }
    }
}
