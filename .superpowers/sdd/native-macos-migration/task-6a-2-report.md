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

**Verification gap — could not compile or run (as of this Linux-sandbox session).** This Linux sandbox has no Swift toolchain at all (`swift`, `swiftc`, `xcodebuild` are all absent; `SessionConnection.swift` imports `Darwin`, an Apple-only module, so even a hypothetical Linux Swift toolchain couldn't compile this file). `./macos/build.sh test` and `./macos/build.sh build` (both hard-required by the brief's Verification section) could not be run and were not run. The Swift code above was hand-verified against the exact Rust `MessageKind` raw values, JSON field names (checked against `protocol.rs`'s `Serialize`/`Deserialize` derives and `server.rs`'s `serde_json::json!` response bodies), and Task 6a's already-`xcodebuild`-verified Swift pattern — but this is not a substitute for compilation.

**Resolved on a real Mac (commit `581aeab`):** `./macos/build.sh test` and `./macos/build.sh build` both now run and pass, closing this gap. See the updated Verification checklist below for what surfaced and was fixed.

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
- [x] `./macos/build.sh test` — run on a real Mac (commit `581aeab`). Surfaced 5 compile errors in `SessionConnectionTests.swift` (lines 364, 599, 655, 752, 791): `XCTAssertNoThrow(try result.get())` inside a `(Result<Void, Error>) -> Void` completion closure makes Swift infer the closure itself as throwing, which doesn't match `SessionConnection`'s non-throwing completion signature. Fixed by replacing each with `if case .failure(let error) = result { XCTFail("unexpected failure: \(error)") }`. After the fix: full suite passes — `SessionConnectionTests` 17/17, all other suites 0 failures. One unrelated flake surfaced in the full-suite run, `WorkspaceWindowControllerTests.testCommandOptionOIsClaimedByMenuBeforeSwiftTermKittyKeyDown` (a real-window/modal-session test, pre-existing, untouched by this task's diff); re-run in isolation (`-only-testing:`) it passes in 0.075s, confirming environment-timing flakiness, not a regression.
- [x] `./macos/build.sh build` — run on a real Mac (commit `581aeab`), **BUILD SUCCEEDED**.
- [x] `git diff --check` — clean.

## Review-fix addendum — `RootsRebuild` duplication (review 1's Important finding)

Review 1 found that `RootsRebuild` was the one operation in this task's surface still hand-rolled at both call sites: `src-tauri/src/roots.rs`'s `roots_rebuild` and the daemon's `MessageKind::RootsRebuild` dispatch arm each independently (a) checked `ingestion.snapshot().running` and rejected with the same message, (b) locked the store and called `roots::rebuild`, (c) called `ingest_roots_in_background` with the same four arguments — the exact duplication this task's extraction was supposed to eliminate.

**Fix:** added `brain_ingest::roots::rebuild_and_reingest(data_dir: &Path, store: &Mutex<Store>, ingestion: &IngestionState) -> Result<()>` (`crates/brain-ingest/src/roots.rs`, placed directly after `rebuild`) that owns the whole sequence: the running-check, the store lock/`rebuild`/swap, and the `ingest_roots_in_background` kickoff — mirroring how `start_ingest` already fully encapsulates its own analogous sequence. It takes the mutex itself (not a pre-acquired guard) so the lock is provably dropped before the background thread is spawned, same as `start_ingest`'s convention.

Both call sites now do nothing but call it:
- `src-tauri/src/roots.rs::roots_rebuild` — `brain_ingest::roots::rebuild_and_reingest(&brain.data_dir, &brain.store, ingestion.inner()).map_err(|e| e.to_string())`.
- `crates/omniagent-pty-daemon/src/server.rs`'s `MessageKind::RootsRebuild` arm — `roots::rebuild_and_reingest(&data_dir, &settings, &ingestion)`, matched into `send_response`/`send_error` exactly like every other kind (`settings: Arc<std::sync::Mutex<Store>>` deref-coerces to `&Mutex<Store>>` at the call site).

Side effect: `ingest_roots_in_background` was no longer called directly from `src-tauri/src/roots.rs`'s production code (only from its `#[cfg(test)]` module, which exercises it directly per this file's own documented test-import convention), so it was moved out of the module-scope `use brain_ingest::roots::{...}` block and into `mod tests`'s own import block to avoid an unused-import warning — no behavior change, an import-hygiene-only edit.

No other behavior changed at either call site: same running-check message (`"ingestion is already running"`), same lock-poisoned message (`"brain store mutex poisoned"`), same success/error shape.

### Verification run (this session, real Mac, commit range starts at `be92c78`)

- `cargo build -p brain-ingest -p omniagent-pty-daemon -p omniagent-ade` — clean, zero warnings (confirmed the `ingest_roots_in_background` import move above; before the move this produced exactly one `unused_imports` warning in `src-tauri/src/roots.rs`).
- `cargo test -p brain-ingest` — **191 passed, 0 failed, 1 ignored** (lib tests, includes `roots.rs`'s module unchanged) plus `cli_test`/`enrich_test`/`ingest_test` integration suites, all passing.
- `cargo test -p omniagent-pty-daemon` — **12 passed, 2 failed** in `server_protocol.rs`: `one_persistent_connection_streams_raw_bytes_and_applies_resize` (the same real-PTY timeout this report already documents as an environment characteristic) and, newly on this machine, `roots_add_rename_pause_and_staleness_round_trip_through_the_daemon` (a `Elapsed(())` timeout in the shared 4s frame-read helper). Neither touches `RootsRebuild`. Verified both are pre-existing, environment-only flakiness and **not caused by this fix**: (1) each passes reliably in isolation, with or without this session's diff (`cargo test -p omniagent-pty-daemon --test server_protocol roots_add_rename_pause_and_staleness_round_trip_through_the_daemon` → ok, 0.05s); (2) `git stash`-ing this session's diff and re-running the full `server_protocol` file reproduces the identical two failures at baseline. `roots_rebuild_round_trips_through_the_daemon` itself passes in every run. `protocol.rs`'s 10 tests all pass.
- `cargo test -p omniagent-ade --lib` — **171 passed, 2 failed**: `tests::the_titles_version_is_the_one_tauri_conf_json_declares` (the same pre-existing `Cargo.toml`/`tauri.conf.json` version-drift check this report already documents, now `v2026.7.28+004` vs `v2026.7.29+006` since the date has moved on) and `sessions::tests::codex_gets_omniagent_mcp_wiring` (an "omniagent-mcp binary not found next to the app binary" ordering flake). Same `git stash` check: both reproduce identically at baseline (171 passed / 2 failed, same two tests, same messages) — pre-existing, unrelated to this fix. `roots.rs`'s own test module passes unchanged.
- `./macos/build.sh build` — **BUILD SUCCEEDED** (no Swift touched by this fix; confirmed rather than assumed).
- `git diff --check` — clean.

### Commit

`fix(brain-ingest): share RootsRebuild's orchestration between src-tauri and the daemon` — adds `rebuild_and_reingest`, updates both call sites, moves the now-test-only `ingest_roots_in_background` import.
