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
//!
//! ## Resolving the real `PATH` for GUI-launched spawns (founder bug,
//! ## 2026-07-25)
//! Bruno hit this live in the packaged `.app`: opening a `"claude"` session
//! failed with `Couldn't start claude in <project>: spawn engine process`.
//! Root cause: `build_command` spawns `"claude"`/`"codex"` as bare command
//! names, which `portable_pty` resolves via whatever `PATH` this process
//! itself inherited at spawn time. A `.app` launched via Finder/`open`
//! inherits macOS's minimal default `PATH`
//! (`/usr/bin:/bin:/usr/sbin:/sbin`) — **not** the user's real shell `PATH`,
//! which lives in their shell startup files and is normally only assembled
//! when a real login shell starts (this is why `cargo tauri dev`, run from
//! inside an already-full-PATH terminal, never reproduced the bug: it
//! inherits the terminal's PATH, not a GUI launch's). On this machine, the
//! real `claude` binary is a symlink at `~/.local/bin/claude`, and
//! `~/.local/bin` is only added to `PATH` by `~/.zshrc`.
//!
//! [`resolve_shell_path`] fixes this the standard way GUI apps on macOS do
//! (VS Code and most Electron apps included): spawn the user's own
//! `$SHELL` once, non-interactively from *this* process's point of view,
//! and capture the `PATH` it ends up with. The exact invocation matters and
//! was verified empirically on this machine (see the commit message /
//! [`resolve_shell_path_for`]'s tests for the comparison) rather than
//! assumed: `<shell> -lc 'echo -n $PATH'` (login, non-interactive — the
//! "standard" advice) sources `.zshenv`/`.zprofile`/`.zlogin` but **not**
//! `.zshrc`, and this machine's `~/.local/bin` entry lives in `.zshrc` —
//! zsh only sources it for *interactive* shells, login or not. `<shell>
//! -ilc '...'` (login **and** interactive) does source `.zshrc` and
//! reliably produces the real, correct `PATH` (including `~/.local/bin`)
//! with clean single-line output — no banner/prompt noise leaked into
//! `stdout`, verified against this exact `$SHELL`/`~/.zshrc` combination.
//! That's the invocation used here.
//!
//! Resolution spawns a real subprocess, so it's cached process-wide after
//! the first call ([`cached_shell_path`], backed by a `std::sync::OnceLock`
//! — this module's first use of that pattern; nothing comparable existed
//! here before) rather than repeated per session. It also runs on a
//! background thread with a hard [`SHELL_PATH_RESOLUTION_TIMEOUT`] via a
//! channel `recv_timeout` (not a bare blocking call) — `stdin` is closed so
//! a profile script trying to interactively prompt gets immediate EOF
//! rather than hanging, but nothing rules out a truly pathological profile
//! (an infinite loop, a network call that never returns), and this sits on
//! session creation's critical path. Any failure — `$SHELL` unset, spawn
//! error, timeout, empty output — resolves to `None`, and callers
//! ([`apply_resolved_path`]) simply skip overriding `PATH`, falling back to
//! exactly today's behavior (bare-name resolution against whatever `PATH`
//! this process already inherited). PATH resolution failing must never
//! become a *new* way for session creation to fail.
//!
//! Applied to `"claude"` and `"codex"` (the bug's actual targets) and,
//! since it's free once computed and strictly more correct from the very
//! first prompt, to `"shell"` too — the engines themselves stay completely
//! stock; this only changes which `PATH` OmniAgent's own spawn call hands
//! them, never anything about how `claude`/`codex` are configured (DESIGN
//! principle 5, same zero-config boundary the rest of this module's docs
//! already describe).
//!
//! ## Making CLIs render color (founder bug, 2026-07-25 — Bruno, verbatim:
//! ## "Can you fix the colors of the terminals? It's currently black and
//! ## white... I like when it's colorful just like claude normally is.")
//! `Terminal.tsx`'s xterm.js `theme` option already has the real, correct
//! ANSI 0-15 palette (sourced from Warp's own bundled theme data) — that
//! was never the bug. The actual cause is the same class of "GUI launch
//! doesn't inherit what a real terminal session would" gap the `PATH` fix
//! above exists for: `CommandBuilder::new` seeds a spawned command's env
//! from whatever THIS process itself inherited at construction time (see
//! `portable_pty::cmdbuilder::get_base_env`), and a `.app` launched via
//! Finder/`open` has no `TERM` at all (no controlling terminal) — unlike
//! `cargo tauri dev` run from an already-interactive shell, which is why
//! this, too, never reproduced outside the packaged app. CLIs like `claude`
//! detect color-capability partly from `TERM`/`COLORTERM`; a missing/absent
//! `TERM` commonly makes them fall back to plain monochrome output — which
//! looks exactly like "black and white" no matter how correct xterm.js's
//! own rendering theme is, since there are no color escape codes in the
//! byte stream for it to render in the first place. Verified for real: a
//! `shell` session running `TERM=dumb tput setaf 1` (a command that emits
//! an ANSI color escape only when the terminfo it's given actually supports
//! color) prints nothing but a `tput: unknown terminal "dumb"`-style error
//! to the pty and no escape bytes at all, whereas the same session with
//! this fix's `TERM=xterm-256color` applied prints the real
//! `\x1b[31m` escape sequence — a genuine before/after byte-level
//! difference, not just "the env var is set in code" (see this task's own
//! commit message / report for the exact transcript).
//!
//! [`apply_terminal_capability_env`] sets `TERM=xterm-256color` (the exact
//! terminal type xterm.js + its WebGL addon actually implement) and
//! `COLORTERM=truecolor` (the de facto signal modern CLIs, including
//! `claude`, check for 24-bit color) on every engine's spawned command,
//! unconditionally — unlike `PATH`, there's no real, discoverable "user's
//! actual value" to resolve here (a GUI launch's `TERM` isn't merely wrong,
//! it's absent), so the fix is to always assert the exact capability this
//! app's own terminal renderer supports rather than to propagate whatever
//! (if anything) this process happened to inherit. Applied to all three
//! engines (`claude`, `codex`, `shell`), same reasoning `apply_resolved_path`
//! above already gives for extending PATH resolution to `shell` too: this is
//! a terminal-capability signal every spawned interactive process benefits
//! from, not an engine-specific behavior — the engines themselves stay
//! completely stock, only the env OmniAgent's own spawn call hands them
//! changes (DESIGN principle 5).

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, OnceLock};
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
        // Armed the instant the file (if any) might exist; disarmed only
        // once the session below has been fully, successfully created --
        // see the guard's own doc comment.
        let mut mcp_cleanup_guard = McpConfigCleanupGuard::new(mcp_config_path.clone());

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

        // Fully, successfully created -- the temp mcp config file's
        // eventual cleanup is now the `SessionHandle`'s responsibility
        // (kill()/the natural-exit path), not this guard's.
        mcp_cleanup_guard.disarm();

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
            apply_resolved_path(&mut cmd);
            apply_terminal_capability_env(&mut cmd);
            Ok((cmd, None))
        }
        "codex" => {
            // Stock spawn — no flags, nothing injected (Zero-config
            // principle: only `claude` gets ADE wiring in this task).
            let mut cmd = CommandBuilder::new("codex");
            cmd.cwd(&req.cwd);
            apply_resolved_path(&mut cmd);
            apply_terminal_capability_env(&mut cmd);
            Ok((cmd, None))
        }
        "claude" => {
            let mut cmd = CommandBuilder::new("claude");
            cmd.cwd(&req.cwd);
            apply_resolved_path(&mut cmd);
            apply_terminal_capability_env(&mut cmd);

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

/// How long [`spawn_and_capture_path`] will wait for the login-shell
/// `PATH`-resolution subprocess before giving up and treating it as a
/// failure (see [`resolve_shell_path_for`]'s doc comment for the rest of
/// the guard: `stdin` is already closed, this timeout is the backstop for
/// whatever that doesn't cover). Generous relative to the real,
/// empirically-measured cost of this machine's own profile chain (well
/// under a second), but bounded — this sits on session creation's critical
/// path and must never be allowed to hang it.
const SHELL_PATH_RESOLUTION_TIMEOUT: Duration = Duration::from_secs(5);

/// Overrides an about-to-be-spawned command's `PATH` with the user's real,
/// shell-resolved `PATH` ([`cached_shell_path`]) — see the module docs'
/// "Resolving the real PATH for GUI-launched spawns" section for why this
/// exists. A no-op (leaves whatever `PATH` this process itself inherited,
/// today's pre-fix behavior) whenever resolution fails for any reason.
fn apply_resolved_path(cmd: &mut CommandBuilder) {
    if let Some(path) = cached_shell_path() {
        cmd.env("PATH", path);
    }
}

/// Sets the terminal-capability env vars xterm.js + its WebGL addon
/// (`Terminal.tsx`) actually implement — see the module docs' "Making CLIs
/// render color" section for the bug this fixes (a GUI-launched `.app` has
/// no `TERM` at all, which makes CLIs like `claude` fall back to plain,
/// uncolored output). Unlike [`apply_resolved_path`], always overrides —
/// there's no "real" value to discover from this process's own environment
/// to fall back to; `xterm-256color`/`truecolor` are simply what this app's
/// terminal renderer supports, independent of whatever (if anything) the
/// spawning process inherited.
fn apply_terminal_capability_env(cmd: &mut CommandBuilder) {
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
}

/// Process-global cache for [`resolve_shell_path`]'s result — the spawn it
/// performs is real (if usually sub-second) latency, so it's paid once per
/// app run, not once per session. See [`cached_or_init`]'s doc comment for
/// why the caching *mechanism* is unit-tested against a fresh, local
/// `OnceLock` rather than this one.
static SHELL_PATH: OnceLock<Option<String>> = OnceLock::new();

/// Cached accessor for the app's actual use: resolves at most once per
/// process lifetime, reusing the cached `Option<String>` (itself `None`
/// when resolution failed) on every subsequent call.
fn cached_shell_path() -> Option<&'static str> {
    #[cfg(test)]
    if FORCE_SHELL_PATH_RESOLUTION_FAILURE.with(|f| f.get()) {
        return None;
    }
    cached_or_init(&SHELL_PATH, resolve_shell_path).as_deref()
}

// Test-only escape hatch, thread-local so it's naturally isolated from
// every other test running concurrently on its own worker thread (`cargo
// test`'s default execution model) — no cross-test races, no extra
// synchronization. Exists purely for
// `create_cleans_up_leaked_mcp_config_temp_file_when_spawn_fails`, whose
// whole premise (claude becomes unresolvable once its directory is
// filtered off `PATH`) this PATH-resolution fix otherwise permanently
// defeats on any machine where the real shell `PATH` *does* contain
// `claude` — which, after this fix, `apply_resolved_path` now consults
// unconditionally, regardless of what a test does to the ambient env.
// Compiled only under `#[cfg(test)]`; doesn't exist in a release binary.
#[cfg(test)]
thread_local! {
    static FORCE_SHELL_PATH_RESOLUTION_FAILURE: std::cell::Cell<bool> = const { std::cell::Cell::new(false) };
}

/// Generic lazy-once cache: runs `init` the first time `cache` is empty,
/// reuses the stored result forever after — precisely `OnceLock::get_or_init`
/// with a name that reads at the call site. Pulled out as its own function
/// (rather than inlining `SHELL_PATH.get_or_init(resolve_shell_path)`
/// directly into [`cached_shell_path`]) purely so the caching mechanism
/// itself can be exercised in tests against a fresh, test-local `OnceLock`
/// and a call-counting closure — asserting a call count against the *real*
/// process-global `SHELL_PATH` would be racy under `cargo test`'s parallel,
/// shared-binary execution (some other test could resolve it first).
fn cached_or_init<T>(cache: &OnceLock<T>, init: impl FnOnce() -> T) -> &T {
    cache.get_or_init(init)
}

/// Resolves the user's real `PATH` by spawning their login shell — the
/// entry point [`cached_shell_path`] caches. Thin wrapper around
/// [`resolve_shell_path_for`] that supplies the real `$SHELL`; kept
/// separate so tests can drive the interesting logic directly with an
/// explicit `Option<&str>` instead of mutating the real process
/// environment (see [`resolve_shell_path_for`]'s tests for why that
/// matters here specifically).
fn resolve_shell_path() -> Option<String> {
    resolve_shell_path_for(std::env::var("SHELL").ok().as_deref())
}

/// Core PATH-resolution logic, parameterized over the shell to use instead
/// of reading `$SHELL` itself. `None` in, or any failure along the way
/// (spawn error, timeout, non-zero exit, empty output), all resolve to
/// `None` out — every one of those is "resolution failed", and every
/// caller already treats `None` as "fall back to today's behavior", so
/// there is no need to distinguish the reasons at this layer.
fn resolve_shell_path_for(shell: Option<&str>) -> Option<String> {
    let shell = shell?;
    spawn_and_capture_path(shell)
}

/// Spawns `<shell> -ilc 'echo -n $PATH'` and returns its trimmed stdout, or
/// `None` if the spawn fails, it doesn't finish within
/// [`SHELL_PATH_RESOLUTION_TIMEOUT`] (in which case the child is left to
/// exit on its own — the timeout only stops *this function* from waiting,
/// it doesn't try to kill a stuck child), it exits non-zero, or its output
/// is empty after trimming.
///
/// `-ilc` (login **and** interactive), not just `-lc` (login only) — see
/// the module docs' "Resolving the real PATH for GUI-launched spawns"
/// section for the empirical reasoning: on this machine (and commonly
/// elsewhere), `PATH` entries added in `.zshrc`/`.bashrc` only take effect
/// for *interactive* shells, login or not, while `-lc` alone only sources
/// the login-only files (`.zprofile`/`.zshenv`/`.zlogin` for zsh) — proven
/// empirically to miss `~/.local/bin` entirely on this machine, where it's
/// added in `.zshrc`.
///
/// Runs on a background thread and waits via a channel `recv_timeout`
/// rather than a bare blocking `Command::output()` call, specifically so a
/// pathological shell profile (infinite loop, a network call that never
/// returns) can't hang session creation forever — `stdin` is already closed
/// (`Stdio::null()`) so a profile script trying to interactively prompt
/// gets immediate EOF instead of blocking, which covers the common case,
/// but doesn't cover every conceivable hang.
fn spawn_and_capture_path(shell: &str) -> Option<String> {
    let shell = shell.to_string();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let result = std::process::Command::new(&shell)
            .arg("-ilc")
            .arg("echo -n $PATH")
            .stdin(std::process::Stdio::null())
            .output();
        let _ = tx.send(result);
    });

    let output = rx.recv_timeout(SHELL_PATH_RESOLUTION_TIMEOUT).ok()?.ok()?;
    if !output.status.success() {
        return None;
    }

    let path = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if path.is_empty() {
        None
    } else {
        Some(path)
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

/// RAII guard for the temp `--mcp-config` file `build_command` writes for
/// `claude` sessions (see [`write_mcp_config`]). `SessionManager::create`
/// arms one right after the file is written and disarms it only once the
/// session has been fully, successfully created and inserted into the
/// registry — ownership of the file's eventual cleanup passes to the
/// `SessionHandle` (and from there to `kill()`/the natural-exit path,
/// which already clean it up) at that point.
///
/// Any of `create()`'s several fallible steps between those two points
/// (`openpty`, `try_clone_reader`/`take_writer`, `spawn_command`,
/// `append_lifecycle_event`) returning early via `?` instead drops this
/// guard while still armed, deleting the file — without this, every one
/// of those failure paths leaked the file permanently into the system
/// temp dir. Realistic trigger: `claude` isn't on `PATH`, so every
/// "claude" session attempt fails at `spawn_command` and leaks one more
/// file, forever.
struct McpConfigCleanupGuard {
    path: Option<PathBuf>,
    armed: bool,
}

impl McpConfigCleanupGuard {
    fn new(path: Option<PathBuf>) -> Self {
        Self { path, armed: true }
    }

    /// Call once the session is fully, successfully created — the file
    /// (if any) is no longer this guard's responsibility from here on.
    fn disarm(&mut self) {
        self.armed = false;
    }
}

impl Drop for McpConfigCleanupGuard {
    fn drop(&mut self) {
        if self.armed {
            cleanup_mcp_config(&self.path);
        }
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

    // -- Shell-PATH resolution (founder bug, 2026-07-25 -- see module docs
    // for the full "Resolving the real PATH for GUI-launched spawns"
    // writeup) --------------------------------------------------------

    /// Proves the caching *mechanism* itself: the `init` closure passed to
    /// `cached_or_init` must run at most once, no matter how many times the
    /// accessor is called, with every call after the first reusing the
    /// cached value. Deliberately uses a fresh, test-local `OnceLock` (not
    /// the real process-global `SHELL_PATH` `cached_shell_path` uses) so
    /// this is fully deterministic and independent of `cargo test`'s
    /// parallel, shared-binary execution -- a test asserting call counts
    /// against the *real* global cache would be racy, since some other test
    /// in this binary might resolve it first.
    #[test]
    fn cached_or_init_only_calls_the_resolver_once_across_multiple_calls() {
        let cache: OnceLock<Option<String>> = OnceLock::new();
        let calls = AtomicU64::new(0);

        let a = cached_or_init(&cache, || {
            calls.fetch_add(1, Ordering::SeqCst);
            Some("fake-resolved-path".to_string())
        });
        let b = cached_or_init(&cache, || {
            calls.fetch_add(1, Ordering::SeqCst);
            Some("fake-resolved-path".to_string())
        });
        let c = cached_or_init(&cache, || {
            calls.fetch_add(1, Ordering::SeqCst);
            Some("fake-resolved-path".to_string())
        });

        assert_eq!(a.as_deref(), Some("fake-resolved-path"));
        assert_eq!(a, b);
        assert_eq!(b, c);
        assert_eq!(
            calls.load(Ordering::SeqCst),
            1,
            "the resolver must run exactly once; later calls must reuse the cached value"
        );
    }

    /// Graceful fallback, case 1: no shell configured at all. Exercises
    /// `resolve_shell_path_for` directly with `None` rather than mutating
    /// the real `$SHELL` env var -- `resolve_shell_path` (the thin wrapper
    /// that actually reads `$SHELL`) is a one-line composition of this, and
    /// mutating process env vars here would risk racing the real,
    /// process-global `cached_shell_path` if some concurrently-running test
    /// happened to trigger its first-ever resolution at the same moment.
    #[test]
    fn resolve_shell_path_for_returns_none_when_no_shell_is_configured() {
        assert_eq!(resolve_shell_path_for(None), None);
    }

    /// Graceful fallback, case 2: `$SHELL` is set but doesn't point at a
    /// real, spawnable binary -- the spawn itself must fail cleanly, not
    /// panic or hang.
    #[test]
    fn resolve_shell_path_for_returns_none_when_the_shell_binary_does_not_exist() {
        assert_eq!(
            resolve_shell_path_for(Some("/no/such/shell/binary/on/this/machine")),
            None
        );
    }

    /// The real proof this task called out specifically: run the actual
    /// resolution logic against this machine's real `$SHELL`. Soft-guarded
    /// rather than hard-failed on the exact `~/.local/bin` marker, since a
    /// stock CI box won't have this developer's home directory -- but if
    /// that exact directory *is* present (i.e. this is genuinely Bruno's
    /// machine, where the bug was reported and `claude` really does live at
    /// `~/.local/bin/claude`), assert the resolution actually found it.
    #[test]
    fn resolve_shell_path_finds_the_real_login_shell_path_on_this_machine() {
        let Some(resolved) = resolve_shell_path() else {
            eprintln!(
                "resolve_shell_path() returned None on this machine (no $SHELL, or \
                 resolution failed) -- nothing further to assert"
            );
            return;
        };

        assert!(
            !resolved.trim().is_empty(),
            "a successful resolution must never yield an empty PATH"
        );

        let home = std::env::var("HOME").unwrap_or_default();
        let marker = format!("{home}/.local/bin");
        if std::path::Path::new(&marker).is_dir() {
            assert!(
                resolved.contains(&marker),
                "resolved PATH should contain {marker} on this machine, got: {resolved}"
            );
        } else {
            eprintln!(
                "note: {marker} doesn't exist on this machine, skipping the exact-marker \
                 assertion -- resolved PATH was: {resolved}"
            );
            let default_path = std::env::var("PATH").unwrap_or_default();
            assert_ne!(
                resolved.trim(),
                default_path.trim(),
                "when the exact marker isn't available, at least prove resolution produced \
                 something distinct from this test process's own bare PATH"
            );
        }
    }

    /// Wiring proof: `build_command` actually applies whatever
    /// `cached_shell_path()` resolves (or doesn't) to the spawned command's
    /// `PATH` env var, for every engine that should get it. Self-consistent
    /// regardless of which machine runs it -- compares against
    /// `cached_shell_path()`'s own live return value rather than a
    /// hardcoded expectation, so it holds whether resolution succeeds here
    /// or not.
    fn assert_build_command_applies_resolved_path(engine: &str) {
        let tmp = tempfile::tempdir().unwrap();
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: engine.into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
        };
        let (cmd, _mcp_path) =
            build_command(&req, tmp.path(), &format!("sess-test-path-{engine}")).unwrap();
        let got = cmd.get_env("PATH").map(|s| s.to_string_lossy().into_owned());

        match cached_shell_path() {
            Some(expected) => assert_eq!(
                got.as_deref(),
                Some(expected),
                "{engine} session's PATH should be the resolved shell PATH"
            ),
            None => assert_eq!(
                got,
                std::env::var("PATH").ok(),
                "{engine} session's PATH should fall back to this process's own PATH \
                 when resolution fails"
            ),
        }
    }

    #[test]
    fn build_command_applies_resolved_path_to_claude() {
        assert_build_command_applies_resolved_path("claude");
    }

    #[test]
    fn build_command_applies_resolved_path_to_codex() {
        assert_build_command_applies_resolved_path("codex");
    }

    #[test]
    fn build_command_applies_resolved_path_to_shell() {
        assert_build_command_applies_resolved_path("shell");
    }

    // -- Terminal-capability env: TERM/COLORTERM (founder bug, 2026-07-25 --
    // "the terminals render black-and-white instead of colorful") ---------

    /// Wiring proof: `build_command` sets `TERM`/`COLORTERM` on the spawned
    /// command's env, for every engine, unconditionally -- see the module
    /// docs' "Making CLIs render color" section for why this is
    /// unconditional (always the same two literal values) rather than
    /// resolved/cached like `PATH` above: unlike `PATH`, there is no "real"
    /// value to discover from the user's environment -- a GUI launch simply
    /// has no `TERM` at all, and the correct fix is to assert the exact
    /// capability this app's own xterm.js + WebGL addon actually support,
    /// not to propagate whatever (if anything) this process happened to
    /// inherit.
    ///
    /// Deliberately forces THIS TEST PROCESS's own `TERM`/`COLORTERM` to
    /// something else first (`dumb`/unset), restored via RAII even if an
    /// assertion panics -- otherwise this assertion would silently pass for
    /// the wrong reason on any machine (this one included: a real terminal
    /// session's own shell already has `TERM=xterm-256color`,
    /// `COLORTERM=truecolor`) where `CommandBuilder::new`'s base-env
    /// inheritance (see `get_base_env` in the `portable-pty` crate) already
    /// happens to match the target values by coincidence, exactly the same
    /// "cargo tauri dev never reproduced the PATH bug" trap the module docs
    /// describe for `PATH` above -- proven empirically while writing this
    /// test: without the override below, this assertion passed even before
    /// `build_command` set anything, purely because this developer's own
    /// shell's `TERM`/`COLORTERM` already matched.
    fn assert_build_command_sets_terminal_capability_env(engine: &str) {
        struct RestoreEnvVar(&'static str, Option<std::ffi::OsString>);
        impl Drop for RestoreEnvVar {
            fn drop(&mut self) {
                match &self.1 {
                    Some(v) => std::env::set_var(self.0, v),
                    None => std::env::remove_var(self.0),
                }
            }
        }
        let _restore_term = RestoreEnvVar("TERM", std::env::var_os("TERM"));
        let _restore_colorterm = RestoreEnvVar("COLORTERM", std::env::var_os("COLORTERM"));
        std::env::set_var("TERM", "dumb");
        std::env::remove_var("COLORTERM");

        let tmp = tempfile::tempdir().unwrap();
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: engine.into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
        };
        let (cmd, _mcp_path) =
            build_command(&req, tmp.path(), &format!("sess-test-color-{engine}")).unwrap();

        assert_eq!(
            cmd.get_env("TERM").map(|s| s.to_string_lossy().into_owned()).as_deref(),
            Some("xterm-256color"),
            "{engine} session's TERM should be set for real color support, regardless of \
             whatever (if anything) this process itself inherited"
        );
        assert_eq!(
            cmd.get_env("COLORTERM").map(|s| s.to_string_lossy().into_owned()).as_deref(),
            Some("truecolor"),
            "{engine} session's COLORTERM should signal 24-bit color support"
        );
    }

    #[test]
    fn build_command_sets_terminal_capability_env_for_claude() {
        assert_build_command_sets_terminal_capability_env("claude");
    }

    #[test]
    fn build_command_sets_terminal_capability_env_for_codex() {
        assert_build_command_sets_terminal_capability_env("codex");
    }

    #[test]
    fn build_command_sets_terminal_capability_env_for_shell() {
        assert_build_command_sets_terminal_capability_env("shell");
    }

    /// Bug: every one of `create()`'s fallible steps *after*
    /// `write_mcp_config` writes the temp `--mcp-config` JSON file
    /// (`openpty`, `try_clone_reader`/`take_writer`, `spawn_command`,
    /// `append_lifecycle_event`) propagated its error via `?` without ever
    /// cleaning that file up -- only `kill()` and the natural-exit path
    /// (both post-success) did. Realistic trigger named in the bug report:
    /// `claude` isn't on `PATH`, so every "claude" session attempt fails at
    /// spawn and leaks one more file into the system temp dir forever.
    ///
    /// Reproduced end-to-end through the real `create()`, exactly that
    /// trigger: a fake sibling `omniagent-mcp` binary is dropped next to
    /// *this test binary itself* so `resolve_mcp_server_binary()` (which
    /// looks up `std::env::current_exe()`, exactly as `create()` calls it
    /// for real) genuinely finds it and writes the config file, then
    /// `PATH` is filtered (for the duration of the `create()` call only,
    /// restored via RAII even if an assertion below panics) to drop only
    /// the specific directory that actually contains a `claude`
    /// executable -- every *other* directory on `PATH` is left untouched,
    /// so anything else on this machine's `PATH` (notably `git`, which
    /// `feedback::tests::git_diff_stat_reports_uncommitted_changes`
    /// shells out to and which flaked when an earlier version of this
    /// test wiped `PATH` entirely and ran concurrently with it) keeps
    /// resolving normally for any test running in parallel with this one.
    /// (Two other failure triggers were tried first and rejected: a
    /// nonexistent `cwd` and an oversized `--append-system-prompt` value
    /// both let `spawn_command` return `Ok` -- the failure happens
    /// invisibly inside the forked child before `exec`, not in the
    /// parent's `spawn_command` call, on this PTY backend/OS -- so neither
    /// actually surfaces as an `Err` here, and worse, both leave a real
    /// child process spawned and running.)
    ///
    /// Updated 2026-07-25 for the shell-`PATH`-resolution fix
    /// (`apply_resolved_path`/`cached_shell_path`): filtering the ambient
    /// `PATH` alone no longer makes `claude` unresolvable, since
    /// `build_command` now overrides the spawned command's `PATH` with the
    /// user's real, shell-resolved one regardless of what this test does to
    /// the current process's env -- which is the fix working as intended,
    /// but it defeats this test's original trigger on any machine where
    /// `claude` really is reachable via the user's shell (this one
    /// included). `_force_resolution_failure` engages a thread-local,
    /// `#[cfg(test)]`-only escape hatch (see
    /// `FORCE_SHELL_PATH_RESOLUTION_FAILURE`'s doc comment) so
    /// `apply_resolved_path` skips its override for the duration of this
    /// test's own thread only, restoring the original filtered-`PATH`
    /// trigger without disturbing any other test's view of the real,
    /// process-global resolution cache.
    #[test]
    fn create_cleans_up_leaked_mcp_config_temp_file_when_spawn_fails() {
        struct ForceShellPathResolutionFailure;
        impl ForceShellPathResolutionFailure {
            fn engage() -> Self {
                FORCE_SHELL_PATH_RESOLUTION_FAILURE.with(|f| f.set(true));
                Self
            }
        }
        impl Drop for ForceShellPathResolutionFailure {
            fn drop(&mut self) {
                FORCE_SHELL_PATH_RESOLUTION_FAILURE.with(|f| f.set(false));
            }
        }
        let _force_resolution_failure = ForceShellPathResolutionFailure::engage();

        let exe = std::env::current_exe().unwrap();
        let sibling = exe.parent().unwrap().join("omniagent-mcp");
        std::fs::write(&sibling, b"fake").unwrap();
        struct RemoveOnDrop(PathBuf);
        impl Drop for RemoveOnDrop {
            fn drop(&mut self) {
                let _ = std::fs::remove_file(&self.0);
            }
        }
        let _sibling_guard = RemoveOnDrop(sibling);

        struct RestorePath(Option<std::ffi::OsString>);
        impl Drop for RestorePath {
            fn drop(&mut self) {
                match &self.0 {
                    Some(p) => std::env::set_var("PATH", p),
                    None => std::env::remove_var("PATH"),
                }
            }
        }
        let original_path = std::env::var_os("PATH");
        let _path_guard = RestorePath(original_path.clone());
        let filtered: Vec<PathBuf> = original_path
            .as_deref()
            .map(std::env::split_paths)
            .into_iter()
            .flatten()
            .filter(|dir| !dir.join("claude").is_file())
            .collect();
        std::env::set_var("PATH", std::env::join_paths(&filtered).unwrap());
        assert!(
            which_claude(&filtered).is_none(),
            "test setup bug: `claude` must not resolve under the filtered PATH"
        );

        let count_leaked = || {
            std::fs::read_dir(std::env::temp_dir())
                .unwrap()
                .filter_map(|e| e.ok())
                .filter(|e| {
                    e.file_name()
                        .to_string_lossy()
                        .starts_with("omniagent-ade-mcp-")
                })
                .count()
        };
        let before = count_leaked();

        let tmp = tempfile::tempdir().unwrap();
        let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink());
        let req = CreateSessionRequest {
            project: "demo".into(),
            engine: "claude".into(),
            cwd: tmp.path().to_string_lossy().into_owned(),
            briefing: None,
        };

        let err = manager
            .create(req)
            .expect_err("claude must fail to spawn once its directory is filtered off PATH");
        assert!(!err.to_string().is_empty());

        assert_eq!(
            count_leaked(),
            before,
            "the --mcp-config temp file written before the failing spawn step must not survive"
        );
    }

    fn which_claude(dirs: &[PathBuf]) -> Option<PathBuf> {
        dirs.iter().map(|d| d.join("claude")).find(|p| p.is_file())
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
