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
        // v6: an identity tombstone remembers who sent it (a hash of sender and subject, no
        // content), so a different message reusing the Message-ID is not swallowed (review 4.7).
        """
        ALTER TABLE tombstones ADD COLUMN who TEXT;
        """,
        // v7: categories (Phase 5.4) — derived, not journalled: the rules recompute theirs, a
        // model's answer is asked again after a rebuild. category NULL = left open by the rules.
        """
        CREATE TABLE classifications(
            message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
            category TEXT,
            source TEXT NOT NULL,
            rule TEXT,
            model TEXT,
            reason TEXT,
            version INTEGER NOT NULL,
            created REAL NOT NULL
        );
        CREATE INDEX classifications_category ON classifications(category);
        """,
        // v8: the roles servers give their mailboxes (RFC 6154: junk, sent, trash …), refreshed at
        // every sync — derived, a rebuild has them back after the next one; names cover the rest.
        """
        CREATE TABLE mailbox_roles(
            account_id TEXT NOT NULL, mailbox TEXT NOT NULL, roles TEXT NOT NULL,
            PRIMARY KEY(account_id, mailbox)
        ) WITHOUT ROWID;
        """,
        // v9: the user's verdict apart from the category ("Kein Spam" keeps the model's category
        // and lets it be asked again), and the phishing assessment beside the category (5.6).
        """
        ALTER TABLE classifications ADD COLUMN verdict TEXT;
        ALTER TABLE classifications ADD COLUMN phishing TEXT;
        ALTER TABLE classifications ADD COLUMN phishing_reason TEXT;
        """,
        // v10: vectors for semantic search and "similar mails" (5.7) — derived, not journalled.
        """
        CREATE TABLE embeddings(
            message_id INTEGER PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
            model TEXT NOT NULL, dim INTEGER NOT NULL, vector BLOB NOT NULL, created REAL NOT NULL
        );
        """,
        // v11: the user's memory (ADR-0005, 6.1). Notes are journalled (`memory` events); examples
        // are a projection of the user's journalled decisions, refreshed with each of them; the
        // ids are stable across rebuilds ("ex:" + identity). Suggestion sources for "Warum?".
        """
        CREATE TABLE memory_items(
            id TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            scope TEXT NOT NULL DEFAULT '',
            subject TEXT NOT NULL DEFAULT '',
            content TEXT NOT NULL,
            provenance TEXT NOT NULL,
            sources TEXT NOT NULL DEFAULT '',
            weight REAL NOT NULL DEFAULT 1,
            created REAL NOT NULL,
            updated REAL NOT NULL,
            last_used REAL,
            active INTEGER NOT NULL DEFAULT 1
        );
        CREATE INDEX memory_items_subject ON memory_items(subject);
        CREATE TABLE suggestion_sources(
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            memory_id TEXT NOT NULL,
            PRIMARY KEY(message_id, memory_id)
        ) WITHOUT ROWID;
        INSERT INTO memory_items(id, kind, subject, content, provenance, sources, created, updated)
        \(Memory.exampleSelect) WHERE c.source = 'user' OR c.verdict IS NOT NULL;
        """,
        // v12: who checked a mail and what came out (topmost Authentication-Results) and where it
        // was delivered (6.3, ADR-0010 §6). Derived from the blob: set at ingest, and for older
        // messages by a background pass that reads only the header (`headers_v` NULL = not yet).
        """
        ALTER TABLE messages ADD COLUMN auth_server TEXT;
        ALTER TABLE messages ADD COLUMN auth_dkim TEXT;
        ALTER TABLE messages ADD COLUMN auth_spf TEXT;
        ALTER TABLE messages ADD COLUMN auth_dmarc TEXT;
        ALTER TABLE messages ADD COLUMN auth_from TEXT;
        ALTER TABLE messages ADD COLUMN delivered_to TEXT;
        ALTER TABLE messages ADD COLUMN headers_v INTEGER;
        CREATE INDEX messages_headers_pending ON messages(headers_v) WHERE headers_v IS NULL;
        """,
        // v13: the inbox screening (6.4) — when a message was looked at, and the register's or the
        // own server's warning (look-alike, failed check) so "Verdächtig" shows it without a model.
        """
        ALTER TABLE classifications ADD COLUMN screened REAL;
        ALTER TABLE classifications ADD COLUMN warning TEXT;
        """,
        // v14: the archive's own placement of a mail per account (6.9, ADR-0011) — journalled
        // (`placed`), a projection like the user's other decisions.
        """
        CREATE TABLE placements(
            message_id INTEGER NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
            account_id TEXT NOT NULL,
            mailbox TEXT NOT NULL,
            time REAL NOT NULL,
            PRIMARY KEY(message_id, account_id)
        );
        CREATE INDEX placements_mailbox ON placements(account_id, mailbox);
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
