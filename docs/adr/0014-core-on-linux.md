# ADR-0014: The shared core also builds on Linux

- Status: accepted (TJ, 2026-11-10)
- Deciders: TJ

## Context

A server is to archive the mailboxes of several people on the homelab's Kubernetes cluster and
hand their attachments to Paperless (project mailkeeper-server). MailKeeper sets it up. App and
server must evaluate the same query language (ADR-0008) and write the same archive format
(ADR-0001) — a second implementation would drift. So the server shares MailKeeper's code, and
that code has to build on Linux.

Until now the core used Apple frameworks in about a dozen places: CryptoKit, SQLite3 as a system
module, Security (keychain), DiskArbitration, Accelerate, UniformTypeIdentifiers and quarantine,
the `@objc` XPC protocol, FoundationModels, `URLSession.bytes(for:)`, `String(localized:)`, and a
few BSD calls (`readpassphrase`, `renamex_np`, `sin_len`).

## Decision

1. **Shared on both:** MailKeeperKit, MailKeeperIMAP, MailKeeperAI and mkctl. macOS only: the
   app, the PDF service (with MailKeeperPDF) and Sparkle — `Package.swift` adds them under
   `#if os(macOS)`.
2. **Same code, platform seams small and named.** `#if canImport(…)` around the Apple part,
   the Linux part next to it. No second implementation of anything the archive or the query
   language depends on.
3. **Stand-ins on Linux:**
   - SHA-256 from **swift-crypto** (same API). Declared for both so the pin is shared, linked
     only on Linux — on macOS the core stays free of outside code.
   - **System SQLite** through a `CSQLite` system library target (`libsqlite3-dev`). The index
     needs FTS5 and `contentless_delete` (3.43+); `Database` refuses an older SQLite when it
     opens instead of failing halfway through a migration. Ubuntu noble has 3.45.
   - **Charsets** stay with CoreFoundation's IANA lookup, which Linux has too — only the
     `as CFString` bridge is Apple's, so the name goes through `CFStringCreateWithCString`.
     Both platforms answer the same.
   - **Secrets** go through `SecretBackend`. macOS: the keychain, unchanged. Linux has no store
     by default: asking for a secret — or whether one exists — throws `noSecretStore` instead of
     answering "none". `exists` may throw for any backend: "unknown" must not read as "absent",
     or a revoke of a good Google grant would follow (7.1 B1). The server brings its own store
     (mailkeeper-server, Phase 1).
   - **Vector math:** plain loops beside the Accelerate calls; a test holds them against
     Accelerate on macOS.
   - **Attachment types:** a MIME table with macOS's own answers, and the extension and MIME
     lists hold what UTType calls risky; two tests on macOS compare both with UTType. No
     quarantine on Linux; "never overwrite" is `link` + `unlink` (fails closed on file systems
     without hard links).
   - **KI requests:** a data task with its own delegate counts each chunk and cancels past the
     limit, as `bytes(for:)` does on macOS (review 5.9 C4). A declared length past the limit
     cancels the task itself — the `.cancel` disposition does not stop the transfer in
     swift-corelibs-foundation. The Apple model reports "nicht verfügbar".
   - **Texts:** Linux has no `String(localized:)`; a stand-in returns the source text (German).
4. **CI keeps it that way.** `ci.yml` has a `linux` job (`swift:6.4-noble`): build and all
   tests of Kit, IMAP and AI. It runs on Gitea's Linux runner (x86_64, like the cluster) and on
   the GitHub mirror. A macOS-only API in the core turns it red.

## Consequences

- A change to the core has to build on both. `#if canImport` is the tool; whatever is
  Apple-only belongs in the app or behind a seam like `SecretBackend`.
- On Linux, tests skip what only macOS has (keychain, quarantine, the Apple model) and, because
  CI containers run as root, the part of a test that relies on a read-only file.
- **URLSession delegates on Linux see only the completion-handler forms.** An `async` delegate
  method compiles, satisfies nothing, and the default applies — the one-click unsubscribe
  followed redirects that way (review B2). Use the completion-handler form; on macOS it is the
  same method. Loopback tests (a real server, not a URLProtocol stub) cover redirects and
  declared lengths.
- mkctl on Linux takes passwords only with `--password-stdin` (no `readpassphrase`); `stdout`
  needs `@preconcurrency import Glibc` before Foundation.
- The batch similarity search (`nearestBatch`) runs as plain loops on Linux. Fast enough for a
  test-sized archive; a server that classifies tens of thousands of mails at once would need
  BLAS (OpenBLAS) — decided when the server does that.
