# Task 3 — Phase 2 Tauri compatibility client

## Implementation

- Consolidated the two legacy Tauri daemon clients into `src-tauri/src/daemon.rs` and deleted `pty_daemon_client.rs`.
- The replacement client keeps one framed Unix-socket connection, performs the v1 hello handshake, correlates concurrent control replies by request ID, and dispatches unsolicited snapshot/output/status/attention/resync/exit frames.
- Reconnection replays every attachment after its last observed sequence. Failed writes clear the stale connection, and timed-out requests remove their pending entry.
- `SessionManager` is now a compatibility adapter only. It retains the frozen request/response/event models and lifecycle/feedback hooks, but the daemon alone creates PTYs, owns children, streams bytes, resizes, interrupts, kills, reaps, and writes transcripts.
- Attachment is lazy on the terminal's first resize/write, after the existing frontend listener is installed, so the initial snapshot cannot race the `session-output:{id}` subscription.
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
