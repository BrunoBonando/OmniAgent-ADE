# Task 2 — Phase 1 versioned persistent daemon protocol

## Implementation

- Replaced newline-delimited per-request JSON with persistent Unix socket connections and the required 16-byte, big-endian v1 envelope.
- Froze all source-plan client kinds at `0x01..0x0b` and server kinds at `0x81..0x8b`; v1 flags are reserved and must be zero.
- Added typed JSON payloads for control messages. `Input`, `Output`, and `Snapshot` carry a length-prefixed UTF-8 session ID followed by untouched raw bytes.
- The daemon now owns the sole PTY, raw input/output stream, resize/interrupt/kill, `vt100` parser, bounded output history, bounded subscriber queues, and monotonic sequence numbers.
- Attach atomically installs a subscriber and either replays retained output after the requested sequence or sends a formatted ANSI snapshot. Empty up-to-date resumes receive a correlated `Response`.
- Slow subscribers cannot block PTY reads: capacity overflow replaces queued output with `ResyncRequired`.
- `vt100` retains 3,000 scrollback lines. Transcripts are independent, append-only, line-buffered, and use the existing `brain_core::redact` security boundary.
- Session creation reserves IDs/capacity under the registry lock, then releases it before PTY/process/filesystem I/O. Kill/shutdown drain registry entries before blocking child/thread work.
- Runtime directories are forced to mode `0700`, sockets to `0600`, and accepted peers must have the runtime directory owner's UID.
- SIGINT/SIGTERM and controlled test shutdown kill sessions, wait for reader/transcript completion, abort client tasks, and remove the socket.
- Removed the daemon attach-helper CLI, 120 ms repaint loop, base64 dependency/data shape, legacy request/response types, and per-request connection path.

## Files

- Modified: `Cargo.lock`
- Modified: `crates/omniagent-pty-daemon/Cargo.toml`
- Replaced: `crates/omniagent-pty-daemon/src/lib.rs`, `crates/omniagent-pty-daemon/src/main.rs`
- Added: `crates/omniagent-pty-daemon/src/protocol.rs`
- Added: `crates/omniagent-pty-daemon/src/server.rs`
- Added: `crates/omniagent-pty-daemon/src/session.rs`
- Added: `crates/omniagent-pty-daemon/tests/protocol.rs`
- Added: `crates/omniagent-pty-daemon/tests/server_protocol.rs`
- Added: `crates/omniagent-pty-daemon/tests/session_runtime.rs`
- No `src-tauri` or Swift file is changed.

## TDD evidence

### RED

1. `cargo test -p omniagent-pty-daemon --test protocol`
   - Failed with `could not find protocol in omniagent_pty_daemon`.
2. `cargo test -p omniagent-pty-daemon --test session_runtime`
   - Failed on missing `AttachState`, `CreateSession`, `SessionEvent`, subscription, attach, and scrollback APIs.
3. `cargo test -p omniagent-pty-daemon --test server_protocol`
   - Failed on missing async frame I/O, `DaemonServer`, and peer UID policy.
4. The first raw socket test timed out because its shell fixture used newline-buffered `read` for non-newline raw bytes. Replacing only the fixture read with fixed-size `dd` made the intended daemon behavior observable.
5. `cargo test -p omniagent-pty-daemon --test protocol deferred_domain_messages_have_frozen_json_payload_shapes`
   - Failed on missing typed status, attention, settings, response, resync, error, and exit payloads.
6. `cargo test -p omniagent-pty-daemon --test session_runtime kill_returns_only_after_exit_is_observable`
   - Failed with immediate `Timeout`, proving kill returned before reader/exit completion.
7. The persistent socket kill test timed out waiting for `SessionExited`, proving explicit kill aborted forwarding too early.
8. `cargo test -p omniagent-pty-daemon --test server_protocol malformed_control_json_closes_an_attached_connection`
   - Timed out because a detached forwarding task retained the socket writer.
9. `cargo test -p omniagent-pty-daemon --test session_runtime transcript_redacts_secrets_before_persisting_them`
   - Failed with the persisted literal `API_KEY=abc123`.
10. The up-to-date attach-resume assertion timed out because an empty replay had no correlated response.

### GREEN

- `cargo test -p omniagent-pty-daemon`
  - 16 passed: 6 protocol, 4 persistent socket/security/concurrency, 6 real PTY/runtime tests; 0 failed.
- Covered behaviors include exact header bytes and IDs, malformed/version/flags/oversize/truncation rejection, raw byte fidelity, real resize, resume/snapshot, bounded slow-client resync, 3,000-line parser vs independent transcript, transcript redaction, synchronous exit, mode/UID policy, malformed attached-client cleanup, eight simultaneous sessions, creator disconnect persistence, reconnect/list/reattach, and socket cleanup.

## Verification

- `cargo fmt -p omniagent-pty-daemon` — passed.
- `cargo test -p omniagent-pty-daemon` — 16 passed, 0 failed.
- `cargo clippy -p omniagent-pty-daemon --all-targets --all-features -- -D warnings` — passed.
- `cargo build -p omniagent-pty-daemon` — passed.
- `cargo test -p mcp-server --test contract_test` — 10 passed, 0 failed; frozen MCP v1 remains unchanged.
- `git diff --check` — passed.
- Legacy audit:
  - `rg "base64|run_attach_mode|data_base64|DaemonRequest|DaemonResponse|from_millis\\(120\\)|read_line|lines\\(\\)" crates/omniagent-pty-daemon`
  - No matches.
- Scope audit: `git diff --quiet -- src-tauri` — clean.

## Self-review

- The envelope validates the payload limit before allocation and rejects unsupported version, kind, and flag values.
- Output history is bounded to 256 PTY chunks (at most 1 MiB with the 4 KiB reader); every subscriber queue is independently bounded.
- Attach registration is performed while terminal state is locked, so output cannot fall into a snapshot/subscription gap.
- Registry locks only reserve, clone, remove, drain, or list entries; PTY spawn, write, resize, kill, wait, transcript I/O, and socket I/O happen after releasing them.
- Explicit kill waits for the reader thread, so transcript flush and `SessionExited` are observable before the correlated response.
- Client attachment teardown is RAII, including malformed-control early returns.
- The existing redaction helper is reused; no new regex/security implementation was added.
- The only added non-test dependency is the existing workspace `brain-core` crate for transcript redaction. `tempfile` is dev-only.
- No MCP model or public MCP shape changed.

## Concerns

- The untouched Phase 2 Tauri clients still import the removed legacy `DaemonRequest`/`DaemonResponse` API and invoke the removed attach-helper CLI. This commit intentionally verifies the authoritative daemon crate only; Task 3 must migrate those clients before the full workspace compiles again.
- `SessionStatus` and `Attention` have frozen payload types/kinds but their domain production remains with the existing Tauri/session layer until its migration.

## Round 1 review fixes

### Implementation

- Kept the exact 11 source-plan server kinds and their existing `0x81..0x8b` discriminants unchanged.
- Wired `SetSetting` and `GetSetting` through the existing `Response` kind and `brain_core::Store` settings table. Set returns `{"ok":true}`; get returns `{"value":<string-or-null>}`, preserving the existing optional-string data behavior and layout JSON byte-for-byte.
- The daemon opens `brain.db` in the service data directory containing its socket. One daemon-owned store connection serves all persistent clients, and SQLite persists values across daemon restarts.
- When `SessionExited` reaches an exactly full subscriber queue, queued output is now replaced with `ResyncRequired`, followed by the exit event. The terminal-marker reservation makes the queue remain bounded while ensuring neither byte-loss notification nor exit observability is sacrificed.

### Focused TDD evidence

Covering test files:

- `crates/omniagent-pty-daemon/tests/server_protocol.rs`
  - `settings_persist_across_connections_and_daemon_restarts`
- `crates/omniagent-pty-daemon/tests/session_runtime.rs`
  - `terminal_exit_after_a_full_output_queue_preserves_resync_and_exit`

RED commands and output:

1. `cargo test -p omniagent-pty-daemon --test server_protocol settings_persist_across_connections_and_daemon_restarts -- --exact`
   - `FAILED`
   - Timed out in `Client::read` with `called Result::unwrap() on an Err value: Elapsed(())` because the daemon emitted `Error` instead of `Response`.
   - `test result: FAILED. 0 passed; 1 failed; 4 filtered out`
2. `cargo test -p omniagent-pty-daemon --test session_runtime terminal_exit_after_a_full_output_queue_preserves_resync_and_exit -- --exact`
   - `FAILED`
   - Failed the first-event assertion because the queue exposed `SessionExited` without `ResyncRequired`.
   - `test result: FAILED. 0 passed; 1 failed; 6 filtered out`

GREEN commands and output:

1. `cargo test -p omniagent-pty-daemon --test server_protocol settings_persist_across_connections_and_daemon_restarts -- --exact`
   - `test settings_persist_across_connections_and_daemon_restarts ... ok`
   - `test result: ok. 1 passed; 0 failed; 4 filtered out`
2. `cargo test -p omniagent-pty-daemon --test session_runtime terminal_exit_after_a_full_output_queue_preserves_resync_and_exit -- --exact`
   - `test terminal_exit_after_a_full_output_queue_preserves_resync_and_exit ... ok`
   - `test result: ok. 1 passed; 0 failed; 6 filtered out`

### Round 1 verification

- `cargo fmt -p omniagent-pty-daemon` — passed.
- `cargo test -p omniagent-pty-daemon` — 18 passed: 6 protocol, 5 persistent socket/server, 7 session runtime; 0 failed.
- `cargo clippy -p omniagent-pty-daemon --all-targets --all-features -- -D warnings` — passed.
- `git diff --check` — passed.
