# ADR-0017: mailkeeper-mcp — the archive as an MCP connector

- Status: accepted (TJ, 2026-11-15: "Starte Phase 3 mail-mcp"; Swift sidecar; a web view of a
  mail comes later, before Phase 4)
- Deciders: TJ

## Context

The homelab's mail tools (`mail_thread`, `mail_attachments`, `summarize_correspondence`) live in
paperless-mcp and work on the `.eml` documents Paperless' mail rules import. The plan
mailkeeper-server (decision 3) moves them to the archive: per person, also in Kastelain, so that
Paperless can drop the mails and keep only the attachments. The connector must meet the homelab's
MCP connector standard v2.2 at level `v2-read`: the result envelope in `structuredContent`, a data
class, declared limits, machine-readable refusals that tell "nothing found" from "not yours", no
side effects on reads, and identity per path — a broker-signed assertion from Kastelain, a direct
path for TJ's own devices.

The archive's search language (ADR-0008), its conversations, its MIME parser and the summariser
with its fences against instructions in mail (ADR-0004, Phase 5.8) exist only in Swift. A Python
connector would either rebuild them (decision 1 of the plan: rebuilds drift apart) or talk to a
read API in front of them — two moving parts instead of one.

## Decision

1. **A third executable, `mailkeeper-mcp`, from this repository,** on a library target
   `MailKeeperMCP` (MailKeeperKit + MailKeeperAI + NIO). It runs as a sidecar next to
   `mailkeeperd`, from the same image, and **only reads**: the index is opened read-only, without
   migrating (a schema it does not know is refused until `mailkeeperd` has migrated), blobs are
   read, the archive lock is never taken. Nothing it does changes the archive or a mail server
   (§14.7).
2. **Transport:** MCP over streamable HTTP, stateless, answers as `application/json` (no SSE), on
   `127.0.0.1` only — reachable through a Ziti sidecar, never through a ClusterIP (a ClusterIP
   bypasses the dial policy). Methods: `initialize`, `notifications/initialized`, `ping`,
   `tools/list`, `tools/call`; anything else is a JSON-RPC error. The `Host` header must be one
   of the configured names (DNS rebinding); bodies above 1 MiB are refused. A second listener on
   the pod address answers `GET /healthz` (the kubelet cannot reach loopback): 200 when the MCP
   listener is up and every configured archive opens.
3. **Identity per path, fail-closed:**
   - **Broker (Kastelain):** `params._meta.kastelain.assertion` = `{kid, alg: "EdDSA", body,
     sig}`. Checked in this order: complete and EdDSA; key by `kid` from the gateway's JWKS
     (refetched on an unknown `kid` at most every 30 s, replaced as a whole); Ed25519 over the
     canonical JSON of `body` (sorted keys, no whitespace, NFC, raw UTF-8 — byte-equal to
     `kastelain.audit.canonical_json`); not expired (5 s leeway); lifetime at most 5 minutes;
     `audience` = the register id (`mail`); a nonce not seen before (kept until expiry, bounded
     store, refused when full). `user` (the LLDAP name) maps to a person through the
     configuration; no mapping → `unknown_user`.
   - **Direct (TJ's devices):** `Authorization: Bearer <direct token>`, compared in constant
     time, acts as one configured person. An assertion, when present, wins.
   - Neither → refused. "No assertion" never means a default person. An empty or short token is
     refused at start, as is a configuration that maps a user to a person without an archive.
   - **A person reads only their own archive** — the admin is no exception (plan: setting up is
     not reading). Ids are archive identities; one from another archive is `not_found`, worded
     "does not exist or is not visible to this user" (§14.5).
   - Honest limit: the process can read every archive on the volume; the mapping in the
     connector is the access control, as root on the volume sees everything anyway (plan).
4. **Tools** — all `risk: read_only`, `data_class: personal` (ceiling and per result, like
   paperless-mcp, which holds the same mails), `confirmation: none`, `audit: metadata`,
   `output_trust: external`; MCP annotations `readOnlyHint`, `idempotentHint`, not destructive,
   closed world:

   | Tool | Input | Card | Limits |
   |---|---|---|---|
   | `search` | `query` (ADR-0008, lenient like the search field), `date_from`/`date_to` (day in the configured zone), `person` (address or name: sender or recipient), `type` (`received`, `sent`, `attachment`), `limit`, `offset` | `result-list` | `limit` ≤ 50, `offset` ≤ 10 000, `query` ≤ 500 characters |
   | `fetch` | `id`, `max_tokens`, `query` (comma keywords: best paragraphs in order) | `document` | `max_tokens` 200–20 000, about 4 characters per token |
   | `list_persons` | `date_from`/`date_to`, `limit` | `table` | `limit` ≤ 200 |
   | `mail_thread` | `id` or `query`, `max_mails` | `result-list` | `max_mails` ≤ 100 |
   | `mail_attachments` | `id` | `table` | — |
   | `summarize_correspondence` | `person`, `date_from`/`date_to`, `focus`, `max_threads` | `document` | `max_threads` ≤ 10, 25 newest mails per conversation, 3 conversations at a time, 180 s per call |

   Every item carries the minimum metadata (v1 §4): `id` (the archive identity — stable across
   index rebuilds, unlike row ids), `title` (subject), `date`, `type`, `person`, `deep_link`
   (`mid:` URL, RFC 2392, as in the Paperless ledger of ADR-0016). Trashed messages never appear.
   `search` returns briefs, never full text. The three tools paperless-mcp has keep their names,
   so prompts and habits carry over.
5. **Envelope and refusals (v2.2 §10.3, §14.5):** `content: [{type: text}]` plus
   `structuredContent: {text, card?, data_class, served_from: "source", as_of, stale: false}`,
   the text byte-equal in both. A refusal is a tool result with `isError: true`,
   `structuredContent.error {code, message, hint?, limit?, got?}` and the text `[code] message`
   — never a JSON-RPC error; codes as in the house (`missing_assertion`, `bad_signature`,
   `expired`, `wrong_audience`, `replay`, `unknown_user`, `not_found`, `invalid`,
   `limit_exceeded`, `source_unreachable`, `ai_unavailable` …). A broken limit is refused, never
   answered in part.
6. **`summarize_correspondence`** reads the person's conversations with a correspondent in the
   time range and summarises each with `MailSummarizer` (fenced mail, instructions to an AI
   removed, no to-dos from a mail that looks like a scam), **through LiteLLM only** — no
   on-device model on a server, and no silent fallback when the endpoint is gone (ADR-0004):
   then the tool refuses with `ai_unavailable`. The summary is model output from external content
   and stays tainted (`output_trust: external`).
7. **Logging:** one line per call, `mcp: <tool> path=<broker|direct> user=<u> run=<id>
   session=<id> ms=<n> result=<ok|code>`, values outside `[A-Za-z0-9._:@-]{1,80}` dropped (forged
   log lines); refusals too. No subjects, addresses or text in the log.
8. **Configuration:** a section `mcp` in the server configuration (ADR-0015) — the same
   ConfigMap, so people and archives are named once. `mailkeeperd` validates it and ignores it;
   `mailkeeper-mcp` reads the people, their archives and its section: listen and health
   addresses, allowed hosts, audience, JWKS URL, user → person map, direct token file and person,
   time zone, LiteLLM URL, model and key file.

## Consequences

- A third implementation of the assertion check (Go in wiki-mcp, Python in paperless-mcp, Swift
  here). They are held together by the shared fixture from tj/kastelain, which the tests here
  read as they do there.
- The MCP protocol subset is built by hand on NIO — there is no Swift server SDK for streamable
  HTTP we would want to depend on. It is tested end to end over real HTTP, and against Claude
  Code and Kastelain's broker before it is registered.
- The volume is mounted writable in the sidecar too: a reader of a WAL index must be able to
  create the `-shm` file, which SQLite removes when the last connection closes — and
  `mailkeeperd` closes its index between runs. The index itself is opened with
  `SQLITE_OPEN_READONLY`, never migrated, and nothing else is written; the protection is the code,
  not the mount.
- `mail_attachments` lists what the mail carries (name, type, size, SHA-256, inline, risky). Which
  Paperless document holds it comes with Phase 4, when `mailkeeperd` keeps the ids Paperless
  returns; until then the SHA-256 is the bridge (Paperless stores it as `checksum`).
- The clickable target for a link from Paperless is a web view of a mail with a login (Keycloak).
  It comes as its own step before Phase 4; until then `deep_link` is the Message-ID.
- Moving the Rechnungs-Abgleich (direct sends to DATEV from the archive's sent mail) and the tag
  healing to the archive is the second part of Phase 3, after this connector runs.
