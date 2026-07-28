//! Manual, real-world drive of the **five-state session light** — the proof
//! that the heuristics in `sessions.rs` survive contact with a real engine,
//! which no automated test can give (a live `claude` needs the binary, an API
//! key, a folder-trust dance and a real conversation).
//!
//! Founder brief (Bruno, 2026-07-26): white/blue *thinking* · green *ready* ·
//! amber *awaiting approval* · red *error* · cyan *tool execution* — *"but
//! only green, yellow or red generate a notification"*.
//!
//! ```sh
//! cd src-tauri
//! cargo run --example manual_status_verify -- shell    # ~35s
//! cargo run --example manual_status_verify -- claude   # ~3min, real API calls
//! ```
//!
//! It prints a timestamped transition log plus the `notify` flag the
//! notifications layer will act on, and kills the session on the way out.
//! Everything goes through the real [`SessionManager`] and the real
//! [`default_daemon_sessions`] wiring — same code path the app runs, not a test-only
//! configuration.
//!
//! **What each run should show** (and what it actually showed on 2026-07-26 —
//! see this task's report for the captured logs):
//!
//! - `shell` — green at the prompt, cyan for `sleep 3`, green again. A failing
//!   command (`false`, `ls /nonexistent`) stays **green**: a stock shell's
//!   per-command exit status is not obtainable without shell integration, so
//!   red is honestly out of reach here. That is a documented gap, not a bug —
//!   see the module docs' "What does not fire, stated plainly".
//! - `claude` — green when idle, white/blue while it answers, amber when it
//!   asks permission, red after a failed tool, cyan while a slow Bash tool is
//!   visibly running.

use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use omniagent_ade_lib::sessions::{
    default_daemon_sessions, CreateSessionRequest, OutputSink, SessionManager, SessionStatusEvent,
    StatusSink,
};

/// One scripted keystroke: send `text` at `at` seconds from the start.
struct Step {
    at: u64,
    text: &'static str,
    note: &'static str,
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let engine = args.get(1).map(String::as_str).unwrap_or("shell");

    let data_dir = brain_core::Store::default_data_dir();
    // A scratch cwd, so a `claude` run doesn't inherit this repo's own
    // conversation history (or write anything into it).
    let cwd = std::env::temp_dir().join(format!("omniagent-status-probe-{}", std::process::id()));
    std::fs::create_dir_all(&cwd).expect("scratch cwd");

    let daemon_sessions = default_daemon_sessions(&data_dir);
    println!(
        "engine={engine}  cwd={}  daemon={}",
        cwd.display(),
        daemon_sessions
            .as_ref()
            .map(|t| t.binary().display().to_string())
            .unwrap_or_else(|| "NOT FOUND (cyan for claude/codex is unreachable)".into())
    );

    let (status_tx, status_rx) = mpsc::channel::<SessionStatusEvent>();
    let status_sink: StatusSink = Arc::new(move |event: &SessionStatusEvent| {
        let _ = status_tx.send(event.clone());
    });
    let sink: OutputSink = Arc::new(|_id: &str, _chunk: &[u8]| {});

    let manager = SessionManager::new(data_dir, sink)
        .with_daemon_sessions(daemon_sessions)
        .with_status_sink(status_sink);

    let info = manager
        .create(CreateSessionRequest {
            project: "status-probe".to_string(),
            engine: engine.to_string(),
            cwd: cwd.to_string_lossy().into_owned(),
            briefing: None,
            restore_id: None,
        })
        .expect("create session");
    println!("session {} (persistent={})\n", info.id, info.persistent);

    let (script, total) = script_for(engine);

    let start = Instant::now();
    let mut pending = script.into_iter().peekable();
    while start.elapsed() < Duration::from_secs(total) {
        let now = start.elapsed().as_secs();
        if pending.peek().is_some_and(|s| now >= s.at) {
            let step = pending.next().unwrap();
            println!(
                "\n[{:>5.1}s]  >>> {}  ({:?})",
                start.elapsed().as_secs_f32(),
                step.note,
                step.text
            );
            manager.write(&info.id, step.text).expect("write");
        }
        if let Ok(event) = status_rx.recv_timeout(Duration::from_millis(100)) {
            println!(
                "[{:>5.1}s]  {:<18} notify={}",
                start.elapsed().as_secs_f32(),
                event.status.as_str(),
                event.notify
            );
        }
    }

    println!(
        "\nfinal on-demand status: {:?}",
        manager.status(&info.id).map(|e| (e.status, e.notify))
    );
    manager.kill(&info.id).expect("kill");
    let _ = std::fs::remove_dir_all(&cwd);
    println!("session killed, scratch dir removed.");
}

fn script_for(engine: &str) -> (Vec<Step>, u64) {
    match engine {
        // A real terminal: idle green, a silent long command (the case only
        // `#{pane_current_command}` can see) cyan, and two real failures that
        // demonstrate the honest gap — neither can turn the light red.
        "shell" => (
            vec![
                Step {
                    at: 3,
                    text: "sleep 3\n",
                    note: "silent long command -> expect cyan",
                },
                Step {
                    at: 12,
                    text: "false\n",
                    note: "failing command -> red NOT expected",
                },
                Step {
                    at: 18,
                    text: "ls /nonexistent-path-xyz-123\n",
                    note: "failing command with stderr -> red NOT expected",
                },
                Step {
                    at: 24,
                    text: "for i in 1 2 3 4 5 6 7 8; do echo streaming-$i; sleep 0.2; done\n",
                    note: "streaming output -> expect cyan again",
                },
            ],
            35,
        ),
        // `\r`, not `\n`: a full-screen TUI in raw mode reads Enter as a
        // carriage return (see manual_daemon_persistence_verify's note).
        _ => (
            vec![
                Step {
                    at: 4,
                    text: "\r",
                    note: "accept the folder-trust prompt",
                },
                Step {
                    at: 10,
                    text: "Write exactly one short haiku about terminals. Do not use any tools.",
                    note: "type a pure text-generation prompt",
                },
                Step {
                    at: 12,
                    text: "\r",
                    note: "submit -> expect thinking (white/blue)",
                },
                Step {
                    at: 45,
                    text: "Use the Bash tool to run exactly: ls /nonexistent-path-xyz-123 \
                           - do not fix it, just report the exit code",
                    note: "type a failing-tool prompt",
                },
                Step {
                    at: 47,
                    text: "\r",
                    note: "submit -> expect amber, then red",
                },
                Step {
                    at: 75,
                    text: "\r",
                    note: "approve the permission prompt",
                },
                Step {
                    at: 110,
                    text: "Use the Bash tool to run: sleep 12 && echo SLOW_TOOL_DONE",
                    note: "type a slow-tool prompt",
                },
                Step {
                    at: 112,
                    text: "\r",
                    note: "submit -> expect cyan while it runs",
                },
                Step {
                    at: 125,
                    text: "\r",
                    note: "approve if it asked",
                },
            ],
            185,
        ),
    }
}
