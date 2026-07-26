//! Manual, real-world proof that **a pane is never handed to the user dead** —
//! the black-screen bug, and the four shapes that must keep working around it.
//!
//! Founder bug (Bruno, 2026-07-26): *"every terminal is a black screen"*. Every
//! transcript in his data dir held literally `no sessions\r` and every
//! lifecycle file an `exit_code: 1` a second after start. Cause: a restore of
//! a session created before `--resume` existed spawns `claude --resume <uuid>`
//! for a conversation that isn't there; Claude exits 1 after ~1.2 s; tmux
//! (`remain-on-exit off`) destroys the session the instant the command dies;
//! the `attach-session` this app then runs finds nothing, prints `no sessions`
//! and exits — a black rectangle with no signal.
//!
//! ```sh
//! cd src-tauri
//! cargo run --example manual_black_pane_verify              # every case
//! cargo run --example manual_black_pane_verify -- restore   # just one
//!
//! # point `restore` at one of the user's ACTUAL black-screen sessions:
//! # its id, and the cwd from its .lifecycle.jsonl `start` event
//! cargo run --example manual_black_pane_verify -- restore \
//!   sess-18c5c98fb5d2c0c0-0 /Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE
//! ```
//!
//! Even pointed at a real session id this stays on a **scratch data dir and a
//! private tmux socket**, so it reads the user's real Claude conversation store
//! (which is the point — that is where the missing conversation is) without
//! touching the app's own transcripts, tmux sessions or settings.
//!
//! Cases:
//! - `restore` — **the bug**: restore an id whose derived conversation UUID has
//!   never existed. Must come back as a live, rendering Claude.
//! - `fresh` — a brand-new Claude pane (no `restore_id`).
//! - `shell` — a `$SHELL` pane, which must never pay a liveness probe.
//! - `reattach` — create, leave it running, create again with the same id: must
//!   attach to the *same* tmux session rather than spawning a second engine.
//! - `broken` — an engine that cannot start at all. Uses `codex`, which is
//!   genuinely not installed on this machine, so this is the real
//!   "engine-not-installed" failure rather than a simulated one. Must surface a
//!   readable diagnosis in the pane rather than nothing.
//!
//! Everything runs on a **private tmux socket and a scratch data dir**, so it
//! can never see, resize, or kill one of the user's real ADE sessions.
//!
//! Run it with the Claude-Code child-session markers stripped if you launch it
//! from inside a Claude session (same caveat as
//! `manual_multi_pane_conversation_verify`):
//!
//! ```sh
//! env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID \
//!   cargo run --example manual_black_pane_verify
//! ```

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use omniagent_ade_lib::sessions::{CreateSessionRequest, OutputSink, SessionManager};
use omniagent_ade_lib::tmux::{self, Tmux};

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let only = args.get(1).cloned();
    // Optional: a real session id and its cwd, so `restore` can be aimed at
    // one of the user's own black-screen sessions rather than a synthetic id.
    let real: Option<(String, String)> = match (args.get(2), args.get(3)) {
        (Some(id), Some(cwd)) => Some((id.clone(), cwd.clone())),
        _ => None,
    };

    let cases: Vec<&str> = match only.as_deref() {
        Some(c) => vec![c],
        None => vec!["restore", "fresh", "shell", "reattach", "broken"],
    };

    let mut results: Vec<(String, bool, String)> = Vec::new();
    for case in cases {
        let (ok, note) = run_case(case, real.as_ref());
        results.push((case.to_string(), ok, note));
    }

    println!("\n================ VERDICT ================");
    for (case, ok, note) in &results {
        println!(
            "{:>10}: {}  {note}",
            case,
            if *ok { "PASS" } else { "FAIL" }
        );
    }
    if results.iter().all(|(_, ok, _)| *ok) {
        println!("\nALL PASS — no pane came back black.");
    } else {
        println!("\nFAILURES ABOVE — a pane was handed over dead.");
        std::process::exit(1);
    }
}

fn run_case(case: &str, real: Option<&(String, String)>) -> (bool, String) {
    println!("\n\n######## case: {case} ########");
    let scratch = std::env::temp_dir().join(format!(
        "omniagent-blackpane-{case}-{}",
        std::process::id()
    ));
    let _ = std::fs::create_dir_all(&scratch);
    let socket = format!("blackpane-{case}-{}", std::process::id());
    let cwd = match real {
        Some((_, dir)) if case == "restore" => std::path::PathBuf::from(dir),
        _ => std::env::current_dir().unwrap(),
    };

    let tmux = Tmux::resolve(&socket, std::env::var("PATH").ok().as_deref())
        .expect("tmux must be installed for this harness")
        .with_config(tmux::write_config(&scratch).expect("write tmux.conf"));
    println!("tmux: {} on socket {socket}", tmux.binary().display());

    let buffers: Arc<Mutex<HashMap<String, Vec<u8>>>> = Arc::new(Mutex::new(HashMap::new()));
    let sink_buffers = Arc::clone(&buffers);
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        sink_buffers
            .lock()
            .unwrap()
            .entry(id.to_string())
            .or_default()
            .extend_from_slice(chunk);
    });

    let manager = SessionManager::new(scratch.clone(), sink).with_tmux(Some(tmux.clone()));

    // A per-run unique id, so the derived Claude conversation UUID has
    // provably never existed — exactly a pre-`--resume` session being
    // restored, which is the founder bug.
    let uniq = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    );

    let (engine, restore_id) = match case {
        "restore" => (
            "claude",
            Some(match real {
                // One of the user's real black-screen sessions.
                Some((id, _)) => id.clone(),
                None => format!("sess-blackpane-{uniq}"),
            }),
        ),
        "fresh" => ("claude", None),
        "shell" => ("shell", None),
        "reattach" => ("claude", Some(format!("sess-reattach-{uniq}"))),
        // `codex` is not installed on this machine — a real
        // engine-not-installed failure, not a simulated one.
        "broken" => ("codex", None),
        other => panic!("unknown case {other}"),
    };

    let req = CreateSessionRequest {
        project: "blackpane".to_string(),
        engine: engine.to_string(),
        cwd: cwd.to_string_lossy().into_owned(),
        briefing: None,
        restore_id: restore_id.clone(),
    };

    let t0 = Instant::now();
    let info = match manager.create(req) {
        Ok(i) => i,
        Err(e) => {
            cleanup(&tmux, &scratch);
            return (false, format!("create() failed outright: {e}"));
        }
    };
    let create_ms = t0.elapsed().as_millis();
    println!(
        "created {} in {create_ms}ms (restored={} persistent={})",
        info.id, info.restored, info.persistent
    );

    // The reattach case's whole point: quit the app *without* closing the
    // tab, relaunch, and land back in the same live engine. "Quitting" is
    // dropping the manager without `kill()` — the tmux server keeps the
    // engine — and "relaunching" is a brand-new `SessionManager` over the
    // same tmux server and data dir, which is exactly what `create` sees on a
    // real relaunch. Re-creating through the *same* manager cannot test this:
    // it is documented to refuse an id that is still live in this app.
    let mut reattach_note = String::new();
    let mut info = info;
    let mut manager = manager;
    if case == "reattach" {
        // Let the first engine settle so there is something live to attach to.
        std::thread::sleep(Duration::from_secs(10));
        let before = tmux.list_sessions();
        println!("before 'quitting': tmux sessions {before:?}");

        // The app quits: the attach clients die, the tmux server does not.
        std::mem::forget(manager);

        let relaunched = SessionManager::new(scratch.clone(), {
            let b = Arc::clone(&buffers);
            Arc::new(move |id: &str, chunk: &[u8]| {
                b.lock().unwrap().entry(id.to_string()).or_default().extend_from_slice(chunk);
            })
        })
        .with_tmux(Some(tmux.clone()));

        let second = relaunched
            .create(CreateSessionRequest {
                project: "blackpane".to_string(),
                engine: "claude".to_string(),
                cwd: cwd.to_string_lossy().into_owned(),
                briefing: None,
                restore_id: restore_id.clone(),
            })
            .expect("a relaunched app must be able to re-attach its own session");
        let after = tmux.list_sessions();
        println!(
            "after 'relaunch': restored={} persistent={} tmux sessions {after:?}",
            second.restored, second.persistent
        );
        reattach_note = format!(
            "restored={} same_session={} sessions before={before:?} after={after:?}",
            second.restored,
            before == after
        );
        // A restore that spawned a *second* engine instead of attaching is the
        // failure this case exists to catch, and it shows up as two sessions.
        assert!(
            second.restored && before == after && after.len() == 1,
            "restore must have attached to the one live session, not spawned another"
        );
        info = second;
        manager = relaunched;
    }

    // Give the engine time to boot and paint.
    let settle = if engine == "shell" { 3 } else { 18 };
    println!("settling {settle}s...");
    std::thread::sleep(Duration::from_secs(settle));

    let bytes = buffers
        .lock()
        .unwrap()
        .get(&info.id)
        .map(|b| b.len())
        .unwrap_or(0);
    let raw = buffers
        .lock()
        .unwrap()
        .get(&info.id)
        .map(|b| String::from_utf8_lossy(b).into_owned())
        .unwrap_or_default();
    let sessions = tmux.list_sessions();
    let pane_cmd = tmux.pane_current_command(&tmux::session_name(&info.id));
    let screen = tmux
        .capture_pane(&tmux::session_name(&info.id))
        .unwrap_or_default();
    let visible: String = strip_ansi(&raw);

    println!("--- PTY bytes: {bytes}");
    println!("--- tmux sessions: {sessions:?}");
    println!("--- pane_current_command: {pane_cmd:?}");
    println!(
        "--- captured pane (first 600 chars):\n{}",
        head(screen.trim(), 600)
    );
    println!(
        "--- what the user would see (stripped PTY tail, 600 chars):\n{}",
        tail(visible.trim(), 600)
    );

    let says_no_sessions = visible.contains("no sessions") || visible.contains("no server running");
    let blank = visible.trim().is_empty();

    let ok = match case {
        // A working engine renders a real TUI: plenty of bytes, no tmux
        // error text, and a non-empty screen.
        "restore" | "fresh" | "reattach" => {
            !says_no_sessions && !blank && bytes > 500 && !screen.trim().is_empty()
        }
        "shell" => !says_no_sessions && !blank && create_ms < 2000,
        // The engine genuinely cannot start; the requirement is only that
        // the user is *told*, not that it works.
        "broken" => !blank && (visible.contains("OmniAgent") || visible.contains("could not")),
        _ => false,
    };

    manager.kill(&info.id).ok();
    cleanup(&tmux, &scratch);

    let note = format!(
        "bytes={bytes} blank={blank} no_sessions_text={says_no_sessions} create_ms={create_ms} {reattach_note}"
    );
    (ok, note)
}

fn cleanup(tmux: &Tmux, scratch: &std::path::Path) {
    tmux.kill_server();
    let _ = std::fs::remove_dir_all(scratch);
}

/// Crude ANSI/OSC stripper — enough to answer "would the user see anything".
fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            match chars.peek() {
                Some('[') => {
                    chars.next();
                    for c2 in chars.by_ref() {
                        if c2.is_ascii_alphabetic() || c2 == '~' {
                            break;
                        }
                    }
                }
                Some(']') => {
                    chars.next();
                    for c2 in chars.by_ref() {
                        if c2 == '\u{7}' {
                            break;
                        }
                    }
                }
                _ => {
                    chars.next();
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

fn tail(s: &str, n: usize) -> String {
    let chars: Vec<char> = s.chars().collect();
    chars[chars.len().saturating_sub(n)..].iter().collect()
}

fn head(s: &str, n: usize) -> String {
    s.chars().take(n).collect()
}
