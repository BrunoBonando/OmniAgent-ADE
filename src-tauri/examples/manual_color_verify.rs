//! Manual, run-by-hand proof of the `TERM`/`COLORTERM` fix for the founder
//! bug (Bruno, 2026-07-25, verbatim: "Can you fix the colors of the
//! terminals? It's currently black and white. I don't like it. I like when
//! it's colorful just like claude normally is."). NOT part of `cargo test`
//! -- same reason `manual_path_resolution_verify.rs` isn't: it deliberately
//! reproduces a GUI launch's minimal starting environment (no `TERM` at
//! all), which isn't something to do inside the shared `cargo test` binary.
//!
//! `sessions.rs`'s module docs ("Making CLIs render color") lay out the
//! root cause: `CommandBuilder::new` seeds a spawned command's env from
//! whatever THIS process itself inherited at construction time, and a
//! Finder/`open`-launched `.app` has no `TERM` at all (no controlling
//! terminal) -- unlike `cargo tauri dev`, which inherits an already-
//! interactive shell's `TERM` and so never reproduces this, exactly the
//! same "cargo tauri dev never reproduced the PATH bug" trap
//! `manual_path_resolution_verify.rs` documents for `PATH`.
//!
//! This example proves the fix with real bytes, not just "the env var is
//! set in code": it runs `tput setaf 1` (emits the raw ANSI "set foreground
//! red" escape sequence ONLY when the terminfo it's given actually
//! describes a color-capable terminal -- a real, external program's own
//! color-detection logic, the same class of check `claude`/`codex` do
//! internally) through a real PTY, twice, under an environment with `TERM`
//! stripped (simulating exactly what a GUI-launched `.app` starts with):
//!
//! 1. **Before** (the bug): a raw `CommandBuilder` with NO override --
//!    bypassing this fix entirely, exactly what `build_command` did before
//!    it existed.
//! 2. **After** (the fix): the real `SessionManager::create` (`engine:
//!    "shell"`), which now applies `apply_terminal_capability_env`.
//!
//! Run:
//! ```sh
//! cargo run -p omniagent-ade --example manual_color_verify
//! ```

use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use portable_pty::{native_pty_system, CommandBuilder, PtySize};

use omniagent_ade_lib::sessions::{CreateSessionRequest, OutputSink, SessionManager};

/// The command whose output is the actual proof: `tput` only emits the raw
/// ANSI "set foreground color" escape sequence (a literal `0x1b` byte) when
/// the `TERM` it's given resolves to a real, color-capable terminfo entry
/// -- an external program making its own real color-capability decision,
/// not anything this app controls. `echo done` afterward just gives a
/// human skimming the printed transcript a visual "the shell is back at a
/// prompt" cue -- it plays no role in how this example decides pass/fail
/// (see `collect_for` below: that's a fixed time window, not a marker
/// search, specifically because the PTY's own local-echo of this typed
/// command line would otherwise make ANY chosen marker string show up in
/// the captured bytes immediately, before the command has even run).
const PROBE_COMMAND: &str = "tput setaf 1; echo done\n";

/// Reads from `rx` for a fixed wall-clock window, returning everything
/// collected. Deliberately NOT "read until some marker shows up" -- the
/// PTY echoes back the typed command line itself (cooked-mode local echo)
/// before it ever runs, so any marker text present in `PROBE_COMMAND`
/// would already appear in that echo, stopping collection before the real
/// command output (the actual proof) has arrived. A plain fixed window is
/// simpler and correct here: `tput`+`echo` finish in well under 100ms,
/// `timeout` just needs to comfortably outlast that.
fn collect_for(rx: &mpsc::Receiver<Vec<u8>>, timeout: Duration) -> Vec<u8> {
    let mut collected = Vec::new();
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Ok(chunk) = rx.recv_timeout(Duration::from_millis(100)) {
            collected.extend_from_slice(&chunk);
        }
    }
    collected
}

/// The actual proof, precisely: does the captured stream contain `tput`'s
/// own literal SGR "set foreground red" escape (`ESC [ 31 m`), the exact
/// bytes `tput setaf 1` writes ONLY when it resolved a color-capable
/// terminfo entry. Deliberately NOT "contains any `0x1b` byte at all" --
/// empirically, a real interactive zsh prompt (this machine's, at least)
/// emits plenty of its own escape sequences regardless of `TERM`
/// (bracketed-paste mode, OSC 133/9 shell-integration markers, reverse-
/// video prompt decoration) that have nothing to do with `tput`'s own
/// color-capability decision -- see this file's own captured BEFORE/AFTER
/// output for a concrete example of that noise. `ESC[31m` is `tput`'s own
/// signal specifically, immune to that noise.
const SGR_RED: &[u8] = b"\x1b[31m";

fn describe(label: &str, bytes: &[u8]) -> bool {
    let has_color = bytes.windows(SGR_RED.len()).any(|w| w == SGR_RED);
    let has_term_error = String::from_utf8_lossy(bytes).contains("No value for $TERM");
    println!("  {label}: {:?}", String::from_utf8_lossy(bytes));
    println!(
        "  {label} raw bytes: {:02x?}",
        &bytes[..bytes.len().min(32)]
    );
    println!("  {label} contains tput's literal ESC[31m (real color escape): {has_color}");
    println!("  {label} contains tput's \"No value for $TERM\" error: {has_term_error}");
    has_color
}

fn main() {
    println!("== manual TERM/COLORTERM-fix verify ==");
    println!(
        "simulating the real Finder/`open`-launched .app's environment: no TERM, no COLORTERM \
         (this process's own TERM/COLORTERM temporarily cleared for the duration of this run)"
    );

    let original_term = std::env::var_os("TERM");
    let original_colorterm = std::env::var_os("COLORTERM");
    std::env::remove_var("TERM");
    std::env::remove_var("COLORTERM");

    let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());

    // -- BEFORE (the bug): a raw CommandBuilder, no TERM/COLORTERM override
    // -- exactly what build_command did before apply_terminal_capability_env
    // existed. Driven through a real PTY directly (not SessionManager) so
    // this genuinely bypasses the fix rather than just calling a different
    // code path that happens to also not have it. ------------------------
    println!("\n-- BEFORE (bug reproduction): raw CommandBuilder, no TERM override --");
    let before_bytes = {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize { rows: 24, cols: 80, pixel_width: 0, pixel_height: 0 })
            .expect("open pty");
        let mut cmd = CommandBuilder::new(&shell);
        // Deliberately NOT calling apply_terminal_capability_env here --
        // this is the "before" arm.
        let mut child = pair.slave.spawn_command(cmd_take(&mut cmd)).expect("spawn shell");
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().expect("clone reader");
        let mut writer = pair.master.take_writer().expect("take writer");
        use std::io::Write;
        writer.write_all(PROBE_COMMAND.as_bytes()).expect("write probe");
        writer.flush().ok();

        let (tx, rx) = mpsc::channel::<Vec<u8>>();
        std::thread::spawn(move || {
            use std::io::Read;
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        if tx.send(buf[..n].to_vec()).is_err() {
                            break;
                        }
                    }
                }
            }
        });
        let bytes = collect_for(&rx, Duration::from_millis(1200));
        let _ = child.kill();
        let _ = child.wait();
        bytes
    };
    let before_has_color = describe("BEFORE", &before_bytes);

    // -- AFTER (the fix): the real SessionManager::create, engine "shell" --
    println!("\n-- AFTER (the fix): SessionManager::create under the same stripped env --");
    let scratch =
        std::env::temp_dir().join(format!("omniagent-ade-color-verify-{}", std::process::id()));
    let data_dir = scratch.join("data");
    let project_dir = scratch.join("project");
    std::fs::create_dir_all(&project_dir).expect("create project dir");

    let (tx, rx) = mpsc::channel::<Vec<u8>>();
    let sink: OutputSink = Arc::new(move |_id: &str, chunk: &[u8]| {
        let _ = tx.send(chunk.to_vec());
    });
    let manager = SessionManager::new(data_dir, sink);
    let info = manager
        .create(CreateSessionRequest {
            project: "color-verify".to_string(),
            engine: "shell".to_string(),
            cwd: project_dir.to_string_lossy().into_owned(),
            briefing: None,
        })
        .expect("SessionManager::create should succeed");

    manager.write(&info.id, PROBE_COMMAND).expect("write probe");
    let after_bytes = collect_for(&rx, Duration::from_millis(1200));
    manager.kill(&info.id).expect("kill should succeed");
    let after_has_color = describe("AFTER", &after_bytes);

    match original_term {
        Some(v) => std::env::set_var("TERM", v),
        None => std::env::remove_var("TERM"),
    }
    match original_colorterm {
        Some(v) => std::env::set_var("COLORTERM", v),
        None => std::env::remove_var("COLORTERM"),
    }

    println!("\n== summary ==");
    println!("  BEFORE (raw spawn, no TERM) emitted a color escape code: {before_has_color}");
    println!("  AFTER  (SessionManager::create, the fix applied) emitted a color escape code: {after_has_color}");
    println!("  fix proven with real bytes: {}", !before_has_color && after_has_color);
    println!("  scratch dir left on disk for inspection: {}", scratch.display());
}

/// `CommandBuilder` doesn't implement `Clone`/`Copy` and `spawn_command`
/// takes it by value -- this just moves it out of the local, letting the
/// rest of the block still read `shell`/etc. without fighting the borrow
/// checker over a single-use local.
fn cmd_take(cmd: &mut CommandBuilder) -> CommandBuilder {
    std::mem::replace(cmd, CommandBuilder::new("true"))
}
