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
        SessionEvent::Resized { .. } => panic!("unexpected resize"),
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
