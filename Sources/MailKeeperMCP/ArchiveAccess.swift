import Foundation
import MailKeeperKit

/// The people's archives, read-only, one reader per person, serialised (a reader is confined to
/// one thread). Opened on first use and kept; a reader reopens by itself after an index rebuild.
public actor ArchiveAccess {
    let archives: [String: URL]
    private var readers: [String: ArchiveReader] = [:]

    public init(archives: [String: URL]) {
        self.archives = archives
    }

    /// Runs `body` with the person's reader. An archive that cannot be opened is
    /// `source_unreachable`; its cause goes to the log, never to the caller.
    public func read<T: Sendable>(_ person: String, _ body: @Sendable (ArchiveReader) throws -> T) throws -> T {
        let reader = try reader(person)
        do { return try body(reader) } catch let refusal as Refusal { throw refusal } catch {
            readers[person] = nil  // a broken connection is not kept
            throw Refusal("source_unreachable", "the archive could not be read", hint: cause(error))
        }
    }

    private func reader(_ person: String) throws -> ArchiveReader {
        if let r = readers[person] { return r }
        guard let url = archives[person] else { throw Refusal("misconfigured", "no archive for this person") }
        do {
            let r = try ArchiveReader(layout: try ArchiveLayout.openExisting(at: url), readOnly: true)
            readers[person] = r
            return r
        } catch {
            throw Refusal("source_unreachable", "the archive is not readable right now", hint: cause(error))
        }
    }

    /// For `/healthz`: every archive opens and answers.
    public func healthy() -> Bool {
        for person in archives.keys {
            guard let r = try? reader(person), (try? r.stats()) != nil else {
                readers[person] = nil
                return false
            }
        }
        return true
    }
}

/// The kind of an internal error, for the log: its type and, for SQLite, the code — never a
/// message, SQL or a path (they can name the person's folder or echo content).
func cause(_ error: Error) -> String {
    switch error {
    case let e as SQLiteError: return "SQLiteError:\(e.code)"
    case let e as ArchiveSchemaMismatch: return "schema:\(e.found)-\(e.expected)"
    default: return String(describing: type(of: error))
    }
}
