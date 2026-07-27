# Native PTY Daemon Migration (Substituting tmux with omniagent-pty-daemon) Implementation Plan

> **For agentic workers:** Use `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the external `tmux` binary wrapper with `omniagent-pty-daemon` — a pure-Rust, zero-dependency background daemon (`crates/omniagent-pty-daemon`) built with `portable-pty` and `vt100`. This decouples terminal sessions across app restarts, guarantees UTF-8 and environment stability, eliminates `tmux` installation requirements, and enables instant screen restoration.

**Architecture:**
- **Daemon Crate:** `crates/omniagent-pty-daemon` (already created, uses `portable-pty`, `vt100`, `tokio::net::UnixListener`, `base64`).
- **Tauri Client:** `src-tauri/src/pty_daemon_client.rs` — a lightweight async Unix socket client connecting to `~/.omniagent-ade/omniagent-pty.sock`. Auto-spawns the daemon binary if not running.
- **Session Manager:** `src-tauri/src/sessions.rs` — updated to interact with `PtyDaemonClient` instead of shelling out to `tmux`.
- **Status & Interruption:** Native `SendInterrupt` (\x03 SIGINT) and process lifecycle tracking directly through daemon RPC frames.

---

## Task Breakdown

### Task 1: Daemon Client Module & Process Auto-Launcher

**Files:**
- Create: `src-tauri/src/pty_daemon_client.rs`
- Modify: `src-tauri/src/lib.rs` (register module)
- Modify: `src-tauri/Cargo.toml` (add `omniagent-pty-daemon` dependency or IPC socket path)

**Goal:** Build a robust Rust Unix socket client (`PtyDaemonClient`) in `src-tauri` that handles connecting to `omniagent-pty.sock` and automatically launches the `omniagent-pty-daemon` background process if it is not already listening.

- [x] **Step 1: Create `src-tauri/src/pty_daemon_client.rs`**
  Implemented socket connection, RPC request serialization/deserialization, and `ensure_daemon_running()` helper that checks socket liveness and spawns the daemon binary if needed.

- [x] **Step 2: Add RPC request wrappers**
  Implemented methods on `PtyDaemonClient`: `create_session`, `attach_session`, `send_input`, `send_interrupt`, `resize_session`, `list_sessions`, `kill_session`.

- [x] **Step 3: Write unit tests in `pty_daemon_client.rs`**
  Verified socket path resolution and daemon RPC framing. (Committed in `c6b3790`).

---

### Task 2: SessionManager Integration — Substituting `tmux`

**Files:**
- Modify: `src-tauri/src/sessions.rs`
- Remove/Deprecate: `src-tauri/src/tmux.rs`

**Goal:** Refactor `SessionManager::create`, `SessionManager::kill`, and `SessionManager::write` to communicate with `PtyDaemonClient` instead of `crate::tmux`.

- [x] **Step 1: Update session creation flow in `sessions.rs`**
  Replace `Tmux::ensure_session` with `PtyDaemonClient::create_session`. When an existing session is found in the daemon upon app startup, mark `restored = true` and attach to its output stream.

- [x] **Step 2: Update session input and resize handlers**
  Route `SessionManager::write` to `PtyDaemonClient::send_input` and `SessionManager::resize` to `PtyDaemonClient::resize_session`.

- [x] **Step 3: Update session teardown & kill**
  Route `SessionManager::kill` to `PtyDaemonClient::kill_session`.

- [x] **Step 4: Update task interruption methods**
  Connect `session_stop_working_tasks` directly to `PtyDaemonClient::send_interrupt` for active sessions.

---

### Task 3: Screen Restoration & VT100 State Sync

**Files:**
- Modify: `crates/omniagent-pty-daemon/src/lib.rs`
- Modify: `src-tauri/src/sessions.rs`

**Goal:** Enable instant screen state restoration when attaching to an existing daemon session (e.g. after quitting and reopening OmniAgent-ADE).

- [x] **Step 1: Enhance `ManagedSession` in daemon**
  Use `vt100::Parser` in `crates/omniagent-pty-daemon/src/lib.rs` to snapshot formatted screen contents upon attachment request (`AttachSession`).

- [x] **Step 2: Stream screen state upon attachment**
  When a client attaches to a running session, transmit the current `vt100` screen state buffer first so the UI terminal surface updates instantly without waiting for new output.

---

### Task 4: Tauri Commands & Build Integration

**Files:**
- Modify: `src-tauri/src/commands/mod.rs`
- Modify: `src-tauri/src/lib.rs`
- Modify: `Cargo.toml` (workspace members)

**Goal:** Wire daemon management commands into Tauri IPC and ensure `omniagent-pty-daemon` builds cleanly as part of the Tauri workspace build pipeline (`cargo build --workspace`).

- [x] **Step 1: Update Tauri build pipeline**
  Ensure `cargo build --workspace` compiles both `omniagent-ade` and `omniagent-pty-daemon`.

- [x] **Step 2: Add daemon status Tauri command**
  Add `#[tauri::command] pub fn pty_daemon_status() -> Result<DaemonStatusInfo, String>` for debugging in the UI/About panel.

---

### Task 5: Testing & Verification

**Files:**
- Modify: `src-tauri/tests/session_test.rs`

**Goal:** Update all session integration tests to run against the native PTY daemon.

- [x] **Step 1: Run Rust test suite**
  Execute `cargo test -p omniagent-ade` and `cargo test -p omniagent-pty-daemon`.

- [x] **Step 2: Run full UI test suite**
  Execute `npm --prefix ui test` to ensure zero regressions in UI component behavior.
