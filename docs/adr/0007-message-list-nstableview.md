# ADR-0007: Message list is an NSTableView, not a SwiftUI Table

- Status: accepted (TJ, 2026-10-10)
- Deciders: TJ

## Context

Archives reach 100k–300k messages per account. Spike S2 measured 200k rows on macOS 27:
NSTableView kept 120 Hz while scrolling, sorted in 0.08 s and used 44 MB; SwiftUI `Table`
(array or lazy collection) took 137–247 s per sort change, ~130 ms per frame on scrollbar
jumps and grew to 600+ MB.

## Decision

The message list is a view-based `NSTableView` in an `NSViewRepresentable`. Rows come from a
SQLite page cache addressed by an ordered id array; sorting and filtering are SQL queries
followed by `reloadData()`. Everything else (sidebar, reader, settings, queue) stays SwiftUI.

## Consequences

- Selection, context menus, drag & drop and keyboard handling for the list are AppKit code
  bridged to the SwiftUI model.
- Re-check when a new macOS ships; the spike is kept runnable (`Spikes/S2-LargeTable`).
