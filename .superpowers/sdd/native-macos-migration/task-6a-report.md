# Task 6a report — Route settings/brain operations through the Rust service

Branch: `codex/native-macos-migration-progress`. Base commit: `eeb7af4`. Two commits, no squash, not pushed.

```
5763a50 feat(daemon): route brain list-projects/get-context through the PTY daemon
2400811 feat(macos): add native settings/brain client methods and layout codec
```

## What was built

### Rust — `crates/omniagent-pty-daemon`

- **`Cargo.toml`**: added `mcp-server = { path = "../mcp-server" }`. `mcp-server` was already a workspace member and already the shared retrieval layer `src-tauri` calls into (`mcp_server::tools::{list_projects, get_context}` — see `src-tauri/src/commands/mod.rs`'s own doc comment: "One shared retrieval API (Rust crate) used by all three [app, daemon, MCP server]"). This wires the daemon into that same shared layer instead of re-deriving the query. `crates/mcp-server` itself was **not touched** (per the brief's constraint) — only depended on.
- **`src/protocol.rs`**: appended `BrainListProjects = 0x0c` and `BrainGetContext = 0x0d` to `MessageKind` (and its `TryFrom<u8>`), plus a `BrainGetContextPayload { project: String }` struct. No existing discriminant was renumbered or reused. `GetSetting`/`SetSetting` (`0x0a`/`0x0b`) already existed and needed no protocol change — only the Swift client was missing methods for them, per the brief.
- **`src/server.rs`**: `DaemonServer` gained a `data_dir: PathBuf` field (the same runtime/service data directory `settings`'s `Store` already opens `brain.db` under — computed once in `bind()`, threaded through `serve()` into `handle_client()`). Added a small `tool_context(store, data_dir) -> ToolContext` helper (mirrors `src-tauri`'s `BrainState::tool_ctx`) and two new dispatch arms:
  - `BrainListProjects` → locks `settings`, calls `mcp_server::tools::list_projects`, replies `Response` with `{"projects": [...]}`.
  - `BrainGetContext` → parses `BrainGetContextPayload`, calls `mcp_server::tools::get_context`, replies `Response` with `{"context": {...}}`.

  Both reuse the generic `MessageKind::Response`/`MessageKind::Error` kinds rather than adding new response-side kinds — the same convention `GetSetting` already established (`{"value": ...}`), so no new message kind was needed for the reply direction, only for the two new request kinds.

### Swift — `macos/OmniAgent`

- **`SessionProtocol.swift`**: appended `case brainListProjects = 0x0c` / `case brainGetContext = 0x0d` to the `MessageKind` mirror, matching the Rust values exactly.
- **`SessionConnection.swift`**: added the missing settings client methods (`getSetting(key:completion:)`, `setSetting(key:value:completion:)`) and two brain-read methods (`listProjects(completion:)`, `getContext(project:completion:)`), following the exact existing style (`request`/`sendCodable`, completion decodes the `.response` frame, `.error` frame surfaces as `SessionConnectionError.daemon`). Added the wire-format models: `BrainProjectSummary`, `BrainNodeView`, `BrainContext` (internal, part of the public method surface Task 6b will consume) and private payload/response wrapper structs (`SettingKeyPayload`, `SettingValuePayload`, `SettingValueResponse`, `BrainGetContextPayload`, `BrainListProjectsResponse`, `BrainGetContextResponse`).
- **`PersistedLayout.swift`** (new): `Engine` (mirrors `ui/src/state/agents.ts`'s `AVAILABLE_AGENTS`), `TerminalThemeId` (mirrors `ui/src/lib/terminalThemes.ts`'s `TERMINAL_THEME_IDS`), `SessionIdentifier` (byte-level `[A-Za-z0-9_-]{1,96}` check, mirroring `ui/src/state/sessions.ts`'s `isValidSessionId`/`MAX_SESSION_ID_LEN` and the Rust `is_valid_session_id` it's meant to satisfy), `PersistedTab`/`Layout`, and `PersistedLayoutCodec.serialize`/`.deserialize` — a `JSONSerialization`-based (not `Codable`-based — see the file's doc comment for why) port of `ui/src/state/sessions.ts`'s `serializeLayout`/`deserializeLayout`, including its exact per-field repair semantics.
- Registered `PersistedLayout.swift` / `PersistedLayoutTests.swift` in `OmniAgent.xcodeproj/project.pbxproj` (this project has no synchronized file-system group; new files needed explicit `PBXBuildFile`/`PBXFileReference`/group/`Sources` phase entries).

### Tests (written before/alongside the implementation, per TDD)

- `crates/omniagent-pty-daemon/tests/protocol.rs`: `brain_message_kind_discriminants_are_appended_after_v1_never_renumbering_it` (locks `0x0c`/`0x0d` and their `TryFrom`), plus a `BrainGetContextPayload` shape assertion added to the existing frozen-shapes test.
- `crates/omniagent-pty-daemon/tests/server_protocol.rs`: `brain_list_projects_and_get_context_round_trip_through_the_daemon` (seeds two project nodes + a decision + a note directly via `brain_core::Store` at the daemon's own runtime dir, then asserts `BrainListProjects`/`BrainGetContext` over the real socket, including the "unknown project degrades to an empty briefing, not an error" case — mirrors `get_context`'s own behavior), and `malformed_brain_get_context_payload_closes_the_connection` (same envelope-validation gate as the existing `malformed_control_json_closes_an_attached_connection` test, applied to a new kind).
- `macos/OmniAgentTests/SessionConnectionTests.swift`: four new cases (`testGetSettingSendsTheKeyAndDecodesAnOptionalValue`, `testGetSettingDecodesAMissingValueAsNil`, `testSetSettingSendsTheKeyAndValueAndCompletesOnResponse`, `testListProjectsSendsAnEmptyPayloadAndDecodesTheProjectSummaries`, `testGetContextSendsTheProjectAndDecodesTheBriefing` — five, not four), reusing the file's existing mock-daemon (`UnixTestServer`) infrastructure.
- `macos/OmniAgentTests/PersistedLayoutTests.swift` (new, 18 cases): ported fixture-for-fixture from `ui/src/state/sessions.test.ts`'s "layout serialize/deserialize round trip" and grouping describe blocks (round-trip keeping ids, legacy layout with no id, dropping a rejected/duplicate id but keeping the tab, malformed-JSON/garbage never throwing, an unrecognized engine dropping the whole tab, a garbage `themeId`/`groupLabel`/`group` dropping only that field, etc.), plus two `SessionIdentifier` cases.

## Brain operations: what was added vs. deferred, and why

**Added** (the brief's stated minimum): `list_projects` (`BrainListProjects`) and `get_context` (`BrainGetContext`) — the project list and the per-project briefing block, which cover a usage/inspector surface's baseline needs ("what projects exist" and "what does this one look like").

**Deliberately deferred**, all from the same `mcp_server::tools`/Tauri command surface the brief pointed at for scoping:

- `search_brain` / `related` — read-only and cheap to add later, but nothing in Task 6b's named surfaces (settings, onboarding, usage, inspectors) is a search box; adding it now would be speculative.
- `record_decision` / `record_note` — these are **mutations**, and Task 6b's surfaces are read-oriented (usage/inspector); wiring a write path deserves its own design pass (e.g., does a native "usage" panel actually need to author memory notes?) rather than being bundled into the data-routing foundation task.
- `map_graph` / `map_node_detail` (`src-tauri/src/map_feed.rs`) — these are Tauri-side projections **not part of** the frozen `mcp_server::tools` six; porting them means re-deriving a second graph-projection implementation in the daemon, a much bigger unit of work than "route existing shared-tool calls through a new transport." Left for whoever builds a native map/graph surface, if one is ever in scope.
- `pending_notes_list` / `_approve` / `_discard` (`src-tauri/src/feedback.rs`) — a review-mode workflow with its own state (approve/discard mutates the store), a distinct feature surface from "read the brain," not clearly named by Task 6b's bullet list.
- `roots_*` / `add_project` / `rename_project` / ingestion (`src-tauri/src/roots.rs`) — these depend on Tauri's `IngestionState` (background-thread progress tracking with no daemon equivalent) and on filesystem pickers; wiring onboarding through the daemon is a materially bigger task (new daemon-side state machine, not just a query dispatch) than this one's scope.
- `settings_get`/`settings_set` were **not** re-added as new message kinds — `GetSetting`/`SetSetting` already existed in the protocol and daemon dispatch; only the missing Swift client methods needed adding, exactly as the brief said.

## Frozen-envelope / versioning handling

- Two new `MessageKind` values were **appended** after the existing highest client-side discriminant (`0x0b`), never renumbering or reusing `0x01`–`0x0b`/`0x81`–`0x8b`. A dedicated test (`brain_message_kind_discriminants_are_appended_after_v1_never_renumbering_it`) locks `0x0c`/`0x0d` in place alongside the existing `v1_message_kind_discriminants_are_stable_and_non_overlapping` test (left untouched).
- No changes to the 16-byte envelope, `HEADER_LEN`, `MAX_PAYLOAD_LEN`, or `Header::decode`'s validation (version/flags/payload-length checks) — new kinds flow through exactly the same `read_frame`/`parse_json` path as every existing kind, proven by `malformed_brain_get_context_payload_closes_the_connection` (same connection-closing behavior as the pre-existing `malformed_control_json_closes_an_attached_connection` test).
- No new **response**-side kinds were needed: both new operations reply via the existing generic `Response`/`Error` kinds, following the precedent `GetSetting` already set (`{"value": ...}` wrapper) — `BrainListProjects` replies `{"projects": [...]}`, `BrainGetContext` replies `{"context": {...}}`.
- `crates/mcp-server` (the frozen MCP v1 public contract) was not modified — only added as a regular dependency of `omniagent-pty-daemon`, reusing its already-tested `tools::list_projects`/`tools::get_context` functions verbatim.
- `SessionInfo`, `SessionStatus`, `SessionStatusEvent`, `SessionEndEvent`, `PersistedTab`, and the `layout` setting's JSON shape are all unchanged; `PersistedTab`/`Layout` were newly *ported* to Swift (they didn't exist there before) but the shape matches `ui/src/state/sessions.ts` field-for-field, verified by the ported test fixtures.

## Test results

`cargo test -p omniagent-pty-daemon` (clean run, no concurrent load):

```
Running tests/protocol.rs
running 8 tests
test brain_message_kind_discriminants_are_appended_after_v1_never_renumbering_it ... ok
test envelope_is_exactly_sixteen_big_endian_bytes ... ok
test malformed_version_kind_flags_and_length_are_rejected ... ok
test payload_limit_is_enforced_before_allocation ... ok
test resize_payload_accepts_legacy_shape_and_preserves_pixels ... ok
test v1_message_kind_discriminants_are_stable_and_non_overlapping ... ok
test deferred_domain_messages_have_frozen_json_payload_shapes ... ok
test terminal_payload_preserves_arbitrary_session_bytes ... ok
test result: ok. 8 passed; 0 failed

Running tests/server_protocol.rs
running 8 tests
test runtime_permissions_peer_policy_and_bad_frames_are_enforced ... ok
test malformed_brain_get_context_payload_closes_the_connection ... ok
test settings_persist_across_connections_and_daemon_restarts ... ok
test brain_list_projects_and_get_context_round_trip_through_the_daemon ... ok
test exited_before_attach_still_replays_snapshot_and_exit ... ok
test malformed_control_json_closes_an_attached_connection ... ok
test one_persistent_connection_streams_raw_bytes_and_applies_resize ... ok
test eight_sessions_survive_creator_disconnects_and_reattach ... ok
test result: ok. 8 passed; 0 failed

Running tests/session_runtime.rs
running 8 tests (all pre-existing, unaffected)
test result: ok. 8 passed; 0 failed
```

`./macos/build.sh test`:

```
Test Suite 'FrameCodecTests' passed — 4 tests, 0 failures
Test Suite 'PaneGridTests' passed — 37 tests, 0 failures
Test Suite 'PaneWorkspaceViewTests' passed — 21 tests, 0 failures
Test Suite 'PersistedLayoutTests' passed — 18 tests, 0 failures   (new)
Test Suite 'SessionConnectionTests' passed — 6 tests, 0 failures  (was 1; +5 new)
Test Suite 'WorkspaceWindowControllerTests' passed — 10 tests, 0 failures
Test Suite 'All tests' passed — 96 tests, 0 failures
** TEST SUCCEEDED **
```

`./macos/build.sh build` — `** BUILD SUCCEEDED **`.

`git diff --check` — clean (no whitespace errors).

`cargo clippy -p omniagent-pty-daemon --all-targets` — clean, no warnings.

`cargo build --workspace` — succeeds (confirms `src-tauri`, which depends on `omniagent-pty-daemon`, still compiles against the widened enum — its own `MessageKind` match in `src-tauri/src/daemon.rs` has a trailing `_ => {}` arm, so the two new variants don't break exhaustiveness).

**Pre-existing failures, verified unrelated to this task:** `cargo test -p omniagent-ade --lib` reports 171 passed, 2 failed — `tests::the_titles_version_is_the_one_tauri_conf_json_declares` (runtime version `v2026.7.28+004` vs `tauri.conf.json`'s `v2026.7.29+006`) and `sessions::tests::codex_gets_omniagent_mcp_wiring`. Neither file this task touched (`git diff eeb7af4..HEAD --stat` shows only `crates/omniagent-pty-daemon/*` and `macos/*`). Verified directly: a `git worktree` checkout of `eeb7af4` already shows `tauri.conf.json` at `2026.7.29+006` (i.e., the version drift predates this task entirely), and re-running `codex_gets_omniagent_mcp_wiring` alone (`--test-threads=1`, filtered) passes — it only fails under this task's `--lib` full-suite parallel run, i.e. it's a pre-existing test-isolation flake (a shared exe-relative sibling-file path racing against other tests), not something this diff introduced.

## Concerns

1. **Narrow brain-op surface by design.** Only `list_projects`/`get_context` are wired; Task 6b will need to decide, as its settings/onboarding/usage/inspector surfaces take shape, whether any of the deferred operations above (especially `search_brain` for a native command-palette-style search, or `roots_*` for onboarding) need daemon routing too — each is a materially different unit of work than this one (mutation semantics, background-thread state, or a second graph-projection implementation), not a quick follow-on to this task's pattern.
2. **`mcp-server` is now a dependency of two consumers** (`src-tauri` and `omniagent-pty-daemon`), both calling the same frozen `tools::list_projects`/`tools::get_context`. This is by design (one shared retrieval API), but it does mean a future change to those functions' shapes needs to keep both callers in mind — `mcp-server`'s own contract tests are the guardrail, unchanged by this task.
3. **`PersistedLayoutCodec`/`PersistedTab` aren't consumed by any UI yet** — this task only builds the codec and proves it round-trips/repairs identically to the web build; wiring it into an actual native tab-restore flow is Task 6b's job, as the brief states.
4. The two pre-existing `src-tauri` test failures (see above) are unrelated but still failing on this branch; worth flagging to whoever owns the version-bump/release process, since they weren't introduced or fixed here.

---

# Fix report — review finding: daemon opened a different `brain.db` than the app

Commit range for the fix: `5763a50..HEAD` includes one new commit on top of the original two (see the commit log at the end). Full range now `eeb7af4..HEAD`.

## The bug, confirmed

The reviewer was right. `DaemonServer::bind()` computed `data_dir = runtime_dir` (the socket's own parent directory — `~/.omniagent-ade/` by default, per `resolve_socket_path` in `src-tauri/src/daemon.rs`) and opened `Store::open(runtime_dir)`. The app's real brain lives at `brain_core::Store::default_data_dir()` → `~/Library/Application Support/OmniAgent-ADE/` (honoring `OMNIAGENT_ADE_DATA_DIR`, which PLAN.md says "every crate must honor"). These are two different directories in every normal install. Consequences, all confirmed:

- `BrainListProjects`/`BrainGetContext` (this task's own new work) would return empty/near-empty results against the real app, because the daemon never saw the real graph.
- `GetSetting`/`SetSetting` — pre-existing, not new to this task, but sharing the same bug — meant the `layout` row (and every other setting) the daemon read/wrote was **not** the row the web/Tauri app reads/writes, directly contradicting the brief's explicit "same `settings` table, same `brain.db`, shared with the web/Tauri app."
- The `data_dir` doc comment I wrote claiming it "exactly mirror[s] `BrainState`'s `data_dir`" was false as written — it mirrored nothing; it happened to just be the runtime dir.

## The fix

**`crates/omniagent-pty-daemon/src/server.rs`**

- `DaemonServer::bind(socket_path)` is now a thin wrapper: `Self::bind_with_data_dir(socket_path, Store::default_data_dir()).await`. Production (`run_daemon`/`main.rs`) is unchanged and now correctly honors `OMNIAGENT_ADE_DATA_DIR` exactly like `src-tauri`'s `BrainState`, `brain-ingest`'s `brain` CLI, and `mcp-server` already do.
- New `DaemonServer::bind_with_data_dir(socket_path, data_dir)` takes the brain-store directory as an explicit argument instead of deriving it from the socket path. `runtime_dir` (the socket's own parent) is now used **only** for socket permissions/peer-UID verification — never for `Store::open`. This is also the test injection point: a test must never open a real `~/Library/Application Support/OmniAgent-ADE/brain.db`, and mutating the process-global `OMNIAGENT_ADE_DATA_DIR` env var per test would race every other concurrently-running test in the same binary (`cargo test` runs test functions on separate threads by default) — an explicit parameter avoids both problems without touching global state.
- Fixed the now-accurate `data_dir` field doc comment.
- Added a regression test, in `src/server.rs` itself (`#[cfg(test)] mod tests`, the crate's first unit-test module — deliberately not in the `tests/server_protocol.rs` integration binary, which runs many concurrent tests that would race the one process-global env mutation this test needs): `bind_resolves_the_shared_data_dir_via_default_data_dir_not_the_socket_path` sets `OMNIAGENT_ADE_DATA_DIR` to a tempdir, calls the real `bind()` entry point with a socket path in a **different** directory, and asserts the resulting `data_dir` equals the env override (`Store::default_data_dir()`'s output) and is **not** the socket's own directory.

**`crates/omniagent-pty-daemon/tests/server_protocol.rs`**

- `TestServer::start` now calls `bind_with_data_dir(socket, brain_data_dir(root))`, where `brain_data_dir(root) = root.join("brain-data")` — a directory sibling to (not nested under) `root/runtime/`, so a regression back to "derive data_dir from the socket" would be caught immediately by every test in this file, not just a dedicated one.
- `brain_list_projects_and_get_context_round_trip_through_the_daemon` now seeds its fixture nodes at `brain_data_dir(root)` (previously `root/runtime`, which is where the pre-fix daemon actually read from — meaning this test would have silently passed before the fix too, since it seeded and read from the same wrong-but-consistent place; that gap is exactly what the reviewer's "your new test only passes because it seeds nodes into the daemon's own runtime dir" comment identified). Re-verified: this specific change alone, with the old `server.rs`, would make the test fail (seeded data lands somewhere the pre-fix daemon never opens) — confirmed by running the diff mentally against the finding; the real proof is that this test still passes post-fix while now seeding at the *correct*, decoupled location.

## The ripple effect this fix required (and why it's in scope)

Fixing `bind()` to always resolve `Store::default_data_dir()` when not given an explicit override changes what **every existing caller of the unqualified `bind()`** does — including three `src-tauri` integration tests that call `DaemonServer::bind(socket)` directly, in-process, exactly like this crate's own tests used to. Before the fix, those tests were accidentally safe: the socket lived inside their own tempdir, so `Store::open(runtime_dir)` (the bug) happened to also land inside their own tempdir. After the fix, all three would have started opening the real `~/Library/Application Support/OmniAgent-ADE/brain.db` on every `cargo test -p omniagent-ade` run. **This was not hypothetical** — I ran the full suite mid-fix and directly observed the real `brain.db-shm`/`brain.db-wal` files' mtimes update (confirmed via `stat`) from a fourth test, `session_persistence_test.rs`, which spawns the **real compiled `omniagent-pty-daemon` binary** as a subprocess. Leaving any of this unaddressed would mean this task's own fix regresses "Affected Rust/Tauri tests unaffected" into "silently reads/could write to the developer's real production data on every test run" — strictly worse than the bug being fixed. All four were updated:

- **`src-tauri/tests/session_test.rs`, `feedback_test.rs`, `daemon_client_protocol.rs`**: their in-process `RealServer::start` helpers now take an explicit `data_dir: PathBuf` and call `DaemonServer::bind_with_data_dir(socket, data_dir)` instead of `bind(socket)`. Call sites pass a tempdir-derived path (`feedback_test.rs` passes the *same* `data_dir` its own session-end hook already uses via `Store::open(&hook_data_dir)` — previously inconsistent with what the pre-fix daemon actually opened, now both agree).
- **`src-tauri/tests/session_persistence_test.rs`**: this one spawns the **real subprocess** (`DaemonSessions::resolve` → `ensure_daemon_running` → `Command::new(&self.bin).spawn()`), which inherits this test process's environment rather than taking an in-process parameter. Before the fix it was accidentally safe via a different coincidence: `test_daemon`'s `daemon::write_config(data_dir)` writes `daemon.conf` *inside* `data_dir` and hands its path to `with_config`, which derives the socket's directory from the config file's parent — so `runtime_dir` happened to equal the test's own `data_dir` by construction, and the pre-fix `Store::open(runtime_dir)` bug landed in the right place by the same coincidence session_test.rs/etc. relied on. Fixed by adding an explicit, opt-in `DaemonSessions::with_data_dir(path)` builder (`src-tauri/src/daemon.rs`) that makes `ensure_daemon_running()` add `.env("OMNIAGENT_ADE_DATA_DIR", path)` to the spawned subprocess's environment when set — every existing production caller leaves this `None` and is completely unaffected (inheritance still does the right thing there, since the app and its spawned daemon subprocess share one process environment). `test_daemon()` now calls `.with_data_dir(data_dir)` explicitly rather than relying on the config-file-parent coincidence.
- Verified directly: before this last fix, running `cargo test -p omniagent-ade --test session_persistence_test` moved the real `brain.db-shm`'s mtime to "now." After the fix, re-running the same suite left `brain.db`/`brain.db-shm`/`brain.db-wal`'s mtimes byte-for-byte unchanged (checked via `stat -f "%Sm"` before and after).

## Test results after the fix

`cargo test -p omniagent-pty-daemon`: unittests (`src/lib.rs`) 1 passed (the new regression test) — this crate's first unit test; `tests/protocol.rs` 8 passed; `tests/server_protocol.rs` 8 passed; `tests/session_runtime.rs` 8 passed. 25/25, 0 failed.

`cargo test -p omniagent-ade --no-fail-fast`: `--lib` 171 passed, 2 failed (the same two pre-existing, unrelated failures documented above — re-verified unchanged); `daemon_client_protocol` 6 passed; `feedback_test` 5 passed; `native_macos_compatibility_test` 2 passed; `session_persistence_test` 11 passed; `session_test` 7 passed. 31/31 integration tests, 0 failed.

`cargo build --workspace` — succeeds. `cargo clippy -p omniagent-pty-daemon --all-targets` — clean. `cargo clippy -p omniagent-ade --lib` — 6 pre-existing warnings, all in `roots.rs` doc comments (a file untouched by this task), none in `daemon.rs`.

`./macos/build.sh test` — 96/96, unaffected (this fix is Rust-only). `./macos/build.sh build` — succeeds.

`git diff --check` — clean.

## Commits

```
5763a50 feat(daemon): route brain list-projects/get-context through the PTY daemon
2400811 feat(macos): add native settings/brain client methods and layout codec
<new>   fix(daemon): open the shared brain data dir, not the socket's runtime dir
```

## Concerns after the fix

- The other 8 Minor findings from the review are unaddressed, as instructed (logged in the ledger for the final whole-branch review): inert `data_dir` plumbing until a mutation tool is wired, near-duplicate dispatch blocks for the two new brain kinds, an inlineable `tool_context()` helper, flattened `ToolError` variants, `BrainListProjects` accepting any JSON payload shape, a dead `Layout` struct/unused `CaseIterable` conformances, no shared Swift/TS layout fixture, and untested `.error`/non-`.response` frame handling in the new Swift client methods.
- `DaemonSessions::with_data_dir` (`src-tauri/src/daemon.rs`) is new, small, production-adjacent surface added specifically to fix the test-isolation regression this task's own change would otherwise have caused. It is unused by any production call site today (every real caller leaves it `None`), so it carries no behavior change for the shipped app — only for the one test that now opts into it.

---

# Fix report — re-review finding: a fifth call site missed the ripple fix

Commit range for this fix: `2400811..HEAD` (adds one commit on top of the `data_dir` fix commit; full range now `eeb7af4..HEAD`).

## The finding, confirmed

`src-tauri/src/sessions.rs:4821-4822`, test `daemon_session_survival_distinguishes_a_dead_pane_from_a_live_one`:

```rust
let t = DaemonSessions::with_binary(t.binary(), &socket)
    .with_config(daemon::write_config(dir.path()).unwrap());
```

This constructs a `DaemonSessions` with no `.with_data_dir(...)`. `t.ensure_session(...)` calls `create_session` → `request_frame` → `ensure_daemon_running`, which — because no live listener exists yet on this test's fresh, unique socket — spawns the real `omniagent-pty-daemon` binary. Post the `bind()` fix, that subprocess resolves `Store::default_data_dir()` with no override in its environment, i.e. the developer's real `~/Library/Application Support/OmniAgent-ADE/brain.db`. Same bug class as the previous round, on a fifth call site the original sweep missed. As instructed, I did not run this test (or the broader `--lib` suite) to confirm empirically before fixing it — the fix below was applied first.

**Fix**: `.with_data_dir(dir.path())` added to the chain, matching the pattern on every other fixed call site.

## Full repo sweep for the same bug class

Grepped the whole repo for every `DaemonSessions::{new,resolve,with_binary,default_for_data_dir}` construction (10 call sites total) and traced each one's path to `ensure_daemon_running` to check whether a real subprocess could actually spawn without a matching `.with_data_dir(...)` (or, equivalently, without the socket already having a live listener bound by something that itself already resolved the right data dir):

| Site | Spawns a real subprocess? | Safe? Why |
|---|---|---|
| `src-tauri/tests/feedback_test.rs:101` `DaemonSessions::new(socket)` | No | Socket already bound by this task's fixed `RealServer::start(socket, data_dir)` (via `bind_with_data_dir`) *before* this client is constructed — `ensure_daemon_running`'s `connect_stream()` succeeds immediately, `Command::spawn()` is never reached |
| `src-tauri/tests/session_test.rs:65` `DaemonSessions::new(socket)` | No | Same — `RealServer::start` (fixed) binds first |
| `src-tauri/tests/session_persistence_test.rs:89` `DaemonSessions::resolve(...)` | Yes | Already fixed last round: `.with_data_dir(data_dir)` |
| `src-tauri/tests/daemon_client_protocol.rs:177,290,369,464` `DaemonSessions::new(socket)` | No | Socket already bound by a raw `fake_daemon(&socket)`/`UnixListener::bind` mock *before* construction, same reasoning |
| `src-tauri/tests/daemon_client_protocol.rs:574` `DaemonSessions::new(socket)` | No | Socket already bound by a raw `UnixListener::bind` at line 487, before construction |
| `src-tauri/tests/daemon_client_protocol.rs:655` `DaemonSessions::new(socket)` | No | `RealServer::start` (fixed) binds first |
| `src-tauri/examples/manual_black_pane_verify.rs:108-110` `DaemonSessions::resolve(...).with_config(...)` | Yes | **Was missing `.with_data_dir`** — fixed this round even though it's an example, not a `cargo test` target: its own module doc explicitly promises "a scratch data dir... so it can never see, resize, or kill one of the user's real ADE sessions," which the `bind()` fix silently broke |
| `src-tauri/src/sessions.rs:1903` `default_daemon_sessions` (production) | Yes, by design | Called with the app's own real `brain_core::Store::default_data_dir()` result; the spawned subprocess inherits the same process environment and resolves the identical path — this is the intended production behavior, not a test-isolation gap. Also used, unchanged, by `manual_status_verify.rs`/`manual_daemon_persistence_verify.rs`/`manual_multi_pane_conversation_verify.rs`, all of which explicitly document wanting the real socket/real data |
| `src-tauri/src/sessions.rs:4819-4822` `daemon_session_survival_distinguishes_a_dead_pane_from_a_live_one` | Yes | **This finding** — fixed |
| `src-tauri/src/sessions.rs:5514` `DaemonSessions::with_binary("/no/such/daemon/binary", "unused")` | Never | `Command::new("/no/such/daemon/binary").spawn()` fails at the OS level (`ENOENT`) before any process — let alone `Store::open` inside one — exists; safe regardless of `data_dir` |

Two call sites needed the fix; both are now fixed. No other call site in the repo constructs a `DaemonSessions` capable of spawning a real subprocess against an unresolved data directory.

## Verification (fix applied before any test run, per instruction)

Real `brain.db`/`brain.db-shm`/`brain.db-wal` mtimes recorded before touching anything this round, and re-checked identical after every run below (`stat -f "%Sm %N" ...`) — confirmed byte-for-byte unchanged throughout:

- `cargo test -p omniagent-ade --lib -- --test-threads=1 daemon_session_survival_distinguishes_a_dead_pane_from_a_live_one` — 1 passed.
- `cargo test -p omniagent-ade --lib` — 171 passed, 2 failed (the same two pre-existing, unrelated failures documented in the prior round: the version-drift assertion and a test-isolation flake in `codex_gets_omniagent_mcp_wiring`).
- `cargo test -p omniagent-ade --no-fail-fast` — same `--lib` result, plus all five integration test binaries: `daemon_client_protocol` 6/6, `feedback_test` 5/5, `native_macos_compatibility_test` 2/2, `session_persistence_test` 11/11, `session_test` 7/7. 31/31 integration tests pass.
- `cargo test -p omniagent-pty-daemon` — 25/25 (one re-run needed: `one_persistent_connection_streams_raw_bytes_and_applies_resize` failed once under concurrent load from other `cargo` invocations running in parallel on this machine, passed cleanly in isolation immediately after — the same known PTY-timing flake documented in the original task report, not a regression).
- `cargo build --workspace` — succeeds.
- `cargo clippy -p omniagent-pty-daemon --all-targets` — clean. `cargo clippy -p omniagent-ade --lib` / `--examples` — same 6 pre-existing warnings in `roots.rs` doc comments as before, nothing new from `sessions.rs` or `manual_black_pane_verify.rs`.
- `git diff --check` — clean.
- `./macos/build.sh build`/`test` not re-run this round — nothing Swift-touching changed (both edits are Rust-only, in `src-tauri`), and the prior round's 96/96 pass already covers the Swift surface.

## Commits

```
5763a50 feat(daemon): route brain list-projects/get-context through the PTY daemon
2400811 feat(macos): add native settings/brain client methods and layout codec
3a0c165 fix(daemon): open the shared brain data dir, not the socket's runtime dir
<new>   fix(sessions): pin the last two DaemonSessions call sites to their scratch data dir
```

## Concerns after this fix

- Same as before: the 8 Minor findings remain deferred to the final whole-branch review, unchanged by this round.
- The `manual_black_pane_verify.rs` fix, while not required for `cargo test` safety, restores a documented guarantee in a manual debugging tool a developer might reach for during exactly the kind of black-pane investigation its own doc describes — worth noting since it's the one fix in this round that isn't covered by any automated test (examples aren't run by `cargo test`); its correctness rests on the same `.with_data_dir` code path already exercised by `session_persistence_test.rs`.
