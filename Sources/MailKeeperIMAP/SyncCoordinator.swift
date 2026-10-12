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
        case .noPassword(let id): "Für Konto „\(id)“ ist kein Passwort im Schlüsselbund"
        case .unconfirmedCertificate(let id): "Das Bridge-Zertifikat von „\(id)“ ist noch nicht bestätigt"
        case .unknownAccount(let id): "Konto „\(id)“ ist hier nicht eingerichtet"
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

/// Glue for CLI and app: password from the keychain, connect, sync, close.
public enum SyncCoordinator {
    /// Runs a planned server-delete job (ADR-0006): one connection per account, opened with the
    /// narrow `.moveToTrash` access; everything else stays refused by the allowlist.
    public static func deleteOnServer(_ jobID: UUID, writer: ArchiveWriter, accounts: [AccountConfig],
                                      credentials: CredentialStore = CredentialStore(), audit: AuditLog = AuditLog(),
                                      progress: @escaping @Sendable (ServerDeleteProgress) -> Void = { _ in }) async throws -> ActionJob {
        let executor = ServerDeleteExecutor(writer: writer, store: ActionStore(layout: writer.layout), audit: audit)
        return try await executor.run(jobID, connect: { id in
            guard let account = accounts.first(where: { $0.id == id }) else { throw SyncError.unknownAccount(id) }
            if case .startTLSPinned(nil) = account.security { throw SyncError.unconfirmedCertificate(id) }
            guard let password = try credentials.password(for: account) else { throw SyncError.noPassword(id) }
            return try await IMAPSession.connect(IMAPEndpoint(account), username: account.username,
                                                 password: account.normalizedPassword(password), access: .moveToTrash)
        }, progress: progress)
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
            if case .startTLSPinned(nil) = account.security { throw SyncError.unconfirmedCertificate(id) }
            guard let password = try credentials.password(for: account) else { throw SyncError.noPassword(id) }
            return try await IMAPSession.connect(IMAPEndpoint(account), username: account.username,
                                                 password: account.normalizedPassword(password), access: .restore,
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
            if case .startTLSPinned(nil) = account.security { throw SyncError.unconfirmedCertificate(id) }
            guard let password = try credentials.password(for: account) else { throw SyncError.noPassword(id) }
            return try await IMAPSession.connect(IMAPEndpoint(account), username: account.username,
                                                 password: account.normalizedPassword(password), access: .rescueFromJunk)
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
            if case .startTLSPinned(nil) = account.security { throw SyncError.unconfirmedCertificate(id) }
            guard let password = try credentials.password(for: account) else { throw SyncError.noPassword(id) }
            return try await IMAPSession.connect(IMAPEndpoint(account), username: account.username,
                                                 password: account.normalizedPassword(password), access: .markAsJunk)
        }, progress: progress)
    }

    /// Connects with an explicit password (setup) and reports mailboxes and, for a bridge in
    /// learn mode, the certificate fingerprint to confirm.
    public static func check(_ account: AccountConfig, password: String) async throws -> ConnectionCheck {
        let session = try await IMAPSession.connect(IMAPEndpoint(account), username: account.username,
                                                    password: account.normalizedPassword(password), readTimeout: .seconds(30))
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
        if case .startTLSPinned(nil) = account.security { throw SyncError.unconfirmedCertificate(account.id) }
        guard let password = try credentials.password(for: account) else { throw SyncError.noPassword(account.id) }
        let session = try await IMAPSession.connect(IMAPEndpoint(account), username: account.username,
                                                    password: account.normalizedPassword(password))
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
