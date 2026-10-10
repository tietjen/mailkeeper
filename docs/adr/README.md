# Architecture decisions

| ADR | Topic | Status |
|---|---|---|
| [0001](0001-archive-format.md) | Archive: raw .eml blobs, metadata journal, SQLite as projection | proposed |
| [0002](0002-imap-stack.md) | IMAP: swift-nio-imap on NIOPosix + NIOSSL | proposed |
| [0003](0003-sandbox-ats-keychain.md) | App Sandbox, ATS (`*.ziti` exception), file-based keychain | proposed |
| [0004](0004-llm-routing.md) | LLM routing: heuristics → kNN → LLM; local models only | proposed |
| [0005](0005-memory-model.md) | Per-user memory: typed, attributed, inspectable | proposed |
| [0006](0006-destructive-actions.md) | Destructive actions: plan → execute → verify, grace period | proposed |
| [0007](0007-message-list-nstableview.md) | Message list is an NSTableView | proposed |

Evidence for 0001–0004 and 0007: [spike results](../spikes/README.md).
