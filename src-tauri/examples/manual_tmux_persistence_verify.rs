//! Manual, real-world proof of session persistence — run by hand, in
//! **separate OS processes**, which is the one thing an integration test
//! inside a single `cargo test` process can't fully simulate: the app really
//! exits between the two halves.
//!
//! Founder brief (Bruno, 2026-07-26): *"if the user closes the application
//! and comes back to that session, the terminal, claude, codex (whatever)
//! session must be restored."*
//!
//! ```sh
//! cd src-tauri
//! # 1. open a session and leave state in it, then let this process EXIT
//! cargo run --example manual_tmux_persistence_verify -- start shell my-probe
//! # 2. from a plain terminal, confirm the engine outlived the app:
//! tmux -L omniagent-ade ls
//! # 3. come back to it — the marker from step 1 must still be there
//! cargo run --example manual_tmux_persistence_verify -- resume shell my-probe
//! # 4. close the tab for real
//! cargo run --example manual_tmux_persistence_verify -- kill shell my-probe
//! ```
//!
//! `<engine>` is `shell`, `claude` or `codex`. For `claude`, `start` sends a
//! short prompt and `resume` reattaches — the reattached pane redraws the
//! *existing* conversation, which is the proof.
//!
//! Uses the real `omniagent-ade` socket and the real `default_tmux` wiring —
//! deliberately, so what's exercised here is exactly what the app does, not a
//! test-only configuration. Run `kill` when you're done so you don't leave an
//! engine running.

use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use omniagent_ade_lib::sessions::{
    default_tmux, CreateSessionRequest, OutputSink, SessionManager, SessionStatusEvent, StatusSink,
};
use omniagent_ade_lib::tmux;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("start");
    let engine = args.get(2).map(String::as_str).unwrap_or("shell");
    let label = args.get(3).map(String::as_str).unwrap_or("manual-probe");
    let id = format!("sess-manual-{label}");

    let data_dir = brain_core::Store::default_data_dir();
    let cwd = std::env::current_dir().unwrap();

    let tmux = default_tmux(&data_dir);
    match &tmux {
        Some(t) => println!("tmux: {} on socket {:?}", t.binary().display(), t.socket()),
        None => println!("tmux: NOT FOUND — sessions will not persist (fallback mode)"),
    }
    println!(
        "session id: {id}  ->  tmux session: {}",
        tmux::session_name(&id)
    );

    let (tx, rx) = mpsc::channel::<(String, Vec<u8>)>();
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        let _ = tx.send((id.to_string(), chunk.to_vec()));
    });
    let (status_tx, status_rx) = mpsc::channel::<SessionStatusEvent>();
    let status_sink: StatusSink = Arc::new(move |event: &SessionStatusEvent| {
        let _ = status_tx.send(event.clone());
    });

    let manager = SessionManager::new(data_dir, sink)
        .with_tmux(tmux.clone())
        .with_status_sink(status_sink);

    if mode == "kill" {
        // Re-attach just so there's a handle to kill, then close the tab.
        let info = manager
            .create(request(engine, &cwd, Some(id.clone())))
            .expect("create/attach");
        manager.kill(&info.id).expect("kill");
        println!("killed. tmux sessions now: {:?}", live_sessions(&tmux));
        return;
    }

    // `restore_id` is the only way to pin an id, and this script needs a
    // known one so its second half can find the session again — so both
    // modes pass it. Note what that means for `start claude`: the manager
    // sees a restore with no live tmux session, hands `claude` a
    // `--continue` it may have nothing to continue, and the retry-without-it
    // fallback fires. That is deliberate here — it's the real-`claude` proof
    // of the booby trap documented in `sessions.rs`, which an earlier draft
    // of this very file is how we found.
    let info = manager
        .create(request(engine, &cwd, Some(id.clone())))
        .expect("create");

    println!(
        "created: id={} restored={} persistent={}",
        info.id, info.restored, info.persistent
    );
    println!("tmux sessions now: {:?}", live_sessions(&tmux));

    match (mode, engine) {
        ("start", "shell") => {
            manager
                .write(&info.id, "OMNIAGENT_MANUAL_PROBE=alive-from-run-1\n")
                .unwrap();
            manager
                .write(&info.id, "echo 'MARKER: run-1 wrote this line'\n")
                .unwrap();
        }
        ("resume", "shell") => {
            manager
                .write(&info.id, "echo PROBE_VALUE_IS:$OMNIAGENT_MANUAL_PROBE\n")
                .unwrap();
        }
        // `\r`, not `\n`: a full-screen TUI in raw mode (Claude's own) reads
        // Enter as carriage return — a bare `\n` lands in its input box
        // without ever submitting, which is exactly what happened the first
        // time this was run by hand.
        ("start", "claude") => {
            // Give Claude's TUI time to boot before typing into it.
            std::thread::sleep(Duration::from_secs(8));
            manager
                .write(
                    &info.id,
                    "Remember the word PERSIMMON. Reply with just: noted.\r",
                )
                .unwrap();
        }
        ("resume", "claude") => {
            std::thread::sleep(Duration::from_secs(4));
            manager
                .write(&info.id, "What word did I ask you to remember?\r")
                .unwrap();
        }
        _ => {}
    }

    // Drain output for a while and print it, so the operator can read what
    // actually came back.
    let deadline = Instant::now() + Duration::from_secs(if engine == "claude" { 30 } else { 6 });
    let mut seen = String::new();
    while Instant::now() < deadline {
        if let Ok((_, chunk)) = rx.recv_timeout(Duration::from_millis(200)) {
            seen.push_str(&String::from_utf8_lossy(&chunk));
        }
        while let Ok(event) = status_rx.try_recv() {
            println!(
                "[status] {} (notify={})",
                event.status.as_str(),
                event.notify
            );
        }
    }

    println!("\n---- raw pty output ----\n{seen}\n---- end ----");
    println!("on-demand status: {:?}", manager.status(&info.id));
    println!(
        "\nNOT killing the session — this process is about to exit, which is the \
         'user closed the app' half of the test.\ntmux sessions still alive: {:?}",
        live_sessions(&tmux)
    );

    // Deliberately leak the manager: exiting without kill() is exactly what a
    // quitting app does.
    std::mem::forget(manager);
}

fn request(
    engine: &str,
    cwd: &std::path::Path,
    restore_id: Option<String>,
) -> CreateSessionRequest {
    CreateSessionRequest {
        project: "OmniAgent-ADE".to_string(),
        engine: engine.to_string(),
        cwd: cwd.to_string_lossy().into_owned(),
        briefing: None,
        restore_id,
    }
}

fn live_sessions(tmux: &Option<omniagent_ade_lib::tmux::Tmux>) -> Vec<String> {
    tmux.as_ref().map(|t| t.list_sessions()).unwrap_or_default()
}
