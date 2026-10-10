import Foundation
import SQLite3

public struct SQLiteError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?

    public var description: String {
        "SQLite error \(code): \(message)" + (sql.map { " — in: \($0.prefix(200))" } ?? "")
    }
}

/// A value bound to or read from a statement.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

extension SQLValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(stringLiteral value: String) { self = .text(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(floatLiteral value: Double) { self = .double(value) }
}

public extension SQLValue {
    static func optional(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
    static func optional(_ d: Double?) -> SQLValue { d.map { .double($0) } ?? .null }
    static func optional(_ i: Int64?) -> SQLValue { i.map { .int($0) } ?? .null }
    static func bool(_ b: Bool) -> SQLValue { .int(b ? 1 : 0) }
}

/// Read access to the current result row.
public struct Row {
    fileprivate let stmt: OpaquePointer

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func bool(_ i: Int32) -> Bool { sqlite3_column_int64(stmt, i) != 0 }

    public func text(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }

    public func data(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }

    public func optionalInt(_ i: Int32) -> Int64? { isNull(i) ? nil : int(i) }
    public func optionalDouble(_ i: Int32) -> Double? { isNull(i) ? nil : double(i) }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One SQLite connection. Not thread-safe: confine an instance to one actor or thread.
/// WAL mode lets a reader connection (UI) and a writer connection (import) work in parallel.
public final class Database {
    private let handle: OpaquePointer
    private var cache: [String: OpaquePointer] = [:]
    public let path: String

    /// `wal: false` uses a rollback journal (the index rebuild builds its fresh file that way,
    /// so no -wal/-shm files exist when it is swapped in).
    public init(path: String, readOnly: Bool = false, wal: Bool = true) throws {
        var h: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)) | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &h, flags, nil)
        guard rc == SQLITE_OK, let h else {
            let msg = h.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            if let h { sqlite3_close_v2(h) }
            throw SQLiteError(code: rc, message: msg, sql: nil)
        }
        handle = h
        self.path = path
        sqlite3_busy_timeout(h, 5_000)
        if !readOnly {
            try execute(wal ? "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;" : "PRAGMA journal_mode=DELETE;")
            // The index holds subjects, senders and snippets: private to the user (SQLite would
            // create it with the umask default, 0644). -wal/-shm inherit the main file's mode.
            if path != ":memory:" { chmod(path, 0o600) }
        }
        try execute("PRAGMA foreign_keys=ON;")
    }

    deinit {
        for stmt in cache.values { sqlite3_finalize(stmt) }
        sqlite3_close_v2(handle)
    }

    public var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(handle) }
    public var changes: Int { Int(sqlite3_changes(handle)) }

    /// Runs one or more statements without parameters (schema, pragmas).
    public func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg, sql: sql)
        }
    }

    /// Runs a single statement that returns no rows.
    public func run(_ sql: String, _ params: [SQLValue] = []) throws {
        let stmt = try prepared(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(params, to: stmt, sql: sql)
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw SQLiteError(code: rc, message: errorMessage, sql: sql)
        }
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ params: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        let stmt = try prepared(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(params, to: stmt, sql: sql)
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: errorMessage, sql: sql) }
            out.append(try map(Row(stmt: stmt)))
        }
        return out
    }

    public func queryOne<T>(_ sql: String, _ params: [SQLValue] = [], _ map: (Row) throws -> T) throws -> T? {
        try query(sql, params, map).first
    }

    /// Calls `body` for every row without collecting (large scans).
    public func forEach(_ sql: String, _ params: [SQLValue] = [], _ body: (Row) throws -> Void) throws {
        let stmt = try prepared(sql)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        try bind(params, to: stmt, sql: sql)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(code: rc, message: errorMessage, sql: sql) }
            try body(Row(stmt: stmt))
        }
    }

    /// BEGIN IMMEDIATE … COMMIT, rolled back if `body` throws.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Internals

    private var errorMessage: String { String(cString: sqlite3_errmsg(handle)) }

    private func prepared(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] { return s }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw SQLiteError(code: rc, message: errorMessage, sql: sql) }
        cache[sql] = stmt
        return stmt
    }

    private func bind(_ params: [SQLValue], to stmt: OpaquePointer, sql: String) throws {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch p {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            }
            guard rc == SQLITE_OK else { throw SQLiteError(code: rc, message: errorMessage, sql: sql) }
        }
    }
}
