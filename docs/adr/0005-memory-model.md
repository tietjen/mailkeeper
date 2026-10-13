# ADR-0005: Per-user memory — typed, attributed, inspectable

- Status: accepted (TJ, 2026-10-10)
- Deciders: TJ

## Context

MailKeeper's suggestions (categories, cleanups, rules, search) should improve from the user's
decisions. TJ decided: memory per macOS user account (the app container separates users).
Mail content is untrusted input (`external_content`); anything learned from it must not turn
into authority — time-shifted prompt injection is the threat (Standard v2 §5).

## Decision

1. **Store:** table `memory_items` in the user's index: `id, kind, scope, subject,
   content (JSON), provenance, source_message_ids, weight, created, updated, last_used,
   active`.
   - `kind`: `preference` (explicit statement), `example` (accepted / rejected / corrected
     suggestion with the features that mattered), `sender_profile` (per sender, domain or
     List-Id: category, importance, usual action), `vocabulary` (the user's terms, e.g.
     "Firma" = the Proton account).
   - `scope`: global or one account. `subject`: what the item is about (address, domain,
     List-Id, category).
2. **Provenance and trust:** `user` (typed in by the user) and `feedback` (the user's own
   decision on a suggestion) are trusted; `derived` (inferred from mail content, possibly by an
   LLM) is not. Derived items are labelled in the UI, never become rules on their own, and can
   only raise caution (flag, ask), never lower it.
3. **Use:** deterministic retrieval first (exact subject match on sender/domain/List-Id), then
   embedding similarity, capped by count and tokens. Retrieved items go into prompts as data
   inside the fence, as few-shot examples, and as priors for the heuristics.
4. **Explainability:** every suggestion stores the memory item ids it used
   (`suggestion_sources`); the UI's "Warum?" shows them, each with edit/delete.
5. **Learning loop:** accept/reject/correct writes an `example` (provenance `feedback`); a
   deterministic consolidation job merges duplicates, recomputes sender profiles and decays
   weights of unused items. An LLM may only phrase display text, not change items.
6. **User control:** memory view (filter, edit, delete), export/import JSON, reset per account
   or all.
7. **Measured, not assumed:** a gold set of labelled mails; consolidation or prompt changes
   must not reduce gold-set accuracy (regression check).

*As built (6.1, 2026-10-12):* schema v11 `memory_items` (+ `suggestion_sources` for 6.2). The
index stays a projection (ADR-0001): notes and terms the user writes are journalled as `memory`
events (id, kind, scope, subject, text; "forget" = the same id with `active: false`) and replayed
by time with the other archive events; examples are not stored twice — each journalled decision
(`classified`: "Art ändern", "Ist Spam", "Kein Spam") refreshes its example `ex:<identity>`
(sender, domain, list, subject, category/verdict), live and in a rebuild, so a rebuild reproduces
them and a new decision brings a forgotten example back. Sources are message identities, never
ids. Notes are bounded (500 characters, no control characters) and only notes and terms can be
written or imported; examples and derived items belong to their archive. "Art ändern" is the
user's category (journalled `classified` with a category): it keeps a "kein Spam" and ends a
"Spam". Settings › Gedächtnis: list by kind, write, edit, forget, export/import JSON, forget all;
`mkctl memory`.

*As built (6.2):* sender profiles are computed when asked (`ArchiveReader.senderProfile`), not
stored: other mails of the address, categories by rules / model / user, the user's verdicts, the
model's phishing flags, and the user's own sent mails to the address or its domain (recipients
from the index, sent = role/name/label as `is:sent`). `MemoryRetriever` picks per mail: notes by
scope (all accounts or the mail's) and subject (general, sender, domain, list; at most 8 /
1,500 characters), the profile, and up to four examples — same sender, same domain, then similar
content (cosine ≥ 0.80 against the examples' vectors, loaded alone; the mail itself never). In the
prompt the user's notes and MailKeeper's counts stand outside the fence, the examples (they carry
mail subjects) inside a fenced block under a trusted header; the instructions say a known sender
counts for authenticity only when the own server's check does not fail. Every model answer stores
what it was shown (`suggestion_sources`, notes/examples by id, the profile as
`profile:sender:…`) and stamps `last_used`; "Warum?" at the reader's category lists it (the
profile as of now), each memory item with "Vergessen". The user's terms go into the search
translation too. Live: a club mail with notes and examples → personal; a look-alike of a bank
with examples of the real one → phishing "ja" (wrong domain, dmarc=fail, link text).

*As built (6.5):* cleanup suggestions are deterministic (unread newsletters by sender — a mail
service gives every campaign its own List-Id —, old notifications, large old mails with a warning
that an archive delete is final after 30 days, confirmed spam), each counting what is still on a
server and what lies only in the archive, acted on only through the plan sheets. Rules are memory
items of kind `rule` (a query in the search language and an action), journalled; suggested from
repeated decisions — the same category for ≥ 3 mails of a sender, "Ist Spam" for ≥ 2, deleted on
the server ≥ 3 times (audit log shas → messages) — and never a rule until the user accepts it
(rejected suggestions stay inactive with `rejected`; a deleted rule may be suggested again). The
export carries notes, terms, rules and relations; the import takes them through the same checks
(a valid search, a domain in one relation only), never examples. A category rule labels its mails by itself (source
`user-rule`: over rules, similarity and models — a model may still flag phishing — under the
user's decision on a single mail; re-applied after a rebuild, undone when the rule goes); a rule
that deletes on the server after N days or moves into the spam folder never acts by itself — it
shows how many mails are ready and opens the plan sheet. Rule-labelled mail still goes through the
register's and the own server's check. Review 6 (second pass): forgetting a rule anywhere —
Settings › Regeln, Gedächtnis, "Warum?" — takes its labels with it; the rule's query is applied
in parentheses (an OR stays inside) and set-based, and a query the parser no longer takes stops
only its own rule.

*As built (6.6, 2026-10-13):* two gold sets, one runner (`MailKeeperAI/Gold.swift`). **In the
repo** (`Tests/MailKeeperAITests/Gold`): 27 fictional mails as `.eml` files and 32 cases in
`cases.json` — every category, phishing, spam without phishing, two prompt injections, and five
pairs of one mail without and with memory (examples, a note, a confirmed relation, a look-alike
in the register, the own server's dmarc=fail); the label is a list of acceptable categories (a
phishing mail may carry its disguise — the phishing flag is judged apart) and a phishing
expectation. Offline checks always run (well-formed, every address made up); the live run
(`MAILKEEPER_AI=1 MAILKEEPER_GOLD=1`) compares with `baseline.json` per model. Models do not
answer alike twice even at temperature 0 (two of 32 flipped between three identical runs), so
the category may lose two mails before a run counts as worse; phishing caught and false alarms
may not move. **In the user's archive**: labels from Settings › Messung (one mail per sender
domain, in turn from every bucket; MailKeeper's own category hidden while labelling) are stored
by identity in `gold.json` beside the archive — never journalled, never in the memory, so a run
with memory cannot see its own answer. A run measures "MailKeeper heute" (what the archive
shows, no model), the model without and with memory, and keeps each run in `gold-runs.jsonl`.
First findings on the repo set: llm-fast 29/32 (phishing 7/7, no false alarm); the Mac's model
24/32, phishing 3/7, and it followed both injections — hence `PromptInjection` (passages that
address an AI are removed before any model reads the mail and reported outside the fence;
strong signs make it at least "Verdacht"), example decisions outside the fence, and a sharper
`personal`; other prompt tweaks measured no gain and were dropped. Now llm-fast 30/32, the
Mac's model 25/32. Examples do not override a strong category (a monitoring report stays a
notification against three "→ work"): that is what rules (6.5b) are for. Review 6.6 (Fable): the
text is cleaned before it is scanned (a zero-width character inside "Ignoriere" slipped past and
came out readable), the display name, attachment names and List-Id are scanned too, the strong
patterns want the AI as the head of the phrase (no alarm on "KI-Experte", "System: Jira ·
Kategorie"), schema words alone are weak; runs are compared on the mails both have; an unreadable
`gold.json` is reported and never saved over; runs are appended with O_APPEND.

## Consequences

- Memory never leaves the Mac except as prompt context to the configured local endpoint.
- Caps (e.g. max examples per subject/category, LRU) keep prompts and storage bounded.
- Shared Macs: each macOS user has separate memory automatically; there is no in-app profile
  switching.
