# ADR-0016: Attachments for Paperless — rules and a dry-run ledger

- Status: accepted (TJ, 2026-11-14: "Phase 2 starten")
- Deciders: TJ

## Context

mailkeeper-server is to replace Paperless' own mail rules: Paperless gets only the attachments,
one owner, tags and storage path per person, and no more `.eml` documents (plan
mailkeeper-server, decision 6). Before anything is uploaded, two weeks of dry run: decide what
would go, write it down, compare it with what Paperless' mail rules import today, and let TJ look
through what stays out. Paperless stores the SHA-256 of every original file as its checksum, so
the comparison can be exact without downloading anything.

## Decision

1. **A `paperless` section in the server configuration**, generic — names come from the
   deployment: `mode` (only `dryRun`; uploading is Phase 4, any other value is refused),
   `ledgerDirectory`, `rule` (a query, ADR-0008, e.g. `-is:list -is:junk`), `since` (a day,
   optional), `timeZone` (IANA name, required), `extensions` (lower case, without dot),
   `minBytes` and `maxMessageBytes` (default 64 MiB). Per person a `paperless` mapping: `owner`,
   `tags`, `storagePath`. A person without one is archived, not exported. Strict like the rest:
   an extension that is a program, macro document, web page or link file is refused, so no rule
   can ever hand those over; the section without any mapping, or a mapping without the section,
   is refused; the ledgers do not go into an archive.
2. **A rule takes field terms only.** The search field is lenient on purpose — an unknown
   `field:` is a word, punctuation alone is no condition — and for a rule that means a typo
   widens it: `-iss:junk` would exclude mails containing "iss junk" instead of the spam folder,
   `-` would match everything. So a rule with plain text (quoted or not), a lone `-`, nothing in
   it, or a term the server cannot answer (category, phishing, suspicion — no classification on
   the server; `pdf:` — no PDF text) is refused before anything runs (review S1). Dates go into
   `since`, which knows the time zone; in the rule they would run in the container's zone.
3. **After each person's fetch, under the archive's lock**, over what the archive holds now —
   also when an account failed, since what came in is complete (ADR-0001). Every message the
   index lists with attachments and the ledger has not decided, in the order the archive first
   saw them, so of two messages carrying the same file the earlier one counts. Trashed messages
   stay out; `since` goes by arrival (INTERNALDATE, as a mail server's SINCE), not by the
   sender's `Date:`. The message is read from its blob, its SHA-256 checked, then parsed with the
   same parser as everywhere.
4. **One decision per attachment, the first reason that applies:** `unreadable` (the part cannot
   be found again), `empty`, `inline` (an image the HTML shows — the reader's notion), `risky`
   (`AttachmentSafety`), `type` (extension not listed), `small` (below `minBytes`), `rule` (the
   message does not match), `duplicate` (the same bytes went before — Paperless would refuse them
   by checksum), else `upload`. The structural reasons come first, so `rule` and `duplicate` name
   exactly the files that would otherwise have gone — what the review has to look at.
5. **Problems are told apart** (review S2, S5): a copy that is there but cannot be read now
   (EIO, too many open files) ends the pass with an error — nothing is decided on an error of the
   moment, the next run carries on. A missing or damaged copy (checksum) is written down once and
   tried again every run, since a restore or repair may bring it back. A message above
   `maxMessageBytes` is not read — parsing holds it two or three times in memory, and one that
   kills the process would be tried again every run — and is decided as `tooLarge`; one whose MIME
   tree the parser does not follow to the end is decided as far as it was read (`truncated`).
6. **The ledger:** one JSON line per message in `<ledgerDirectory>/<person>-<fingerprint>.jsonl`
   (0600, created in one step, appended with O_APPEND, never through a symbolic link). The
   fingerprint covers what decides: rule, since, time zone, extensions, both sizes and the
   person's mapping — a changed setting starts a new ledger and decides every message again, the
   old one stays as it was (review S3). Each line: version, fingerprint, the message's identity,
   Message-ID, date, sender, subject, places, whether the rule matched and whether it was sent,
   a problem if any, and every attachment with sanitised name, type, size, SHA-256,
   `Content-Disposition`, decision and reason. For `upload` also the document Paperless would get:
   the file name without extension as title (not the subject every attachment of a mail shares),
   the mail's day in `timeZone` (Gregorian, never the locale's calendar) as created date, owner,
   tags and storage path of the person, the sender's address as correspondent (none for mail the
   person sent), and the mail as an RFC 2392 `mid:` URL. Appended in batches of 200 and flushed;
   a kill leaves at most an incomplete last line, which the next read cuts off, so that message is
   decided again. One line per message keeps "decided" atomic. Any other unreadable line, or one
   of another version, stops the export of that person; deleting the ledger decides everything
   again.
7. **Counts, not content, outside the ledger:** the log line and `exports` in the status file
   carry numbers per reason only, `running` while a pass is under way, and a `warning` while
   messages could not be read. The ledger holds subjects and file names — the same data as the
   archive, on the same volume.

## Consequences

- The first pass reads every message with attachments once (all of an existing archive unless
  `since` is set); later passes only what is new. A changed setting means one more first pass.
- A message is decided when it is first seen. A mail that lay in the spam folder then and is
  rescued later stays `rule`; one taken out of the archive trash, or brought in by an earlier
  `since`, is decided after younger ones. Fine for a dry run; for uploading (Phase 4) a rescue
  has to count.
- A copy that exists but can never be read (a bad block) stops every pass at the same message,
  and the messages after it are not decided — visible as the export's error in the status file.
  Writing it down as a problem after a few failures may come later.
- The ledger keeps every attachment's checksum and reason, so other thresholds or lists can be
  tried on it offline before the configuration changes.
- Paperless' mail rules with "attachments only" take just parts marked
  `Content-Disposition: attachment`; this export also takes named parts without disposition and
  Apple Mail's `inline; filename=…pdf` (everything but images the HTML shows). The comparison
  shows what that adds.
- The type is the extension, fail-closed through the list and checked for risk first; the
  content (magic bytes) is not looked at. For uploading (Phase 4) a `rechnung.pdf` that is no PDF
  should stay out. On Linux the risk table decides, on macOS UTType as well — the server's
  ledger is the one that counts.
- Paperless refuses duplicates across all owners. Once two people get the same file, the second
  upload fails and the document keeps the first owner — to settle before the family's accounts
  (mailkeeper-server, Phase 6).
- Uploading (Phase 4) needs its own record of what Paperless accepted; the dry-run ledger stays
  what it is, a record of decisions.
