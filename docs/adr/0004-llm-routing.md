# ADR-0004: LLM routing and data classes

- Status: accepted (TJ, 2026-10-10)
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

*As built (5.1, 2026-10-11):* module `MailKeeperAI` (Kit stays model-free). Settings per archive
in `ai.json` (endpoint, model alias per task, on-device fallback on/off, timeout), the API key in
the keychain. The router tries the endpoint first; when it is not set up, unreachable, 502–504 or
silent past the timeout, it pauses it for a minute and asks the on-device model (if allowed);
wrong answers (4xx, bad JSON, truncated) are errors, never hidden by the fallback. Connection
errors and 429/502/503 get one retry; a timeout never (the gateway keeps generating). On-device
means `SystemLanguageModel` only — never Private Cloud Compute. HTTP only for localhost and
`.ziti` (ATS); non-local endpoints get a warning. `~/Library/Logs/MailKeeper/ai.jsonl` logs
task, path, model, seconds, tokens, finish reason, attempt and outcome — no prompt, no answer.

*As built (5.4):* nine categories (S3). The rules run in the background for every message
(headers in the index only, no message is read; 43k in seconds) and settle newsletters,
notifications, and invoices/orders/travel with clear signs; personal, work, account and spam are
never decided by a rule (a rule calling a phishing mail "Konto/Sicherheit" would lend it
credibility). A model asks only on request (selection, the list's open ones), fenced, strict
schema, and is stored with its path, model and a one-line reason ("Warum?" in the reader). Rule
results are recomputed when the rules change; a model's answer is never overwritten by them.
Categories are labels only — no action follows from them.

## Consequences

- Backfills over 100k mails cannot be LLM-bound; throughput comes from steps 1–2.
- Without the homelab endpoint MailKeeper still works (on-device + heuristics), with lower
  quality — the UI must say which path produced a suggestion.
