# ADR-0001: Archive format — raw .eml blobs, metadata journal, SQLite as a projection

- Status: accepted (TJ, 2026-10-10)
- Deciders: TJ

## Context

The archive must outlive the app: readable without MailKeeper, verifiable, and restorable
after index loss. Spike S1 showed that "the same mail" is not always the same bytes:
Dovecot and Gmail return byte-identical messages, Proton Bridge rebuilds headers on every
APPEND/import. Mailboxes reach 300k messages / 20 GB.

## Decision

1. **Blobs:** every fetched message is stored exactly as received under
   `<root>/blobs/<aa>/<bb>/<sha256>.eml` (content-addressed, written tmp → fsync → hash →
   rename). Identical bytes from several folders/accounts are stored once. Plain `.eml`, no
   app-specific compression or encryption — confidentiality comes from FileVault / an
   encrypted volume; MailKeeper warns when the archive root sits on an unencrypted volume.
2. **Metadata journal:** provider metadata that is not in the bytes (account, mailbox,
   UIDVALIDITY/UID, INTERNALDATE, flags, Gmail labels/X-GM-MSGID, "gone from server", user
   actions) is appended to `<root>/journal/<account-id>/<yyyy-mm>.jsonl`. No message content
   in the journal. Blobs + journal are the source of truth.
3. **Index:** SQLite (WAL) in the archive root is a rebuildable projection of blobs + journal:
   `messages` (identity), `blobs`, `locations`, `attachments`, FTS5, tags, rules, memory,
   audit. Schema migrations are versioned; "Rebuild index" is a supported command.
4. **Identity:** a *blob* is identified by its SHA-256; a *message* by its normalised
   Message-ID, with a fallback key (hash of normalised From/Date/Subject + decoded text) for
   mails without one. One message can have several blobs (e.g. original from mailcow, rebuilt
   copy from Proton).
5. **Integrity:** "archived" means: blob present and its hash re-verified after the write;
   periodic scrub re-hashes blobs. Server-side verification after a restore is provider
   specific (bytes equal for Dovecot/Gmail; Message-ID + decoded text for Proton).
6. **Search normalisation:** FTS5 `unicode61 remove_diacritics 2` plus our own folding before
   indexing and querying (ß→ss; query-time expansion ae/oe/ue ↔ ä/ö/ü), because unicode61
   leaves ß alone (spike S4).

## Consequences

- Any mail tool can read the blobs; `grep`/`ripgrep` works on the archive.
- Losing `index.sqlite` costs a rebuild, not data. Losing the journal loses folder/label
  history but not mail.
- The archive root must be backed up as a whole (restic / Time Machine). Blob files are
  immutable, which suits deduplicating backup tools.
- Deleting a blob is only allowed when no message references it (see ADR-0006).

## Alternatives

- Maildir: readable, but filename-encoded flags clash with immutable blobs, no label model,
  no dedupe across folders.
- Everything in SQLite (blobs as BLOBs): one file, but unreadable without the app and a
  single point of corruption.
