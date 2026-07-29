//! PTY lifecycle integration tests — plain Rust, no Tauri app/window
//! involved. Exercises `omniagent_ade_lib::sessions::SessionManager`
//! directly against the real daemon and real PTYs (`$SHELL` processes),
//! matching PLAN.md
//! Task 5.1's exact asks:
//!   1. shell session + `echo hi\n` -> observed output contains "hi"
//!   2. `kill` reaps the child (no zombie)
//!   3. transcript file exists and is redacted

use std::collections::HashMap;
use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use omniagent_ade_lib::daemon::{self, DaemonSessions};
use omniagent_ade_lib::sessions::{CreateSessionRequest, OutputSink, SessionManager};
use omniagent_pty_daemon::DaemonServer;

struct RealServer {
    stop: Option<tokio::sync::oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl RealServer {
    fn start(socket: std::path::PathBuf) -> Self {
        let (ready_tx, ready_rx) = mpsc::channel();
        let (stop, stopped) = tokio::sync::oneshot::channel();
        let thread = std::thread::spawn(move || {
            let runtime = tokio::runtime::Runtime::new().unwrap();
            runtime.block_on(async move {
                let server = DaemonServer::bind(socket).await.unwrap();
                ready_tx.send(()).unwrap();
                server.run_until(stopped).await.unwrap();
            });
        });
        ready_rx.recv_timeout(Duration::from_secs(3)).unwrap();
        Self {
            stop: Some(stop),
            thread: Some(thread),
        }
    }
}

impl Drop for RealServer {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}

fn test_daemon(temp: &tempfile::TempDir) -> (DaemonSessions, RealServer) {
    let socket = temp.path().join("runtime/daemon.sock");
    let server = RealServer::start(socket.clone());
    (DaemonSessions::new(socket), server)
}

fn silent_sink() -> OutputSink {
    Arc::new(|_id: &str, _chunk: &[u8]| {})
}

fn shell_request(cwd: &std::path::Path) -> CreateSessionRequest {
    CreateSessionRequest {
        project: "demo".to_string(),
        engine: "shell".to_string(),
        cwd: cwd.to_string_lossy().into_owned(),
        briefing: None,
        restore_id: None,
    }
}

#[test]
fn shell_echo_is_observed_on_the_output_sink() {
    let tmp = tempfile::tempdir().unwrap();
    let (tx, rx) = mpsc::channel::<(String, Vec<u8>)>();
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        let _ = tx.send((id.to_string(), chunk.to_vec()));
    });

    let (daemon, _server) = test_daemon(&tmp);
    let manager =
        SessionManager::new(tmp.path().to_path_buf(), sink).with_daemon_sessions(Some(daemon));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    manager.write(&info.id, "echo hi\n").unwrap();

    let mut collected = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut found = false;
    while Instant::now() < deadline {
        match rx.recv_timeout(Duration::from_millis(200)) {
            Ok((id, chunk)) => {
                assert_eq!(id, info.id, "event id must match the session id");
                collected.extend_from_slice(&chunk);
                if String::from_utf8_lossy(&collected).contains("hi") {
                    found = true;
                    break;
                }
            }
            Err(_) => continue,
        }
    }

    assert!(
        found,
        "expected PTY output to contain 'hi', got: {:?}",
        String::from_utf8_lossy(&collected)
    );

    manager.kill(&info.id).unwrap();
}

#[test]
fn kill_removes_the_daemon_owned_process_without_a_tauri_proxy_pid() {
    let tmp = tempfile::tempdir().unwrap();
    let (daemon, _server) = test_daemon(&tmp);
    let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink())
        .with_daemon_sessions(Some(daemon.clone()));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    assert_eq!(
        manager.pid(&info.id),
        None,
        "the compatibility adapter must not own a proxy child"
    );

    manager.kill(&info.id).unwrap();
    assert!(
        !daemon
            .list_sessions()
            .contains(&daemon::session_name(&info.id)),
        "kill must synchronously remove the daemon-owned session"
    );
}

#[test]
fn transcript_file_exists_and_secrets_are_redacted() {
    let tmp = tempfile::tempdir().unwrap();
    let (daemon, _server) = test_daemon(&tmp);
    let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink())
        .with_daemon_sessions(Some(daemon));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    manager.write(&info.id, "echo API_KEY=abc123\n").unwrap();

    // Give the reader thread time to observe the echoed line and flush it
    // (line-buffered) to the transcript file before we kill the session.
    std::thread::sleep(Duration::from_millis(800));

    // No sleep needed here: `SessionManager::kill` joins the reader thread
    // before returning, so any transcript content still sitting in its
    // line-buffer (including a trailing partial line with no `\n` yet) is
    // guaranteed to be redacted + flushed to disk by the time this call
    // returns — this is what actually caught the real bug (see sessions.rs
    // `SessionHandle::reader_thread` docs): a fullscreen-TUI engine that
    // rarely emits bare `\n` could otherwise lose its final flush to a
    // detached thread racing the caller's own process exit.
    manager.kill(&info.id).unwrap();

    let transcript_path = tmp
        .path()
        .join("transcripts")
        .join(format!("{}.log", info.id));
    assert!(transcript_path.exists(), "transcript file should exist");

    let contents = std::fs::read_to_string(&transcript_path).unwrap();
    assert!(
        !contents.contains("abc123"),
        "transcript must not contain the raw secret: {contents}"
    );
    assert!(
        contents.contains("[redacted]"),
        "transcript should show the redaction marker: {contents}"
    );
}

#[test]
fn write_and_resize_on_unknown_session_return_errors_not_panics() {
    let tmp = tempfile::tempdir().unwrap();
    let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink());

    assert!(manager.write("no-such-session", "hi\n").is_err());
    assert!(manager.resize("no-such-session", 80, 24).is_err());
    assert!(manager.kill("no-such-session").is_err());
}

/// Task (founder feedback, 2026-07-24 — Bruno, verbatim): "the user can add
/// multiple sessions within one project" — this is `SessionManager` doing
/// exactly what the sidebar's per-project "+"/⌘T button already calls
/// (`session_create` in `commands.rs` -> this same `create`), just exercised
/// directly rather than through a GUI click that couldn't be automated in
/// this environment (no Accessibility/Screen-Recording/Safari-remote-
/// automation permission available to drive the real Tauri window). Proves
/// three concurrent same-project sessions are independent on every axis that
/// matters: distinct ids, no cross-talk between their output streams, and
/// killing one leaves its siblings alive and still responsive.
#[test]
fn multiple_concurrent_sessions_in_the_same_project_are_independent() {
    let tmp = tempfile::tempdir().unwrap();
    let (tx, rx) = mpsc::channel::<(String, Vec<u8>)>();
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        let _ = tx.send((id.to_string(), chunk.to_vec()));
    });
    let (daemon, _server) = test_daemon(&tmp);
    let manager = SessionManager::new(tmp.path().to_path_buf(), sink)
        .with_daemon_sessions(Some(daemon.clone()));

    let a = manager.create(shell_request(tmp.path())).unwrap();
    let b = manager.create(shell_request(tmp.path())).unwrap();
    let c = manager.create(shell_request(tmp.path())).unwrap();

    assert_ne!(a.id, b.id);
    assert_ne!(b.id, c.id);
    assert_ne!(a.id, c.id);
    for s in [&a, &b, &c] {
        assert_eq!(s.project, "demo");
    }

    manager.write(&a.id, "echo FROM_A\n").unwrap();
    manager.write(&b.id, "echo FROM_B\n").unwrap();
    manager.write(&c.id, "echo FROM_C\n").unwrap();

    let mut seen: HashMap<String, String> = HashMap::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline
        && !(seen.get(&a.id).is_some_and(|s| s.contains("FROM_A"))
            && seen.get(&b.id).is_some_and(|s| s.contains("FROM_B"))
            && seen.get(&c.id).is_some_and(|s| s.contains("FROM_C")))
    {
        if let Ok((id, chunk)) = rx.recv_timeout(Duration::from_millis(200)) {
            seen.entry(id)
                .or_default()
                .push_str(&String::from_utf8_lossy(&chunk));
        }
    }

    assert!(
        seen.get(&a.id).is_some_and(|s| s.contains("FROM_A")),
        "a's output: {:?}",
        seen.get(&a.id)
    );
    assert!(
        seen.get(&b.id).is_some_and(|s| s.contains("FROM_B")),
        "b's output: {:?}",
        seen.get(&b.id)
    );
    assert!(
        seen.get(&c.id).is_some_and(|s| s.contains("FROM_C")),
        "c's output: {:?}",
        seen.get(&c.id)
    );

    // No cross-talk: each session's stream carries only its own marker.
    assert!(!seen[&a.id].contains("FROM_B") && !seen[&a.id].contains("FROM_C"));
    assert!(!seen[&b.id].contains("FROM_A") && !seen[&b.id].contains("FROM_C"));
    assert!(!seen[&c.id].contains("FROM_A") && !seen[&c.id].contains("FROM_B"));

    // Killing one session (closing that tab) leaves its siblings alive...
    manager.kill(&b.id).unwrap();
    assert!(
        daemon
            .list_sessions()
            .contains(&daemon::session_name(&a.id)),
        "a should still be alive after b is killed"
    );
    assert!(
        daemon
            .list_sessions()
            .contains(&daemon::session_name(&c.id)),
        "c should still be alive after b is killed"
    );

    // ...and still genuinely responsive, not just present in the map.
    manager.write(&a.id, "echo STILL_ALIVE_A\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut still_alive = false;
    while Instant::now() < deadline {
        if let Ok((id, chunk)) = rx.recv_timeout(Duration::from_millis(200)) {
            if id == a.id && String::from_utf8_lossy(&chunk).contains("STILL_ALIVE_A") {
                still_alive = true;
                break;
            }
        }
    }
    assert!(
        still_alive,
        "session a should still be responsive after a sibling was killed"
    );

    manager.kill(&a.id).unwrap();
    manager.kill(&c.id).unwrap();
}

#[test]
fn resize_a_live_session_succeeds() {
    let tmp = tempfile::tempdir().unwrap();
    let (daemon, _server) = test_daemon(&tmp);
    let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink())
        .with_daemon_sessions(Some(daemon));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    manager.resize(&info.id, 120, 40).unwrap();

    manager.kill(&info.id).unwrap();
}

/// Founder feedback (2026-07-24 — Bruno, verbatim): "every claude session
/// can notify the app whenever it needs attention". `sessions.rs`'s module
/// docs record the investigation (hooks need user config -> out; plain BEL
/// is just OSC-title-terminator noise -> out; `OSC 777 notify` is real but
/// gated behind an undocumented Warp-only handshake -> out) that landed on
/// plain-text matching against the exact copy stock `claude` prints in its
/// tool-permission dialog. This test can't spawn a real `claude` (no API
/// key / network / trusted-workspace prompt in CI, and the input here would
/// need to go through Claude's own conversation loop rather than just being
/// echoed), so it proves the wiring the same dependency-free way
/// `transcript_file_exists_and_secrets_are_redacted` above proves
/// redaction: a `shell` session `echo`ing the exact marker text stands in
/// for Claude printing it (the reader thread's detection is a plain
/// substring match on raw output — see the daemon-output processor
/// for why it's deliberately not hard-gated to `engine == "claude"`, this
/// test is exactly why). A *real* end-to-end proof against an actual
/// `claude` CLI is `examples/manual_attention_verify.rs`, run by hand per
/// its own doc comment.
#[test]
fn attention_marker_burst_fires_exactly_one_debounced_event() {
    let tmp = tempfile::tempdir().unwrap();
    let (tx, rx) = mpsc::channel::<String>();

    let attention_hits: omniagent_ade_lib::sessions::AttentionSink = {
        let tx = tx.clone();
        Arc::new(move |id: &str| {
            let _ = tx.send(id.to_string());
        })
    };

    let (daemon, _server) = test_daemon(&tmp);
    let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink())
        .with_daemon_sessions(Some(daemon))
        .with_attention_sink(attention_hits);
    let info = manager.create(shell_request(tmp.path())).unwrap();

    // Simulate the exact marker text arriving in a burst — a real pending
    // permission prompt redraws its box repeatedly while the user hasn't
    // acted, which is exactly the storm `AttentionDebouncer` exists to
    // collapse into one event.
    for _ in 0..5 {
        manager
            .write(&info.id, "echo 'Do you want to proceed?'\n")
            .unwrap();
        std::thread::sleep(Duration::from_millis(150));
    }

    // Give the reader thread a little more time to drain the last echo.
    std::thread::sleep(Duration::from_millis(500));

    let mut hits = Vec::new();
    while let Ok(id) = rx.recv_timeout(Duration::from_millis(200)) {
        hits.push(id);
    }

    assert_eq!(
        hits,
        vec![info.id.clone()],
        "expected exactly one debounced attention event for the burst, got: {hits:?}"
    );

    manager.kill(&info.id).unwrap();
}
