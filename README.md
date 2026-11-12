# MailKeeper

A macOS app that pulls mail from several accounts (Gmail, any IMAPS server, Proton Mail via
Proton Mail Bridge) into a local, searchable archive — search, filter, delete, restore — with
local-first LLM assistance that learns per macOS user.

**Documentation (German):** [handbook](docs/handbuch/) · [function reference](docs/funktionen.md)
· [how it is built](docs/architektur.md) · [architecture decisions](docs/adr/)

Principles: archive first, server second · plan → execute → verify for every bulk action ·
the model suggests, the user decides · mail content is untrusted data · the archive stays
readable without the app (raw `.eml` + SQLite index).

## Install

macOS 26 (Tahoe) or later. With [Homebrew](https://brew.sh):

```bash
brew install --cask tietjen/tap/mailkeeper
```

Or download the DMG from the [latest release](https://github.com/tietjen/mailkeeper/releases/latest)
and drag MailKeeper into *Applications*. The app is signed with a Developer ID and notarised by
Apple. It updates itself (Sparkle, EdDSA-signed) once you allow it to look for updates; it asks
on its second start. Uninstalling — `brew uninstall --cask mailkeeper` or moving the app to the
trash — leaves the archive in the app's container alone, on purpose: after a clean-up it is often
the only copy of the mail.

The first start sets up an archive and your mail accounts; the
[handbook](docs/handbuch/01-archiv-einrichten.md) walks through it.

## Development

Requirements: macOS 26+, Xcode 26+ (Swift 6). No external dependencies in the core on macOS.

```bash
swift test                                   # MailKeeperKit tests (synthetic data only)
swift build -c release --product mkctl       # command line tool
Scripts/build-app.sh                         # signed, sandboxed build/MailKeeper.app
Scripts/build-app.sh --dev                   # unsandboxed "MailKeeper Dev" for development
```

The shared core — MailKeeperKit, IMAP, AI and `mkctl` — also builds on Linux, for the server
([ADR-0014](docs/adr/0014-core-on-linux.md)). In the image CI uses (its own build folder,
so the macOS `.build` stays untouched):

```bash
docker run --rm -v "$PWD":/src -w /src swift:6.4-noble \
  bash -c 'apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && swift test --scratch-path /tmp/build --force-resolved-versions'
```

`mailkeeperd` is the server built on it: it fetches the configured mailboxes into one archive per
person, over and over, and only reads from mail servers ([ADR-0015](docs/adr/0015-mailkeeperd.md)).
Its image comes from `packaging/server/Dockerfile`:

```bash
docker build -f packaging/server/Dockerfile -t mailkeeperd .
docker run --rm -v ./config.json:/etc/mailkeeper/config.json:ro mailkeeperd --check-config
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
