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
    }
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
