//! PTY session engine — plain Rust, no Tauri types.
//!
//! This module owns the whole lifecycle of terminal sessions: spawning real
//! PTYs via `portable-pty`, streaming their raw output to whoever is
//! listening (a Tauri event, a test channel, anything implementing
//! [`OutputSink`]), tee-ing a redacted transcript to disk, and reaping
//! children on kill. It is deliberately decoupled from `tauri::AppHandle`/
//! `State` so it can be unit- and integration-tested by just calling Rust
//! functions (see `src-tauri/tests/session_test.rs`) — the thin
//! `#[tauri::command]` wrappers live in `commands.rs` and only adapt this
//! API to Tauri's calling convention.
//!
//! ## On-disk layout (under `<data_dir>/transcripts/`)
//! - `<session-id>.log` — raw PTY output, secret-redacted
//!   ([`brain_core::redact::redact`]), line-buffered so a secret split
//!   across two PTY reads still gets caught before it hits disk.
//! - `<session-id>.lifecycle.jsonl` — one JSON object per line, one line per
//!   lifecycle event. Two shapes (tagged by `"event"`):
//!   ```json
//!   {"event":"start","ts":1753500000,"engine":"claude","project":"demo","cwd":"/path"}
//!   {"event":"end","ts":1753500042,"exit_code":0,"signal":null,"killed":false}
//!   ```
//!   `ts` is unix seconds ([`brain_core::now_ts`]). `exit_code`/`signal` are
//!   `null` when unknown (e.g. the process was still starting up when the
//!   event fired). `killed` is `true` only when `SessionManager::kill` drove
//!   the shutdown, `false` for a natural exit (e.g. the user typed `exit`).
//!
//! ## Zero-config Claude wiring (DESIGN principle 5)
//! When `engine == "claude"`, [`SessionManager::create`] resolves the
//! `omniagent-mcp` binary built from this same workspace
//! ([`resolve_mcp_server_binary`]), writes a throwaway `--mcp-config` JSON
//! file registering it (with `OMNIAGENT_ADE_DATA_DIR` set in its `env`
//! block), and — if a `briefing` was supplied — forwards it verbatim via
//! `--append-system-prompt`. If the MCP binary can't be found, `claude` is
//! still spawned, just without that flag (logged, never a hard failure —
//! see [`resolve_mcp_server_binary`]'s doc comment for why). `codex` and
//! `shell` are spawned completely stock: no injected flags, nothing written
//! to the user's own `~/.claude/*`, project `CLAUDE.md`, or any global MCP
//! config — every bit of wiring is a per-invocation CLI flag on the child
//! process we spawn, never a file we edit.
//!
//! ## Attention detection (founder feedback, 2026-07-24)
//! Bruno: "every claude session[...] can notify the app whenever it needs
//! attention[...] that session can require attention, generate a badge".
//! Investigated three candidate signals before picking one:
//!
//! 1. **Claude Code's `Notification` hook event** — real, but every way to
//!    wire it (`~/.claude/settings.json`, a project's `.claude/settings.
//!    json`) requires the user to configure their own install, which is
//!    exactly what DESIGN principle 5 rules out. `claude --help` has no
//!    per-invocation hook flag (`--settings <file-or-json>` loads *general*
//!    settings for one invocation — same throwaway-file trick this module
//!    already uses for `--mcp-config` — but hooks specifically shell out to
//!    an arbitrary command, and configuring that non-interactively still
//!    reads as "asking the user to set something up" the moment it's their
//!    own persistent `settings.json` a plain terminal `claude` would also
//!    see; a throwaway `--settings` hook would be per-invocation and
//!    config-free in principle, but see #2 below for why a PTY-stream
//!    signal made this moot). Ruled out as the primary mechanism.
//! 2. **Plain BEL (`0x07`)** — empirically, stock `claude` (2.1.219) only
//!    ever emits `0x07` as the string terminator of `OSC` escape sequences
//!    (window-title updates, `ESC ] 0 ; <title> BEL`), which fire
//!    continuously during any activity (every spinner frame), not
//!    specifically at attention-worthy moments. A raw BEL count is pure
//!    noise here — verified by driving a real `claude` session through a
//!    Python-PTY probe and diffing BEL positions against a hex dump; every
//!    single occurrence traced back to a title-terminator, none to a
//!    standalone "ring the bell" gesture. Ruled out.
//! 3. **`OSC 777 notify` (`ESC ] 777 ; notify ; warp://cli-agent ; <json>
//!    BEL`)** — real, structured, and genuinely tempting: stock `claude`
//!    emits this with a machine-readable `{"event": "..."}` payload
//!    (`permission_request`, `stop`, `idle_prompt`, etc. — exactly the
//!    taxonomy Bruno described) whenever it's running with
//!    `TERM_PROGRAM=WarpTerminal` in its environment. But it's gated behind
//!    more than that single env var (setting only `TERM_PROGRAM` while
//!    stripping the rest of Warp's `WARP_*` vars does **not** unlock it —
//!    verified empirically), and reverse-engineering the rest of an
//!    undocumented, third-party terminal's proprietary detection heuristic
//!    just to spoof it crosses the line DESIGN principle 5 draws ("the
//!    engine runs completely unmodified... exactly as in a plain
//!    terminal") — we'd be lying to `claude` about its host, not just
//!    observing its stock behavior. Ruled out as something to build on,
//!    even though it's a genuinely interesting integration to know about.
//!
//! **What's actually implemented**: plain-text pattern matching on the raw
//! PTY stream for the literal marker `"Do you want to proceed?"` /
//! `"Do you want to"` ([`ATTENTION_MARKERS`]) — the exact copy stock
//! `claude` prints in its tool-permission confirmation dialog (verified
//! against both a Bash-tool and a Write-tool prompt; the two use different
//! trailing wording — "...proceed?" vs "...create notes.txt?" — but share
//! the "Do you want to" opening, which is what's actually matched). This is
//! honestly the fragile, version-coupled fallback the founder brief itself
//! anticipated ("don't force a solution that doesn't reflect reality") —
//! it requires zero configuration and zero engine spoofing, which is the
//! one property that mattered most here. Not hard-gated to `engine ==
//! "claude"` (see `spawn_reader_thread`'s doc comment for why — in short,
//! that would make it untestable through a real PTY without an actual
//! `claude` process, network access, and a live conversation); in practice
//! this is still effectively Claude-specific, since it's Claude Code's own
//! UI copy no other stock engine would print. Matches are debounced per
//! session via [`AttentionDebouncer`] so a single pending prompt's redraw
//! storm (dozens of re-renders a second while nothing has actually changed)
//! fires one
//! event, not hundreds.

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;

use brain_core::{now_ts, redact::redact};

/// A callback invoked with `(session_id, raw_chunk)` for every chunk read
/// from a session's PTY, in real time, un-redacted (this is the "live
/// terminal" feed — redaction only applies to the on-disk transcript, see
/// module docs). The Tauri wrapper in `lib.rs` supplies one that calls
/// `app_handle.emit(&format!("session-output:{id}"), base64_of(chunk))`;
/// tests supply one that pushes to an `mpsc` channel.
pub type OutputSink = Arc<dyn Fn(&str, &[u8]) + Send + Sync>;

/// Everything Phase 7's feedback loop needs to know about a session that
/// just ended — the argument to [`SessionEndHook`]. Fired once per session,
/// whichever way it ended (see [`SessionManager::kill`] and the natural-exit
/// path in `spawn_reader_thread`), always *after* the transcript's final
/// flush is guaranteed on disk (same ordering guarantee `kill()` already
/// gives its callers for the transcript file itself — see the module docs
/// on `SessionHandle::reader_thread`), so `event.transcript_path` is always
/// safe to read in full by the time a hook observes it.
#[derive(Debug, Clone)]
pub struct SessionEndEvent {
    pub id: String,
    pub project: String,
    pub cwd: String,
    pub engine: String,
    pub transcript_path: PathBuf,
}

/// Invoked once per ended session — the hook point PLAN.md's Task 7.1 names
/// ("extend `sessions.rs`'s kill/exit path"). `lib.rs` wires this at boot
/// (via [`SessionManager::with_end_hook`]) to `feedback::on_session_end`,
/// which enqueues the `session_summary` enrichment job; plain
/// `SessionManager::new` callers (most existing tests) get no hook at all —
/// this is additive, not a required wiring step for every caller.
pub type SessionEndHook = Arc<dyn Fn(&SessionEndEvent) + Send + Sync>;

/// Invoked with just the session id when the PTY reader thread decides a
/// live session needs the user's attention (see the module docs' "Attention
/// detection" section for what triggers this and why). `lib.rs` wires this
/// at boot to emit `session-attention:{id}`, matching the existing
/// `session-output:{id}` naming convention; tests supply one that pushes to
/// a channel. Already debounced per session ([`AttentionDebouncer`]) by the
/// time this is called — callers don't need their own rate limiting.
pub type AttentionSink = Arc<dyn Fn(&str) + Send + Sync>;

/// Public shape returned by `session_create` — the Task 5.2 UI contract.
#[derive(Debug, Clone, Serialize)]
pub struct SessionInfo {
    pub id: String,
    pub project: String,
    pub engine: String,
    pub cwd: String,
    pub created: i64,
}

/// Input to [`SessionManager::create`]. `engine` must be `"claude"`,
/// `"codex"`, or `"shell"`. `briefing`, when `Some`, is forwarded verbatim
/// to `claude --append-system-prompt` — this module does not generate or
/// interpret its contents (that's Task 5.2 / `get_context`'s job).
#[derive(Debug, Clone, Default)]
pub struct CreateSessionRequest {
    pub project: String,
    pub engine: String,
    pub cwd: String,
    pub briefing: Option<String>,
}

/// Everything needed to keep one live PTY session going.
struct SessionHandle {
    master: Box<dyn MasterPty + Send>,
    writer: Box<dyn Write + Send>,
    child: Box<dyn Child + Send + Sync>,
    /// Temp `--mcp-config` file for `claude` sessions, if any; removed on
    /// kill/natural-exit cleanup.
    mcp_config_path: Option<PathBuf>,
    /// Carried from the original `CreateSessionRequest` purely so
    /// [`SessionManager::kill`] can build a [`SessionEndEvent`] without a
    /// second lookup once the handle's already been removed from the
    /// registry (see `kill`'s body) — nothing PTY-related reads these.
    project: String,
    cwd: String,
    engine: String,
    /// The background PTY-reader thread (see `spawn_reader_thread`).
    /// `SessionManager::kill` joins this before returning, so the transcript's
    /// final flush is guaranteed to have happened by the time `kill()`
    /// returns — important because a fullscreen-TUI engine (Claude's own
    /// interactive UI redraws via `\r` + cursor-position escapes, not bare
    /// `\n`) can leave content sitting in the line-buffered redaction
    /// buffer for a long time with nothing to flush it until EOF; without
    /// joining, a caller that exits its own process right after `kill()`
    /// could race this detached thread and lose that final flush.
    reader_thread: thread::JoinHandle<()>,
}

/// The PTY session registry. One instance lives for the app's lifetime
/// (managed Tauri state in `lib.rs`); tests construct their own with a
/// scratch data dir and an in-memory sink.
pub struct SessionManager {
    data_dir: PathBuf,
    sink: OutputSink,
    sessions: Arc<Mutex<HashMap<String, SessionHandle>>>,
    /// Phase 7 feedback-loop hook, `None` by default (see [`SessionEndHook`]
    /// and [`SessionManager::with_end_hook`]).
    on_end: Option<SessionEndHook>,
    /// Founder-feedback attention hook, `None` by default (see
    /// [`AttentionSink`] and [`SessionManager::with_attention_sink`]).
    on_attention: Option<AttentionSink>,
}

impl SessionManager {
    pub fn new(data_dir: PathBuf, sink: OutputSink) -> Self {
        let _ = std::fs::create_dir_all(transcripts_dir(&data_dir));
        Self {
            data_dir,
            sink,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            on_end: None,
            on_attention: None,
        }
    }

    /// Builder-style setter for the Phase 7 feedback-loop hook. `lib.rs`
    /// calls this once at boot, after constructing the manager, to register
    /// `feedback::on_session_end`. Kept as a separate setter rather than a
    /// third `new()` parameter so every existing `SessionManager::new(...)`
    /// call site (this file's own tests, `session_test.rs`, ...) keeps
    /// compiling unchanged — the feedback loop is additive wiring, not a
    /// required constructor argument.
    pub fn with_end_hook(mut self, hook: SessionEndHook) -> Self {
        self.on_end = Some(hook);
        self
    }

    /// Builder-style setter for the founder-feedback attention hook —
    /// same additive shape as [`with_end_hook`](Self::with_end_hook) and for
    /// the same reason: every existing `SessionManager::new(...)` call site
    /// keeps compiling unchanged. `lib.rs` calls this once at boot to wire
    /// `session-attention:{id}` emission; most tests never call it, which
    /// makes the reader thread skip the (cheap but non-zero) detection work
    /// entirely — see `spawn_reader_thread`.
    pub fn with_attention_sink(mut self, sink: AttentionSink) -> Self {
        self.on_attention = Some(sink);
        self
    }

    /// Spawns a real PTY running the requested engine and registers it.
    /// Starts a background reader thread that feeds `self.sink` and the
    /// redacted transcript file.
    pub fn create(&self, req: CreateSessionRequest) -> Result<SessionInfo> {
        let id = generate_session_id();
        let created = now_ts();

        std::fs::create_dir_all(transcripts_dir(&self.data_dir))
            .context("create transcripts dir")?;

        let (cmd, mcp_config_path) = build_command(&req, &self.data_dir, &id)?;

        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows: 24,
                cols: 80,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("open pty")?;

        let reader = pair.master.try_clone_reader().context("clone pty reader")?;
        let writer = pair.master.take_writer().context("take pty writer")?;
        let child = pair.slave.spawn_command(cmd).context("spawn engine process")?;
        // Crucial: drop our own handle to the slave side. If we keep it
        // open, the kernel won't deliver EOF/EIO to the master reader when
        // the child exits (our fd would still be holding the slave open),
        // and the reader thread would never terminate / reap naturally.
        drop(pair.slave);

        let lifecycle_path = lifecycle_path(&self.data_dir, &id);
        append_lifecycle_event(
            &lifecycle_path,
            &LifecycleEvent::Start {
                ts: created,
                engine: req.engine.clone(),
                project: req.project.clone(),
                cwd: req.cwd.clone(),
            },
        )
        .context("write start lifecycle event")?;

        let info = SessionInfo {
            id: id.clone(),
            project: req.project.clone(),
            engine: req.engine.clone(),
            cwd: req.cwd.clone(),
            created,
        };

        let reader_thread = spawn_reader_thread(
            id.clone(),
            reader,
            transcript_path(&self.data_dir, &info.id),
            lifecycle_path,
            self.sink.clone(),
            Arc::clone(&self.sessions),
            self.on_end.clone(),
            self.on_attention.clone(),
            req.project.clone(),
            req.cwd.clone(),
            req.engine.clone(),
        );

        let handle = SessionHandle {
            master: pair.master,
            writer,
            child,
            mcp_config_path,
            project: req.project.clone(),
            cwd: req.cwd.clone(),
            engine: req.engine.clone(),
            reader_thread,
        };

        self.sessions.lock().unwrap().insert(id, handle);

        Ok(info)
    }

    /// Writes raw bytes to a session's PTY (keystrokes, pasted text, etc).
    pub fn write(&self, id: &str, data: &str) -> Result<()> {
        let mut sessions = self.sessions.lock().unwrap();
        let handle = sessions
            .get_mut(id)
            .ok_or_else(|| anyhow!("no such session: {id}"))?;
        handle.writer.write_all(data.as_bytes())?;
        handle.writer.flush()?;
        Ok(())
    }

    /// Resizes the PTY (call on terminal-pane resize / fit-addon changes).
    pub fn resize(&self, id: &str, cols: u16, rows: u16) -> Result<()> {
        let sessions = self.sessions.lock().unwrap();
        let handle = sessions
            .get(id)
            .ok_or_else(|| anyhow!("no such session: {id}"))?;
        handle
            .master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("resize pty")?;
        Ok(())
    }

    /// Kills a session's process and synchronously reaps it (no zombies).
    /// `Child::kill` (portable-pty) sends SIGHUP with a short grace period
    /// before escalating to SIGKILL on unix; we always follow up with an
    /// explicit `wait()` so the process is fully reaped by the time this
    /// returns, even on the SIGKILL path where `kill()` alone doesn't wait.
    /// (If `kill()` already reaped during its own grace-period polling, the
    /// second `wait()` harmlessly errors with ECHILD — ignored.)
    pub fn kill(&self, id: &str) -> Result<()> {
        let mut handle = {
            let mut sessions = self.sessions.lock().unwrap();
            sessions
                .remove(id)
                .ok_or_else(|| anyhow!("no such session: {id}"))?
        };

        let _ = handle.child.kill();
        let status = handle.child.wait();

        cleanup_mcp_config(&handle.mcp_config_path);

        let _ = append_lifecycle_event(
            &lifecycle_path(&self.data_dir, id),
            &LifecycleEvent::End {
                ts: now_ts(),
                exit_code: status.as_ref().ok().map(|s| s.exit_code()),
                signal: status
                    .as_ref()
                    .ok()
                    .and_then(|s| s.signal().map(|s| s.to_string())),
                killed: true,
            },
        );

        // Explicitly close our master/writer fds so the reader thread's
        // blocked `read()` unblocks with EOF/EIO right away (it's already
        // unblocking on its own now that the child is reaped, but do this
        // for determinism), then join it: this guarantees any transcript
        // content still sitting in its line-buffer gets redacted + flushed
        // to disk before `kill()` returns, rather than racing a detached
        // thread against our caller's own next move (e.g. reading the
        // transcript file, or the whole process exiting).
        drop(handle.writer);
        drop(handle.master);
        let _ = handle.reader_thread.join();

        // Phase 7 feedback loop: fire only after the join above, so the
        // hook (which reads the transcript file's tail) always sees the
        // final flush, never a partial line still sitting in the reader
        // thread's buffer.
        if let Some(hook) = &self.on_end {
            hook(&SessionEndEvent {
                id: id.to_string(),
                project: handle.project,
                cwd: handle.cwd,
                engine: handle.engine,
                transcript_path: transcript_path(&self.data_dir, id),
            });
        }

        Ok(())
    }

    /// OS pid of a live session's child process. Not part of the frozen
    /// Tauri-command contract — used by tests to verify reaping, and
    /// earmarked for the DESIGN 3.1 machine-pressure badge (CPU/RAM per
    /// session) later.
    pub fn pid(&self, id: &str) -> Option<u32> {
        let sessions = self.sessions.lock().unwrap();
        sessions.get(id)?.child.process_id()
    }
}

fn transcripts_dir(data_dir: &Path) -> PathBuf {
    data_dir.join("transcripts")
}

fn transcript_path(data_dir: &Path, id: &str) -> PathBuf {
    transcripts_dir(data_dir).join(format!("{id}.log"))
}

fn lifecycle_path(data_dir: &Path, id: &str) -> PathBuf {
    transcripts_dir(data_dir).join(format!("{id}.lifecycle.jsonl"))
}

static SESSION_COUNTER: AtomicU64 = AtomicU64::new(0);

/// `sess-<nanos-since-epoch-hex>-<counter-hex>` — unique within a process
/// lifetime without pulling in a UUID dependency for what is purely a local,
/// in-memory-registry key.
fn generate_session_id() -> String {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let seq = SESSION_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("sess-{nanos:x}-{seq:x}")
}

/// Builds the `CommandBuilder` for a session request, plus the `--mcp-config`
/// temp-file path for `claude` sessions (so it can be cleaned up on kill).
fn build_command(
    req: &CreateSessionRequest,
    data_dir: &Path,
    session_id: &str,
) -> Result<(CommandBuilder, Option<PathBuf>)> {
    match req.engine.as_str() {
        "shell" => {
            let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
            let mut cmd = CommandBuilder::new(shell);
            cmd.cwd(&req.cwd);
            Ok((cmd, None))
        }
        "codex" => {
            // Stock spawn — no flags, nothing injected (Zero-config
            // principle: only `claude` gets ADE wiring in this task).
            let mut cmd = CommandBuilder::new("codex");
            cmd.cwd(&req.cwd);
            Ok((cmd, None))
        }
        "claude" => {
            let mut cmd = CommandBuilder::new("claude");
            cmd.cwd(&req.cwd);

            let mcp_config_path = match resolve_mcp_server_binary() {
                Some(bin) => {
                    let cfg_path = write_mcp_config(&bin, data_dir, session_id)
                        .context("write mcp config")?;
                    cmd.arg("--mcp-config");
                    cmd.arg(&cfg_path);
                    Some(cfg_path)
                }
                None => {
                    eprintln!(
                        "omniagent-ade: omniagent-mcp binary not found next to the app \
                         binary; launching claude for session {session_id} without ADE's \
                         MCP wiring (briefing, if any, still applies)"
                    );
                    None
                }
            };

            if let Some(briefing) = &req.briefing {
                cmd.arg("--append-system-prompt");
                cmd.arg(briefing);
            }

            Ok((cmd, mcp_config_path))
        }
        other => Err(anyhow!(
            "unsupported engine: {other:?} (expected \"claude\", \"codex\", or \"shell\")"
        )),
    }
}

/// Locates the `omniagent-mcp` binary built from this same workspace,
/// relative to the currently running app binary.
///
/// - **Dev** (`cargo tauri dev` / `cargo test`): both binaries land in the
///   same Cargo `target/{debug,release}/` directory, so they're plain
///   siblings.
/// - **Release bundle**: the app binary lives at
///   `OmniAgent.app/Contents/MacOS/omniagent-ade`; we look for
///   `OmniAgent.app/Contents/Resources/omniagent-mcp`.
///   TODO(Phase 8 packaging): nothing copies `omniagent-mcp` into
///   `Contents/Resources` yet — add it to `bundle.resources` in
///   `src-tauri/tauri.conf.json` (or wire it as a Tauri sidecar binary)
///   when Task 8.2 sets up `tauri build`. Until then, release builds will
///   hit the "binary not found" fallback below and Claude sessions launch
///   without MCP wiring — degraded but not broken (DESIGN 5.1: still fully
///   usable, terminals + lexical still work offline-style).
///
/// Returns `None` rather than erroring if it can't be found anywhere —
/// callers must treat that as "spawn claude without `--mcp-config`", never
/// a hard failure per DESIGN principle 5 (the engine must always still run).
pub fn resolve_mcp_server_binary() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    resolve_mcp_server_binary_from(&exe)
}

/// Pure, testable core of [`resolve_mcp_server_binary`]: given the path to
/// the running app binary, find the sibling `omniagent-mcp` binary.
pub fn resolve_mcp_server_binary_from(exe: &Path) -> Option<PathBuf> {
    let dir = exe.parent()?;

    let sibling = dir.join("omniagent-mcp");
    if sibling.is_file() {
        return Some(sibling);
    }

    // .app bundle layout: Contents/MacOS/<exe> -> Contents/Resources/omniagent-mcp
    let resources = dir.parent()?.join("Resources").join("omniagent-mcp");
    if resources.is_file() {
        return Some(resources);
    }

    None
}

fn write_mcp_config(mcp_binary: &Path, data_dir: &Path, session_id: &str) -> Result<PathBuf> {
    let config = serde_json::json!({
        "mcpServers": {
            "omniagent": {
                "command": mcp_binary.to_string_lossy(),
                "args": [],
                "env": {
                    "OMNIAGENT_ADE_DATA_DIR": data_dir.to_string_lossy(),
                }
            }
        }
    });
    let path = std::env::temp_dir().join(format!("omniagent-ade-mcp-{session_id}.json"));
    std::fs::write(&path, serde_json::to_vec_pretty(&config)?)
        .with_context(|| format!("write mcp config to {}", path.display()))?;
    Ok(path)
}

fn cleanup_mcp_config(path: &Option<PathBuf>) {
    if let Some(p) = path {
        let _ = std::fs::remove_file(p);
    }
}

#[derive(Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
enum LifecycleEvent {
    Start {
        ts: i64,
        engine: String,
        project: String,
        cwd: String,
    },
    End {
        ts: i64,
        exit_code: Option<u32>,
        signal: Option<String>,
        killed: bool,
    },
}

fn append_lifecycle_event(path: &Path, event: &LifecycleEvent) -> Result<()> {
    let mut f = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .with_context(|| format!("open lifecycle file {}", path.display()))?;
    let line = serde_json::to_string(event)?;
    writeln!(f, "{line}")?;
    Ok(())
}

/// Spawns the background thread that drains a session's PTY: forwards every
/// raw chunk to `sink` immediately (live terminal feed), and separately
/// line-buffers + redacts + appends to the transcript file. Line-buffering
/// the transcript (instead of redacting each raw chunk independently) means
/// a secret whose bytes happen to land in two different `read()` calls
/// still gets redacted, as long as it doesn't span a newline.
///
/// On EOF, best-effort reaps the child *only if* the session is still in
/// the registry (i.e. nobody has already called `SessionManager::kill`,
/// which removes it and reaps synchronously itself) — this covers natural
/// exits (e.g. the user typing `exit` in a shell session) so those don't
/// leave zombies either. Also fires the Phase 7 `on_end` hook (if any) on
/// that same natural-exit path — `SessionManager::kill` fires it itself for
/// the explicit-kill path, so between the two, every session end is
/// covered exactly once.
///
/// Also runs the founder-feedback attention detection (module docs'
/// "Attention detection" section) when `on_attention` is `Some` and
/// `on_attention` is `Some` — scanning every chunk against a small rolling
/// window (`ATTENTION_MARKERS`) and firing through it, debounced per session
/// by `AttentionDebouncer`. Skipped entirely (not just a no-op check) when
/// no sink was registered, so this adds zero work to the common test/
/// manual-example path that doesn't care. Not hard-gated to `engine ==
/// "claude"` even though `ATTENTION_MARKERS` is Claude-Code-specific UI
/// copy: in practice only a `claude` session's own TUI would ever produce
/// it, and gating on the engine string would make this untestable through a
/// real PTY without spawning an actual `claude` process (network calls, a
/// live API key, and an interactive trust/permission dance an automated
/// test can't drive) — `attention_marker_burst_fires_exactly_one_debounced_
/// event` in `tests/session_test.rs` instead proves the wiring the same
/// dependency-free way the existing redaction test does, with a `shell`
/// session `echo`ing the marker text.
#[allow(clippy::too_many_arguments)]
fn spawn_reader_thread(
    id: String,
    mut reader: Box<dyn Read + Send>,
    transcript_path: PathBuf,
    lifecycle_path: PathBuf,
    sink: OutputSink,
    sessions: Arc<Mutex<HashMap<String, SessionHandle>>>,
    on_end: Option<SessionEndHook>,
    on_attention: Option<AttentionSink>,
    project: String,
    cwd: String,
    engine: String,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut transcript_file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&transcript_path)
            .ok();

        let mut pending = String::new();
        let mut buf = [0u8; 8192];
        // Decodes chunks for the transcript/attention paths only (see its
        // doc comment) — buffers an incomplete trailing multi-byte
        // sequence across reads instead of lossy-converting each raw
        // chunk independently, which would otherwise corrupt any
        // multi-byte character split across two `read()`s. The raw
        // `chunk` handed to `sink` below is untouched by this.
        let mut utf8_decoder = Utf8ChunkDecoder::new();

        // Attention detection only runs when a sink is actually registered
        // (see this function's doc comment for why it's not also hard-gated
        // to `engine == "claude"`).
        let watch_for_attention = on_attention.is_some();
        let mut attention_window = String::new();
        let mut attention_debouncer = AttentionDebouncer::new(ATTENTION_COOLDOWN);

        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let chunk = &buf[..n];
                    sink(&id, chunk);

                    // Decoded once per chunk and reused for both
                    // consumers below — they observe the identical raw
                    // byte stream, so a character split across two reads
                    // must reassemble identically for each.
                    let decoded = utf8_decoder.decode(chunk);

                    if watch_for_attention {
                        attention_window.push_str(&decoded);
                        trim_to_last_n_bytes(&mut attention_window, ATTENTION_WINDOW_BYTES);
                        if contains_attention_marker(&attention_window)
                            && attention_debouncer.should_fire(Instant::now())
                        {
                            if let Some(attention_sink) = &on_attention {
                                attention_sink(&id);
                            }
                        }
                    }

                    pending.push_str(&decoded);
                    flush_complete_lines(&mut pending, &mut transcript_file);
                }
                Err(_) => break,
            }
        }

        // EOF: flush any incomplete trailing sequence still held by the
        // decoder (see `Utf8ChunkDecoder::finish`'s doc comment) before
        // the final pending flush below, so the last few bytes of a
        // torn-off character at the very end of the stream aren't
        // silently lost.
        pending.push_str(&utf8_decoder.finish());

        if !pending.is_empty() {
            write_redacted(&mut transcript_file, &pending);
        }

        // Remove the handle from the registry and let the lock drop
        // immediately (end of this block) *before* the blocking
        // `child.wait()` and filesystem cleanup below -- matching
        // `SessionManager::kill`'s pattern exactly. Holding the registry
        // lock across those would stall every other session's write/
        // resize/kill/create for as long as this reap takes.
        let mut handle = {
            let mut sessions = sessions.lock().unwrap();
            match sessions.remove(&id) {
                Some(h) => h,
                None => {
                    // Already removed+reaped by SessionManager::kill; that
                    // call already wrote its own "end" lifecycle event.
                    return;
                }
            }
        };

        // Not already handled by an explicit kill: this is a natural
        // exit. Reap it so it doesn't zombie -- unlocked, same as kill().
        let status = handle.child.wait();
        cleanup_mcp_config(&handle.mcp_config_path);
        let exit_code = status.as_ref().ok().map(|s| s.exit_code());
        let signal = status.as_ref().ok().and_then(|s| s.signal().map(String::from));

        let _ = append_lifecycle_event(
            &lifecycle_path,
            &LifecycleEvent::End {
                ts: now_ts(),
                exit_code,
                signal,
                killed: false,
            },
        );

        if let Some(hook) = &on_end {
            hook(&SessionEndEvent {
                id,
                project,
                cwd,
                engine,
                transcript_path,
            });
        }
    })
}

/// Incrementally decodes a stream of raw PTY byte chunks as UTF-8,
/// buffering any incomplete trailing multi-byte sequence across calls
/// instead of lossy-converting each raw `read()` result independently.
///
/// PTY `read()`s aren't UTF-8-boundary-aligned: a multi-byte character
/// (box-drawing glyphs like `─│╭╮╰╯` from a TUI redraw, emoji, non-ASCII
/// text) can have its bytes split across two separate reads. Calling
/// `String::from_utf8_lossy` on each raw chunk independently (the bug this
/// type fixes) replaces *both* halves with `U+FFFD`, since neither half is
/// valid UTF-8 on its own, even though the two halves concatenated are
/// perfectly valid. This type instead keeps up to 3 trailing undecoded
/// bytes (the most a valid UTF-8 sequence can still be missing) from one
/// `decode()` call, prepends them to the next chunk, and only
/// lossy-converts the portion that's genuinely, unambiguously invalid —
/// using `std::str::from_utf8`'s error to distinguish "incomplete, might
/// still become valid" (`error_len() == None`, at the very end of the
/// slice) from "genuinely invalid" (`error_len() == Some(_)`), exactly how
/// a streaming UTF-8 decoder is supposed to work.
///
/// Deliberately NOT used for the raw byte stream handed to `sink` (the
/// live terminal view) — xterm.js handles raw bytes correctly on its own,
/// and buffering there would add latency to the live render path for zero
/// benefit. Only the transcript (`pending`) and attention-detection
/// (`attention_window`) paths, which both need real decoded text rather
/// than raw bytes, go through this.
struct Utf8ChunkDecoder {
    /// Trailing bytes from the previous `decode()` call that didn't form a
    /// complete, valid UTF-8 sequence yet — never more than 3 bytes (the
    /// longest a UTF-8 sequence can be missing and still possibly become
    /// valid with more bytes).
    carry: Vec<u8>,
}

impl Utf8ChunkDecoder {
    fn new() -> Self {
        Self { carry: Vec::new() }
    }

    /// Decodes one raw chunk, prepending any carry-over from the previous
    /// call. Returns the decoded text; any incomplete trailing sequence is
    /// retained internally rather than returned, to be prepended to the
    /// *next* `decode()` call.
    fn decode(&mut self, chunk: &[u8]) -> String {
        self.carry.extend_from_slice(chunk);

        let mut out = String::new();
        let mut start = 0usize;
        loop {
            match std::str::from_utf8(&self.carry[start..]) {
                Ok(s) => {
                    out.push_str(s);
                    self.carry.clear();
                    return out;
                }
                Err(e) => {
                    let valid_up_to = e.valid_up_to();
                    // Safe: `from_utf8` already told us this sub-slice is
                    // valid UTF-8.
                    out.push_str(
                        std::str::from_utf8(&self.carry[start..start + valid_up_to]).unwrap(),
                    );
                    match e.error_len() {
                        Some(bad_len) => {
                            // A genuinely invalid byte sequence (not just
                            // incomplete) -- lossy-replace it, same as
                            // `from_utf8_lossy` would, and keep decoding
                            // whatever comes after it in this same chunk.
                            out.push('\u{FFFD}');
                            start += valid_up_to + bad_len;
                        }
                        None => {
                            // The tail is a valid-so-far but incomplete
                            // sequence (ran out of bytes, not into a bad
                            // one) -- carry it over instead of guessing.
                            let tail = self.carry[start + valid_up_to..].to_vec();
                            self.carry = tail;
                            return out;
                        }
                    }
                }
            }
        }
    }

    /// Call once at EOF: there's no more data coming, so any bytes still
    /// held in `carry` are genuinely incomplete (not just "waiting for the
    /// next chunk") and are lossy-replaced rather than silently dropped —
    /// matching `from_utf8_lossy`'s behavior for the same bytes.
    fn finish(&mut self) -> String {
        if self.carry.is_empty() {
            return String::new();
        }
        let out = String::from_utf8_lossy(&self.carry).into_owned();
        self.carry.clear();
        out
    }
}

fn flush_complete_lines(pending: &mut String, file: &mut Option<std::fs::File>) {
    if let Some(idx) = pending.rfind('\n') {
        let split_at = idx + 1;
        let complete: String = pending.drain(..split_at).collect();
        write_redacted(file, &complete);
    }
}

fn write_redacted(file: &mut Option<std::fs::File>, text: &str) {
    if let Some(f) = file {
        let redacted = redact(text);
        let _ = f.write_all(redacted.as_bytes());
        let _ = f.flush();
    }
}

// -------------------------------------------------------------------------
// Founder-feedback attention detection (see module docs for the
// investigation this came out of).
// -------------------------------------------------------------------------

/// Text stock `claude` prints when it genuinely needs the user — currently
/// just the shared opening of its tool-permission confirmation dialog
/// (verified against both a Bash-tool prompt, "Do you want to proceed?",
/// and a Write-tool prompt, "Do you want to create notes.txt?" — the
/// trailing wording differs per tool, the opening doesn't). A list, not a
/// single `&str`, so a future marker (a different dialog's wording, if one
/// turns out not to share this opening) is a one-line addition, not a
/// matching-logic change.
const ATTENTION_MARKERS: &[&str] = &["Do you want to"];

/// How much of the raw (un-redacted) output stream is kept around purely to
/// catch an `ATTENTION_MARKERS` entry split across two PTY `read()` calls.
/// Unlike the transcript's line-buffered redaction, this can't wait for a
/// bare `\n` to flush before checking — Claude's full-screen TUI redraws
/// with cursor-positioning escapes and `\r`, not bare newlines (see the
/// module docs on why the transcript logic has the same problem) — so this
/// is just a small rolling window instead. The longest marker here is well
/// under 64 bytes; 4096 is generous slack for a cheap `contains` scan.
const ATTENTION_WINDOW_BYTES: usize = 4096;

/// Minimum time between two `session-attention` events for the same
/// session. Chosen empirically: a real pending permission prompt was
/// observed redrawing its box roughly twice a second while the user hadn't
/// touched anything yet (a PTY probe run during this task's investigation
/// counted 100+ redraws over 51 real seconds) — without debouncing, every
/// single redraw would independently re-match the marker and fire another
/// event. 15s comfortably collapses an entire redraw storm into one event.
/// It's not trying to bound "how fresh can a second, genuinely different
/// prompt's badge be" — the frontend badge is a sticky boolean cleared only
/// on tab focus (`ui/src/state/sessions.ts`'s `tab/activated` case), not a
/// toast, so a suppressed event during the cooldown never hides a real
/// attention need; it just avoids re-announcing one already flagged.
const ATTENTION_COOLDOWN: Duration = Duration::from_secs(15);

fn contains_attention_marker(text: &str) -> bool {
    ATTENTION_MARKERS.iter().any(|marker| text.contains(marker))
}

/// Keeps `s` at most `max_bytes` long by dropping from the front, snapping
/// the cut point forward to the nearest `char` boundary (a `String` can't be
/// sliced/drained mid-character) — at most a few bytes' extra slack per
/// call since UTF-8 characters are never more than 4 bytes.
fn trim_to_last_n_bytes(s: &mut String, max_bytes: usize) {
    if s.len() <= max_bytes {
        return;
    }
    let mut cut = s.len() - max_bytes;
    while cut < s.len() && !s.is_char_boundary(cut) {
        cut += 1;
    }
    s.drain(..cut);
}

/// Per-session rate limiter for attention events — see [`ATTENTION_COOLDOWN`]
/// for the reasoning behind the default duration. Takes `Instant` as an
/// explicit parameter (rather than calling `Instant::now()` internally) so
/// its own tests can drive it with synthetic, zero-real-time timestamps
/// instead of sleeping — `Instant + Duration` arithmetic is deterministic
/// and doesn't require a real clock to advance.
struct AttentionDebouncer {
    cooldown: Duration,
    last_fired: Option<Instant>,
}

impl AttentionDebouncer {
    fn new(cooldown: Duration) -> Self {
        Self { cooldown, last_fired: None }
    }

    /// Call once per marker match. Returns `true` exactly when the caller
    /// should actually fire the attention event (first-ever match, or the
    /// cooldown has elapsed since the last one it approved) — and records
    /// `now` as the new "last fired" instant whenever it does.
    fn should_fire(&mut self, now: Instant) -> bool {
        let fire = match self.last_fired {
            None => true,
            Some(last) => now.duration_since(last) >= self.cooldown,
        };
        if fire {
            self.last_fired = Some(now);
        }
        fire
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolves_dev_sibling_binary() {
        let tmp = tempfile::tempdir().unwrap();
        let target_debug = tmp.path().join("target/debug");
        std::fs::create_dir_all(&target_debug).unwrap();
        let exe = target_debug.join("omniagent-ade");
        let mcp = target_debug.join("omniagent-mcp");
        std::fs::write(&exe, b"fake").unwrap();
        std::fs::write(&mcp, b"fake").unwrap();

        let resolved = resolve_mcp_server_binary_from(&exe);
        assert_eq!(resolved, Some(mcp));
    }

    #[test]
    fn resolves_app_bundle_resources_binary() {
        let tmp = tempfile::tempdir().unwrap();
        let macos_dir = tmp.path().join("OmniAgent.app/Contents/MacOS");
        let resources_dir = tmp.path().join("OmniAgent.app/Contents/Resources");
        std::fs::create_dir_all(&macos_dir).unwrap();
        std::fs::create_dir_all(&resources_dir).unwrap();
        let exe = macos_dir.join("omniagent-ade");
        let mcp = resources_dir.join("omniagent-mcp");
        std::fs::write(&exe, b"fake").unwrap();
        std::fs::write(&mcp, b"fake").unwrap();

        let resolved = resolve_mcp_server_binary_from(&exe);
        assert_eq!(resolved, Some(mcp));
    }

    #[test]
    fn returns_none_gracefully_when_binary_missing() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("target/debug");
        std::fs::create_dir_all(&dir).unwrap();
        let exe = dir.join("omniagent-ade");
        std::fs::write(&exe, b"fake").unwrap();

        assert_eq!(resolve_mcp_server_binary_from(&exe), None);
    }

    #[test]
    fn rejects_unknown_engine() {
        let tmp = tempfile::tempdir().unwrap();
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: "not-a-real-engine".into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
        };
        let err = build_command(&req, tmp.path(), "sess-test").unwrap_err();
        assert!(err.to_string().contains("unsupported engine"));
    }

    #[test]
    fn line_buffered_redaction_catches_secret_split_across_reads() {
        let tmp = tempfile::tempdir().unwrap();
        let file_path = tmp.path().join("t.log");
        let mut file = Some(std::fs::File::create(&file_path).unwrap());

        let mut pending = String::new();
        // Simulate the secret's key/value pair arriving in two separate
        // PTY reads, split mid-value.
        pending.push_str("API_KEY=abc");
        flush_complete_lines(&mut pending, &mut file);
        pending.push_str("123\n");
        flush_complete_lines(&mut pending, &mut file);

        drop(file);
        let contents = std::fs::read_to_string(&file_path).unwrap();
        assert!(!contents.contains("abc123"), "{contents}");
        assert!(contents.contains("[redacted]"));
    }

    #[test]
    fn transcript_reassembles_a_multibyte_char_split_across_two_pty_reads() {
        let tmp = tempfile::tempdir().unwrap();
        let file_path = tmp.path().join("t.log");
        let mut file = Some(std::fs::File::create(&file_path).unwrap());

        // "a─b" -- U+2500 BOX DRAWINGS LIGHT HORIZONTAL, UTF-8 bytes
        // E2 94 80 -- split mid-character across two separate PTY
        // `read()` feeds, the exact repro confirmed in review. Real PTY
        // reads aren't UTF-8-boundary-aligned; box-drawing glyphs like
        // this are exactly what a TUI redraw (Claude Code's own
        // full-screen UI) streams constantly.
        let full = "a─b\n";
        let bytes = full.as_bytes();
        assert_eq!(bytes, &[0x61, 0xE2, 0x94, 0x80, 0x62, 0x0A]);
        let chunk1 = &bytes[..3]; // 'a' + the first 2 bytes of the 3-byte sequence
        let chunk2 = &bytes[3..]; // the sequence's last byte + "b\n"

        let mut decoder = Utf8ChunkDecoder::new();
        let mut pending = String::new();

        pending.push_str(&decoder.decode(chunk1));
        flush_complete_lines(&mut pending, &mut file);
        pending.push_str(&decoder.decode(chunk2));
        flush_complete_lines(&mut pending, &mut file);

        drop(file);
        let contents = std::fs::read_to_string(&file_path).unwrap();
        assert_eq!(contents, full, "{contents:?}");
        assert!(
            !contents.contains('\u{FFFD}'),
            "multi-byte char split across reads must not corrupt to U+FFFD: {contents:?}"
        );
    }

    #[test]
    fn utf8_chunk_decoder_still_lossy_replaces_genuinely_invalid_bytes() {
        // 0xFF is never valid UTF-8 (standalone or as a lead byte) -- this
        // isn't an incomplete-sequence case, so it must still become
        // U+FFFD immediately, same as `from_utf8_lossy` would, rather than
        // being carried over forever waiting for bytes that would never
        // complete it.
        let mut decoder = Utf8ChunkDecoder::new();
        let decoded = decoder.decode(&[b'x', 0xFF, b'y']);
        assert_eq!(decoded, "x\u{FFFD}y");
        assert_eq!(decoder.finish(), "", "nothing left carried over");
    }

    #[test]
    fn utf8_chunk_decoder_finish_flushes_a_truly_incomplete_trailing_sequence_at_eof() {
        // If the byte stream ends (EOF) mid-character, there's no more
        // data ever coming for that sequence -- `finish()` must still
        // surface it (lossy-replaced) rather than silently dropping those
        // final bytes forever.
        let mut decoder = Utf8ChunkDecoder::new();
        // First two bytes of "─" (E2 94 80), never followed by the third.
        let decoded = decoder.decode(&[0x61, 0xE2, 0x94]);
        assert_eq!(decoded, "a", "the incomplete tail must be carried, not lost or corrupted");
        let trailing = decoder.finish();
        assert_eq!(trailing, "\u{FFFD}");
    }

    fn shell_request(cwd: &Path) -> CreateSessionRequest {
        CreateSessionRequest {
            project: "demo".to_string(),
            engine: "shell".to_string(),
            cwd: cwd.to_string_lossy().into_owned(),
            briefing: None,
        }
    }

    fn silent_sink() -> OutputSink {
        Arc::new(|_id: &str, _chunk: &[u8]| {})
    }

    /// Test double for `portable_pty::Child` whose `wait()` sleeps for a
    /// controlled, precise duration before returning — the only reliable
    /// way to get a *deterministic*, measurable slow reap in a test: this
    /// crate's real PTY implementation ties master-side EOF to the actual
    /// termination of the child process on this OS (verified empirically:
    /// closing a shell's own stdin/stdout/stderr via `exec ... </dev/null
    /// >/dev/null 2>/dev/null` does *not* make the master see EOF any
    /// earlier than the process's real exit), so there is no shell-level
    /// trick that widens the gap between "EOF observed" and "wait()
    /// returns" enough to measure. A fake `Child` sidesteps that entirely.
    struct SlowWaitChild {
        wait_delay: Duration,
    }

    impl std::fmt::Debug for SlowWaitChild {
        fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
            f.debug_struct("SlowWaitChild").finish()
        }
    }

    impl portable_pty::ChildKiller for SlowWaitChild {
        fn kill(&mut self) -> std::io::Result<()> {
            Ok(())
        }
        fn clone_killer(&self) -> Box<dyn portable_pty::ChildKiller + Send + Sync> {
            Box::new(SlowWaitChild { wait_delay: self.wait_delay })
        }
    }

    impl Child for SlowWaitChild {
        fn try_wait(&mut self) -> std::io::Result<Option<portable_pty::ExitStatus>> {
            Ok(None)
        }
        fn wait(&mut self) -> std::io::Result<portable_pty::ExitStatus> {
            thread::sleep(self.wait_delay);
            Ok(portable_pty::ExitStatus::with_exit_code(0))
        }
        fn process_id(&self) -> Option<u32> {
            None
        }
        #[cfg(windows)]
        fn as_raw_handle(&self) -> Option<std::os::windows::io::RawHandle> {
            None
        }
    }

    /// Bug: the natural-exit reader-thread path (the `sessions.remove(&id)`
    /// branch at the end of `spawn_reader_thread`) used to hold the global
    /// registry lock across the blocking `child.wait()` and
    /// `cleanup_mcp_config` filesystem call, stalling every other open
    /// session's write/resize/kill/create for as long as that reap took —
    /// even though `SessionManager::kill` already got this right (release
    /// the lock immediately after removing the handle, then
    /// `wait()`/cleanup unlocked).
    ///
    /// Session A is hand-assembled with a real PTY master (so its reader
    /// thread observes a genuine EOF, exactly like production) but a fake
    /// `Child` ([`SlowWaitChild`]) whose `wait()` deliberately sleeps for
    /// 1.5s — giving a precise, deterministic window during which the
    /// natural-exit path is genuinely reaping. Session B is a real, live
    /// shell session; its `write`/`resize` (which briefly take the very
    /// same registry lock A's cleanup does) must return promptly the whole
    /// time, proving the lock isn't held across A's slow `wait()`.
    #[test]
    fn natural_exit_cleanup_does_not_block_other_sessions_write_and_resize() {
        let tmp = tempfile::tempdir().unwrap();
        let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink());

        let b = manager.create(shell_request(tmp.path())).unwrap();

        // Assemble session A by hand: a real pty pair's master (so its
        // reader thread behaves exactly like a real session) with nothing
        // ever spawned into the slave side, plus the fake slow-waiting
        // child above.
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
            .unwrap();
        let reader = pair.master.try_clone_reader().unwrap();
        let writer = pair.master.take_writer().unwrap();

        let a_id = "sess-test-natural-exit-lock-scope".to_string();
        let reader_thread = spawn_reader_thread(
            a_id.clone(),
            reader,
            tmp.path().join("transcripts").join(format!("{a_id}.log")),
            tmp.path().join("transcripts").join(format!("{a_id}.lifecycle.jsonl")),
            silent_sink(),
            Arc::clone(&manager.sessions),
            None,
            None,
            "demo".to_string(),
            tmp.path().to_string_lossy().into_owned(),
            "shell".to_string(),
        );
        let handle = SessionHandle {
            master: pair.master,
            writer,
            child: Box::new(SlowWaitChild { wait_delay: Duration::from_millis(1500) }),
            mcp_config_path: None,
            project: "demo".to_string(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            engine: "shell".to_string(),
            reader_thread,
        };
        // Insert A into the registry *before* triggering EOF below — the
        // reader thread is already running (blocked in `read()`, since the
        // slave side is still held open by `pair.slave` at this point), so
        // there's no race with its own `sessions.remove(&a_id)`.
        manager.sessions.lock().unwrap().insert(a_id.clone(), handle);

        // Now close the *only* remaining reference to the slave side
        // (nothing was ever spawned into it) -- this immediately unblocks
        // A's reader thread with EOF, kicking off the natural-exit path,
        // whose `child.wait()` will now sleep for 1.5s inside
        // `SlowWaitChild`.
        drop(pair.slave);

        // Give A's reader thread a moment to actually observe the EOF and
        // enter the natural-exit path (acquiring + releasing the lock to
        // remove itself) before touching session B.
        thread::sleep(Duration::from_millis(150));

        let started = Instant::now();
        manager.write(&b.id, "echo still-alive\n").unwrap();
        manager.resize(&b.id, 100, 30).unwrap();
        let elapsed = started.elapsed();

        assert!(
            elapsed < Duration::from_millis(500),
            "session B's write/resize must not block on session A's in-flight \
             natural-exit cleanup (a 1.5s fake wait()), took {elapsed:?}"
        );

        manager.kill(&b.id).unwrap();
        // Let A's fake 1.5s wait() finish before the test ends, so its
        // background reader thread doesn't outlive the test process.
        thread::sleep(Duration::from_millis(1600));
    }

    #[test]
    fn attention_marker_matches_both_observed_permission_dialog_wordings() {
        // The two real dialogs this was verified against (module docs):
        // a Bash-tool prompt and a Write-tool prompt, different trailing
        // wording, shared opening.
        assert!(contains_attention_marker("Do you want to proceed?"));
        assert!(contains_attention_marker("Do you want to create notes.txt?"));
        // Realistic surrounding noise (cursor-position junk, box-drawing
        // characters) shouldn't defeat the match — it's a substring check.
        assert!(contains_attention_marker(
            "\u{2502} Bash command \u{2502}\nDo you want to proceed?\n\u{2570}\u{2500}\u{256f}"
        ));
    }

    #[test]
    fn attention_marker_ignores_unrelated_output() {
        assert!(!contains_attention_marker("hi\n"));
        assert!(!contains_attention_marker("Quick safety check: Is this a project you trust?"));
        assert!(!contains_attention_marker(""));
    }

    #[test]
    fn trim_to_last_n_bytes_snaps_to_a_char_boundary() {
        // "é" is 2 bytes (0xC3 0xA9) — a naive byte-offset cut here would
        // land mid-character and panic on `drain`.
        let mut s = "xé".to_string();
        assert_eq!(s.len(), 3);
        trim_to_last_n_bytes(&mut s, 2);
        // Cut point (byte 1) isn't a boundary, so it snaps forward to byte
        // 3 (the whole "é" survives, "x" gets dropped) rather than panicking.
        assert_eq!(s, "é");
    }

    #[test]
    fn trim_to_last_n_bytes_is_a_no_op_under_the_limit() {
        let mut s = "short".to_string();
        trim_to_last_n_bytes(&mut s, 4096);
        assert_eq!(s, "short");
    }

    #[test]
    fn attention_debouncer_fires_once_for_a_burst_then_again_after_cooldown() {
        // Pure, no real sleeping — Instant + Duration arithmetic is
        // deterministic, so this drives the debouncer with synthetic
        // timestamps exactly like a real redraw storm would produce them,
        // without spending 15 real seconds per test run.
        let mut debouncer = AttentionDebouncer::new(Duration::from_secs(15));
        let t0 = Instant::now();

        // First match in a fresh session: always fires.
        assert!(debouncer.should_fire(t0));

        // A burst of re-matches within the cooldown window (mirrors the
        // empirically observed ~2 redraws/sec while a prompt sits pending)
        // must not fire again.
        for i in 1..=20u64 {
            let t = t0 + Duration::from_millis(i * 400); // spans ~8s, well under 15s
            assert!(
                !debouncer.should_fire(t),
                "burst re-match at +{}ms should have been suppressed",
                i * 400
            );
        }

        // Right at the boundary: still within cooldown, still suppressed.
        assert!(!debouncer.should_fire(t0 + Duration::from_millis(14_999)));

        // Once the cooldown has fully elapsed, a fresh match fires again.
        let t_after = t0 + Duration::from_secs(15);
        assert!(debouncer.should_fire(t_after));

        // ...and that new firing starts its own fresh cooldown window.
        assert!(!debouncer.should_fire(t_after + Duration::from_secs(1)));
    }
}
