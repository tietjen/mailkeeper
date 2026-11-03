# MailKeeper

A macOS app that pulls mail from several accounts (Gmail, any IMAPS server, Proton Mail via
Proton Mail Bridge) into a local, searchable archive — search, filter, delete, restore — with
local-first LLM assistance that learns per macOS user.

**Documentation (German):** [handbook](docs/handbuch/) · [function reference](docs/funktionen.md)
· [how it is built](docs/architektur.md) · [architecture decisions](docs/adr/)

Principles: archive first, server second · plan → execute → verify for every bulk action ·
the model suggests, the user decides · mail content is untrusted data · the archive stays
readable without the app (raw `.eml` + SQLite index).

## Development

Requirements: macOS 26+, Xcode 26+ (Swift 6). No external dependencies in the core.

```bash
swift test                                   # MailKeeperKit tests (synthetic data only)
swift build -c release --product mkctl       # command line tool
Scripts/build-app.sh                         # signed, sandboxed build/MailKeeper.app
Scripts/build-app.sh --dev                   # unsandboxed "MailKeeper Dev" for development
```

`mkctl` works on the same archive format as the app:

```bash
mkctl --archive ~/MailKeeperArchive import maildir ~/MailArchive --account parasec
mkctl --archive ~/MailKeeperArchive import mbox ~/Takeout/Mail/All\ mail.mbox --account gmail
mkctl --archive ~/MailKeeperArchive search rechnung müller
mkctl --archive ~/MailKeeperArchive verify
```

The dev app opens an archive given by environment: `open --env MAILKEEPER_ARCHIVE=/path "build/MailKeeper Dev.app"`.
The sandboxed app uses its container by default; choose another archive folder via *Ablage › Archiv wählen …*.

## Layout

| Path | Content |
|---|---|
| `Sources/MailKeeperKit` | archive (blobs, journal, lock), MIME parser, SQLite index + FTS5, importers |
| `Sources/mkctl` | CLI |
| `Sources/MailKeeperGUI` | SwiftUI app; message list as NSTableView; locked-down HTML reader |
| `Spikes/` | Phase 0 experiments (independent packages, not built with the app) |
| `docs/adr/` | architecture decisions · `docs/spikes/` measurements |

## Licence

The source is public so that anyone can check what MailKeeper does with their
mail. It is licensed under the [PolyForm Noncommercial License 1.0.0](LICENSE):
free for private and other noncommercial use — including changing it and passing
it on — while commercial use needs a separate licence. That makes it
source-available, not open source.

[TERMS.md](TERMS.md) (German, with an English translation) explains what counts as
noncommercial and covers the app downloads and updates: privacy, liability, support.
The app carries the licences of its third-party components in
`Contents/Resources/ThirdPartyNotices.txt`.
