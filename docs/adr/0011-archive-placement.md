# ADR-0011: The archive's own placement of a mail (Ablage)

- Status: accepted (TJ, 2026-10-13)
- Deciders: TJ

## Context

Until now a mail's "Ablage" in MailKeeper was where it had been seen: a server folder from a
sync, or the folder an import came from. The archive could not file a mail anywhere else. TJ's
example: a newsletter imported from a backup's "Junk", judged "kein Spam" — it stays under
"jan-tietjen › Junk" in the archive, and in "Spam-Prüfung", for good. MailKeeper's purpose makes
this matter: the archive is what stays; the server copy is often deleted after archiving.

TJ also wants a mail on a server to follow when he files it — or not: "Selbe Ablage auf Server",
"Andere Ablage auf Server", "Auf Server nicht ändern".

## Decision

1. **Placement = the archive's folder for a mail, per account.** Without one, a mail is filed
   where it was seen (its locations, as before). With one, the archive files it there for that
   account, whatever the server does. One placement per message and account; it applies to all of
   the mail's locations in that account.
2. **Journalled.** A `placed` event (account, identity, mailbox; no mailbox = back to where it was
   seen) in the account's journal; the index keeps `placements(message_id, account_id, mailbox,
   time)` (schema v14) as a projection, replayed after all `seen` events in time order like the
   user's other decisions. An older binary drops the unknown event on a rebuild (placements are
   lost there, nothing else).
3. **What follows the placement (the archive's view):** the sidebar's folders and counts, the
   reader's "Ablage", `in:`/`ordner:` and the folder scope, saved searches with a folder.
   **What stays with the facts (the server):** "Ort" (on a server / only in the archive), where a
   sync finds the mail, server actions (delete, restore, rescue, "Ist Spam" choose server
   locations), sent/drafts/trash detection, the screening, `is:war-im-spam`.
4. **The spam folder:** `is:junk` (lies in a spam folder now) follows the server for mail on a
   server — a mail in the server's Junk stays in "Spam-Prüfung" until it leaves it there; for an
   import (no server) it follows the placement: filed out of "Junk", it is out. Filed into a
   folder with a spam name, it is in.
5. **The server, if the mail lies on one (6.9b):** the sheet asks — the same folder on the server
   (only if it exists: MailKeeper creates no folders), another folder on the server, or no change
   on the server. Moves go through their own narrow IMAP access (`.moveToFolder`): out of any
   mailbox but trash, sent and drafts, into a mailbox that `RemoteMailbox.mayTakeRescued` admits
   (INBOX or an ordinary folder; never spam, trash, sent, drafts, All Mail, Starred, Important);
   exactly the named UIDs, checked before and after like every server action (ADR-0006). Into the
   spam folder is "Ist Spam" (§9), out of it the server's filter learns "ham" (§8). Gmail is
   label-based: a folder move there is not a move — server changes on Gmail wait; the archive's
   placement works.

## Consequences

- A mail can be filed differently in the archive and on the server; the reader shows the server
  place under "Ort" and the archive's under "Ablage" — the difference is visible, not hidden.
- Folder queries look at two tables; the sidebar counts a union. Indexes keep it fast.
- New folders exist in the archive only until a server has them — MailKeeper never creates
  server folders.
