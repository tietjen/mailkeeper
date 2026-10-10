# ADR-0003: App Sandbox, ATS and keychain

- Status: proposed (2026-10-10, after spike S4)
- Deciders: TJ

## Context

MailKeeper renders hostile content (mail HTML, attachments) and holds credentials for several
mail accounts — it should be confined. Distribution is Developer ID + notarisation + Sparkle
(not the App Store). Spike S4 verified a sandboxed build end to end.

## Decision

1. **App Sandbox on**, entitlements: `app-sandbox`, `network.client`,
   `files.user-selected.read-write`, `files.bookmarks.app-scope`, and for Sparkle
   `temporary-exception.mach-lookup.global-name` = `<bundle-id>-spks`, `<bundle-id>-spki`
   with `SUEnableInstallerLauncherService = YES`. No `network.server`, no home-folder
   exceptions.
2. **Archive location:** default inside the container; a user-chosen folder (external SSD,
   NAS) via an app-scoped security-scoped bookmark. Imports (Maildir, mbox, Takeout) via the
   open panel.
3. **ATS:** `NSAllowsLocalNetworking` plus an exception domain `ziti` (subdomains, insecure
   HTTP allowed — OpenZiti encrypts the transport). Every other LLM endpoint must be HTTPS.
   (Measured: `127.0.0.1`/`localhost` pass ATS even without keys; `http://*.ziti` fails with
   `-1022` without the exception.)
4. **Keychain:** the file-based login keychain, items created and owned by the app
   (service `de.paranoidsecurity.MailKeeper`, account = account id). The data protection
   keychain needs a provisioning profile (`-34018`) — not used. Never read items created by
   other programs: that raises an access prompt even with `kSecUseAuthenticationUIFail`.

## Consequences

- Credentials are entered in MailKeeper's account setup, not imported from other keychain
  items. Integration tests run unsandboxed (`swift test`) and may use the probe items.
- A non-sandboxed helper (e.g. a future `mkctl` CLI for headless sync on macmini01) cannot
  simply read the app container — macOS asks "access data from other apps". Shared data must
  live in a user-chosen archive root both can reach, or the CLI owns its own archive.
- Sparkle works sandboxed with the documented setup; re-sign Sparkle's parts inside-out with
  `--preserve-metadata=entitlements` for `Downloader.xpc`.
- A user with a plain-HTTP LLM endpoint on another host must put it behind HTTPS (or Ziti).
