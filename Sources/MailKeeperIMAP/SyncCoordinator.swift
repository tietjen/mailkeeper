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

    public var description: String {
        switch self {
        case .noPassword(let id): "Für Konto „\(id)“ ist kein Passwort im Schlüsselbund"
        case .unconfirmedCertificate(let id): "Das Bridge-Zertifikat von „\(id)“ ist noch nicht bestätigt"
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
