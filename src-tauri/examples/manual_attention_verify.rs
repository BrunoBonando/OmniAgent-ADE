//! Manual, run-by-hand proof that the founder-feedback attention feature
//! (2026-07-24 — Bruno, verbatim: "every claude session[...] can notify the
//! app whenever it needs attention[...] generate a badge") actually detects
//! a real moment a human would want to be notified — NOT part of
//! `cargo test` (real `claude` CLI, real interactive TUI, takes a while,
//! and — unlike `manual_claude_verify.rs`, which reuses this repo's own
//! already-trusted directory — this one deliberately spawns in a **fresh,
//! never-seen-before** scratch directory so `claude`'s workspace-trust
//! dialog *and* its tool-permission dialog both genuinely appear from
//! scratch, exactly like a brand-new OmniAgent-ADE project would look to a
//! real user the first time they open a terminal in it. Side effect worth
//! knowing about: this permanently adds that scratch path to `claude`'s own
//! trusted-folder list on this machine (same as any real interactive
//! `claude` session in a new directory would) — harmless, but it does mean
//! re-running this leaves a small trail of one-off trusted entries behind.
//!
//! Drives the PTY the same way `sessions.rs`'s module docs describe the
//! investigation being done: send Claude a prompt that requires it to call
//! the Bash tool, accept the workspace-trust dialog (sending `\r`, matching
//! how a real user would just hit Enter), then watch whether
//! `SessionManager`'s attention detection actually fires when Claude's own
//! tool-permission dialog ("Do you want to proceed?") shows up waiting for
//! a human's yes/no — the exact moment Bruno's feedback is about.
//!
//! Run:
//! ```sh
//! cargo run -p omniagent-ade --example manual_attention_verify
//! ```

use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use omniagent_ade_lib::sessions::{
    AttentionSink, CreateSessionRequest, OutputSink, SessionManager,
};

fn main() {
    let scratch = std::env::temp_dir().join(format!(
        "omniagent-ade-attention-verify-{}",
        std::process::id()
    ));
    let data_dir = scratch.join("data");
    let project_dir = scratch.join("project");
    std::fs::create_dir_all(&project_dir).expect("create project dir");

    println!("== manual attention verify ==");
    println!("data_dir:    {}", data_dir.display());
    println!(
        "project_dir: {} (fresh — never trusted before)",
        project_dir.display()
    );

    let captured = Arc::new(std::sync::Mutex::new(String::new()));
    let captured_sink = Arc::clone(&captured);
    let sink: OutputSink = Arc::new(move |_id: &str, chunk: &[u8]| {
        let text = String::from_utf8_lossy(chunk);
        print!("{text}");
        use std::io::Write;
        let _ = std::io::stdout().flush();
        captured_sink.lock().unwrap().push_str(&text);
    });

    let (attention_tx, attention_rx) = mpsc::channel::<(String, Instant)>();
    let attention_sink: AttentionSink = Arc::new(move |id: &str| {
        let _ = attention_tx.send((id.to_string(), Instant::now()));
    });

    let manager = SessionManager::new(data_dir, sink).with_attention_sink(attention_sink);

    let start = Instant::now();
    let info = manager
        .create(CreateSessionRequest {
            project: "attention-verify-project".to_string(),
            engine: "claude".to_string(),
            cwd: project_dir.to_string_lossy().into_owned(),
            briefing: None,
            restore_id: None,
        })
        .expect("session_create should succeed");
    println!("\n-- session created: {info:?} --\n");

    // Let claude's TUI boot far enough to show the workspace-trust dialog.
    std::thread::sleep(Duration::from_secs(5));

    println!("\n-- accepting workspace-trust dialog (Enter on its default 'Yes') --\n");
    manager.write(&info.id, "\r").expect("write should succeed");
    std::thread::sleep(Duration::from_secs(3));

    println!("\n-- asking claude to run a Bash command (needs permission) --\n");
    manager
        .write(
            &info.id,
            "Use the Bash tool to run `touch /tmp/omniagent-ade-attention-verify-probe.txt`. \
             Do it now, do not ask for a permission bypass, just call the tool normally.",
        )
        .expect("write should succeed");
    std::thread::sleep(Duration::from_millis(500));
    manager.write(&info.id, "\r").expect("write should succeed"); // submit

    // A real permission dialog should appear well within a minute even on a
    // slow API round trip; give it a generous window anyway.
    let deadline = Duration::from_secs(90);
    let fired = match attention_rx.recv_timeout(deadline) {
        Ok((id, at)) => {
            println!(
                "\n\n== ATTENTION EVENT FIRED == session={id} elapsed={:.1}s",
                at.duration_since(start).as_secs_f64()
            );
            true
        }
        Err(_) => {
            println!(
                "\n\n== NO attention event within {}s ==",
                deadline.as_secs()
            );
            false
        }
    };

    // Prove the debounce too: if the dialog is still sitting there
    // re-rendering, no *further* event should show up immediately.
    let extra = attention_rx.recv_timeout(Duration::from_secs(3));
    println!("extra event within 3s of the first one: {}", extra.is_ok());

    manager.kill(&info.id).expect("kill should succeed");

    let full = captured.lock().unwrap().clone();
    println!(
        "\n== raw permission-dialog text present in captured output: {} ==",
        full.contains("Do you want to")
    );

    println!("\n== summary ==");
    println!("  attention event fired: {fired}");
    println!(
        "  scratch dir left on disk for inspection: {}",
        scratch.display()
    );
}
