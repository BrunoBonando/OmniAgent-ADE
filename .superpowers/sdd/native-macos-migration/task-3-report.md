# Task 3 — Phase 2 Tauri compatibility client

## Implementation

- Consolidated the two legacy Tauri daemon clients into `src-tauri/src/daemon.rs` and deleted `pty_daemon_client.rs`.
- The replacement client keeps one framed Unix-socket connection, performs the v1 hello handshake, correlates concurrent control replies by request ID, and dispatches unsolicited snapshot/output/status/attention/resync/exit frames.
- Reconnection replays every attachment after its last observed sequence. Failed writes clear the stale connection, and timed-out requests remove their pending entry.
- `SessionManager` is now a compatibility adapter only. It retains the frozen request/response/event models and lifecycle/feedback hooks, but the daemon alone creates PTYs, owns children, streams bytes, resizes, interrupts, kills, reaps, and writes transcripts.
- Attachment now starts during session creation, so lifecycle/status/attention/output/exit events are observed even before a pane becomes visible. Only display bytes wait in a bounded compatibility buffer for the frontend's first resize/write; ended sessions retain those final bytes until renderer readiness without delaying lifecycle cleanup.
- Removed the attach-helper argv path, proxy PTY, direct-spawn fallback, second daemon client, per-request socket protocol, full-screen status polling, and production `portable-pty` dependency. `portable-pty` remains dev-only for isolated legacy classifier/startup unit tests.
- Kept the Tauri command names, `CreateSessionRequest`, `SessionInfo`, `SessionStatus`, `SessionStatusEvent`, `SessionEndEvent`, event channel names, lifecycle files, status/attention behavior, feedback enqueueing, and MCP contract unchanged.
- Tauri now emits raw terminal bytes as JSON byte arrays. The two frontend consumers use `Uint8Array` directly; base64 encoding/decoding and the direct base64 dependency were removed.
- Preserved-behavior integration tests for sessions, persistence/status, and feedback now run against private in-process daemon servers. Tests whose asserted mechanism was explicitly removed (direct-spawn/no-daemon fallback and screen capture polling) were deleted.
- Updated manual probes that referenced removed screen-polling APIs.

## TDD evidence

### RED

1. Baseline and first protocol-client run:
   - `cargo test -p omniagent-ade --lib`
   - `cargo test -p omniagent-ade --test daemon_client_protocol -- --nocapture`
   - Both failed to compile because `daemon.rs` and `pty_daemon_client.rs` still imported the Phase 1-removed `DaemonRequest` and `DaemonResponse`.
2. Daemon-only ownership regression:
   - `cargo test -p omniagent-ade --test daemon_client_protocol session_manager_is_a_daemon_compatibility_adapter_not_a_second_pty_owner -- --exact --nocapture`
   - Failed because the old manager exposed a proxy child PID (`Some(...)`) instead of `None`.
3. Raw-byte frontend event:
   - `npm --prefix ui run test -- --run src/App.usageAnalytics.test.tsx`
   - Failed with token total `0` instead of `105` when the test emitted a byte array; the consumer still expected base64 text.
4. Status compatibility after screen polling removal:
   - `cargo test -p omniagent-ade --test session_persistence_test a_failed_tool_exit_turns_the_light_red_and_writing_clears_it -- --exact --nocapture`
   - Failed because the dismissed error latch still reported `Error` instead of returning to `Ready`.
5. Preserved integration suites initially exposed their old fixture dependency:
   - `session_test`: 6 failures, all `PTY daemon is unavailable`.
   - `feedback_test`: 5 failures, all `PTY daemon is unavailable`.
   - The fixtures were converted to private real daemon servers; their user-behavior assertions were retained.

Intermediate compile failures were not hidden:

- The first lib rebuild still referenced removed proxy-PTY fields/helpers from a superseded natural-exit unit test; that test-only implementation block was removed.
- The reconnect regression initially used a nonexistent `ResponsePayload.value` field; the fixture was corrected to the shared Phase 1 payload type before the behavioral run.
- `cargo check --all-targets` initially found the manual black-pane probe calling the removed screen-polling methods; the probe now observes the raw event stream and daemon session list.

### GREEN

- `cargo test -p omniagent-ade --test daemon_client_protocol`
  - 3 passed: single persistent connection/raw bytes, reconnect with last-sequence reattach, and daemon-only ownership.
- `cargo test -p omniagent-ade --test feedback_test`
  - 5 passed.
- `cargo test -p omniagent-ade --test native_macos_compatibility_test`
  - 2 passed; frozen model fixtures are unchanged.
- `cargo test -p omniagent-ade --test session_persistence_test`
  - 11 passed.
- `cargo test -p omniagent-ade --test session_test`
  - 7 passed.
- `npm --prefix ui run test -- --run`
  - 78 files passed; 1,180 tests passed and 8 skipped.

## Verification

- Changed Rust files: `rustfmt --edition 2021 --check ...` — passed.
- `cargo check -p omniagent-ade --all-targets --all-features` — passed.
- `cargo test -p omniagent-ade -- --skip commands::tests::git_branch_returns_the_checked_out_branch_for_a_real_repo --skip tests::the_titles_version_is_the_one_tauri_conf_json_declares`
  - 198 passed, 0 failed, 2 explicitly filtered pre-existing repository assertions.
- `cargo test -p omniagent-pty-daemon`
  - 18 passed, 0 failed.
- `cargo test -p mcp-server --test contract_test`
  - 10 passed, 0 failed; frozen MCP v1 shapes remain unchanged.
- `npm --prefix ui run build` — passed.
- `cargo build -p omniagent-ade -p omniagent-pty-daemon` — passed.
- `cargo clippy -p omniagent-pty-daemon --all-targets --all-features -- -D warnings` — passed.
- `git diff --check` — passed.
- Legacy audit:
  - `rg "spawn_reader_thread|spawn_session_process|spawn_with_notice|pane_current_command|capture_pane|attach_argv|daemon_attach_command|pty_daemon_client|base64" src-tauri ui/src`
  - No matches.

## Broader-suite baseline failures

- Unfiltered `cargo test -p omniagent-ade --lib` has two unrelated failures already present on this worktree:
  - `git_branch_returns_the_checked_out_branch_for_a_real_repo` hard-codes `main`, but the required worktree branch is `codex/native-macos-migration`.
  - `the_titles_version_is_the_one_tauri_conf_json_declares` compares package `2026.7.28+004` with existing config `2026.7.29+004`.
- `cargo test --workspace` advances through the earlier crates, then stops at the known `brain-ingest` fixture failure `ingest_fixture_mines_git_cochange_between_auth_and_util`; its diagnostic says the seeded `fixtures/sample-project/.git` history is absent.
- Tauri clippy with `-D warnings` is blocked only by six pre-existing `clippy::doc_lazy_continuation` diagnostics in untouched `src-tauri/src/roots.rs:12-17`. The daemon's strict clippy run is clean.
- `cargo fmt --all --check` reports pre-existing formatting drift in untouched manual examples; every Rust file changed by this task passes direct `rustfmt --check`.
- The UI production build retains its pre-existing large-chunk warning.

## Self-review

- The compatibility client uses the daemon's shared `protocol` module rather than duplicating the envelope, message kinds, raw payload codec, or Serde models.
- No Tauri-side PTY handle, writer, child, attach process, or transcript writer remains in production code.
- One mutex serializes framed writes; one reader thread demultiplexes replies and events. User callbacks run outside internal locks.
- Reconnect subscriptions carry their last dispatched sequence. `ResyncRequired` requests a fresh snapshot.
- Kill waits for the daemon response before lifecycle/feedback finalization, preserving transcript-flush ordering.
- Raw bytes remain untouched from daemon payload to Tauri byte-array event to xterm.js.
- No public MCP type or command/event name changed.

## Concerns

- The repository-wide baseline failures above prevent claiming a fully green unfiltered workspace, but none is in Task 3's changed behavior or files.
- The legacy module documentation in `sessions.rs` still contains historical tmux/status investigation notes; executable screen polling and attach/proxy paths are removed.

## Fix round 1 — lifecycle, listener, reconnect, and callback races

### Changes

- Session creation now installs the daemon handler immediately. Snapshot/output bytes are held separately from the live-session registry until renderer readiness, capped at 1 MiB per session; overflow requests a fresh daemon snapshot. Status, attention, resync, and natural exit processing never wait for a visible pane or resize.
- An immediately ended session is removed and its lifecycle/end hook runs at once, while its bounded final display bytes remain available for the later first resize. Intentional kills still finalize synchronously after the daemon's flush/reap acknowledgment, preserving feedback-hook ordering.
- `Terminal.tsx` does not expose its xterm startup function, fit, or initial `sessionResize` until `listen(session-output:...)` resolves successfully. A listener-ready visible pane reschedules startup; cancellation and hidden-pane checks remain in place.
- EOF now starts a proactive reconnect loop whenever handlers remain, with exponential backoff from 50 ms capped at 1 s. Every reconnect replays handlers after their last received sequence without requiring an input/resize/list call.
- User callbacks run on one bounded 64-event worker per attached session, preserving per-session order and keeping the socket reader free for correlated control responses. Overflow collapses to `ResyncRequired`; no thread is created per frame.
- Natural `SessionExited` removes its handler before callback delivery, so reconnect cannot replay a stale attachment.
- The persistent daemon now owns shell busy/ready transitions too: after a submitted command it watches the PTY foreground process group (not terminal snapshots), emits `tool_execution` while a child command owns the foreground, and emits `ready` when control returns to the shell. The current status is queued on every attach, including hidden/immediately attached sessions.

### TDD evidence

RED, before implementation:

- `cargo test -p omniagent-ade --test daemon_client_protocol reconnect_reattaches_after_the_last_observed_sequence -- --exact --nocapture`
  - Failed after 2.22 s with an event-channel timeout; EOF did not reconnect until control input.
- `cargo test -p omniagent-ade --test daemon_client_protocol slow_event_callback_does_not_block_control_responses -- --exact --nocapture`
  - Failed at the 300 ms prompt-response assertion; the reader was blocked inside the callback.
- `cargo test -p omniagent-ade --test daemon_client_protocol session_manager_attaches_during_create_so_early_exit_is_observed -- --exact --nocapture`
  - Failed after 2.97 s with an end-hook timeout; creation had not attached.
- `npm --prefix ui test -- Workspace.visibility.test.tsx -t "does not start or resize until the output listener is registered"`
  - Failed because xterm had already constructed once while the mocked listener promise was unresolved.
- The first broader `feedback_test` run after moving callbacks off-reader exposed an intentional-kill ordering regression: 3 tests failed because the queued exit callback could make `kill()` return before feedback finalization. Intentional kills now finalize synchronously after the daemon acknowledgment.
- `cargo test -p omniagent-ade --test session_persistence_test shell_status_goes_ready_then_tool_execution_then_ready_around_a_real_command -- --exact --nocapture`
  - Failed with `a running command must show tool execution (cyan); saw [Ready]`, exposing that the Phase 1 protocol defined status frames but the persistent server did not yet emit them.

GREEN:

- `cargo test -p omniagent-ade --test daemon_client_protocol`
  - 6 passed, including passive sequence replay, bounded slow-callback dispatch/control response, natural-exit handler removal, and creation-time output/status/attention/exit with final display flush.
- `cargo test -p omniagent-ade --test feedback_test`
  - 5 passed; kill/feedback ordering is preserved.
- `npm --prefix ui test -- Workspace.visibility.test.tsx`
  - 9 passed, including delayed listener registration.
- `npm --prefix ui test`
  - 78 files passed; 1,181 tests passed and 8 skipped.
- `npm --prefix ui run build`
  - Passed.
- `cargo check -p omniagent-ade --all-targets --all-features`
  - Passed.
- `cargo clippy -p omniagent-ade --lib --tests --all-features -- -A clippy::doc_lazy_continuation -D warnings`
  - Passed; the allow covers only the pre-existing untouched `roots.rs` documentation diagnostics recorded above.
- `cargo test -p omniagent-pty-daemon`
  - 19 passed, including `shell_status_tracks_a_silent_foreground_command_without_screen_polling`.
- `cargo test -p omniagent-ade --test session_persistence_test -- --test-threads=1`
  - 11 passed; the real silent `sleep 2` shell transition is green → cyan → green again.
- `cargo test -p mcp-server --test contract_test`
  - 10 passed; frozen MCP shapes remain unchanged.
- Direct `rustfmt --check` on all changed Rust files and `git diff --check`
  - Passed.

### Broader-suite observations

- The unfiltered Tauri lib run remains 170/172 with the two baseline branch/version assertions documented above.
- Persistence-test daemon processes are intentionally persistent and their legacy `ServerGuard` kills sessions but not the server process. The private instances spawned by the failed verification runs were identified by explicit PID/start time, terminated, and a process check confirmed none remained.

## Fix round 2 — exited attach, authoritative shell status, display ordering

### Changes

- The daemon registry now moves naturally exited sessions into a late-attach tombstone rather than dropping the last authoritative state immediately. Tombstones are excluded from active `ListSessions`, retained for at most 10 seconds, and capped at 16 entries. A new session with the same id replaces its old tombstone.
- A tombstone attach uses the unchanged v1 shapes to deliver the terminal snapshot/replay followed by the recorded `SessionExited`. This closes the real create-response → child-exit → registry-removal → Attach race without timing sleeps or a public protocol change.
- Tauri records daemon shell status separately from local activity. `compute_status` still gives attention/error priority, then treats daemon shell `tool_execution`/`ready` as authoritative for poll and pull paths; non-shell agents retain their existing output heuristics.
- Display readiness now has an explicit flushing phase. New callback bytes append while buffered batches drain, concurrent readiness calls wait, and `ready` becomes true only while holding the gate on an atomically empty queue. Sink calls remain outside the gate mutex.

### TDD evidence

RED, before implementation:

- `cargo test -p omniagent-pty-daemon --test server_protocol exited_before_attach_still_replays_snapshot_and_exit -- --exact --nocapture`
  - The test first observed `fast-exit` absent from active `SessionList`, then Attach received `Error` instead of `Snapshot`.
- `cargo test -p omniagent-ade --test session_persistence_test shell_status_goes_ready_then_tool_execution_then_ready_around_a_real_command -- --exact --nocapture`
  - Push observed cyan, but the first pull during the silent `sleep 2` returned `Ready`, proving the 300 ms local classifier overwrote daemon state.
- `cargo test -p omniagent-ade --lib sessions::tests::display_flush_keeps_new_bytes_behind_the_buffered_prefix -- --exact --nocapture`
  - Deterministic blocked-sink orchestration delivered `[new, old]` instead of `[old, new]`.

GREEN:

- The same three focused commands pass.
- `cargo test -p omniagent-ade --test daemon_client_protocol`
  - 6 passed.
- `cargo test -p omniagent-ade --test feedback_test`
  - 5 passed.
- `cargo test -p omniagent-ade --test session_persistence_test -- --test-threads=1`
  - 11 passed, including three repeated authoritative pull assertions while the silent command is running and a final Ready pull.
- `cargo test -p omniagent-pty-daemon --test server_protocol exited_before_attach_still_replays_snapshot_and_exit -- --exact`
  - Real fast child passed: active list removal was observed before Attach, then recoverable `ULTRA_EARLY` snapshot bytes and exit code 7 arrived.
- `cargo test -p omniagent-pty-daemon --test session_runtime shell_status_tracks_a_silent_foreground_command_without_screen_polling -- --exact`
  - Passed.
- `cargo test -p omniagent-ade --lib -- --test-threads=1 --skip commands::tests::git_branch_returns_the_checked_out_branch_for_a_real_repo --skip tests::the_titles_version_is_the_one_tauri_conf_json_declares`
  - 171 passed, 2 known baseline assertions filtered.
- `cargo test -p mcp-server --test contract_test`
  - 10 passed; the frozen v1 MCP contract remains unchanged.
- `npm --prefix ui test`
  - 78 files passed; 1,181 tests passed and 8 skipped.
- `npm --prefix ui run build`
  - Passed; only the existing Vite chunk-size advisory was emitted.
- `cargo check -p omniagent-ade --all-targets --all-features` and warning-as-error Clippy for both changed Rust packages passed.
- `rustfmt --check` passed for every changed Rust file and `git diff --check` passed. Workspace-wide `cargo fmt --all -- --check` still reports only the two pre-existing, unmodified manual-example formatting diffs.

### Verification notes

- The daemon suite's new and changed tests pass. One unmodified scrollback/transcript test intermittently read its transcript before `line-3099` was flushed during the all-tests run; its immediate exact rerun passed.
- A final serial protocol run passed 5/6 while the unmodified `one_persistent_connection_streams_raw_bytes_and_applies_resize` test timed out waiting for its final kill response; two exact attempts reproduced that existing four-second timeout and a subsequent exact run passed. The new exited-before-attach regression remained green throughout.
- Successful persistence runs left no external `omniagent-pty-daemon` process behind; process state is checked again before commit.
