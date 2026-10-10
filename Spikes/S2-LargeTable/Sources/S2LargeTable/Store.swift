import Foundation
import SQLite3

struct RowData: Identifiable, Hashable {
    let id: Int64
    let date: Date
    let sender: String
    let subject: String
    let size: Int
    let account: String
}

enum SortKey: String, CaseIterable {
    case date, sender, subject, size, account
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Synthetic message index. Accessed from the main thread only (spike).
final class Store {
    let db: OpaquePointer
    private(set) var ids: [Int64] = []
    private(set) var version = 0
    var sortKey: SortKey = .date
    var ascending = false
    var filter: String?

    let pageSize = 256
    private var pages: [Int: [RowData]] = [:]
    private var pageLRU: [Int] = []
    private(set) var pageLoads = 0

    init(rows: Int) throws {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appending(path: "mailkeeper-s2")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appending(path: "messages-\(rows).sqlite").path
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let handle else { throw StoreError("open \(path)") }
        db = handle
        exec("PRAGMA journal_mode=WAL")
        exec("CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY, date REAL, sender TEXT, subject TEXT, size INTEGER, account TEXT)")
        if count() < rows {
            let t = Date()
            exec("DELETE FROM messages")
            generate(rows)
            log("generated \(rows) rows in \(String(format: "%.1f", Date().timeIntervalSince(t)))s at \(path)")
        }
        for col in ["date", "sender", "subject", "size", "account"] {
            exec("CREATE INDEX IF NOT EXISTS idx_\(col) ON messages(\(col), id)")
        }
    }

    struct StoreError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }

    // MARK: Queries

    private var orderClause: String {
        "ORDER BY \(sortKey.rawValue) \(ascending ? "ASC" : "DESC"), id \(ascending ? "ASC" : "DESC")"
    }

    private var whereClause: String { filter == nil ? "" : "WHERE subject LIKE ?1" }

    private func bindFilter(_ stmt: OpaquePointer) {
        if let filter { sqlite3_bind_text(stmt, 1, "%\(filter)%", -1, SQLITE_TRANSIENT) }
    }

    /// Ordered id list for the lazy variants (8 bytes per row).
    func reloadIDs() {
        var out: [Int64] = []
        out.reserveCapacity(ids.count)
        query("SELECT id FROM messages \(whereClause) \(orderClause)", bind: bindFilter) { s in
            out.append(sqlite3_column_int64(s, 0))
        }
        ids = out
        pages.removeAll(keepingCapacity: true)
        pageLRU.removeAll(keepingCapacity: true)
        version += 1
    }

    /// Every row materialised, for the array variant.
    func loadAll() -> [RowData] {
        var out: [RowData] = []
        out.reserveCapacity(ids.count)
        query("SELECT id, date, sender, subject, size, account FROM messages \(whereClause) \(orderClause)", bind: bindFilter) { s in
            out.append(Self.row(s))
        }
        return out
    }

    func row(at index: Int) -> RowData {
        let page = index / pageSize
        if let p = pages[page] { return p[index - page * pageSize] }
        let lo = page * pageSize, hi = min(ids.count, lo + pageSize)
        let slice = Array(ids[lo..<hi])
        var byID: [Int64: RowData] = [:]
        byID.reserveCapacity(slice.count)
        let placeholders = Array(repeating: "?", count: slice.count).joined(separator: ",")
        query("SELECT id, date, sender, subject, size, account FROM messages WHERE id IN (\(placeholders))", bind: { s in
            for (i, id) in slice.enumerated() { sqlite3_bind_int64(s, Int32(i + 1), id) }
        }) { s in
            let r = Self.row(s)
            byID[r.id] = r
        }
        let rows = slice.map { byID[$0]! }
        pages[page] = rows
        pageLRU.append(page)
        if pageLRU.count > 400 { pages[pageLRU.removeFirst()] = nil }
        pageLoads += 1
        return rows[index - lo]
    }

    private static func row(_ s: OpaquePointer) -> RowData {
        RowData(id: sqlite3_column_int64(s, 0),
                date: Date(timeIntervalSince1970: sqlite3_column_double(s, 1)),
                sender: String(cString: sqlite3_column_text(s, 2)),
                subject: String(cString: sqlite3_column_text(s, 3)),
                size: Int(sqlite3_column_int64(s, 4)),
                account: String(cString: sqlite3_column_text(s, 5)))
    }

    // MARK: SQLite helpers

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            log("sqlite error: \(String(cString: sqlite3_errmsg(db))) in \(sql)")
        }
    }

    private func count() -> Int {
        var n = 0
        query("SELECT count(*) FROM messages", bind: { _ in }) { s in n = Int(sqlite3_column_int64(s, 0)) }
        return n
    }

    private func query(_ sql: String, bind: (OpaquePointer) -> Void, row: (OpaquePointer) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            log("prepare failed: \(String(cString: sqlite3_errmsg(db)))")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
    }

    // MARK: Synthetic data

    private func generate(_ n: Int) {
        var rng = SplitMix64(seed: 42)
        let first = ["Anna", "Jan", "Lena", "Tom", "Sarah", "Markus", "Ingrid", "Paul", "Mia", "Felix", "Noah", "Emma"]
        let last = ["Berger", "Klein", "Weber", "Hansen", "Schulz", "Meyer", "Wagner", "Becker", "Hoffmann", "Koch"]
        let orgs = ["Amazon", "DHL", "netcup", "GitHub", "Heise", "PayPal", "Deutsche Bahn", "Lufthansa", "Stadtwerke",
                    "IKEA", "Proton", "Google", "LinkedIn", "Booking.com", "Reichelt", "Apple", "Spotify", "Sparkasse"]
        let topics = ["Rechnung", "Bestellung", "Lieferung", "Newsletter", "Termin", "Angebot", "Erinnerung",
                      "Sicherheitswarnung", "Projekt", "Fotos", "Buchung", "Re: Architektur-Review", "Fwd: Unterlagen"]
        let accounts = ["Gmail", "Proton", "parasec"]
        let now = Date().timeIntervalSince1970
        exec("BEGIN")
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO messages(id, date, sender, subject, size, account) VALUES (?,?,?,?,?,?)", -1, &stmt, nil)
        for i in 1...n {
            let human = rng.next() % 3 == 0
            let sender = human
                ? "\(first[rng.pick(first.count)]) \(last[rng.pick(last.count)])"
                : "\(orgs[rng.pick(orgs.count)])"
            let subject = "\(topics[rng.pick(topics.count)]) \(rng.pick(100_000)) – \(orgs[rng.pick(orgs.count)])"
            sqlite3_bind_int64(stmt, 1, Int64(i))
            sqlite3_bind_double(stmt, 2, now - Double(rng.pick(15 * 365 * 86_400)))
            sqlite3_bind_text(stmt, 3, sender, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 4, subject, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 5, Int64(2_000 + rng.pick(rng.pick(10) == 0 ? 20_000_000 : 120_000)))
            sqlite3_bind_text(stmt, 6, accounts[rng.pick(accounts.count)], -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)
        exec("COMMIT")
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func pick(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
}

func log(_ s: String) {
    FileHandle.standardError.write(Data("[S2] \(s)\n".utf8))
}
