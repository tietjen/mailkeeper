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
   the archive with its history. The configuration is strict: an unknown field, a field that does
   not apply to the account's kind (a host for a bridge) and every overlap are refused before
   anything runs — duplicate ids, archives inside each other (compared on path components, after
   symbolic links), the status file or the secrets inside an archive, one mailbox under two people,
   two accounts reading one secret file. `mailkeeperd --check-config` checks just that.
3. **Secrets are files** (`FileSecretBackend`, in the core): a mounted Kubernetes secret, one file
   per account, named after the account's key (`mailkeeperd --secret-names`). Read-only; a missing
   folder is an error, never "no password"; an empty file is no password, so no login is tried.
   Setting secrets from the app needs an encrypted store of the server's own — Phase 5.
   **A refused login backs off:** one interval, then twice as long each time, at most six hours,
   kept in the status file across restarts; a changed secret file ends the wait. A wrong or revoked
   password must not knock every interval (fail2ban on the own mail server bans the cluster's
   address for everything else too).
4. **A bridge certificate is confirmed, not trusted on first use.** A Proton Bridge account
   without a `fingerprint` in the configuration is not fetched; mailkeeperd reads the certificate
   after STARTTLS **without logging in** (`IMAPSession.certificateFingerprint`) and logs its
   fingerprint, so whoever deploys can compare it and put it in — 64 hex digits, colons and case
   do not matter; anything else, the empty string included, is refused.
5. **Status file** before and after every account: last attempt, last success, new messages, the
   error, whether a fetch is running, the login backoff — no mail content. A run with an error keeps
   the last success, so a stale one is what to alert on; accounts no longer configured leave the
   file. Written durably (fsync, fixed temporary name, rename). `--once` exits 1 if any account
   failed.
6. **SIGTERM ends it at once.** Every write to an archive is complete or absent (ADR-0001), as with
   Ctrl-C for `mkctl sync`; as PID 1 it installs the handler itself.
7. **Image:** `packaging/server/Dockerfile` — static Swift runtime, stripped, on Ubuntu noble with
   libsqlite3, libcurl and CA certificates; `mkctl` comes along for maintenance. Built by CI on
   Gitea only, from main. **Deployment manifests are not in this repository**: they name people
   and addresses, and this repository is public. They live where the server is deployed.

## Consequences

- **Known limit:** people and accounts run one after the other without an overall deadline per
  account — only the read timeout (120 s of silence) ends a stuck connection. A first fetch of a
  big mailbox holds up the others for hours; `running` in the status file shows who is busy. A
  deadline or parallel people come when the family is added (mailkeeper-server, Phase 6).
- Phase 1 needs no port, no API and no Ziti: the server only connects out, to mail servers and to
  a bridge on loopback.
- Exactly the pinned versions on Linux (`--force-resolved-versions`): its manifest lacks Sparkle,
  and SwiftPM would otherwise resolve anew and rewrite `Package.resolved`.
- The texts of the core speak of the keychain; mailkeeperd names the missing secret file instead.
