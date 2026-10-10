# ADR-0004: LLM routing and data classes

- Status: proposed (2026-10-10, informed by spike S3)
- Deciders: TJ

## Context

Mail content is `personal` and untrusted (`external_content`). TJ decided (2026-10-10): local
models only — an OpenAI-compatible endpoint (homelab LiteLLM) plus Apple Foundation Models
on-device; no cloud provider. Spike S3 (37 synthetic mails): LiteLLM `llm-fast` 34/34 correct,
0 injections followed, ~5 s/mail; on-device 30–31/34, 1–2 injections followed, ~1.3–1.8 s/mail,
and occasional requests that hang indefinitely.

## Decision

1. Pipeline per mail: deterministic heuristics (List-Id, List-Unsubscribe, Precedence,
   Auto-Submitted, sender profile) → kNN against the user's labelled examples → LLM only for
   what remains ambiguous.
2. Quality path: OpenAI-compatible endpoint. Fast/offline path: Foundation Models, always
   behind a hard timeout that does not rely on cancellation.
3. Prompt hygiene: per-request random fence around mail content, schema-constrained output,
   no tools with side effects, mail instructions treated as a warning signal.
4. A model signal may only tighten (flag, ask, suggest); it never executes or approves a
   destructive action. Rules derived from suggestions are deterministic and user-accepted.
5. Every LLM call is logged with task, provider/model, seconds, tokens, finish reason, attempt.

## Consequences

- Backfills over 100k mails cannot be LLM-bound; throughput comes from steps 1–2.
- Without the homelab endpoint MailKeeper still works (on-device + heuristics), with lower
  quality — the UI must say which path produced a suggestion.
