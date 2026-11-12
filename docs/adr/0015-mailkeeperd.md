# ADR-0015: mailkeeperd — the server that fetches mailboxes into one archive per person

- Status: accepted (TJ, 2026-11-12)
- Deciders: TJ

## Context

mailkeeper-server archives the mailboxes of a family on a homelab Kubernetes cluster, one
archive per person, and later hands attachments to Paperless (Phase 2+). The core builds on
Linux (ADR-0014). Phase 1 needs the part that runs there: fetch, and nothing else. The app sets
the server up later (Phase 5); until then the deployment's configuration does.

## Decision

1. **`mailkeeperd`** is a command line program around a library, **MailKeeperServer**: a loop over
   people and their accounts with `SyncCoordinator.sync` — the same read-only connections as
   the app (ADR-0002), the same archive format (ADR-0001). One run, then a pause
   (`intervalSeconds`); people and accounts one after the other.
2. **Configuration is one JSON file**, written where the server is deployed, never by the
   server: people (id, archive folder) and their accounts. Accounts are declared and reconciled
   with the archive's `accounts.json`: a declared account is stored as declared (keeping its
   creation date), an account dropped from the configuration is no longer fetched but stays in
   the archive with its history. `mailkeeperd --check-config` refuses mistakes before anything
   runs (duplicate ids, archives inside each other, a pin with TLS).
3. **Secrets are files** (`FileSecretBackend`, in the core): a mounted Kubernetes secret, one file
   per account, named after the account's key (`mailkeeperd --secret-names`). Read-only; a missing
   folder is an error, never "no password". Setting secrets from the app needs an encrypted store
   of the server's own — Phase 5.
4. **A bridge certificate is confirmed, not trusted on first use.** A Proton Bridge account
   without a `fingerprint` in the configuration is not fetched; mailkeeperd logs the fingerprint
   it saw, so whoever deploys can compare it and put it in.
5. **Status file** after every account: last attempt, last success, new messages, the error — no
   mail content. A run with an error keeps the last success, so a stale one is what to alert on.
6. **SIGTERM ends it at once.** Every write to an archive is complete or absent (ADR-0001), as with
   Ctrl-C for `mkctl sync`; as PID 1 it installs the handler itself.
7. **Image:** `packaging/server/Dockerfile` — static Swift runtime, stripped, on Ubuntu noble with
   libsqlite3, libcurl and CA certificates; `mkctl` comes along for maintenance. Built by CI on
   Gitea only, from main. **Deployment manifests are not in this repository**: they name people
   and addresses, and this repository is public. They live where the server is deployed.

## Consequences

- Phase 1 needs no port, no API and no Ziti: the server only connects out, to mail servers and to
  a bridge on loopback.
- Exactly the pinned versions on Linux (`--force-resolved-versions`): its manifest lacks Sparkle,
  and SwiftPM would otherwise resolve anew and rewrite `Package.resolved`.
- The texts of the core speak of the keychain; mailkeeperd names the missing secret file instead.
