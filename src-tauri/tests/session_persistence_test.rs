//! Session persistence + traffic-light status, against **real tmux** and
//! **real PTYs** — no mocks anywhere in the persistence path.
//!
//! Founder brief (Bruno, 2026-07-26): *"Every new claude or terminal or codex
//! session, must be stored, if not properly closed… if the user closes the
//! application and comes back to that session, the terminal, claude, codex
//! (whatever) session must be restored"*, and *"Green means ready for any new
//! command, yellow means executing, red means requires attention or input."*
//!
//! Every test that needs tmux is guarded by [`test_tmux`] and **skips
//! cleanly** when it isn't installed, so the suite still passes on a machine
//! without it (which is also the machine the no-tmux fallback tests below
//! exist for). Each test gets its own tmux **socket**, so tests never see each
//! other's sessions, never race, and can never touch the user's own tmux
//! server or OmniAgent's real `omniagent-ade` one. A [`ServerGuard`] kills
//! each test's server on the way out, including on panic.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::sync::Arc;
use std::time::{Duration, Instant};

use omniagent_ade_lib::sessions::{
    CreateSessionRequest, OutputSink, SessionManager, SessionStatus, SessionStatusEvent, StatusSink,
};
use omniagent_ade_lib::tmux::{self, Tmux};

// ---------------------------------------------------------------------------
// harness
// ---------------------------------------------------------------------------

static SOCKET_COUNTER: AtomicU64 = AtomicU64::new(0);

/// A socket name unique to one test run *and* one test — `cargo test` runs
/// this binary's tests in parallel threads sharing a process, so a shared
/// socket would mean tests seeing (and killing) each other's sessions.
fn unique_socket(label: &str) -> String {
    let pid = std::process::id();
    let n = SOCKET_COUNTER.fetch_add(1, Ordering::Relaxed);
    format!("omniagent-test-{label}-{pid}-{n}")
}

/// Kills the test's private tmux server when the test ends — including on a
/// failed assertion, which would otherwise leave a real shell (or `claude`)
/// process running forever after `cargo test` exits.
///
/// `kill-server`, not a loop of `kill-session`, **and** an explicit unlink of
/// the socket file: tmux does not remove the socket inode when its server
/// exits, and since each run's sockets are pid-stamped, every `cargo test`
/// left another set behind — 150+ dead socket files had piled up in
/// `/tmp/tmux-<uid>/` before this was noticed.
struct ServerGuard(Option<Tmux>);

impl Drop for ServerGuard {
    fn drop(&mut self) {
        if let Some(t) = &self.0 {
            t.kill_server();
            if let Some(path) = default_socket_path(t.socket()) {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}

/// Where `tmux -L <name>` puts its socket: `$TMUX_TMPDIR` (or `/tmp`) +
/// `tmux-<uid>/<name>`. Mirrors tmux's own rule; only used to clean up after
/// tests, so being wrong costs a leftover file, never a failure.
fn default_socket_path(socket_name: &str) -> Option<std::path::PathBuf> {
    let base = std::env::var("TMUX_TMPDIR").unwrap_or_else(|_| "/tmp".to_string());
    let uid = unsafe { libc::getuid() };
    Some(std::path::PathBuf::from(base).join(format!("tmux-{uid}")).join(socket_name))
}

/// Real tmux on a private socket + this app's real config, or `None` when
/// tmux isn't installed (in which case the caller skips).
fn test_tmux(label: &str, data_dir: &std::path::Path) -> Option<Tmux> {
    let socket = unique_socket(label);
    let resolved = Tmux::resolve(&socket, std::env::var("PATH").ok().as_deref())?;
    Some(match tmux::write_config(data_dir) {
        Some(cfg) => resolved.with_config(cfg),
        None => resolved,
    })
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

/// Drains an output channel until `needle` shows up or `timeout` elapses.
/// Returns everything seen, so a failure message can show what *did* arrive.
fn wait_for_output(
    rx: &mpsc::Receiver<(String, Vec<u8>)>,
    session_id: &str,
    needle: &str,
    timeout: Duration,
) -> (bool, String) {
    let deadline = Instant::now() + timeout;
    let mut seen = String::new();
    while Instant::now() < deadline {
        if let Ok((id, chunk)) = rx.recv_timeout(Duration::from_millis(150)) {
            if id == session_id {
                seen.push_str(&String::from_utf8_lossy(&chunk));
                if seen.contains(needle) {
                    return (true, seen);
                }
            }
        }
    }
    (false, seen)
}

/// A manager plus the channel its status events land on — the shape every
/// status test below needs.
fn manager_with_status(
    data_dir: &std::path::Path,
    tmux: Option<Tmux>,
) -> (SessionManager, mpsc::Receiver<SessionStatusEvent>) {
    let (tx, rx) = mpsc::channel::<SessionStatusEvent>();
    let status_sink: StatusSink = Arc::new(move |event: &SessionStatusEvent| {
        let _ = tx.send(event.clone());
    });
    let manager = SessionManager::new(data_dir.to_path_buf(), silent_sink())
        .with_tmux(tmux)
        .with_status_sink(status_sink);
    (manager, rx)
}

/// Waits until the status stream reports `wanted`, collecting the whole
/// sequence so a failure can show the real transitions.
///
/// Also asserts, on every event that goes by, that the payload's `notify`
/// flag matches [`SessionStatus::notifies`] — so the notification contract is
/// checked against *real* emitted events in every status test, not only in the
/// unit test for the classifier.
fn wait_for_status(
    rx: &mpsc::Receiver<SessionStatusEvent>,
    seen: &mut Vec<SessionStatus>,
    wanted: SessionStatus,
    timeout: Duration,
) -> bool {
    let deadline = Instant::now() + timeout;
    while Instant::now() < deadline {
        if let Ok(event) = rx.recv_timeout(Duration::from_millis(100)) {
            assert_eq!(
                event.notify,
                event.status.notifies(),
                "a real emitted event disagreed with the notification classifier: {event:?}"
            );
            assert!(!event.id.is_empty(), "every event must name its session");
            seen.push(event.status);
            if event.status == wanted {
                return true;
            }
        }
    }
    false
}

/// The status of a live session, right now, via the pull API.
fn status_of(manager: &SessionManager, id: &str) -> Option<SessionStatus> {
    manager.status(id).map(|e| e.status)
}

// ---------------------------------------------------------------------------
// 1. lifecycle: a session really is a tmux session, and closing the tab
//    really deletes it
// ---------------------------------------------------------------------------

/// The base claim of the whole feature: an ADE session *is* a tmux session
/// named `omniagent-<id>`, asserted against real `tmux list-sessions` output
/// rather than against our own bookkeeping — and Bruno's deletion rule ("If
/// the user closes the terminal, tmux or claude session can be deleted")
/// holds: `kill()` removes it from the server.
#[test]
fn a_session_creates_a_real_tmux_session_and_kill_deletes_it() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("lifecycle", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink())
        .with_tmux(Some(t.clone()));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    let expected_name = tmux::session_name(&info.id);
    assert!(info.persistent, "a tmux-backed session must report persistent");
    assert!(!info.restored, "a brand-new session was not restored");
    assert_eq!(
        t.list_sessions(),
        vec![expected_name.clone()],
        "real `tmux list-sessions` must show exactly this session"
    );
    assert!(t.has_session(&expected_name));

    manager.kill(&info.id).unwrap();

    assert!(
        t.list_sessions().is_empty(),
        "closing the tab must delete the tmux session, got: {:?}",
        t.list_sessions()
    );
}

// ---------------------------------------------------------------------------
// 2. the feature itself: close the app, come back, same live session
// ---------------------------------------------------------------------------

/// **The test this whole task exists for.** Simulates the founder's exact
/// scenario end to end:
///
/// 1. open a session under a known id and put state into it (a shell variable
///    — something only *that* process could still know);
/// 2. simulate the app closing by dropping the `SessionManager` without ever
///    calling `kill()` (no tab was closed, the app just went away);
/// 3. assert against real `tmux list-sessions` that the session survived;
/// 4. create again with the **same id** and assert it *attached* rather than
///    spawning a second engine — proven three ways: `restored == true`, real
///    `tmux list-sessions` still showing exactly one session (not two), and
///    the shell variable from step 1 still being readable, which no freshly
///    spawned shell could possibly reproduce.
#[test]
fn closing_the_app_and_returning_reattaches_the_same_live_session() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("restore", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let stable_id = "sess-restore-probe";
    let expected_name = tmux::session_name(stable_id);

    // ---- app run #1 -------------------------------------------------------
    {
        let (tx, rx) = mpsc::channel::<(String, Vec<u8>)>();
        let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
            let _ = tx.send((id.to_string(), chunk.to_vec()));
        });
        let manager = SessionManager::new(tmp.path().to_path_buf(), sink)
            .with_tmux(Some(t.clone()));

        let info = manager
            .create(CreateSessionRequest {
                restore_id: Some(stable_id.to_string()),
                ..shell_request(tmp.path())
            })
            .unwrap();
        assert_eq!(info.id, stable_id, "restore_id must be used verbatim as the id");
        assert!(!info.restored, "nothing existed yet — this is a fresh start");
        assert!(info.persistent);

        // Put state into the live process that only *it* can know.
        manager
            .write(&info.id, "OMNIAGENT_PROBE=survived-the-app-close\n")
            .unwrap();
        manager.write(&info.id, "echo READY_RUN_1\n").unwrap();
        let (found, seen) = wait_for_output(&rx, &info.id, "READY_RUN_1", Duration::from_secs(10));
        assert!(found, "run #1's shell never responded; saw: {seen:?}");

        // The app closes: the manager goes away, and *nothing* calls kill().
        drop(manager);
    }

    // ---- the app is gone; the engine is not --------------------------------
    assert!(
        t.has_session(&expected_name),
        "the tmux session must outlive the app closing — real list-sessions: {:?}",
        t.list_sessions()
    );

    // ---- app run #2: the user comes back -----------------------------------
    let (tx, rx) = mpsc::channel::<(String, Vec<u8>)>();
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        let _ = tx.send((id.to_string(), chunk.to_vec()));
    });
    let manager = SessionManager::new(tmp.path().to_path_buf(), sink).with_tmux(Some(t.clone()));

    let info = manager
        .create(CreateSessionRequest {
            restore_id: Some(stable_id.to_string()),
            ..shell_request(tmp.path())
        })
        .unwrap();

    assert!(
        info.restored,
        "the second create must report that it attached to a live session"
    );
    assert_eq!(
        t.list_sessions(),
        vec![expected_name.clone()],
        "attaching must NOT have spawned a second tmux session"
    );

    // The real proof: the variable set in run #1 is still there, so this is
    // literally the same shell process, not a fresh one that merely has the
    // same name.
    manager
        .write(&info.id, "echo PROBE_IS:$OMNIAGENT_PROBE\n")
        .unwrap();
    let (found, seen) = wait_for_output(
        &rx,
        &info.id,
        "PROBE_IS:survived-the-app-close",
        Duration::from_secs(10),
    );
    assert!(
        found,
        "the restored session must be the SAME process (its shell variable must survive); saw: {seen:?}"
    );

    manager.kill(&info.id).unwrap();
    assert!(t.list_sessions().is_empty());
}

/// A restore for an id whose tmux session is *gone* (server restarted,
/// machine rebooted) must not fail — it starts a fresh engine under the same
/// id and says so (`restored == false`), which is the honest answer.
#[test]
fn restoring_an_id_whose_tmux_session_is_gone_starts_fresh_without_failing() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("gone", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let manager =
        SessionManager::new(tmp.path().to_path_buf(), silent_sink()).with_tmux(Some(t.clone()));
    let info = manager
        .create(CreateSessionRequest {
            restore_id: Some("sess-never-existed".to_string()),
            ..shell_request(tmp.path())
        })
        .unwrap();

    assert_eq!(info.id, "sess-never-existed");
    assert!(!info.restored, "nothing was there to restore");
    assert!(info.persistent, "but it is persistent from here on");
    manager.kill(&info.id).unwrap();
}

/// Two live tabs must never collide onto one tmux session, and a `restore_id`
/// naming a tab that's already open is a frontend bug worth surfacing rather
/// than silently hijacking the running session.
#[test]
fn restoring_an_id_that_is_already_live_is_rejected() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("dup", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let manager =
        SessionManager::new(tmp.path().to_path_buf(), silent_sink()).with_tmux(Some(t.clone()));
    let info = manager
        .create(CreateSessionRequest {
            restore_id: Some("sess-already-open".to_string()),
            ..shell_request(tmp.path())
        })
        .unwrap();

    let err = manager
        .create(CreateSessionRequest {
            restore_id: Some("sess-already-open".to_string()),
            ..shell_request(tmp.path())
        })
        .unwrap_err();
    assert!(err.to_string().contains("already live"), "{err}");

    manager.kill(&info.id).unwrap();
}

/// `restore_id` reaches the filesystem (`<id>.log`) and a tmux target, so a
/// hostile/garbled value must be rejected, never sanitized into some other
/// session's name.
#[test]
fn a_malformed_restore_id_is_rejected_rather_than_sanitized() {
    let tmp = tempfile::tempdir().unwrap();
    let manager = SessionManager::new(tmp.path().to_path_buf(), silent_sink());

    for bad in [
        "../../etc/passwd",
        "has spaces",
        "colon:target",
        "dot.target",
        "",
        &"x".repeat(200),
    ] {
        let err = manager
            .create(CreateSessionRequest {
                restore_id: Some(bad.to_string()),
                ..shell_request(tmp.path())
            })
            .unwrap_err();
        assert!(
            err.to_string().contains("invalid restore_id"),
            "{bad:?} should have been rejected, got: {err}"
        );
    }
}

// ---------------------------------------------------------------------------
// 3. traffic-light status
// ---------------------------------------------------------------------------

/// Bruno's cyan, driven by a real long-running command in a real tmux-backed
/// shell: **green → cyan → green** around `sleep 2`.
///
/// `sleep` is chosen deliberately — it produces *no output at all*, so this
/// only passes because the shell path uses tmux's `#{pane_current_command}`
/// (which reports the pane's foreground process group) rather than an
/// output-activity guess, which would call a silent command "idle".
#[test]
fn shell_status_goes_ready_then_tool_execution_then_ready_around_a_real_command() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("status", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let (manager, rx) = manager_with_status(tmp.path(), Some(t.clone()));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    let mut seen = Vec::new();
    assert!(
        wait_for_status(&rx, &mut seen, SessionStatus::Ready, Duration::from_secs(10)),
        "an idle shell must settle on ready (green); saw {seen:?}"
    );

    // On demand, right now — the pull side the frontend uses on mount. It
    // returns the full event, `notify` included, exactly like the push side.
    let pulled = manager.status(&info.id).unwrap();
    assert_eq!(pulled.status, SessionStatus::Ready);
    assert_eq!(pulled.id, info.id);
    assert_eq!(pulled.engine, "shell");
    assert!(pulled.notify, "green is notification-worthy (Bruno's rule)");

    manager.write(&info.id, "sleep 2\n").unwrap();
    assert!(
        wait_for_status(
            &rx,
            &mut seen,
            SessionStatus::ToolExecution,
            Duration::from_secs(5)
        ),
        "a running command must show tool execution (cyan); saw {seen:?}"
    );

    assert!(
        wait_for_status(&rx, &mut seen, SessionStatus::Ready, Duration::from_secs(10)),
        "the light must go back to green when the command finishes; saw {seen:?}"
    );

    assert!(
        seen.len() >= 3,
        "expected at least ready→tool_execution→ready, saw {seen:?}"
    );
    assert!(
        !seen.contains(&SessionStatus::Thinking),
        "a shell must never report `thinking`; saw {seen:?}"
    );

    manager.kill(&info.id).unwrap();
}

/// Amber beats everything, and the user answering clears it. Uses the same
/// dependency-free stand-in the existing attention test does (a `shell`
/// session echoing Claude's exact permission-prompt copy) — see
/// `sessions.rs`'s `spawn_reader_thread` docs for why detection isn't gated
/// on the engine name.
#[test]
fn approval_marker_turns_the_light_amber_and_writing_clears_it() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("attention", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let (manager, rx) = manager_with_status(tmp.path(), Some(t.clone()));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    let mut seen = Vec::new();
    assert!(wait_for_status(&rx, &mut seen, SessionStatus::Ready, Duration::from_secs(10)));

    // The prompt appears a beat *after* the user's own input, the way a real
    // engine's does (you send a message; some seconds later Claude asks for
    // permission) — not in the same breath. That gap matters: a marker
    // arriving within `ATTENTION_INPUT_GRACE` of the user's keystroke is
    // treated as the echo of a prompt they already answered, which is the
    // whole point of the grace window.
    manager
        .write(&info.id, "sleep 2 && echo 'Do you want to proceed?'\n")
        .unwrap();
    assert!(
        wait_for_status(
            &rx,
            &mut seen,
            SessionStatus::AwaitingApproval,
            Duration::from_secs(15)
        ),
        "the permission-prompt marker must turn the light amber; saw {seen:?}"
    );
    let pulled = manager.status(&info.id).unwrap();
    assert_eq!(pulled.status, SessionStatus::AwaitingApproval);
    assert!(pulled.notify, "amber must be notification-worthy");

    // The user answers, and the dialog leaves the screen — `clear` stands in
    // for a real engine repainting without its prompt.
    manager.write(&info.id, "clear\n").unwrap();

    // Then let the terminal settle before judging. This wait is the honest
    // shape of the feature, not a fudge: the signal is *screen text*, and
    // under parallel load tmux's repaint of the pre-clear screen (marker
    // still on it) can arrive well over a second after the keystroke —
    // outside `ATTENTION_INPUT_GRACE`, which re-latches red. That is the
    // documented limitation (see `sessions.rs` module docs), and asserting
    // against it would only make this test a load-sensitive coin flip.
    std::thread::sleep(Duration::from_secs(3));

    // With the screen quiet and no prompt on it, the contract under test —
    // a user write clears the attention latch — must hold, checked through
    // the on-demand query so it doesn't depend on an event happening to fire.
    manager.write(&info.id, "").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline && status_of(&manager, &info.id) != Some(SessionStatus::Ready) {
        std::thread::sleep(Duration::from_millis(200));
    }
    assert_eq!(
        status_of(&manager, &info.id),
        Some(SessionStatus::Ready),
        "writing to the session must clear the approval latch; status stream was {seen:?}"
    );

    manager.kill(&info.id).unwrap();
}

/// Bruno's red, end to end through a real PTY: a non-zero `Exit code N` line
/// — the literal real `claude` renders for a failed Bash tool (measured
/// 2026-07-26, see `sessions.rs`'s `ERROR_MARKER`) — turns the light red, and
/// the user typing clears it.
///
/// Same dependency-free stand-in as the approval test above: a `shell` session
/// echoing the exact copy, rather than a live `claude` (which would need
/// network, an API key and an interactive conversation an automated test can't
/// drive). What's under test is the detection + latch + clear chain, which is
/// engine-independent by design.
#[test]
fn a_failed_tool_exit_turns_the_light_red_and_writing_clears_it() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("error", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let (manager, rx) = manager_with_status(tmp.path(), Some(t.clone()));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    let mut seen = Vec::new();
    assert!(wait_for_status(
        &rx,
        &mut seen,
        SessionStatus::Ready,
        Duration::from_secs(10)
    ));

    // The failure lands a beat after the user's own input, the way a real one
    // does (you approve a command; it fails a second or two later) — the
    // `sleep` puts it outside `ATTENTION_INPUT_GRACE`. Deliberately only 2 s:
    // a real `claude` reports a failed tool within ~1-2 s of the approval
    // keystroke, and an earlier 5 s error-only grace suppressed exactly that
    // (see `ATTENTION_INPUT_GRACE`), so this test now runs at the timing that
    // actually caught it.
    //
    // The text is the **80-column** rendering — a label, then the value
    // bolded, i.e. an SGR escape between the two — because that is what a real
    // ADE pane (opened at 24x80) actually produces. A marker built only from a
    // 120-column probe matched nothing in a live session; this test now emits
    // the exact bytes that caught it.
    manager
        .write(
            &info.id,
            "sleep 2 && printf 'Exit code: \\033[1m1\\033[m\\n'\n",
        )
        .unwrap();

    assert!(
        wait_for_status(&rx, &mut seen, SessionStatus::Error, Duration::from_secs(20)),
        "a non-zero exit-code line must turn the light red; saw {seen:?}"
    );
    let pulled = manager.status(&info.id).unwrap();
    assert_eq!(pulled.status, SessionStatus::Error);
    assert!(pulled.notify, "red must be notification-worthy");

    // The user acknowledges by typing, and the failure leaves the screen
    // (`clear` stands in for the engine repainting past it). No settling dance
    // is needed here, and that is the point of reconciling red against the
    // live pane rather than against the stream: the moment `capture-pane` stops
    // showing the failure, the latch is released. An earlier stream-only
    // version needed a sleep plus a second write to survive the repaint that
    // arrives after the keystroke, and even then red came back later.
    manager.write(&info.id, "clear\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline && status_of(&manager, &info.id) != Some(SessionStatus::Ready) {
        std::thread::sleep(Duration::from_millis(200));
    }
    assert_eq!(
        status_of(&manager, &info.id),
        Some(SessionStatus::Ready),
        "writing to the session must clear the error latch; status stream was {seen:?}"
    );

    manager.kill(&info.id).unwrap();
}

/// **The anti-strobe regression test.** The reason `SUSTAINED_ACTIVITY_MIN`
/// exists is that a real idle `claude` twitches its TUI periodically and naive
/// recency made the light flip every few seconds. Whatever else changes about
/// the state model, an idle session must sit on exactly one state and emit
/// nothing further.
///
/// Uses a `shell` session so it needs no engine, no network and no API key —
/// what's under test is the poller's emit-on-change contract, which is shared
/// by every engine. The live five-state check against a genuinely idle
/// `claude` is the manual verification recorded in this task's report (0
/// transitions across 60 s).
#[test]
fn an_idle_session_settles_on_one_state_and_stops_emitting() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("idle", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let (manager, rx) = manager_with_status(tmp.path(), Some(t.clone()));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    let mut seen = Vec::new();
    assert!(
        wait_for_status(&rx, &mut seen, SessionStatus::Ready, Duration::from_secs(10)),
        "an idle shell must settle on ready; saw {seen:?}"
    );
    // Let the prompt finish painting before the quiet window starts.
    std::thread::sleep(Duration::from_secs(2));
    while rx.try_recv().is_ok() {}

    // 12 s at a 300 ms poll interval = ~40 evaluations. A light that flaps at
    // all — for any reason, at any period under ~12 s — cannot survive this.
    let watch = Duration::from_secs(12);
    let deadline = Instant::now() + watch;
    let mut transitions = Vec::new();
    while Instant::now() < deadline {
        if let Ok(event) = rx.recv_timeout(Duration::from_millis(200)) {
            transitions.push(event.status);
        }
    }

    assert!(
        transitions.is_empty(),
        "an idle session must not change state at all over {watch:?}; got {transitions:?}"
    );
    assert_eq!(
        status_of(&manager, &info.id),
        Some(SessionStatus::Ready),
        "and it must still be green at the end"
    );

    manager.kill(&info.id).unwrap();
}

/// The plumbing behind claude/codex cyan: `capture-pane` must return the
/// pane's *live screen* through this app's real tmux config.
///
/// This is the one half of that path an automated test can reach without a
/// live `claude` — the marker matching itself is unit-tested against the real
/// captured copy (`sessions::tests::a_visibly_running_bash_tool_reads_as_
/// tool_execution`), and the two together are what the manual verification
/// exercises end to end.
#[test]
fn capture_pane_reads_the_live_screen_through_the_apps_tmux_config() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("capture", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let manager =
        SessionManager::new(tmp.path().to_path_buf(), silent_sink()).with_tmux(Some(t.clone()));
    let info = manager.create(shell_request(tmp.path())).unwrap();
    let name = tmux::session_name(&info.id);

    manager
        .write(&info.id, "echo ON_THE_SCREEN_NOW\n")
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut screen = String::new();
    while Instant::now() < deadline {
        screen = t.capture_pane(&name).unwrap_or_default();
        if screen.contains("ON_THE_SCREEN_NOW") {
            break;
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    assert!(
        screen.contains("ON_THE_SCREEN_NOW"),
        "capture-pane must show what's on the pane right now; got {screen:?}"
    );

    // ...and it must be *state*, not history: once the screen is cleared the
    // text is gone from the capture, with no clearing heuristic on our side.
    // (This is exactly why cyan is computed from the screen and not from a
    // stream latch.)
    manager.write(&info.id, "clear\n").unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        screen = t.capture_pane(&name).unwrap_or_default();
        if !screen.contains("ON_THE_SCREEN_NOW") {
            break;
        }
        std::thread::sleep(Duration::from_millis(150));
    }
    assert!(
        !screen.contains("ON_THE_SCREEN_NOW"),
        "a cleared screen must stop reporting the old text; got {screen:?}"
    );

    manager.kill(&info.id).unwrap();
}

// ---------------------------------------------------------------------------
// 4. graceful degradation — no tmux on this machine
// ---------------------------------------------------------------------------

/// tmux missing must cost persistence and nothing else: the session still
/// creates, still runs, still streams output, and honestly reports
/// `persistent: false`. Injected by pointing the tmux binary at a path that
/// doesn't exist, so this proves the fallback *on a machine where tmux is
/// installed* — no uninstall required.
#[test]
fn a_missing_tmux_binary_falls_back_to_a_working_direct_spawn() {
    let tmp = tempfile::tempdir().unwrap();
    let (tx, rx) = mpsc::channel::<(String, Vec<u8>)>();
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        let _ = tx.send((id.to_string(), chunk.to_vec()));
    });

    let broken = Tmux::with_binary("/no/such/tmux/binary/anywhere", "unused-socket");
    let manager = SessionManager::new(tmp.path().to_path_buf(), sink).with_tmux(Some(broken));

    let info = manager.create(shell_request(tmp.path())).unwrap();
    assert!(!info.persistent, "a fallback spawn is not persistent");
    assert!(!info.restored);

    manager.write(&info.id, "echo FALLBACK_WORKS\n").unwrap();
    let (found, seen) = wait_for_output(&rx, &info.id, "FALLBACK_WORKS", Duration::from_secs(10));
    assert!(found, "the fallback session must actually work; saw {seen:?}");

    manager.kill(&info.id).unwrap();
}

/// The same degradation via the other door: no tmux configured at all (what
/// `SessionManager::new` gives you, and what `lib.rs` ends up with when
/// `default_tmux` resolves to `None`).
#[test]
fn no_tmux_configured_at_all_still_creates_a_working_session() {
    let tmp = tempfile::tempdir().unwrap();
    let (tx, rx) = mpsc::channel::<(String, Vec<u8>)>();
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        let _ = tx.send((id.to_string(), chunk.to_vec()));
    });

    let manager = SessionManager::new(tmp.path().to_path_buf(), sink).with_tmux(None);
    let info = manager.create(shell_request(tmp.path())).unwrap();
    assert!(!info.persistent);

    manager.write(&info.id, "echo NO_TMUX_WORKS\n").unwrap();
    let (found, seen) = wait_for_output(&rx, &info.id, "NO_TMUX_WORKS", Duration::from_secs(10));
    assert!(found, "saw {seen:?}");

    manager.kill(&info.id).unwrap();
}

/// Without tmux there's no `#{pane_current_command}`, so status falls back to
/// output activity for every engine — including `shell`. This asserts the
/// fallback is *live and honest*, not that it's as good: an `echo` (which
/// does produce output) is visible as executing and then settles to ready.
/// The documented blind spot — a silent long-running command like `sleep`
/// looking idle — is exactly why tmux is the default.
#[test]
fn without_tmux_status_still_works_via_the_output_activity_fallback() {
    let tmp = tempfile::tempdir().unwrap();
    let (manager, rx) = manager_with_status(tmp.path(), None);
    let info = manager.create(shell_request(tmp.path())).unwrap();

    let mut seen = Vec::new();
    assert!(
        wait_for_status(&rx, &mut seen, SessionStatus::Ready, Duration::from_secs(10)),
        "an idle shell must reach ready even without tmux; saw {seen:?}"
    );

    // A *sustained* run of output — output every 200 ms for ~4 s. Both
    // halves of the heuristic matter here: the 200 ms spacing stays inside
    // the quiet threshold so it reads as one unbroken run, and 4 s is
    // comfortably longer than the 1 s a run must last before it counts as
    // executing. (A tight `seq 1 40000` loop, tried first, was *too* fast —
    // it finished in well under a second, which by design does not qualify.)
    manager
        .write(&info.id, "for i in $(seq 1 20); do echo busy-$i; sleep 0.2; done\n")
        .unwrap();
    assert!(
        wait_for_status(
            &rx,
            &mut seen,
            SessionStatus::ToolExecution,
            Duration::from_secs(10)
        ),
        "streaming output from a shell must read as tool execution; saw {seen:?}"
    );
    assert!(
        wait_for_status(&rx, &mut seen, SessionStatus::Ready, Duration::from_secs(30)),
        "and must settle back to ready once the output stops; saw {seen:?}"
    );

    manager.kill(&info.id).unwrap();
}

// ---------------------------------------------------------------------------
// 5. the wrapped engine still behaves exactly as it did
// ---------------------------------------------------------------------------

/// Wrapping in tmux must not break the transcript contract: output still
/// lands on disk, still redacted. (`sessions.rs`'s redaction is line-buffered
/// with a guaranteed final flush on `kill()`, which is what makes this hold
/// even though tmux redraws with cursor escapes rather than newlines.)
#[test]
fn a_tmux_backed_session_still_writes_a_redacted_transcript() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("transcript", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let (tx, rx) = mpsc::channel::<(String, Vec<u8>)>();
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        let _ = tx.send((id.to_string(), chunk.to_vec()));
    });
    let manager =
        SessionManager::new(tmp.path().to_path_buf(), sink).with_tmux(Some(t.clone()));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    manager.write(&info.id, "echo API_KEY=abc123\n").unwrap();
    let (found, seen) = wait_for_output(&rx, &info.id, "abc123", Duration::from_secs(10));
    assert!(found, "the secret should reach the live stream first; saw {seen:?}");

    manager.kill(&info.id).unwrap();

    let transcript = tmp
        .path()
        .join("transcripts")
        .join(format!("{}.log", info.id));
    let contents = std::fs::read_to_string(&transcript).unwrap();
    assert!(
        !contents.contains("abc123"),
        "transcript must not contain the raw secret: {contents}"
    );
    assert!(
        contents.contains("[redacted]"),
        "transcript should show the redaction marker: {contents}"
    );
}

/// `resize` must reach the engine through tmux, not just the client — a
/// tmux window follows its attached client's size, so this proves the whole
/// chain (PTY ioctl → SIGWINCH → tmux client → window → pane) still works.
#[test]
fn resize_reaches_the_engine_through_tmux() {
    let tmp = tempfile::tempdir().unwrap();
    let Some(t) = test_tmux("resize", tmp.path()) else {
        eprintln!("tmux not installed — skipping");
        return;
    };
    let _guard = ServerGuard(Some(t.clone()));

    let (tx, rx) = mpsc::channel::<(String, Vec<u8>)>();
    let sink: OutputSink = Arc::new(move |id: &str, chunk: &[u8]| {
        let _ = tx.send((id.to_string(), chunk.to_vec()));
    });
    let manager =
        SessionManager::new(tmp.path().to_path_buf(), sink).with_tmux(Some(t.clone()));
    let info = manager.create(shell_request(tmp.path())).unwrap();

    manager.resize(&info.id, 132, 43).unwrap();
    // Let tmux propagate the SIGWINCH to the pane before asking.
    std::thread::sleep(Duration::from_millis(600));

    manager.write(&info.id, "echo COLS_ARE:$(tput cols)\n").unwrap();
    let (found, seen) = wait_for_output(&rx, &info.id, "COLS_ARE:132", Duration::from_secs(10));
    assert!(
        found,
        "the pane's process must see the resized width; saw {seen:?}"
    );

    manager.kill(&info.id).unwrap();
}
