# ADR-0006: Destructive actions — plan, execute, verify; archive first

- Status: accepted (TJ, 2026-10-10)
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
   - *Audit*: `Logs/MailKeeper/audit.jsonl` in the user's Library, metadata only. *As built:* the
     sandboxed app's Library is its container (`~/Library/Containers/de.paranoidsecurity.MailKeeper/
     Data/Library/Logs/MailKeeper/`); `~/Library/Logs/MailKeeper/` is mkctl's and the dev build's.
2. **Server delete preconditions** (all must hold): a verified blob exists; the location still
   matches (UIDVALIDITY unchanged, Message-ID re-fetched for that UID right before acting —
   claim, then act); the message is older than the account's **grace period** (default 30
   days); it is not protected (flagged, pinned by a rule).
3. **Provider semantics:** delete = `UID MOVE` to the SPECIAL-USE `\Trash` (localised names
   resolved, never guessed). Permanent deletion (EXPUNGE in Trash) is a separate, explicit
   choice and asks for Touch ID / password. Gmail: removing from a label is not deletion;
   restoring a still-trashed message untrashes it (same X-GM-MSGID).
   *As built (2026-11-09, first real Gmail runs):* Gmail moved 50 messages out of All Mail in
   1–3 s one evening and in 65 s to over 120 s the next morning; the 120 s read timeout then
   closed the connection under a move Gmail carried out, and the job stopped. Delete connections
   now wait 300 s like restore; Gmail accounts use batches of 20; a dropped connection
   (`IMAPError.closed`/`.connection` — a reset socket counts as `.connection` now, no longer as a
   protocol error) is opened again — the reconnect itself included — up to twice in a row
   without progress per account, and the account's open items go on, claimed ones re-checked as
   on resume. An item claimed *in this run* whose UID is gone on that re-check, seconds after
   the drop, was moved by this delete: done with "beim unterbrochenen Lauf in den Papierkorb
   verschoben", which "Komplett entfernen" treats like a plain done. A claim from an earlier run
   (resumed by hand, maybe days later; the process may have died between claim and move) proves
   less and stays "war bereits nicht mehr auf dem Server", like an unclaimed one; a hand-resumed
   job has no archive half anyway. The re-check also merges several FETCH responses of one UID (Gmail
   answered one message of a batch without its header; alone it answered in full), and an
   identity without a Message-ID in the answer is compared by its bytes, never failed as "does
   not match" for a missing header.
4. **Archive delete:** to the archive trash (30 days), then purge; a blob is removed only when
   no message references it. *As built (review 4.7):* the writer enforces "in the trash means on
   no server" itself — `trash` leaves a message with a live server location alone (checked when
   it happens, not only when planned), `purge` takes only what is in the trash (a stale list in
   the GUI cannot purge live mail) and takes a trashed message that is back on a server out of
   the trash instead. A location marked gone that the server lists again is present again (sync,
   journalled), and leaves the trash. A purged `mid:` identity's tombstone keeps a hash of sender
   and subject (no text): a different message reusing the Message-ID is not swallowed by it.
   *As built (TJ 2026-11-08):* the period is the archive's own (`settings.json`, default 30
   days, 1–3650, or `null` = only by hand; a file that is there but unreadable means only by
   hand, never the default — fail closed); a shorter period that would purge at once, or whose
   count fails, asks for Touch ID / password like any permanent delete, and purges right after. **"Komplett entfernen"** is a server delete
   followed by an archive delete of the same messages, planned together (both halves' items fixed
   at plan time) and shown in one plan sheet. The archive half is stored and run only after the
   server half ran to its end — a stopped or failed server half leaves no archive half to resume
   on its own — and it plans messages still on a server as well: the writer's own check leaves
   whatever the server half did not take off the server ("liegt noch auf einem Server"). Before
   it runs, it is fitted to the server half's result (`ActionJob.archiveHalf`, matched by
   Message-ID or blob): a mail with a server item not done stays, and so does one whose UID was
   already gone — it may have moved to another folder since the last fetch, which the writer
   cannot see ("erst neu abrufen"). A retry of failed server items is a removal again. An
   account that fetches its server trash brings a removed mail back out of the archive trash
   with the next fetch (nothing lost; the removal holds only until then).
5. **Restore:** `APPEND` of the stored bytes with original flags and INTERNALDATE (Proton
   ignores the date and uses `Date:`); Message-ID pre-check in the target; Gmail labels via
   `STORE +X-GM-LABELS`; Proton in batches of 100–500 with long timeouts (~1.5 s/message).
   Verified per provider (bytes for Dovecot/Gmail, Message-ID + decoded text for Proton).
   *As built (4.4, 2026-10-11):* default target = where the message was last seen, in each
   account it is no longer in (moved on the server = still there, no duplicate); otherwise one
   chosen mailbox, only among those the account syncs. Own connection access `.restore`:
   SELECT, APPEND into an existing mailbox that is neither Trash nor Junk (never CREATE),
   `+X-GM-LABELS` only on UIDs appended on that connection — nothing that removes, moves or
   changes flags. Only the system flags `\Seen \Answered \Flagged \Draft` go back (`\Deleted`
   never); Gmail system labels only Inbox/Important/Starred. After the APPEND the message is
   fetched back (APPENDUID, else by Message-ID), compared (bytes, or Message-ID where the
   provider rewrites) and recorded as a location exactly like a sync. A claimed item is looked
   up again on resume; without a Message-ID its outcome cannot be checked and it fails with a
   hint rather than risk a duplicate.
   *After review (4.4):* the executor checks every target again against the account's current
   sync selection (`SyncPolicy.select` on the server's LIST) — a resumed job or an edited queue
   file cannot write where MailKeeper does not look. "Already there" needs Message-ID *and*
   sender/subject (the archive's identity rule). A server refusing an APPEND before the literal
   (NO instead of `+`; seen live on Dovecot) makes swift-nio-imap drop reply and connection: it
   fails that item and the executor reconnects. APPENDLIMIT is honoured up front; Gmail labels
   that no longer exist are left out (STORE would create them); without SPECIAL-USE a name veto
   keeps uploads out of "Trash"/"Junk". Client flags the server changed on the way in are put
   back on that upload only (Proton marks uploads as read) — only when the APPENDUID names it;
   found by search instead, labels and flags stay as the server stored them (noted). After three
   refusals in a row an account's rest is not tried (full mailbox: no login storm). The
   connection itself checks that every STORE names only UIDs it appended.
6. **Models never act:** LLM output can propose a queue entry; only the user executes it.
   Rules may run unattended only for non-destructive actions (tags, labels in the archive).
7. **Export (4.6):** not destructive, so no queue: one `.eml` per message (exactly the archived
   bytes, `O_EXCL` — never overwrites, date as file date) or one mbox (mboxrd: `From` line,
   `>From` escaping, bytes and line endings kept, one LF after each message — MailKeeper's mbox
   import gives back the same blobs). Every blob is verified first; damaged or missing copies
   are reported, not written. A stopped mbox export removes the half file. Files are 0600.
   Replacing an mbox (confirmed in the save panel) builds it beside the old one and swaps it in
   only when complete; a new file is `O_EXCL | O_NOFOLLOW`, so a stop removes only its own file.
8. **"Kein Spam → Posteingang" (5.5):** a mail in a spam folder that the user calls not spam moves
   on the server from that folder to INBOX — through the queue and the audit like every server
   action, with one click for a single mail (TJ) and the plan sheet for several. Own access
   `.rescueFromJunk`: SELECT, UID MOVE (or COPY + STORE +\Deleted + UID EXPUNGE on exactly the
   copied UIDs) only from the selected mailbox if it is the server's \Junk (by name only on a
   server without roles) and only into INBOX; `$` never stands for UIDs. Before acting:
   UIDVALIDITY and "still the same message" as for a delete; afterwards: gone from the spam folder,
   found in INBOX (Message-ID, bytes or sender/subject) and recorded like a sync; the user's
   decision ("Kein Spam" / "Ist Spam") is journalled and no model overrides it. Spam folders are
   read only when the account says so (`includeJunk`, never the trash; an include list still
   rules — Proton stays in its test folder).

   *As built (6.8, TJ 2026-10-13):* "Kein Spam" sends a mail back where it lay, not always to
   INBOX: the planner takes the account's newest ordinary location of the message (no spam,
   trash, sent, drafts or All Mail; gone rows count — a project folder before the server's filter
   took it, INBOX before an "Ist Spam"), else INBOX; the plan sheet can send all to one folder of
   the account instead. The executor and the `.rescueFromJunk` access take any target the server
   lists that is no spam, trash, sent or drafts mailbox by role and by name (an edited queue file
   naming "Sent" ends in INBOX, said); the allowlist admits exactly the one target of the running
   move. Why it matters (TJ): server-side filters learn from the spam folder — Dovecot IMAPSieve
   with rspamd (mailcow) or SpamAssassin trains "ham" when a mail is copied or moved out of
   Junk — so false positives must leave it; a model's "not spam" alone never moves anything: the
   "Laut KI kein Spam" list (`is:fehlalarm`) is seen first and confirmed in one plan, what must
   stay is taken out with "Ist Spam". `is:junk` means a spam folder the mail lies in now (on the
   server, or an import's folder) — a rescued mail left the review; "Kein Spam" also ends a "Spam"
   category, whoever gave it. Live on the mailcow test account: a folder → Junk → back to the
   folder. MailKeeper sets no `$Junk`/`$NotJunk` keywords (the access could not); filters that
   learn by keyword alone do not see the decision. Review 6.8 (Fable): one rule for the target,
   shared by executor and session (`RemoteMailbox.mayTakeRescued`: INBOX, or a selectable mailbox
   other than the source with no role but Archive — never All Mail, Starred, Important — whose
   name is no spam, trash, sent, drafts or Gmail-like view; one list of names for sync, queries
   and vetoes, "Bin" a trash only at the top level); a move the session refuses fails its group,
   not the job; `is:war-im-spam` (ever in a spam folder) keeps the unsubscribe lock, "Verdächtig"
   and the old-spam suggestion right after a server purges its spam folder; "Alle zurückholen"
   takes the list as shown; a user rule never calls spam what the user called no spam.
9. **"Ist Spam → Spam-Ordner" (6.4, TJ 2026-10-12):** the other direction of §8 with the same
   rails. Own IMAP access `.markAsJunk`: SELECT a mailbox that is no spam, trash, sent or drafts
   mailbox (by role and by name, always — review 6.7 S7: a server marking only \Junk and \Trash
   may keep "Sent" without a role) and move exactly the named UIDs into the
   spam mailbox (\Junk, or by name without roles; never created) — UID MOVE, or UID COPY + STORE
   +\Deleted + UID EXPUNGE on its own copies; every stream part checked, `$` refused. The planner
   takes per message and account one fetched location outside spam, sent and trash, INBOX first
   (Gmail: one move takes it out of All Mail too); imported mail gets the verdict only. Before the
   move UIDVALIDITY and identity are checked, after it the old location is marked gone, the mail
   is found in the spam mailbox (recorded where the account fetches it, `includeJunk`) and the
   user's "Ist Spam" is journalled. One mail is one click, several go through the plan sheet;
   queue and audit as everywhere. Live on the mailcow test account (both directions).

## Consequences

- Deleting is slower than a mail client's delete key — by design.
- The grace period protects other consumers (Paperless) and recent mail; it is per account.
- Crash or quit mid-run resumes from the queue and journal without repeating finished items.
