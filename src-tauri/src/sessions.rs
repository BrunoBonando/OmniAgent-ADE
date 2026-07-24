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

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

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
}

impl SessionManager {
    pub fn new(data_dir: PathBuf, sink: OutputSink) -> Self {
        let _ = std::fs::create_dir_all(transcripts_dir(&data_dir));
        Self {
            data_dir,
            sink,
            sessions: Arc::new(Mutex::new(HashMap::new())),
            on_end: None,
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
#[allow(clippy::too_many_arguments)]
fn spawn_reader_thread(
    id: String,
    mut reader: Box<dyn Read + Send>,
    transcript_path: PathBuf,
    lifecycle_path: PathBuf,
    sink: OutputSink,
    sessions: Arc<Mutex<HashMap<String, SessionHandle>>>,
    on_end: Option<SessionEndHook>,
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

        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let chunk = &buf[..n];
                    sink(&id, chunk);

                    pending.push_str(&String::from_utf8_lossy(chunk));
                    flush_complete_lines(&mut pending, &mut transcript_file);
                }
                Err(_) => break,
            }
        }

        if !pending.is_empty() {
            write_redacted(&mut transcript_file, &pending);
        }

        let (exit_code, signal) = {
            let mut sessions = sessions.lock().unwrap();
            match sessions.remove(&id) {
                Some(mut handle) => {
                    // Not already handled by an explicit kill: this is a
                    // natural exit. Reap it so it doesn't zombie.
                    let status = handle.child.wait();
                    cleanup_mcp_config(&handle.mcp_config_path);
                    (
                        status.as_ref().ok().map(|s| s.exit_code()),
                        status.as_ref().ok().and_then(|s| s.signal().map(String::from)),
                    )
                }
                None => {
                    // Already removed+reaped by SessionManager::kill; that
                    // call already wrote its own "end" lifecycle event.
                    return;
                }
            }
        };

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
}
