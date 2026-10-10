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
    ]

    static var currentVersion: Int { migrations.count }

    static func migrate(_ db: Database) throws {
        let version = Int(try db.queryOne("PRAGMA user_version") { $0.int(0) } ?? 0)
        guard version < migrations.count else { return }
        try db.transaction {
            for v in version..<migrations.count {
                try db.execute(migrations[v])
            }
            try db.execute("PRAGMA user_version = \(migrations.count)")
        }
    }
}
