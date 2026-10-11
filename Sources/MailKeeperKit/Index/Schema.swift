import Foundation

/// Index schema (a projection of blobs + journal, ADR-0001). Migrations run in order; the
/// applied version lives in `PRAGMA user_version`.
enum Schema {
    static let migrations: [String] = [
        // v1
        """
        CREATE TABLE accounts(
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            display_name TEXT NOT NULL,
            created REAL NOT NULL
        );
        CREATE TABLE blobs(
            sha256 TEXT PRIMARY KEY,
            size INTEGER NOT NULL,
            added REAL NOT NULL,
            verified REAL
        );
        CREATE TABLE messages(
            id INTEGER PRIMARY KEY,
            identity TEXT NOT NULL UNIQUE,
            message_id TEXT,
            subject TEXT,
            from_name TEXT,
            from_addr TEXT,
            to_addrs TEXT,
            cc_addrs TEXT,
            date REAL,
            in_reply_to TEXT,
            refs TEXT,
            list_id TEXT,
            list_unsubscribe INTEGER NOT NULL DEFAULT 0,
            precedence TEXT,
            auto_submitted TEXT,
            attachment_count INTEGER NOT NULL DEFAULT 0,
            size INTEGER NOT NULL,
            primary_blob TEXT NOT NULL REFERENCES blobs(sha256),
            snippet TEXT,
            first_seen REAL NOT NULL
        );
        CREATE INDEX messages_date ON messages(date);
        CREATE INDEX messages_from ON messages(from_addr);
        CREATE INDEX messages_list ON messages(list_id);
        CREATE INDEX messages_msgid ON messages(message_id);
        CREATE TABLE message_blobs(
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            sha256 TEXT NOT NULL REFERENCES blobs(sha256),
            PRIMARY KEY(message_id, sha256)
        );
        CREATE INDEX message_blobs_sha ON message_blobs(sha256);
        CREATE TABLE locations(
            id INTEGER PRIMARY KEY,
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            sha256 TEXT NOT NULL REFERENCES blobs(sha256),
            account_id TEXT NOT NULL REFERENCES accounts(id),
            mailbox TEXT NOT NULL,
            uid_validity INTEGER,
            uid INTEGER,
            provider_id TEXT,
            internal_date REAL,
            flags TEXT NOT NULL DEFAULT '',
            labels TEXT NOT NULL DEFAULT '',
            on_server INTEGER NOT NULL DEFAULT 1,
            first_seen REAL NOT NULL,
            last_seen REAL NOT NULL
        );
        CREATE UNIQUE INDEX locations_uid ON locations(account_id, mailbox, uid_validity, uid) WHERE uid IS NOT NULL;
        CREATE UNIQUE INDEX locations_pid ON locations(account_id, mailbox, provider_id) WHERE uid IS NULL AND provider_id IS NOT NULL;
        CREATE INDEX locations_box ON locations(account_id, mailbox);
        CREATE INDEX locations_msg ON locations(message_id);
        CREATE TABLE attachments(
            id INTEGER PRIMARY KEY,
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            filename TEXT,
            mime_type TEXT NOT NULL,
            size INTEGER NOT NULL,
            content_id TEXT,
            is_inline INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX attachments_msg ON attachments(message_id);
        CREATE VIRTUAL TABLE messages_fts USING fts5(
            subject, from_text, to_text, body, attachments,
            content='', contentless_delete=1,
            tokenize='unicode61 remove_diacritics 2'
        );
        """,
        // v2: per-mailbox sync state. Derived, not journalled: losing it only costs one full
        // flags fetch.
        """
        CREATE TABLE sync_state(
            account_id TEXT NOT NULL,
            mailbox TEXT NOT NULL,
            uid_validity INTEGER NOT NULL,
            highest_modseq INTEGER,
            last_sync REAL NOT NULL,
            PRIMARY KEY(account_id, mailbox)
        );
        CREATE INDEX locations_validity ON locations(account_id, mailbox, uid_validity);
        """,
        // v3: conversations (Threads.swift). Existing messages are linked right after.
        """
        ALTER TABLE messages ADD COLUMN thread_id INTEGER;
        CREATE INDEX messages_thread ON messages(thread_id);
        CREATE TABLE message_refs(
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            ref TEXT NOT NULL,
            PRIMARY KEY(message_id, ref)
        ) WITHOUT ROWID;
        CREATE INDEX message_refs_ref ON message_refs(ref);
        """,
        // v4: text of PDF attachments (ADR-0009). Derived from blobs, filled by a background
        // queue; a rebuild queues it again.
        """
        CREATE TABLE attachment_text(
            message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
            status TEXT NOT NULL,
            chars INTEGER NOT NULL DEFAULT 0,
            detail TEXT,
            extracted REAL NOT NULL,
            version INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE attachment_text_fts USING fts5(
            text, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2'
        );
        """,
        // v5: archive trash and tombstones (Phase 4.3, ADR-0006 4). Projections of journal
        // events (trashed/untrashed/purged).
        """
        ALTER TABLE messages ADD COLUMN trashed REAL;
        CREATE INDEX messages_trashed ON messages(trashed) WHERE trashed IS NOT NULL;
        CREATE TABLE tombstones(key TEXT PRIMARY KEY, purged REAL NOT NULL) WITHOUT ROWID;
        CREATE TABLE tombstone_locations(
            account_id TEXT NOT NULL, mailbox TEXT NOT NULL, uid_validity INTEGER NOT NULL, uid INTEGER NOT NULL,
            PRIMARY KEY(account_id, mailbox, uid_validity, uid)
        ) WITHOUT ROWID;
        """,
    ]

    static var currentVersion: Int { migrations.count }

    private static func version(_ db: Database) throws -> Int {
        Int(try db.queryOne("PRAGMA user_version") { $0.int(0) } ?? 0)
    }

    static func migrate(_ db: Database) throws {
        guard try version(db) < migrations.count else { return }
        try db.transaction {
            // Re-check under the write lock: another process may have migrated meanwhile.
            let version = try version(db)
            guard version < migrations.count else { return }
            for v in version..<migrations.count {
                try db.execute(migrations[v])
                if v == 2 { try Threads.backfill(db) }  // in the same transaction as the schema change
            }
            try db.execute("PRAGMA user_version = \(migrations.count)")
        }
    }
}
