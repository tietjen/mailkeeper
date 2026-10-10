# Phase 0 spikes — results (2026-10-10)

Machine: Mac (Apple silicon), macOS 27.0.1, Xcode 27.0, Swift 6.4, 120 Hz display.
All test data is synthetic. Raw results sit next to this file (`S1-*.json`, `S2-*.json`, `S3-*.json`).

## S1 — IMAP layer (`Spikes/S1-IMAP`)

`apple/swift-nio-imap` 0.4.0 on NIOPosix + NIOSSL, probed against three accounts with a
hard mailbox allowlist (Proton: only `Folders/MailKeeper-Test`, `Labels/MailKeeper-Label`).

| Check | mailcow (Dovecot) | Gmail | Proton Bridge 3.27 |
|---|---|---|---|
| TLS | implicit 993, full verification | implicit 993, full verification | STARTTLS on 127.0.0.1:1143, leaf pinned (TOFU) |
| LOGIN | ok | ok (app password, spaces stripped) | ok (Bridge-generated password) |
| Capabilities of note | UIDPLUS MOVE CONDSTORE QRESYNC SPECIAL-USE ESEARCH COMPRESS | UIDPLUS MOVE CONDSTORE (no QRESYNC) SPECIAL-USE X-GM-EXT-1 ESEARCH COMPRESS UTF8=ACCEPT | UIDPLUS MOVE IDLE only (no CONDSTORE/QRESYNC) |
| LIST special-use | Trash Archive Sent Drafts Junk | localised: `[Gmail]/Alle Nachrichten` (\All), `[Gmail]/Papierkorb` (\Trash), `[Gmail]/Entw&APw-rfe` (modified UTF-7) | Drafts Trash Archive Spam(\Junk) Starred(\Flagged) Sent All Mail(\All) |
| APPEND + APPENDUID | ok, ~70 ms | ok, 0.6–0.9 s | ok, **1.4–1.8 s per message** (encrypt + upload) |
| Round trip byte-identical | **5/5** | **5/5** | **0/5** — Bridge rebuilds headers (X-Pm-*, Date in UTC, adds Reply-To, References with internal id), transcodes ISO-8859-1 to UTF-8; Message-ID kept |
| INTERNALDATE from APPEND | honoured | honoured (returned in UTC) | **ignored** — Proton uses the `Date:` header |
| BODY.PEEK leaves \Seen alone | yes | yes | yes |
| Re-run idempotent (search by Message-ID) | yes | yes | yes |
| Labels | n/a | `STORE +X-GM-LABELS` ok; X-GM-LABELS omits the label of the selected mailbox | COPY into `Labels/x` adds, \Deleted+EXPUNGE there removes the label |
| Delete → restore → purge | MOVE to \Trash, re-APPEND, EXPUNGE from Trash: all ok | MOVE ok; **re-APPEND reuses the trashed message** (same X-GM-MSGID, pulled out of Trash) | not run (outside allowlist) |

Findings:
- **Network.framework cannot do STARTTLS** (no TLS upgrade of an existing connection), and
  Proton Bridge defaults to STARTTLS. Transport therefore is NIOPosix + NIOSSL (BoringSSL);
  pinning via `customVerificationCallback`. Bridge v3 keeps its certificate inside `vault.enc`,
  so pinning is trust-on-first-use (or an exported certificate).
- swift-nio-imap worked for everything exercised (LIST, SELECT with CONDSTORE, ENABLE QRESYNC,
  streaming FETCH, APPEND with date, UID MOVE/COPY/STORE/EXPUNGE, X-GM-LABELS store). Rough
  edges: some types have internal `rawValue`/`buffer` (UIDValidity, GmailLabel), README still
  says "not production ready". Usable behind our own thin client facade.
- **Archive integrity must be defined per provider.** The archive stores exactly what was
  fetched (hash of that). "Restored correctly" cannot mean "same bytes" for Proton; it means
  Message-ID present in the target plus equal decoded text.
- **Gmail dedupes APPEND by Message-ID across the whole account.** Restoring a message that
  still sits in Trash brings the same message back (same X-GM-MSGID, new UID in the target
  label) instead of creating a copy. Restore is therefore idempotent on Gmail; "restore" of a
  trashed message equals "untrash".
- Gmail: read labels from `\All` — X-GM-LABELS leaves out the label of the selected mailbox.
  Folder names are localised and modified-UTF-7 encoded; always resolve via SPECIAL-USE.
- Gmail app passwords are displayed as `abcd efgh ijkl mnop`; IMAP needs them without spaces.
  (A first login failure was a wrong address in the test setup, not the client.)

## S2 — message list with 200 000 rows (`Spikes/S2-LargeTable`)

Synthetic SQLite index (200k rows, generated in 0.2 s). Scripted interaction driven by a
display link; a late frame means the main thread was busy.

| Metric | NSTableView (view-based, page cache) | SwiftUI `Table`, lazy collection | SwiftUI `Table`, `[RowData]` |
|---|---|---|---|
| Model ready | 0.01 s | 0.01 s | 0.22 s |
| Smooth scroll, 40 px/frame | p95 8.35 ms, 1 late frame in 600 | ok for 60 frames | ok for 60 frames |
| Jump scroll (scrollbar drag) | ~20 ms/frame | ~130 ms/frame | ~125 ms/frame |
| Sort change | **0.08 s** | **137 s / 247 s** | **138 s** |
| Select all | 0.05 s | not reached | not reached |
| Memory (footprint) | 43–44 MB | 116 → 383 → 619 MB | 156 → 409 → 686 MB |

SwiftUI `Table` hosts one `NSHostingView` per row and diffs 200k identities on every data
change; sorting took minutes and memory grew with every scroll. Untested mitigation: forcing
a rebuild with `.id(version)` instead of diffing — would not fix jump scrolling or memory.

→ **Message list = NSTableView via NSViewRepresentable**, data from a SQLite page cache keyed
by an ordered id array (8 bytes/row). SwiftUI for everything else.

## S3 — classification (`Spikes/S3-Classify`)

37 synthetic mails (34 regular, 3 prompt-injection probes), 9 categories, per-request random
fence around the mail, schema-constrained output.

| Provider | Correct (34) | Injection followed (3) | Errors | p50 | p95 |
|---|---|---|---|---|---|
| Apple Foundation Models, general | 30 | 1 | 0 | 1.30 s | 1.65 s |
| Apple Foundation Models, `.contentTagging` | 31 (of 32 answered) | 2 | **2 hangs** | 1.83 s | 2.87 s |
| LiteLLM `llm-fast` (DGX Spark) | **34** | **0** | 0 | 4.94 s | 7.16 s |

Findings:
- **Foundation Models requests can hang indefinitely** (waiting on the inference daemon).
  A task-group timeout does not help when the child ignores cancellation; the spike races the
  request against a timer with an unstructured continuation.
- On-device misses were plausible but wrong in ways that matter: phishing → account_security,
  rail ticket → order_shipping, tax advisor → invoice. Reasons came back in English for
  `.contentTagging` despite German instructions.
- Injection: instructions in the mail steered on-device answers (fake "admin" fence break
  `</mail>` → invoice). The per-request fence plus "instructions in mail are a warning sign"
  made `llm-fast` label them spam instead.
- Throughput: ~5 s/mail on the shared DGX is fine for interactive single mails, far too slow
  for 100k-mail backfills → heuristics + kNN first, LLM only for the ambiguous rest.

→ Classification signals never drive destructive actions on their own; the on-device model
is a fast pre-sorter with a mandatory timeout, LiteLLM the quality path.

## S4 — App Sandbox, keychain, network/ATS, Sparkle (`Spikes/S4-Sandbox`)

A sandboxed probe app (Developer ID, hardened runtime; entitlements `app-sandbox`,
`network.client`, `files.user-selected.read-write`, `files.bookmarks.app-scope`, Sparkle's
mach-lookup exceptions `<bundle-id>-spks/-spki`; `SUEnableInstallerLauncherService`). Results
leave the sandbox through a local HTTP server's access log — a non-sandboxed process reading
the app container triggers a TCC "access data from other apps" prompt.

| Check | Result |
|---|---|
| Sandbox active, container path | yes, `~/Library/Containers/<bundle-id>/Data/Library/Application Support/…` |
| Reading `~/.config`, the repo, `~/Documents` | denied |
| SQLite 3.54.0 with FTS5 in the container | ok; `unicode61 remove_diacritics 2` folds ü→u but **not ß→ss** (`GRÜSSE`/`grusse` do not find „Grüße“) |
| Keychain, file-based (login keychain), own item | add/read/delete ok |
| Keychain, data protection (`kSecUseDataProtectionKeychain`) | **-34018** missing entitlement (needs a provisioning profile) |
| Keychain item created by another program (`security`) | **shows an access prompt** even with `kSecUseAuthenticationUIFail` — the app must own its items |
| IMAPS to mail.parasec.de:993, TCP to Bridge 127.0.0.1:1143 | ok (Network.framework; NIO needs the same `network.client`) |
| `https://` | ok |
| `http://litellm.rk1.ziti:4000` without ATS keys | blocked, `-1022` |
| … with `NSExceptionDomains { ziti: includeSubdomains, allowInsecureHTTP }` | HTTP 200 |
| `http://127.0.0.1`, `http://localhost` | allowed even without ATS keys |
| **Sparkle 2.10 update v1 → v2** from a local EdDSA-signed feed, custom user driver | **ok**: check → found → download → extract → install → relaunch; v2 runs sandboxed, signature valid, no quarantine xattr left |

Not covered: security-scoped bookmarks with a real folder pick (needs a user click) — first
real use is the archive-location picker in Phase 1.

Gotcha: a global `let version` is shadowed by `NSObject.version()` inside NSObject subclasses
(AppDelegate, user driver) — "static member 'version' cannot be used on instance".

## Still open

- Throughput on a large real mailbox (read-only), security-scoped bookmark round trip.
