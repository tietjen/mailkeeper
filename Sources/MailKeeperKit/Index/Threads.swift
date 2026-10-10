import Foundation

/// Conversations: two messages share a thread when one references the other (References,
/// In-Reply-To) or both reference the same message — which also joins replies whose original
/// is not in the archive. Union-find, incremental: a new message merges the threads of every
/// message it touches. The partition does not depend on arrival order, so a rebuild reproduces
/// it; thread ids may differ, which is why queries name a thread by a member's Message-ID.
enum Threads {
    /// The last references are the closest ancestors; long chains only add cost.
    static let maxReferences = 20

    /// The references a message links by: plausible ids only (`<1>`, `<unknown>` would chain
    /// unrelated mail), without its own id, deduplicated.
    static func references(inReplyTo: String?, references: [String], own: String?) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for r in references.suffix(maxReferences) + [inReplyTo].compactMap({ $0 })
        where r != own && MessageIDs.isPlausible(r) && seen.insert(r).inserted {
            out.append(r)
        }
        return out
    }

    /// Assigns message `id` its thread and merges the threads it connects.
    static func link(_ db: Database, id: Int64, messageID: String?, references refs: [String]) throws {
        var threads: Set<Int64> = []
        let collect = { (row: Row) in _ = threads.insert(row.int(0)) }
        if !refs.isEmpty {
            let marks = Array(repeating: "?", count: refs.count).joined(separator: ",")
            let values = refs.map { SQLValue.text($0) }
            // ancestors in the archive
            try db.forEach("SELECT DISTINCT thread_id FROM messages WHERE message_id IN (\(marks)) AND thread_id IS NOT NULL",
                           values, collect)
            // siblings: messages referencing the same ancestor
            try db.forEach("""
                SELECT DISTINCT m.thread_id FROM message_refs r JOIN messages m ON m.id = r.message_id
                WHERE r.ref IN (\(marks)) AND m.thread_id IS NOT NULL
                """, values, collect)
        }
        if let messageID {
            // replies that arrived before their original
            try db.forEach("""
                SELECT DISTINCT m.thread_id FROM message_refs r JOIN messages m ON m.id = r.message_id
                WHERE r.ref = ? AND m.thread_id IS NOT NULL
                """, [.text(messageID)], collect)
        }
        let thread = threads.union([id]).min()!
        let merged = threads.subtracting([thread])
        if !merged.isEmpty {
            let marks = Array(repeating: "?", count: merged.count).joined(separator: ",")
            try db.run("UPDATE messages SET thread_id = ? WHERE thread_id IN (\(marks))", [.int(thread)] + merged.map { .int($0) })
        }
        try db.run("UPDATE messages SET thread_id = ? WHERE id = ?", [.int(thread), .int(id)])
        for r in refs {
            try db.run("INSERT OR IGNORE INTO message_refs(message_id, ref) VALUES (?, ?)", [.int(id), .text(r)])
        }
    }

    /// Archives indexed before threads existed (schema v3): link every message in id order
    /// from the stored header columns — no blob is read.
    static func backfill(_ db: Database) throws {
        var rows: [(id: Int64, messageID: String?, inReplyTo: String?, refs: String)] = []
        try db.forEach("SELECT id, message_id, in_reply_to, refs FROM messages WHERE thread_id IS NULL ORDER BY id") { row in
            rows.append((row.int(0), row.text(1), row.text(2), row.text(3) ?? ""))
        }
        for r in rows {
            let refs = references(inReplyTo: r.inReplyTo, references: r.refs.split(separator: " ").map(String.init), own: r.messageID)
            try link(db, id: r.id, messageID: r.messageID, references: refs)
        }
    }
}
