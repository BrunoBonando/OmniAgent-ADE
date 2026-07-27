//! Manual, run-by-hand proof of the shell-`PATH`-resolution fix for the
//! founder bug (Bruno, 2026-07-25): opening a "claude" session in the
//! packaged `.app` failed with `Couldn't start claude in <project>: spawn
//! engine process`. NOT part of `cargo test` -- deliberately manipulates
//! this *process's own* `PATH` env var to simulate exactly what a
//! Finder/`open`-launched `.app` inherits, which isn't something to do
//! inside the shared `cargo test` binary (every other test in that binary
//! shares the same process-wide env and the same `PATH`-resolution cache).
//!
//! This isn't a simulated PATH value picked out of a hunch -- it was
//! captured live from the real, freshly-built, Finder-launched `.app`
//! during this task's own manual verification:
//!
//! ```sh
//! cd src-tauri && ../ui/node_modules/.bin/tauri build
//! open ../target/release/bundle/macos/OmniAgent.app
//! PID=$(pgrep -f 'OmniAgent.app/Contents/MacOS/omniagent-ade')
//! ps eww -p "$PID" | tr ' ' '\n' | grep '^PATH='
//! # => PATH=/usr/bin:/bin:/usr/sbin:/sbin
//! ```
//!
//! That confirms the bug's precondition for real: a `.app` opened exactly
//! the way a real user would (Finder, or `open`, never `cargo tauri dev`,
//! which inherits a terminal's already-full `PATH` and would never
//! reproduce this) really does start with macOS's minimal default GUI
//! `PATH` -- not the user's real shell `PATH`, wherever their package
//! manager put `claude`/`codex` (`~/.local/bin` on this machine).
//!
//! This example reproduces that exact starting `PATH` for the current
//! process and does a real before/after comparison against it:
//! 1. **Before** (the bug): a raw, bare `claude` spawn -- bypassing this
//!    fix entirely -- under that minimal `PATH`.
//! 2. **After** (the fix): the real `SessionManager::create` (which now
//!    applies the shell-resolved `PATH` via `apply_resolved_path`) under
//!    the exact same starting `PATH`.
//!
//! Run:
//! ```sh
//! cargo run -p omniagent-ade --example manual_path_resolution_verify
//! ```

use std::sync::Arc;

use omniagent_ade_lib::sessions::{CreateSessionRequest, OutputSink, SessionManager};

/// Captured live from the real packaged `.app`, launched via `open` -- see
/// this file's module doc comment for the exact command that produced it.
const GUI_MINIMAL_PATH: &str = "/usr/bin:/bin:/usr/sbin:/sbin";

fn main() {
    println!("== manual PATH-resolution verify ==");
    println!("simulating the real Finder/`open`-launched .app's minimal PATH: {GUI_MINIMAL_PATH}");

    let original_path = std::env::var_os("PATH");
    std::env::set_var("PATH", GUI_MINIMAL_PATH);

    println!("\n-- BEFORE (bug reproduction): raw bare `claude` spawn under minimal PATH --");
    let before_ok = match std::process::Command::new("claude")
        .arg("--version")
        .output()
    {
        Ok(out) if out.status.success() => {
            println!(
                "  UNEXPECTED: raw spawn succeeded -- is `claude` somehow already on \
                 {GUI_MINIMAL_PATH} on this machine?"
            );
            true
        }
        Ok(out) => {
            println!("  raw spawn ran but exited non-zero: {:?}", out.status);
            false
        }
        Err(e) => {
            println!("  raw spawn failed to even start (this IS the bug, reproduced): {e}");
            false
        }
    };

    println!("\n-- AFTER (the fix): SessionManager::create under the same minimal PATH --");
    let scratch =
        std::env::temp_dir().join(format!("omniagent-ade-path-verify-{}", std::process::id()));
    let data_dir = scratch.join("data");
    let project_dir = scratch.join("project");
    std::fs::create_dir_all(&project_dir).expect("create project dir");

    let sink: OutputSink = Arc::new(|_id: &str, _chunk: &[u8]| {});
    let manager = SessionManager::new(data_dir, sink);

    let result = manager.create(CreateSessionRequest {
        project: "path-verify".to_string(),
        engine: "claude".to_string(),
        cwd: project_dir.to_string_lossy().into_owned(),
        briefing: None,
        restore_id: None,
    });

    let after_ok = match &result {
        Ok(info) => {
            println!("  SessionManager::create SUCCEEDED: {info:?}");
            // Give the real claude process a moment to actually be alive
            // under the PID before we kill it -- proves this isn't just an
            // `Ok` return with a dead child.
            std::thread::sleep(std::time::Duration::from_millis(500));
            manager.kill(&info.id).expect("kill should succeed");
            true
        }
        Err(e) => {
            println!("  SessionManager::create FAILED: {e:#}");
            false
        }
    };

    // Restore this process's own PATH before printing the summary (not
    // that it matters much for a one-shot example, but good hygiene).
    match original_path {
        Some(p) => std::env::set_var("PATH", p),
        None => std::env::remove_var("PATH"),
    }

    println!("\n== summary ==");
    println!("  BEFORE (raw spawn under minimal PATH) succeeded: {before_ok}");
    println!("  AFTER  (SessionManager::create under minimal PATH) succeeded: {after_ok}");
    println!("  fix proven: {}", !before_ok && after_ok);
    println!(
        "  scratch dir left on disk for inspection: {}",
        scratch.display()
    );
}
