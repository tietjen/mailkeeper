# ADR-0009: Attachment text is extracted out of process, in a locked-down XPC service

- Status: proposed (2026-10-10)
- Deciders: TJ

## Context

Phase 3 makes PDF attachments searchable. The text comes from PDFKit, a large parser that
reads hostile input: anyone can mail a crafted PDF. Parsing it inside MailKeeper would give a
parser bug the app's rights — network access, the archive, the keychain entries — and a PDF
that hangs or balloons would freeze or kill the app. Extraction is also slow (tens to hundreds
of milliseconds per file) and must not block import, sync or the UI.

## Decision

- **Separate process.** PDF text is extracted by an XPC service bundled with the app
  (`Contents/XPCServices/de.paranoidsecurity.MailKeeper.PDFText.xpc`). Its only entitlement is
  the App Sandbox: no network, no user files, no keychain. It receives PDF bytes, returns text
  and a status — nothing else crosses the boundary. The service is sandboxed in the dev build
  too, where the app itself is not.
- **Scans included.** PDFKit recognises text on image-only pages by itself (TextRecognition,
  seen in a stack sample on macOS 27) — scanned letters become searchable at a few seconds per
  page. A time budget of 15 s per PDF, checked between pages, keeps the text found so far.
- **Watchdogs inside the service.** A timer outside the parsing thread ends the process when
  one PDF takes longer than 60 s (a hang, not a slow scan) or the footprint passes 1.5 GB;
  launchd starts a fresh one for the next request. Limits per PDF: 100 MB, 500 pages,
  512 K characters.
- **Fails safe.** Encrypted (non-empty password), image-only, oversized or crashing PDFs are
  recorded with their status and not retried until the extractor version changes. A failed PDF
  never blocks the queue.
- **Background queue in the index.** `attachment_text` records the status per message, the
  text goes into its own contentless FTS table. A background indexer works newest first,
  yields to import and sync (they cancel it, it resumes afterwards) and survives restarts. The
  text is derived from blobs, so an index rebuild simply queues the work again (ADR-0001).
- **Search.** Plain words match message or attachment text, each word on its own (so "telekom
  2024" finds a mail whose body says Telekom and whose PDF says 2024); `pdf:` searches only the
  attachment text (ADR-0008, additive).
- `mkctl` (outside the app bundle) does not extract; it reports the queue in `stats`.

## Consequences

- One more bundle to build and sign; the service is tested through the app, its extraction
  logic through unit tests with generated PDFs.
- Other document types (Office, images) can use the same service later.
