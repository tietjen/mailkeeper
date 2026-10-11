# ADR-0008: One query language for the search field, saved searches and the AI

- Status: accepted (TJ, 2026-10-10)
- Deciders: TJ

## Context

Phase 3 brings filters beyond plain text: sender, dates, size, attachments, folders, flags.
Phase 5 lets a local model turn everyday language into a filter ("Rechnungen von Amazon 2024
mit PDF"), and Phase 4 runs destructive actions on filter results. The filter therefore needs
a textual form that people can read and edit, that the model can produce, and whose meaning
is fixed and testable.

## Decision

A small Gmail-like query language, parsed in MailKeeperKit (`QueryParser`) into a typed tree
and compiled to SQL plus FTS5 (`QuerySQL`). The search field, saved searches, `mkctl search`
and later the model all use it; the model's output is shown as query text before it runs.

```
rechnung "jahres abrechnung"        words and phrases, all of them (AND)
from:amazon  to:  subject:  body:   words in that field (name and address for from/to)
sender:billing@amazon.de            exact sender address; sender:@amazon.de = the whole domain
domain:amazon.de  listid:news.x.de  exact sender domain (no subdomains), exact List-Id
filename:vertrag  has:attachment|pdf|image|calendar
larger:5M  smaller:100K             size (K/M/G = 1024)
after:2024-03  before:2025  until:2024-12-31  date:2024-05   calendar periods, local time
after:30d  before:1y                relative (d, w, m, y)
account:gmail  folder:INBOX  folder:Archiv/*  label:Steuer  list:newsletter   (List-Id contains)
is:unread|read|flagged|answered|list|sent   on:server  only:archive   msgid:<id@host>
thread:<id@host>                    the conversation containing that message (3.4, additive)
pdf:kündigung                       only the text of PDF attachments; plain words also match it (3.5, ADR-0009)
-word  -from:x                      negation
a OR b   ( … )                      alternatives and grouping; AND binds tighter than OR
```

- **Periods:** `after:` includes the start of the period, `before:` excludes it, `until:`
  includes its end, `date:` is the period itself. German aliases follow the same rule
  (`ab:` = after, `vor:` = before, `bis:` = until, `datum:` = date; also `von:`, `an:`,
  `betreff:`, `konto:`, `ordner:`, `größer:`, `kleiner:`, `ist:`, `hat:`).
- **Strict values, lenient words:** an unknown word before a colon (`https://…`, `re:`) is
  plain text, but a known field with an invalid value (`larger:abc`, `before:13.13.2024`) is
  an error and the query does not run. A typo must never widen a result that a destructive
  action might act on.
- **Prefix:** the last bare word matches as prefix unless the text ends with a space (live
  search); `word*` asks for a prefix anywhere. Same text, same result, wherever it runs.
- **Safety:** every user value is an SQL parameter; FTS terms are quoted and stripped of
  quotes; LIKE patterns are escaped. Input is limited to 4096 characters, 64 terms and a
  nesting depth of 16.
- **Exact fields for drill-downs:** `sender:`, `domain:` and `listid:` match exactly, so a
  group in the cleanup view and the list it opens contain the same messages — the basis for
  bulk actions in Phase 4.
- Location predicates (`account:`, `folder:`, `label:`, flags, `on:server`) are evaluated
  per predicate ("some location matches"), not jointly on the same location.
- `on:server` means a location fetched over IMAP (it has a UID) that was present at the last
  fetch; imported mail (Maildir, mbox, .eml) is `only:archive` — MailKeeper knows no server
  location for it, and Phase 4 may only act on locations it knows (found with TJ's import).

*As built (5.3, 2026-10-11):* `QueryTranslator` gives the model this table, today's date and the
archive's account and folder names, and asks for `{query, explanation}` (strict schema). The
query must pass `QueryParser`; otherwise one retry with the parser's message, then an error —
an invalid query never runs. The app puts the query into the search field (editable), shows
the request, the explanation, the model and the time above the chips, with a way back. The
user's words are the user's own; mail content never enters this prompt.

## Consequences

- One parser to test exhaustively; the UI shows the parsed terms as chips and errors inline.
- The model in Phase 5 only has to emit this language; invalid output fails closed.
- New fields (e.g. `thread:` in Phase 3.4) are additive; existing saved searches keep their
  meaning.
