import Foundation

/// The last result per account ("jan/parasec"), written after every account. Counts and error
/// texts only, never mail content — readable for probes and for people with `kubectl exec`.
public struct ServerStatus: Codable, Sendable, Equatable {
    public var updated: Date
    public var accounts: [String: AccountStatus]

    public struct AccountStatus: Codable, Sendable, Equatable {
        public var lastAttempt: Date
        public var lastSuccess: Date?
        /// New messages in the last successful run.
        public var newMessages: Int
        /// Why the last run did not get through — nil after a clean run.
        public var error: String?
    }

    public init(updated: Date = Date(), accounts: [String: AccountStatus] = [:]) {
        self.updated = updated
        self.accounts = accounts
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// A missing or unreadable file starts empty: the status is a report, not a source of truth.
    public static func load(from url: URL) -> ServerStatus {
        (try? decoder.decode(ServerStatus.self, from: Data(contentsOf: url))) ?? ServerStatus()
    }

    /// Atomically (temporary file + rename), 0600 like the rest of the data volume.
    public func write(to url: URL) throws {
        let data = try Self.encoder.encode(self)
        let tmp = url.deletingLastPathComponent().appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        guard rename(tmp.path, url.path) == 0 else {
            unlink(tmp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
