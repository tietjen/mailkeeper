# ADR-0008: One query language for the search field, saved searches and the AI

- Status: proposed (2026-10-10)
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
sender:billing@amazon.de            exact sender address
domain:amazon.de  listid:news.x.de  exact sender domain (no subdomains), exact List-Id
filename:vertrag  has:attachment|pdf|image|calendar
larger:5M  smaller:100K             size (K/M/G = 1024)
after:2024-03  before:2025  until:2024-12-31  date:2024-05   calendar periods, local time
after:30d  before:1y                relative (d, w, m, y)
account:gmail  folder:INBOX  folder:Archiv/*  label:Steuer  list:newsletter   (List-Id contains)
is:unread|read|flagged|answered|list   on:server  only:archive   msgid:<id@host>
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

## Consequences

- One parser to test exhaustively; the UI shows the parsed terms as chips and errors inline.
- The model in Phase 5 only has to emit this language; invalid output fails closed.
- New fields (e.g. `thread:` in Phase 3.4) are additive; existing saved searches keep their
  meaning.
