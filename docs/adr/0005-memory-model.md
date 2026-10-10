# ADR-0005: Per-user memory — typed, attributed, inspectable

- Status: proposed (2026-10-10)
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

## Consequences

- Memory never leaves the Mac except as prompt context to the configured local endpoint.
- Caps (e.g. max examples per subject/category, LRU) keep prompts and storage bounded.
- Shared Macs: each macOS user has separate memory automatically; there is no in-app profile
  switching.
