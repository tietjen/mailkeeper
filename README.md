# MailKeeper

A macOS app that pulls mail from several accounts (Gmail, any IMAPS server, Proton Mail via
Proton Mail Bridge) into a local, searchable archive — search, filter, delete, restore — with
local-first LLM assistance that learns per macOS user.

Status: Phase 0 (spikes and architecture decisions). See `docs/spikes/README.md` and `docs/adr/`.

Principles: archive first, server second · plan → execute → verify for every bulk action ·
the model suggests, the user decides · mail content is untrusted data · the archive stays
readable without the app (raw `.eml` + SQLite index).
