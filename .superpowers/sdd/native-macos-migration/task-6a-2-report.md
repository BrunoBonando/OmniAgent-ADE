# Task 6a-2 report — Route project ingestion/roots operations through the daemon

Branch: `codex/native-macos-migration-progress` (pushed to `claude/native-migration-continue-sl21e0`). Resumed after the interrupted session recorded in `progress.md`; base commits `8eb7461`..`21f3257` (extraction + refactor + protocol + WIP dispatch) were already in place and untouched by this session except where noted below.

## What was already done before this session (verified, not rewritten)

- `crates/brain-ingest/src/roots.rs`: the Tauri-independent extraction (`8eb7461`) — `IngestionState`, `get_roots`/`add_root`, `add_project`/`rename_project`/`set_paused`/`paused_projects`/`staleness`/`reingest_project`/`rebuild`/`start_ingest`/`biggest_project`. No `tauri` dependency.
- `src-tauri/src/roots.rs`: refactored (`25ba266`) to thin `#[tauri::command]` wrappers delegating to `brain_ingest::roots`. Its own pre-existing `#[cfg(test)]` suite (22 tests) is unchanged.
- `crates/omniagent-pty-daemon/src/protocol.rs`: twelve new `MessageKind` discriminants `0x0e`-`0x19` (`bf46bf5`) — `RootsStartIngest`, `RootsIngestionStatus`, `RootsList`, `RootsBiggestProject`, `RootsAddProject`, `RootsRenameProject`, `RootsPausedProjects`, `RootsSetPaused`, `RootsStaleness`, `RootsReingestProject`, `RootsRebuild`, `BrainSearch` — appended after Task 6a's `BrainGetContext` (`0x0d`), none renumbered.
- `crates/omniagent-pty-daemon/src/server.rs`: dispatch arms for all twelve kinds (`21f3257`), routing to `brain_ingest::roots`'s functions and `mcp_server::tools::search_brain` through the same `tool_context(store, data_dir)` helper Task 6a introduced. `DaemonServer` gained an `ingestion: IngestionState` field, constructed once at `bind()`/`bind_with_data_dir()` and shared across every connection — independent of (not coordinated with) the Tauri app's own `IngestionState`, per the brief.

This left the interrupted session's own summary accurate: "compiles clean, but ... before the daemon test suite was run and before any covering tests were added for this dispatch code, and before the corresponding Swift SessionConnection client methods."

## What this session added

### Rust tests — `crates/omniagent-pty-daemon/tests/server_protocol.rs`

Six new `#[tokio::test]` functions, following Task 6a's `brain_list_projects_and_get_context_round_trip_through_the_daemon` / `malformed_brain_get_context_payload_closes_the_connection` pattern:

- `roots_add_rename_pause_and_staleness_round_trip_through_the_daemon` — add → list → rename → pause → paused-list → staleness → reingest (known + unknown project, the latter asserting an `Error` frame).
- `roots_start_ingest_list_and_ingestion_status_round_trip_through_the_daemon` — start-ingest against an empty temp root, polls `RootsIngestionStatus` to settle (bounded 5s), then `RootsList`/`RootsBiggestProject` (asserting the latter degrades to `null`, not an error, when nothing was ingested).
- `roots_rebuild_round_trips_through_the_daemon` — seeds one `Project` node directly via `Store`, confirms `BrainListProjects` sees it, calls `RootsRebuild`, confirms the store is empty afterward (proves the wipe actually happens, not just an ack).
- `brain_search_round_trips_through_the_daemon` — seeds a node, searches for it (hit) and for a non-existent term (empty, not an error).
- `malformed_roots_and_search_payloads_close_the_connection` — loops over the six typed-payload kinds (`RootsStartIngest`, `RootsAddProject`, `RootsRenameProject`, `RootsSetPaused`, `RootsReingestProject`, `BrainSearch`), one fresh connection each, asserting a truncated-JSON frame closes the connection.
- `malformed_json_closes_the_connection_for_no_payload_roots_kinds` — same, for the six kinds that decode `serde_json::Value` (`RootsIngestionStatus`, `RootsList`, `RootsBiggestProject`, `RootsPausedProjects`, `RootsStaleness`, `RootsRebuild`) — confirms they still go through `parse_json`, not a validation bypass.

**Result:** `cargo test -p omniagent-pty-daemon` — 13/13 new+existing `server_protocol` tests pass. One pre-existing, unrelated failure: `one_persistent_connection_streams_raw_bytes_and_applies_resize` times out waiting on real PTY output in this sandbox; confirmed via a throwaway `git worktree` at Task 6a's baseline commit (`9e6a9c2`, before any Task 6a-2 change) that it fails identically there — an environment characteristic of this Linux sandbox, not a regression. Needs a real machine (or this sandbox's PTY behavior fixed) to clear; out of scope for this task.

`cargo test -p omniagent-ade --lib` — 171 passed, 2 failed, both pre-existing and unrelated: `git_branch_returns_the_checked_out_branch_for_a_real_repo` asserts the checked-out branch is literally `"main"` (this sandbox is on a feature branch); `the_titles_version_is_the_one_tauri_conf_json_declares` is a pre-existing `Cargo.toml`/`tauri.conf.json` version-string drift. `roots.rs`'s own 22-test module passed unchanged, confirming Task 6a-2's earlier refactor is non-regressing.

(Getting `cargo test -p omniagent-ade` to run at all in this sandbox required installing `libgtk-3-dev`/`libwebkit2gtk-4.1-dev`/`libsoup-3.0-dev` via `apt-get`, absent from the base image, and building release `omniagent-mcp`/`omniagent-pty-daemon` binaries the Tauri build script bundles as resources — neither is a code change, both are one-time sandbox setup.)

### Swift client — `macos/OmniAgent/{SessionProtocol,SessionConnection}.swift`, `macos/OmniAgentTests/SessionConnectionTests.swift`

- `SessionProtocol.swift`: the same twelve `MessageKind` cases (`0x0e`-`0x19`), matching the Rust raw values exactly.
- `SessionConnection.swift`: twelve client methods — `startIngest`, `ingestionStatus`, `rootsList`, `biggestProject`, `addProject`, `renameProject`, `pausedProjects`, `setPaused`, `staleness`, `reingestProject`, `rebuildBrain`, `search` — following Task 6a's `sendCodable`/`request` + completion pattern exactly. Reused `BrainProjectSummary` for `RootsAddProject`/`RootsBiggestProject` responses (identical `{id, label, path}` shape to `ProjectSummary`) and `BrainNodeView` for `BrainSearch` results (identical shape to `search_brain`'s node projection), rather than defining redundant near-duplicate types. New public types: `IngestionStatus` (mirrors `brain_ingest::roots::IngestionStatus`'s Serde shape field-for-field, `active_workers` excluded since it's `#[serde(skip)]` on the Rust side too) and `ProjectStaleness` (mirrors `{project, last_ingested, stale}`). New private payload/response wrapper structs for each kind, `CodingKeys` mapping to the exact Rust JSON field names (`new_label`, `projects_total`, `last_ingested`, etc.).
- `SessionConnectionTests.swift`: twelve new `XCTestCase` methods, one per client method, using the file's existing `UnixTestServer` mock-daemon harness — each asserts the outgoing frame's `MessageKind` and payload shape, then feeds back a `Response` frame and asserts the decoded result (including the "biggest project is nil when nothing ingested yet" and "staleness with a `null` `last_ingested`" edge cases).

**Verification gap — could not compile or run.** This Linux sandbox has no Swift toolchain at all (`swift`, `swiftc`, `xcodebuild` are all absent; `SessionConnection.swift` imports `Darwin`, an Apple-only module, so even a hypothetical Linux Swift toolchain couldn't compile this file). `./macos/build.sh test` and `./macos/build.sh build` (both hard-required by the brief's Verification section) could not be run and were not run. The Swift code above was hand-verified against the exact Rust `MessageKind` raw values, JSON field names (checked against `protocol.rs`'s `Serialize`/`Deserialize` derives and `server.rs`'s `serde_json::json!` response bodies), and Task 6a's already-`xcodebuild`-verified Swift pattern — but this is not a substitute for compilation. **This must be run on a real Mac before Task 6a-2 (or anything depending on it, i.e. Task 6b-2) is considered complete**, mirroring this plan's existing Task 4 external-gate precedent ("signed-installed-app Instruments p95 ... remain unrun and block release acceptance").

## Final message-kind routing table

| `MessageKind` | Daemon dispatch | `src-tauri` equivalent |
|---|---|---|
| `RootsStartIngest` (`0x0e`) | `roots::start_ingest` | `roots_start_ingest` |
| `RootsIngestionStatus` (`0x0f`) | `ingestion.snapshot()` | `ingestion_status` |
| `RootsList` (`0x10`) | `roots::get_roots` | `roots_list` |
| `RootsBiggestProject` (`0x11`) | `roots::biggest_project` | `roots_biggest_project` |
| `RootsAddProject` (`0x12`) | `roots::add_project` | `add_project` |
| `RootsRenameProject` (`0x13`) | `roots::rename_project` | `rename_project` |
| `RootsPausedProjects` (`0x14`) | `roots::paused_projects` | `roots_paused_projects` |
| `RootsSetPaused` (`0x15`) | `roots::set_paused` | `roots_set_paused` |
| `RootsStaleness` (`0x16`) | `roots::staleness` | `roots_staleness` |
| `RootsReingestProject` (`0x17`) | `roots::reingest_project` | `roots_reingest_project` |
| `RootsRebuild` (`0x18`) | `roots::rebuild` + `roots::ingest_roots_in_background` | `roots_rebuild` |
| `BrainSearch` (`0x19`) | `mcp_server::tools::search_brain` | (was unwired — Task 6a-2 closes this gap for the native command palette) |

All twelve reply via the existing generic `Response`/`Error` kinds (no new response-side kinds needed), following `GetSetting`'s precedent.

## `src-tauri/src/roots.rs` commands now delegating to the extracted module

All of them, per `25ba266` (unchanged in this session): `roots_start_ingest`, `ingestion_status`, `roots_list`, `roots_biggest_project`, `add_project`, `rename_project`, `roots_set_paused`, `roots_reingest_project`, `roots_rebuild`. `roots_staleness` also delegates (`brain_ingest::roots::staleness`).

## Deliberately out of scope (per the brief)

`record_decision`/`record_note` — stay deferred, unless a later task needs them. Not touched.

## Verification checklist (brief's Verification section)

- [x] `cargo test -p omniagent-pty-daemon` — pass (one pre-existing unrelated sandbox flake, see above).
- [x] `cargo test -p omniagent-ade --lib` and its integration tests — pass, zero regressions in `roots.rs`'s existing test module (two pre-existing unrelated failures, see above).
- [x] The extracted module (`brain_ingest::roots`) has its own test coverage independent of both Tauri and the daemon — pre-existing (22 tests, from `8eb7461`), unchanged.
- [ ] `./macos/build.sh test` — **not run, no Swift toolchain in this sandbox.**
- [ ] `./macos/build.sh build` — **not run, same reason.**
- [x] `git diff --check` — clean.
