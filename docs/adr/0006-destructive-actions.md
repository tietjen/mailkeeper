# ADR-0006: Destructive actions — plan, execute, verify; archive first

- Status: proposed (2026-10-10, informed by spike S1)
- Deciders: TJ

## Context

Deleting on servers and in the archive, and restoring into accounts, are the operations that
can lose mail. Other consumers read the same mailboxes (Paperless ingests mailcow and Proton
with a 30-day window). Provider semantics differ (S1): Gmail labels and Message-ID dedupe on
APPEND, Proton rebuilds messages and ignores the APPEND date, Dovecot is textbook.

## Decision

1. **One path:** every destructive or bulk action goes through the persisted queue
   (`queue.json`, 0600, read entry by entry, unreadable entries kept aside) as
   **plan → execute → verify → audit**:
   - *Plan* (dry run): affected messages, counts, size, examples, per-message preconditions.
   - *Execute*: batched, resumable, progress, stop after the current item; each item moves
     planned → claimed → done/failed and is journalled before and after.
   - *Verify*: re-read the server/archive state; failures stay visible with a retry.
   - *Audit*: `~/Library/Logs/MailKeeper/audit.jsonl`, metadata only.
2. **Server delete preconditions** (all must hold): a verified blob exists; the location still
   matches (UIDVALIDITY unchanged, Message-ID re-fetched for that UID right before acting —
   claim, then act); the message is older than the account's **grace period** (default 30
   days); it is not protected (flagged, pinned by a rule).
3. **Provider semantics:** delete = `UID MOVE` to the SPECIAL-USE `\Trash` (localised names
   resolved, never guessed). Permanent deletion (EXPUNGE in Trash) is a separate, explicit
   choice and asks for Touch ID / password. Gmail: removing from a label is not deletion;
   restoring a still-trashed message untrashes it (same X-GM-MSGID).
4. **Archive delete:** to the archive trash (30 days), then purge; a blob is removed only when
   no message references it.
5. **Restore:** `APPEND` of the stored bytes with original flags and INTERNALDATE (Proton
   ignores the date and uses `Date:`); Message-ID pre-check in the target; Gmail labels via
   `STORE +X-GM-LABELS`; Proton in batches of 100–500 with long timeouts (~1.5 s/message).
   Verified per provider (bytes for Dovecot/Gmail, Message-ID + decoded text for Proton).
6. **Models never act:** LLM output can propose a queue entry; only the user executes it.
   Rules may run unattended only for non-destructive actions (tags, labels in the archive).

## Consequences

- Deleting is slower than a mail client's delete key — by design.
- The grace period protects other consumers (Paperless) and recent mail; it is per account.
- Crash or quit mid-run resumes from the queue and journal without repeating finished items.
