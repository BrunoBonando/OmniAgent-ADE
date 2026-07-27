//! Manual, real-world proof that **each Claude pane restores its own
//! conversation** — the multi-pane case, which is the only shape that can
//! catch the bug this exists for.
//!
//! Founder bug (Bruno, 2026-07-26): `claude --continue` continues *the most
//! recent conversation in the current directory*, and this app encourages
//! several Claude panes per project folder. After a reboot (tmux dies with
//! the machine, so every pane falls back to a fresh spawn at once) every pane
//! in a project restored the **same** conversation — panes 2..N silently
//! became duplicates of pane 1. A single-session test passes happily against
//! that behavior, which is why this harness opens two.
//!
//! Two panes, same directory, different secrets:
//!
//! ```sh
//! cd src-tauri
//! # 1. two claude panes in this folder; A is told PERSIMMON, B is told AUBERGINE
//! cargo run --example manual_multi_pane_conversation_verify -- start after
//! # 2. simulate a reboot: tmux is userspace, it does not survive one
//! tmux -L omniagent-ade kill-server
//! # 3. restore both by their original OmniAgent ids and ask each what it was told
//! cargo run --example manual_multi_pane_conversation_verify -- resume after
//! # 4. clean up
//! cargo run --example manual_multi_pane_conversation_verify -- kill after
//! ```
//!
//! **Pass** = pane A recalls PERSIMMON and pane B recalls AUBERGINE. Under
//! the old `--continue` behavior both panes answer the same word, and the
//! step-3 output says so out loud. The `<label>` argument namespaces the
//! session ids so a before/after pair can be run back to back in one folder.
//!
//! Run it with the Claude-Code child-session markers stripped from the
//! environment if you launch it from inside a Claude session —
//! `CLAUDE_CODE_CHILD_SESSION` makes the spawned `claude` disable transcript
//! saving, and a conversation that was never written to disk cannot be
//! resumed by anyone:
//!
//! ```sh
//! env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID \
//!   cargo run --example manual_multi_pane_conversation_verify -- start after
//! ```
//!
//! Uses the real `omniagent-ade` socket and the real `default_tmux` wiring,
//! deliberately: what's exercised here is exactly what the app does.

use std::collections::HashMap;
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use omniagent_ade_lib::sessions::{default_tmux, CreateSessionRequest, OutputSink, SessionManager};

/// The two panes: (id suffix, the word only this pane is ever told).
const PANES: [(&str, &str); 2] = [("a", "PERSIMMON"), ("b", "AUBERGINE")];

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mode = args.get(1).map(String::as_str).unwrap_or("start");
    let label = args.get(2).map(String::as_str).unwrap_or("probe");

    let data_dir = brain_core::Store::default_data_dir();
    let cwd = std::env::current_dir().unwrap();
    let tmux = default_tmux(&data_dir);

    println!("cwd (shared by both panes): {}", cwd.display());
    match &tmux {
        Some(t) => println!("tmux: {} on socket {:?}", t.binary().display(), t.socket()),
        None => println!("tmux: NOT FOUND — every pane is a direct spawn"),
    }
    if std::env::var("CLAUDE_CODE_CHILD_SESSION").is_ok() {
        println!(
            "\n!! CLAUDE_CODE_CHILD_SESSION is set: the spawned claude will refuse to save its\n\
             !! transcript, so nothing will be resumable. Re-run under `env -u ...` (module docs).\n"
        );
    }

    // One buffer per session id, so each pane's output can be judged on its
    // own — the whole point here is telling two panes apart.
    let buffers: Arc<Mutex<HashMap<String, String>>> = Arc::new(Mutex::new(HashMap::new()));
    let sink_buffers = Arc::clone(&buffers);
    let (tick_tx, tick_rx) = mpsc::channel::<()>();
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        sink_buffers
            .lock()
            .unwrap()
            .entry(id.to_string())
            .or_default()
            .push_str(&String::from_utf8_lossy(chunk));
        let _ = tick_tx.send(());
    });

    let manager = SessionManager::new(data_dir, sink).with_tmux(tmux.clone());

    let ids: Vec<String> = PANES
        .iter()
        .map(|(suffix, _)| format!("sess-mp-{label}-{suffix}"))
        .collect();

    if mode == "kill" {
        for id in &ids {
            match manager.create(request(&cwd, id)) {
                Ok(info) => {
                    let _ = manager.kill(&info.id);
                    println!("killed {id}");
                }
                Err(e) => println!("could not attach {id} to kill it: {e}"),
            }
        }
        println!("tmux sessions now: {:?}", live_sessions(&tmux));
        return;
    }

    // Open (or restore) both panes *first*, so both engines boot in parallel
    // and neither pane's conversation can be "the most recent" by virtue of
    // being asked first.
    for id in &ids {
        let info = manager.create(request(&cwd, id)).expect("create");
        println!(
            "pane {id}: restored={} persistent={}",
            info.restored, info.persistent
        );
    }
    println!("tmux sessions now: {:?}", live_sessions(&tmux));

    // Claude's TUI needs to be up before anything typed at it registers, and
    // a restore has to finish replaying the conversation on top of that —
    // which is why the resume half waits noticeably longer.
    let boot = if mode == "start" { 20 } else { 35 };
    println!("waiting {boot}s for both Claude TUIs to be ready...");
    std::thread::sleep(Duration::from_secs(boot));

    // `\r`, not `\n`: a full-screen TUI in raw mode reads Enter as carriage
    // return; a bare `\n` lands in the input box without ever submitting.
    for (id, (_, word)) in ids.iter().zip(PANES.iter()) {
        let prompt = match mode {
            "start" => format!("Remember the word {word}. Reply with just: noted.\r"),
            _ => "What word did I ask you to remember? Reply with just that word.\r".to_string(),
        };
        manager.write(id, &prompt).expect("write");
    }
    // A second Enter a few seconds later. Observed on a real restore: the
    // first `\r` can land while the TUI is still settling and leave the text
    // sitting unsent in the input box. A stray Enter on an already-submitted
    // prompt is a no-op, so this costs nothing when it isn't needed.
    std::thread::sleep(Duration::from_secs(5));
    for id in &ids {
        manager.write(id, "\r").expect("write");
    }

    // Drain until both panes have gone quiet for a while, or the cap.
    let cap = Instant::now() + Duration::from_secs(90);
    let mut last_output = Instant::now();
    while Instant::now() < cap && last_output.elapsed() < Duration::from_secs(12) {
        if tick_rx.recv_timeout(Duration::from_millis(500)).is_ok() {
            last_output = Instant::now();
        }
    }

    println!("\n================ WHAT EACH PANE SAYS ================");
    let buffers = buffers.lock().unwrap();
    let mut verdicts = Vec::new();
    for (id, (_, own_word)) in ids.iter().zip(PANES.iter()) {
        let other_word = PANES
            .iter()
            .find(|(_, w)| w != own_word)
            .map(|(_, w)| *w)
            .unwrap();
        let seen = buffers.get(id).cloned().unwrap_or_default();
        let has_own = seen.contains(own_word);
        let has_other = seen.contains(other_word);
        println!(
            "\n--- {id} (was told {own_word}) ---\n{}",
            tail(&seen, 1200)
        );
        println!(">>> contains {own_word}: {has_own} | contains {other_word}: {has_other}");
        verdicts.push(has_own && !has_other);
    }
    println!("\n================ VERDICT ================");
    if verdicts.iter().all(|ok| *ok) {
        println!("PASS — each pane recalled its own word and only its own word.");
    } else {
        println!(
            "FAIL — at least one pane did not have its own conversation back. \
             Two panes showing the same word is the `--continue` bug."
        );
    }
    if mode == "start" {
        println!(
            "\nNOT killing anything: exiting now is the 'user closed the app' half.\n\
             Next: `tmux -L omniagent-ade kill-server` (the reboot), then re-run with `resume`."
        );
    }

    // Exiting without kill() is exactly what a quitting app does.
    drop(buffers);
    std::mem::forget(manager);
}

fn request(cwd: &std::path::Path, restore_id: &str) -> CreateSessionRequest {
    CreateSessionRequest {
        project: "OmniAgent-ADE".to_string(),
        engine: "claude".to_string(),
        cwd: cwd.to_string_lossy().into_owned(),
        briefing: None,
        restore_id: Some(restore_id.to_string()),
    }
}

fn live_sessions(tmux: &Option<omniagent_ade_lib::tmux::Tmux>) -> Vec<String> {
    tmux.as_ref().map(|t| t.list_sessions()).unwrap_or_default()
}

/// The last `n` characters, which is where a TUI's final rendered state is.
fn tail(s: &str, n: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    chars[chars.len().saturating_sub(n)..].iter().collect()
}
