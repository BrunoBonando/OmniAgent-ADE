use omniagent_pty_daemon::{
    AttachState, CreateSession, SessionEvent, SessionRegistry, SCROLLBACK_LINES,
};
use std::collections::HashMap;
use std::time::{Duration, Instant};

fn create(
    registry: &SessionRegistry,
    id: &str,
    script: &str,
    transcript_path: Option<std::path::PathBuf>,
) -> std::sync::Arc<omniagent_pty_daemon::ManagedSession> {
    registry
        .create_session(CreateSession {
            id: id.to_string(),
            command: vec!["/bin/sh".into(), "-c".into(), script.into()],
            cwd: None,
            env: HashMap::new(),
            cols: 80,
            rows: 24,
            transcript_path,
        })
        .unwrap()
}

fn next_output(
    subscription: &omniagent_pty_daemon::SessionSubscription,
    timeout: Duration,
) -> (u64, Vec<u8>) {
    match subscription.recv_timeout(timeout).unwrap() {
        SessionEvent::Output { sequence, bytes } => (sequence, bytes),
        SessionEvent::Exited { .. } => panic!("session exited before expected output"),
        SessionEvent::ResyncRequired { .. } => panic!("unexpected resync"),
        SessionEvent::Status { .. } => panic!("unexpected status"),
    }
}

#[test]
fn shell_status_tracks_a_silent_foreground_command_without_screen_polling() {
    let registry = SessionRegistry::new();
    let session = registry
        .create_session(CreateSession {
            id: "shell-status".into(),
            command: vec!["/bin/sh".into()],
            cwd: None,
            env: HashMap::new(),
            cols: 80,
            rows: 24,
            transcript_path: None,
        })
        .unwrap();
    let (_, subscription) = session.attach_and_subscribe(None, 32);

    let wait_for = |wanted| {
        let deadline = Instant::now() + Duration::from_secs(3);
        while Instant::now() < deadline {
            if matches!(
                subscription.recv_timeout(Duration::from_millis(200)),
                Ok(SessionEvent::Status { status, .. }) if status == wanted
            ) {
                return true;
            }
        }
        false
    };

    assert!(wait_for(
        omniagent_pty_daemon::protocol::SessionStatus::Ready
    ));
    session.write_input(b"sleep 1\n").unwrap();
    assert!(wait_for(
        omniagent_pty_daemon::protocol::SessionStatus::ToolExecution
    ));
    assert!(wait_for(
        omniagent_pty_daemon::protocol::SessionStatus::Ready
    ));
    registry.kill("shell-status");
}

/// The bug this exists for: a Claude pane that is visibly working reads green
/// the moment it stops repainting for 700ms. Measured live before the fix --
/// one `✽ Brewing…` pane flapped Ready/Thinking six times in ten seconds.
///
/// A fake `claude` on the argv is what makes the engine inference pick the
/// agent path; the point is the *silence* after the footer is drawn.
#[test]
fn an_agent_showing_its_working_footer_stays_busy_while_it_is_silent() {
    let dir = std::env::temp_dir().join(format!("omniagent-working-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let fake = dir.join("claude");
    std::fs::write(
        &fake,
        "#!/bin/sh\nprintf '\\342\\234\\275 Brewing\\342\\200\\246 (4m 59s)\\r\\n'\nsleep 4\n",
    )
    .unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
    }

    let registry = SessionRegistry::new();
    let session = registry
        .create_session(CreateSession {
            id: "working-footer".into(),
            command: vec![fake.to_string_lossy().into_owned()],
            cwd: None,
            env: HashMap::new(),
            cols: 80,
            rows: 24,
            transcript_path: None,
        })
        .unwrap();
    let (_, subscription) = session.attach_and_subscribe(None, 64);

    let mut saw_busy = false;
    let deadline = Instant::now() + Duration::from_secs(3);
    while Instant::now() < deadline {
        match subscription.recv_timeout(Duration::from_millis(200)) {
            Ok(SessionEvent::Status { status, .. }) => match status {
                omniagent_pty_daemon::protocol::SessionStatus::Thinking => saw_busy = true,
                omniagent_pty_daemon::protocol::SessionStatus::Ready if saw_busy => {
                    panic!("went Ready while the working footer was still on screen")
                }
                _ => {}
            },
            Ok(_) => {}
            Err(_) => {}
        }
    }
    assert!(saw_busy, "a visible working footer must read as busy");
    registry.kill("working-footer");
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn real_pty_output_preserves_raw_bytes_and_transcript_is_independent() {
    let temp = tempfile::tempdir().unwrap();
    let transcript = temp.path().join("raw.log");
    let registry = SessionRegistry::new();
    let session = create(
        &registry,
        "raw",
        "sleep 0.2; stty raw -echo; printf READY; dd bs=7 count=1 2>/dev/null",
        Some(transcript.clone()),
    );
    let subscription = session.subscribe(32);

    let mut seen_ready = Vec::new();
    while !seen_ready.windows(5).any(|window| window == b"READY") {
        seen_ready.extend(next_output(&subscription, Duration::from_secs(2)).1);
    }

    let raw = [0, 0xff, b'\n', 0x1b, b'[', b'2', b'J'];
    session.write_input(&raw).unwrap();

    let mut output = Vec::new();
    let mut sequences = Vec::new();
    while output.len() < raw.len() {
        let (sequence, bytes) = next_output(&subscription, Duration::from_secs(2));
        sequences.push(sequence);
        output.extend(bytes);
    }
    assert_eq!(output, raw);
    assert!(sequences.windows(2).all(|pair| pair[0] < pair[1]));

    loop {
        if let SessionEvent::Exited { .. } =
            subscription.recv_timeout(Duration::from_secs(2)).unwrap()
        {
            break;
        }
    }
    assert!(std::fs::read(transcript).unwrap().starts_with(b"READY"));
}

#[test]
fn attach_resumes_after_a_sequence_or_returns_an_ansi_snapshot() {
    let registry = SessionRegistry::new();
    let session = create(
        &registry,
        "resume",
        "sleep 0.2; stty raw -echo; printf READY; cat",
        None,
    );
    let subscription = session.subscribe(32);
    while next_output(&subscription, Duration::from_secs(2)).1 != b"READY" {}

    session.write_input(b"first").unwrap();
    let (first_sequence, first) = next_output(&subscription, Duration::from_secs(2));
    assert_eq!(first, b"first");
    session.write_input(b"second").unwrap();
    let (second_sequence, second) = next_output(&subscription, Duration::from_secs(2));
    assert_eq!(second, b"second");

    match session.attach(Some(first_sequence)) {
        AttachState::Resume(events) => assert!(events.iter().any(
            |event| matches!(event, SessionEvent::Output { sequence, bytes }
                if *sequence == second_sequence && bytes == b"second")
        )),
        AttachState::Snapshot { .. } => panic!("recent sequence should resume"),
    }
    match session.attach(None) {
        AttachState::Snapshot { sequence, bytes } => {
            assert_eq!(sequence, second_sequence);
            assert!(bytes.windows(11).any(|window| window == b"firstsecond"));
            assert!(
                bytes.contains(&0x1b),
                "snapshot must carry terminal formatting"
            );
        }
        AttachState::Resume(_) => panic!("fresh attach needs a snapshot"),
    }

    registry.kill("resume");
}

#[test]
fn a_slow_subscriber_is_bounded_and_told_to_resync() {
    let registry = SessionRegistry::new();
    let session = create(
        &registry,
        "slow",
        "sleep 0.2; read _; yes x | head -c 262144; sleep 2",
        None,
    );
    let subscription = session.subscribe(2);
    std::thread::sleep(Duration::from_millis(300));
    session.write_input(b"go\n").unwrap();
    std::thread::sleep(Duration::from_millis(500));

    let first = subscription.recv_timeout(Duration::from_secs(2)).unwrap();
    assert!(matches!(first, SessionEvent::ResyncRequired { .. }));
    assert!(subscription.pending_len() <= 1);

    registry.kill("slow");
}

#[test]
fn terminal_exit_after_a_full_output_queue_preserves_resync_and_exit() {
    let registry = SessionRegistry::new();
    let session = create(
        &registry,
        "full-then-exit",
        "sleep 0.2; stty -echo; printf LOST; sleep 0.5",
        None,
    );
    let subscription = session.subscribe(1);

    let deadline = Instant::now() + Duration::from_secs(2);
    while subscription.pending_len() == 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(subscription.pending_len(), 1);
    std::thread::sleep(Duration::from_millis(700));

    assert!(matches!(
        subscription.recv_timeout(Duration::from_secs(2)).unwrap(),
        SessionEvent::ResyncRequired { .. }
    ));
    assert!(matches!(
        subscription.recv_timeout(Duration::from_secs(2)).unwrap(),
        SessionEvent::Exited { .. }
    ));
}

#[test]
fn parser_scrollback_is_bounded_but_transcript_is_not() {
    let temp = tempfile::tempdir().unwrap();
    let transcript = temp.path().join("scrollback.log");
    let registry = SessionRegistry::new();
    let session = create(
        &registry,
        "scrollback",
        "i=0; while [ $i -lt 3100 ]; do printf 'line-%04d\\n' \"$i\"; i=$((i+1)); done; sleep 2",
        Some(transcript.clone()),
    );
    let deadline = Instant::now() + Duration::from_secs(3);
    while session.scrollback_rows() < SCROLLBACK_LINES && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(20));
    }

    assert_eq!(session.scrollback_rows(), SCROLLBACK_LINES);
    let transcript = std::fs::read(transcript).unwrap();
    assert!(transcript.windows(9).any(|window| window == b"line-0000"));
    assert!(transcript.windows(9).any(|window| window == b"line-3099"));

    registry.kill("scrollback");
}

#[test]
fn kill_returns_only_after_exit_is_observable() {
    let registry = SessionRegistry::new();
    let session = create(&registry, "kill", "sleep 30", None);
    let subscription = session.subscribe(4);

    assert!(registry.kill("kill"));
    assert!(matches!(
        subscription.recv_timeout(Duration::ZERO).unwrap(),
        SessionEvent::Exited { .. }
    ));
}

/// The polite SIGHUP is not the end of the story: a process that ignores it
/// keeps the PTY open, and a kill that waits on the PTY would then never
/// return — the app's next request queues behind it, and the "deleted"
/// terminal lives on. Kill must end the session anyway, and promptly.
#[test]
fn kill_ends_a_session_whose_process_ignores_sighup() {
    let registry = SessionRegistry::new();
    let session = create(&registry, "hup", "trap '' HUP; sleep 30", None);
    let subscription = session.subscribe(4);
    std::thread::sleep(Duration::from_millis(300));

    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || tx.send(registry.kill("hup")).unwrap());
    assert!(rx
        .recv_timeout(Duration::from_secs(5))
        .expect("kill returned within the bound"));
    assert!(matches!(
        subscription.recv_timeout(Duration::from_secs(2)).unwrap(),
        SessionEvent::Exited { .. }
    ));
}

#[test]
fn transcript_redacts_secrets_before_persisting_them() {
    let temp = tempfile::tempdir().unwrap();
    let transcript = temp.path().join("redacted.log");
    let registry = SessionRegistry::new();
    let session = create(
        &registry,
        "redacted",
        "printf 'API_KEY=abc123\\n'",
        Some(transcript.clone()),
    );
    let subscription = session.subscribe(4);
    loop {
        if matches!(
            subscription.recv_timeout(Duration::from_secs(2)).unwrap(),
            SessionEvent::Exited { .. }
        ) {
            break;
        }
    }

    let transcript = std::fs::read_to_string(transcript).unwrap();
    assert!(!transcript.contains("abc123"), "{transcript}");
    assert!(transcript.contains("[redacted]"), "{transcript}");
}

// MARK: - Bare-name engine resolution (Task 28's carried gap, 2026-09-01
// remote environment sharing spec §4/§6): a remote viewer sends the engine
// *name*; the daemon resolves it against its own host disk, never the
// client-sent `env["PATH"]`.

/// A remote viewer sends `"claude"`, not `/opt/homebrew/bin/claude` — proven
/// here by handing the daemon a name alongside a client `PATH` that could
/// not possibly resolve it, and expecting the daemon's own on-disk lookup to
/// find it anyway.
#[test]
fn a_bare_engine_name_is_resolved_against_this_machines_own_disk_not_the_clients_path() {
    let registry = SessionRegistry::new();
    let result = registry.create_session(CreateSession {
        id: "bare-name-resolve".into(),
        command: vec!["sh".into(), "-c".into(), "exit 0".into()],
        cwd: None,
        // If the daemon trusted this (the *sender's* own machine's PATH)
        // rather than resolving on its own, session creation would fail.
        env: HashMap::from([("PATH".to_string(), "/definitely/not/a/real/dir".to_string())]),
        cols: 80,
        rows: 24,
        transcript_path: None,
    });
    assert!(result.is_ok(), "{:?}", result.err());
}

/// A name this machine genuinely does not have is a clear, host-scoped
/// error — not the raw `ENOENT` `portable_pty::spawn_command` would
/// otherwise surface a layer down, and not a silent success against the
/// wrong file.
#[test]
fn a_bare_name_this_machine_does_not_have_is_a_clear_error() {
    let registry = SessionRegistry::new();
    let result = registry.create_session(CreateSession {
        id: "bare-name-missing".into(),
        command: vec!["definitely-not-a-real-omniagent-engine-binary".into()],
        cwd: None,
        env: HashMap::new(),
        cols: 80,
        rows: 24,
        transcript_path: None,
    });
    let error = match result {
        Err(error) => error.to_string(),
        Ok(_) => panic!("expected a resolution failure for a binary that does not exist"),
    };
    assert!(
        error.contains("definitely-not-a-real-omniagent-engine-binary")
            && error.contains("not installed"),
        "{error}"
    );
}

/// An absolute path — every local launch, unchanged — bypasses resolution
/// entirely: no lookup, no dependence on `PATH` at all, exactly as before
/// this function existed.
#[test]
fn an_absolute_path_bypasses_resolution_entirely_the_local_case_unchanged() {
    let registry = SessionRegistry::new();
    let result = registry.create_session(CreateSession {
        id: "absolute-path-unchanged".into(),
        command: vec!["/bin/sh".into(), "-c".into(), "exit 0".into()],
        cwd: None,
        env: HashMap::from([("PATH".to_string(), "/definitely/not/a/real/dir".to_string())]),
        cols: 80,
        rows: 24,
        transcript_path: None,
    });
    assert!(result.is_ok(), "{:?}", result.err());
}

// MARK: - `host_search_path` (Task 28 fix round 1): `HostState` reports
// engine availability from `EngineLauncher.searchPath`, the app's own
// login-shell PATH — the one place that actually reaches an nvm/asdf
// install, which lives under a versioned subdirectory no fixed list can
// name. Resolving against the fixed list alone reintroduced this fix's own
// "reports available, then fails to launch" bug one layer down; these tests
// pin that `create_session_with_search_path`'s `host_search_path` closes it.

/// Writes a tiny executable shell script at `dir/name` and returns `dir`'s
/// path as a string — a stand-in for an nvm/asdf `bin` directory holding
/// exactly one engine, deliberately outside every fixed-list location and
/// outside this test process's own inherited `PATH`.
fn write_fake_engine_bin(dir: &std::path::Path, name: &str) -> String {
    use std::os::unix::fs::PermissionsExt;
    let path = dir.join(name);
    std::fs::write(&path, "#!/bin/sh\nexit 0\n").unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    dir.to_string_lossy().into_owned()
}

/// The positive case: a bare name unreachable through the fixed list or this
/// process's own inherited `PATH` resolves — and launches — once its
/// directory is offered as `host_search_path`, exactly as the app publishes
/// its login-shell `PATH` to the `engine_search_path` settings row.
#[test]
fn a_bare_name_reachable_only_through_the_login_shell_path_resolves_and_launches() {
    let temp = tempfile::tempdir().unwrap();
    let nvm_style_bin = write_fake_engine_bin(temp.path(), "totally-fake-nvm-engine");

    let registry = SessionRegistry::new();
    let without_search_path = registry.create_session(CreateSession {
        id: "nvm-engine-no-search-path".into(),
        command: vec!["totally-fake-nvm-engine".into()],
        cwd: None,
        env: HashMap::new(),
        cols: 80,
        rows: 24,
        transcript_path: None,
    });
    assert!(
        without_search_path.is_err(),
        "a location outside the fixed list must NOT resolve without host_search_path — \
         otherwise this test is not proving what it claims to"
    );

    let with_search_path = registry.create_session_with_search_path(
        CreateSession {
            id: "nvm-engine-with-search-path".into(),
            command: vec!["totally-fake-nvm-engine".into()],
            cwd: None,
            env: HashMap::new(),
            cols: 80,
            rows: 24,
            transcript_path: None,
        },
        Some(&nvm_style_bin),
    );
    assert!(with_search_path.is_ok(), "{:?}", with_search_path.err());
}

/// `host_search_path` is what the *daemon's own settings row* carries
/// (`server.rs`'s `ENGINE_SEARCH_PATH_KEY`), never the wire request's own
/// `env["PATH"]` — proven by handing the client a `PATH` that names the real
/// binary's directory while `host_search_path` names a different, empty one:
/// resolution must still fail, because only `host_search_path` is trusted.
#[test]
fn the_clients_own_env_path_is_still_never_trusted_even_with_a_search_path_present() {
    let temp = tempfile::tempdir().unwrap();
    let real_bin = write_fake_engine_bin(temp.path(), "totally-fake-nvm-engine");
    let empty = tempfile::tempdir().unwrap();

    let registry = SessionRegistry::new();
    let result = registry.create_session_with_search_path(
        CreateSession {
            id: "client-path-ignored".into(),
            command: vec!["totally-fake-nvm-engine".into()],
            cwd: None,
            // The client's own PATH names exactly where the binary lives —
            // if this were consulted, resolution would succeed for the
            // wrong reason.
            env: HashMap::from([("PATH".to_string(), real_bin)]),
            cols: 80,
            rows: 24,
            transcript_path: None,
        },
        Some(&empty.path().to_string_lossy()),
    );
    assert!(
        result.is_err(),
        "the client's own env[\"PATH\"] must never be consulted, even alongside a real host_search_path"
    );
}

// The empty-`PATH`-entry fix (Task 28 fix round 2, item 3) is proven as a
// unit test inside `session.rs` itself, directly against the private
// `resolve_engine_binary` — not here. An end-to-end `CreateSession` round
// trip cannot isolate it: `resolve_engine_binary`'s own (buggy, pre-fix)
// match on an empty entry returns nothing more than the bare name back
// (`PathBuf::from("").join(name) == PathBuf::from(name)`), which
// `portable_pty::CommandBuilder` then re-resolves *itself* — against its
// own notion of the child's cwd/PATH, decoupled from this crate's fix —
// so the overall spawn fails at that later, unrelated layer regardless of
// whether this fix's filter is present. A first draft of this test lived
// here and passed identically with the filter removed, which is what
// caught the flaw.
