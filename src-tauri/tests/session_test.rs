//! PTY lifecycle integration tests — plain Rust, no Tauri app/window
//! involved. Exercises `omniagent_ade_lib::sessions::SessionManager`
//! directly against real PTYs (real `$SHELL` processes), matching PLAN.md
//! Task 5.1's exact asks:
//!   1. shell session + `echo hi\n` -> observed output contains "hi"
//!   2. `kill` reaps the child (no zombie)
//!   3. transcript file exists and is redacted

use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use omniagent_ade_lib::sessions::{CreateSessionRequest, OutputSink, SessionManager};

fn silent_sink() -> OutputSink {
    Arc::new(|_id: &str, _chunk: &[u8]| {})
}

fn shell_request(cwd: &std::path::Path) -> CreateSessionRequest {
    CreateSessionRequest {
        project: "demo".to_string(),
        engine: "shell".to_string(),
        cwd: cwd.to_string_lossy().into_owned(),
        briefing: None,
    }
}

#[test]
fn shell_echo_is_observed_on_the_output_sink() {
    let tmp = tempfile::tempdir().unwrap();
    let (tx, rx) = mpsc::channel::<(String, Vec<u8>)>();
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        let _ = tx.send((id.to_string(), chunk.to_vec()));
    });

    let manager = SessionManager::new(tmp.path().to_path_buf(), sink);
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
fn kill_reaps_the_child_process_no_zombie() {
    let tmp = tempfile::tempdir().unwrap();
    let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink());
    let info = manager.create(shell_request(tmp.path())).unwrap();

    let pid = manager
        .pid(&info.id)
        .expect("pid should be available while the session is alive");

    manager.kill(&info.id).unwrap();

    // `SessionManager::kill` calls `child.wait()` synchronously before
    // returning, so by now the process must be fully reaped, not just
    // signaled. Two independent OS-level checks prove that:
    //
    // 1. `kill(pid, 0)` (signal 0 = "does this pid exist") must fail with
    //    ESRCH. A *zombie* process still responds successfully to this
    //    (the pid is still allocated, exit status just hasn't been
    //    collected yet) — only a fully-reaped process frees the pid.
    let alive = unsafe { libc::kill(pid as i32, 0) };
    let alive_errno = std::io::Error::last_os_error().raw_os_error();
    assert_eq!(alive, -1, "pid {pid} should no longer exist");
    assert_eq!(alive_errno, Some(libc::ESRCH), "expected ESRCH, got {alive_errno:?}");

    // 2. A second `waitpid` on the same pid must find no such child of
    //    this process (ECHILD) — proving *we* already collected it via
    //    `kill()`'s internal `wait()`, rather than leaving it dangling.
    let mut status: libc::c_int = 0;
    let wp = unsafe { libc::waitpid(pid as i32, &mut status, libc::WNOHANG) };
    let wp_errno = std::io::Error::last_os_error().raw_os_error();
    assert_eq!(wp, -1, "waitpid should find no such child (already reaped)");
    assert_eq!(wp_errno, Some(libc::ECHILD), "expected ECHILD, got {wp_errno:?}");
}

#[test]
fn transcript_file_exists_and_secrets_are_redacted() {
    let tmp = tempfile::tempdir().unwrap();
    let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink());
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

#[test]
fn resize_a_live_session_succeeds() {
    let tmp = tempfile::tempdir().unwrap();
    let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink());
    let info = manager.create(shell_request(tmp.path())).unwrap();

    manager.resize(&info.id, 120, 40).unwrap();

    manager.kill(&info.id).unwrap();
}
