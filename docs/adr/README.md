# Architecture decisions

| ADR | Topic | Status |
|---|---|---|
| [0001](0001-archive-format.md) | Archive: raw .eml blobs, metadata journal, SQLite as projection | accepted |
| [0002](0002-imap-stack.md) | IMAP: swift-nio-imap on NIOPosix + NIOSSL | accepted |
| [0003](0003-sandbox-ats-keychain.md) | App Sandbox, ATS (`*.ziti` exception), file-based keychain | accepted |
| [0004](0004-llm-routing.md) | LLM routing: heuristics → kNN → LLM; local models only | accepted |
| [0005](0005-memory-model.md) | Per-user memory: typed, attributed, inspectable | accepted |
| [0006](0006-destructive-actions.md) | Destructive actions: plan → execute → verify, grace period | accepted |
| [0007](0007-message-list-nstableview.md) | Message list is an NSTableView | accepted |
| [0008](0008-query-language.md) | One query language for search field, saved searches and AI | accepted |
| [0009](0009-attachment-text-out-of-process.md) | PDF text extracted out of process, in a sandboxed XPC service | accepted |
| [0010](0010-spam-phishing-signals.md) | Spam and phishing: separate signals, the user decides | accepted |
| [0011](0011-archive-placement.md) | The archive's own placement of a mail (Ablage) | accepted |
| [0012](0012-gmail-oauth.md) | Gmail sign-in with Google (OAuth, PKCE, loopback) | accepted |
| [0013](0013-distribution-und-lizenz.md) | Vertrieb und Lizenz: quelloffen lesbar, Verwertung beim Autor | accepted (PolyForm NC) |
| [0014](0014-core-on-linux.md) | The shared core also builds on Linux (server) | accepted |

Evidence for 0001–0004 and 0007: [spike results](../spikes/README.md).

Für Leserinnen und Leser, die wissen wollen *wie* statt *warum*:
[Wie MailKeeper gebaut ist](../architektur.md).
