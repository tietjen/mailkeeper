# ADR-0002: IMAP stack — swift-nio-imap on NIOPosix + NIOSSL

- Status: proposed (2026-10-10, after spike S1)
- Deciders: TJ

## Context

MailKeeper needs IMAP for mailcow/generic servers, Gmail (X-GM-EXT-1) and Proton Mail Bridge.
Apple ships no IMAP framework. Requirements: streaming FETCH of full messages, APPEND with
date and flags, UIDPLUS, MOVE, CONDSTORE/QRESYNC where offered, SPECIAL-USE, Gmail labels,
STARTTLS (Proton Bridge default) and certificate pinning for the Bridge's self-signed cert.

## Decision

Use `apple/swift-nio-imap` (pinned exact version) for parsing/encoding, on NIOPosix with
NIOSSL for TLS. Wrap it in our own `IMAPConnection` facade (command → result, streaming fetch
into a sink) so the library stays replaceable.

## Consequences

- Dependencies: swift-nio, swift-nio-ssl (BoringSSL), swift-nio-imap, swift-collections.
  Deviation from the "no external dependencies" convention — justified, IMAP parsing is the
  hard part and these are Apple-maintained.
- Network.framework is not an option: it cannot upgrade a connection with STARTTLS.
- swift-nio-imap is 0.x and labelled "not production ready": pin exact versions, keep the
  facade thin, cover our used surface with integration tests against mailcow + Bridge.
- TLS policy: full verification for remote hosts; for `127.0.0.1` Bridge only, leaf pinning
  (TOFU with explicit confirmation in the UI, or an exported Bridge certificate).

## Alternatives

- Own minimal IMAP client on Network.framework: no STARTTLS; parser effort for literals,
  nested lists, response codes.
- MailCore2: Objective-C, unmaintained.
