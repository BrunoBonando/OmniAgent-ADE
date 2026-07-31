# Task 6a — Route settings/brain operations through the Rust service

Sub-task of plan Task 6 (`docs/plans/native-macos-migration.md`), split for implementer-sized review. Plan bullet:

> Route settings/brain operations through the Rust service while preserving data/model compatibility and per-field layout repair.

This is the data-routing foundation Task 6b's SwiftUI settings/onboarding/usage/inspector surfaces will call into. Do this one first.

## Existing state (confirmed by research, not speculation)

- The daemon protocol's `MessageKind` enum (`crates/omniagent-pty-daemon/src/protocol.rs:107-132`) already defines `GetSetting = 0x0a` / `SetSetting = 0x0b`, and the daemon server (`crates/omniagent-pty-daemon/src/server.rs:307-340`) already opens the same `brain_core::Store` (`Store::open(runtime_dir)`, `server.rs:44-45`) and dispatches `GetSetting`/`SetSetting` against its `settings` table. **No Rust protocol change needed for plain settings get/set.**
- `macos/OmniAgent/SessionProtocol.swift:3-25` mirrors the enum including `getSetting`/`setSetting`, but `macos/OmniAgent/SessionConnection.swift` (650 lines) exposes no client methods for them at all — only `listSessions/createSession/attach/write/resize/interrupt/kill`. **Add the Swift client methods.**
- Brain read/mutate operations (`list_projects`, `search`, `get_context`, `briefing`, `map_graph`, `map_node_detail`, `pending_notes_*`, `roots_*`) have **no message kind at all** in either `protocol.rs` or `SessionProtocol.swift` today — they only exist as Tauri commands (`src-tauri/src/commands/mod.rs:164-234`, `src-tauri/src/roots.rs`, `src-tauri/src/feedback.rs:197-206`) called by the web/Tauri UI. Routing brain operations natively requires **appending new `MessageKind` values** (never renumber/reuse existing ones — the envelope format is frozen for existing kinds) to both `protocol.rs` and the Swift mirror, plus server-side dispatch in `server.rs` against the same `Store`.
- Scope the brain operations you add to what a "usage/inspector" surface plausibly needs (at minimum: project list, get-context or briefing equivalent). You do not need to mirror every Tauri brain command — note in your report which ones you added and which you deliberately deferred, and why.
- The `layout` setting is a JSON blob under settings key `"layout"` (`LAYOUT_SETTING_KEY`, `ui/src/state/sessions.ts:401`) — same `settings` table, same `brain.db`, shared with the web/Tauri app. Its shape is `PersistedTab[]` (`ui/src/state/sessions.ts:467-489`: `project`, `engine`, `cwd`, `id?`, `label?`, `themeId?`, `group?`, `groupLabel?`) wrapped as `{ tabs: PersistedTab[] }` (`:490-492`). The native client must round-trip this **exact** JSON shape — the web app reads/writes the same row.
- Per-field layout repair currently lives only in the frontend, in `deserializeLayout()` (`ui/src/state/sessions.ts` ~526-560): never throws (corrupt/missing → `[]`); invalid `themeId` dropped (falls back to default theme); invalid/duplicate `id` dropped (fresh session rather than vanishing pane); invalid `group` dropped; empty `groupLabel` trimmed/dropped. Port this exact repair behavior into Swift — do not fail-closed on a malformed layout.

## Global constraints that bind this task

- Do not change public MCP shapes (`crates/mcp-server`) — this task is the daemon's own socket protocol, a separate, already-versioned channel from MCP v1. Do not touch `crates/mcp-server`.
- Reject payloads over 1 MiB, malformed frames, unsupported versions, wrong-user peers — new message kinds must go through the same envelope validation as existing ones, not a side channel.
- Preserve `SessionInfo`, `SessionStatus`, `SessionStatusEvent`, `SessionEndEvent`, `PersistedTab`, and the `layout` setting exactly.
- Follow TDD for behavior changes.

## Verification

- `cargo test -p omniagent-pty-daemon` (new message-kind round-trip, malformed/oversized/version-mismatch rejection still holds for the new kinds)
- Affected Rust/Tauri tests unaffected (`src-tauri` — do not touch its command surface, this task is daemon+Swift only)
- `./macos/build.sh test`
- `./macos/build.sh build`
- `git diff --check`

Commit all Task 6a work and write `.superpowers/sdd/native-macos-migration/task-6a-report.md`, including which brain operations you added vs. deferred and why.
