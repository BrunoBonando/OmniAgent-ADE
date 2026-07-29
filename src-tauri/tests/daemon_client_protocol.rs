use omniagent_ade_lib::daemon::{session_name, DaemonEvent, DaemonSessions};
use omniagent_ade_lib::sessions::{
    AttentionSink, CreateSessionRequest, OutputSink, SessionEndHook, SessionManager, SessionStatus,
    StatusSink,
};
use omniagent_pty_daemon::protocol::{
    decode_raw_payload, encode_raw_payload, AttachPayload, AttentionPayload, Frame, Header,
    HelloAckPayload, MessageKind, ResizePayload, ResponsePayload, SessionCreatedPayload,
    SessionExitedPayload, SessionListPayload, SessionStatus as ProtocolSessionStatus,
    SessionStatusPayload, HEADER_LEN,
};
use omniagent_pty_daemon::{CreateSession, DaemonServer};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

fn read_frame(stream: &mut UnixStream) -> Frame {
    let mut header = [0; HEADER_LEN];
    stream.read_exact(&mut header).unwrap();
    let header = Header::decode(header).unwrap();
    let mut payload = vec![0; header.payload_length as usize];
    stream.read_exact(&mut payload).unwrap();
    Frame { header, payload }
}

fn write_frame(stream: &mut UnixStream, frame: Frame) {
    stream.write_all(&frame.encode().unwrap()).unwrap();
    stream.flush().unwrap();
}

fn write_json(
    stream: &mut UnixStream,
    kind: MessageKind,
    request: u64,
    value: &impl serde::Serialize,
) {
    write_frame(
        stream,
        Frame::new(kind, request, serde_json::to_vec(value).unwrap()),
    );
}

fn fake_daemon(socket: &Path) -> std::thread::JoinHandle<()> {
    let listener = UnixListener::bind(socket).unwrap();
    std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();

        let hello = read_frame(&mut stream);
        assert_eq!(hello.header.message_kind, MessageKind::Hello);
        write_json(
            &mut stream,
            MessageKind::HelloAck,
            hello.header.request_or_sequence,
            &HelloAckPayload {
                protocol_version: 1,
            },
        );

        let list = read_frame(&mut stream);
        assert_eq!(list.header.message_kind, MessageKind::ListSessions);
        write_json(
            &mut stream,
            MessageKind::SessionList,
            list.header.request_or_sequence,
            &SessionListPayload { sessions: vec![] },
        );

        let create = read_frame(&mut stream);
        assert_eq!(create.header.message_kind, MessageKind::CreateSession);
        let create_payload: CreateSession = serde_json::from_slice(&create.payload).unwrap();
        assert_eq!(create_payload.id, "persistent");
        write_json(
            &mut stream,
            MessageKind::SessionCreated,
            create.header.request_or_sequence,
            &SessionCreatedPayload {
                id: "persistent".into(),
            },
        );

        let attach = read_frame(&mut stream);
        assert_eq!(attach.header.message_kind, MessageKind::Attach);
        assert_eq!(
            serde_json::from_slice::<AttachPayload>(&attach.payload).unwrap(),
            AttachPayload {
                id: "persistent".into(),
                after_sequence: None,
            }
        );
        write_frame(
            &mut stream,
            Frame::new(
                MessageKind::Snapshot,
                7,
                encode_raw_payload("persistent", b"snapshot").unwrap(),
            ),
        );

        let input = read_frame(&mut stream);
        assert_eq!(input.header.message_kind, MessageKind::Input);
        assert_eq!(
            decode_raw_payload(&input.payload).unwrap(),
            ("persistent", b"\0\xff".as_slice())
        );
        write_json(
            &mut stream,
            MessageKind::Response,
            input.header.request_or_sequence,
            &ResponsePayload { ok: true },
        );
        write_frame(
            &mut stream,
            Frame::new(
                MessageKind::Output,
                8,
                encode_raw_payload("persistent", b"\0\xff").unwrap(),
            ),
        );

        let resize = read_frame(&mut stream);
        assert_eq!(resize.header.message_kind, MessageKind::Resize);
        assert_eq!(
            serde_json::from_slice::<ResizePayload>(&resize.payload).unwrap(),
            ResizePayload {
                id: "persistent".into(),
                cols: 132,
                rows: 43,
            }
        );
        write_json(
            &mut stream,
            MessageKind::Response,
            resize.header.request_or_sequence,
            &ResponsePayload { ok: true },
        );

        let interrupt = read_frame(&mut stream);
        assert_eq!(interrupt.header.message_kind, MessageKind::Interrupt);
        write_json(
            &mut stream,
            MessageKind::Response,
            interrupt.header.request_or_sequence,
            &ResponsePayload { ok: true },
        );

        let kill = read_frame(&mut stream);
        assert_eq!(kill.header.message_kind, MessageKind::Kill);
        write_json(
            &mut stream,
            MessageKind::SessionExited,
            9,
            &SessionExitedPayload {
                id: "persistent".into(),
                exit_code: Some(130),
            },
        );
        write_json(
            &mut stream,
            MessageKind::Response,
            kill.header.request_or_sequence,
            &ResponsePayload { ok: true },
        );
    })
}

#[test]
fn one_connection_routes_control_and_raw_terminal_events() {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("daemon.sock");
    let server = fake_daemon(&socket);
    let client = DaemonSessions::new(socket);

    assert_eq!(client.list().unwrap(), Vec::<String>::new());
    client
        .create_session(CreateSession {
            id: "persistent".into(),
            command: vec!["/bin/sh".into()],
            cwd: None,
            env: HashMap::new(),
            cols: 80,
            rows: 24,
            transcript_path: None,
        })
        .unwrap();

    let (events_tx, events_rx) = mpsc::channel();
    client
        .attach_session(
            "persistent",
            None,
            Arc::new(move |event| {
                events_tx.send(event).unwrap();
            }),
        )
        .unwrap();
    assert!(matches!(
        events_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        DaemonEvent::Snapshot {
            sequence: 7,
            bytes,
            ..
        } if bytes == b"snapshot"
    ));

    client.send_input("persistent", b"\0\xff").unwrap();
    assert!(matches!(
        events_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        DaemonEvent::Output {
            sequence: 8,
            bytes,
            ..
        } if bytes == b"\0\xff"
    ));
    client.resize("persistent", 132, 43).unwrap();
    client.send_interrupt("persistent").unwrap();
    client.kill("persistent").unwrap();
    assert!(matches!(
        events_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        DaemonEvent::Exited {
            sequence: 9,
            exit_code: Some(130),
            ..
        }
    ));

    drop(client);
    server.join().unwrap();
}

#[test]
fn reconnect_reattaches_after_the_last_observed_sequence() {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("daemon.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let (mut first, _) = listener.accept().unwrap();
        let hello = read_frame(&mut first);
        write_json(
            &mut first,
            MessageKind::HelloAck,
            hello.header.request_or_sequence,
            &HelloAckPayload {
                protocol_version: 1,
            },
        );
        let attach = read_frame(&mut first);
        let payload: AttachPayload = serde_json::from_slice(&attach.payload).unwrap();
        assert_eq!(payload.id, "session-reconnect");
        assert_eq!(payload.after_sequence, None);
        write_frame(
            &mut first,
            Frame::new(
                MessageKind::Snapshot,
                10,
                encode_raw_payload("session-reconnect", b"snapshot").unwrap(),
            ),
        );
        drop(first);

        let (mut second, _) = listener.accept().unwrap();
        let hello = read_frame(&mut second);
        write_json(
            &mut second,
            MessageKind::HelloAck,
            hello.header.request_or_sequence,
            &HelloAckPayload {
                protocol_version: 1,
            },
        );
        let reattach = read_frame(&mut second);
        let payload: AttachPayload = serde_json::from_slice(&reattach.payload).unwrap();
        assert_eq!(payload.id, "session-reconnect");
        assert_eq!(payload.after_sequence, Some(10));
        write_frame(
            &mut second,
            Frame::new(
                MessageKind::Output,
                11,
                encode_raw_payload("session-reconnect", b"resumed").unwrap(),
            ),
        );
    });

    let client = DaemonSessions::new(socket);
    let (events_tx, events_rx) = mpsc::channel();
    client
        .attach_session(
            "session-reconnect",
            None,
            Arc::new(move |event| events_tx.send(event).unwrap()),
        )
        .unwrap();
    assert!(matches!(
        events_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        DaemonEvent::Snapshot {
            sequence: 10,
            bytes,
            ..
        } if bytes == b"snapshot"
    ));

    assert!(matches!(
        events_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        DaemonEvent::Output {
            sequence: 11,
            bytes,
            ..
        } if bytes == b"resumed"
    ));
    drop(client);
    server.join().unwrap();
}

#[test]
fn slow_event_callback_does_not_block_control_responses() {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("daemon.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let hello = read_frame(&mut stream);
        write_json(
            &mut stream,
            MessageKind::HelloAck,
            hello.header.request_or_sequence,
            &HelloAckPayload {
                protocol_version: 1,
            },
        );
        let attach = read_frame(&mut stream);
        assert_eq!(attach.header.message_kind, MessageKind::Attach);
        write_frame(
            &mut stream,
            Frame::new(
                MessageKind::Output,
                1,
                encode_raw_payload("slow-callback", b"blocked").unwrap(),
            ),
        );
        for sequence in 2..=71 {
            write_frame(
                &mut stream,
                Frame::new(
                    MessageKind::Output,
                    sequence,
                    encode_raw_payload("slow-callback", b"queued").unwrap(),
                ),
            );
        }

        let list = read_frame(&mut stream);
        assert_eq!(list.header.message_kind, MessageKind::ListSessions);
        write_json(
            &mut stream,
            MessageKind::SessionList,
            list.header.request_or_sequence,
            &SessionListPayload {
                sessions: vec!["slow-callback".into()],
            },
        );
    });

    let client = DaemonSessions::new(socket);
    let (callback_started_tx, callback_started_rx) = mpsc::channel();
    let (release_callback_tx, release_callback_rx) = mpsc::channel();
    let (events_tx, events_rx) = mpsc::channel();
    let release_callback_rx = Arc::new(Mutex::new(release_callback_rx));
    let first_callback = Arc::new(AtomicBool::new(true));
    client
        .attach_session(
            "slow-callback",
            None,
            Arc::new(move |event| {
                if first_callback.swap(false, Ordering::Relaxed) {
                    callback_started_tx.send(()).unwrap();
                    release_callback_rx.lock().unwrap().recv().unwrap();
                }
                events_tx.send(event).unwrap();
            }),
        )
        .unwrap();
    callback_started_rx
        .recv_timeout(Duration::from_secs(2))
        .unwrap();

    let request_client = client.clone();
    let (result_tx, result_rx) = mpsc::channel();
    let request = std::thread::spawn(move || {
        result_tx.send(request_client.list()).unwrap();
    });
    let prompt_result = result_rx.recv_timeout(Duration::from_millis(300));
    let response_was_prompt = prompt_result.is_ok();
    release_callback_tx.send(()).unwrap();
    let eventual_result = match prompt_result {
        Ok(result) => result,
        Err(_) => result_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
    };
    request.join().unwrap();
    server.join().unwrap();

    assert!(
        response_was_prompt,
        "daemon control response was blocked behind a slow event callback"
    );
    assert_eq!(eventual_result.unwrap(), vec!["slow-callback"]);
    assert!(matches!(
        events_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
        DaemonEvent::Output { sequence: 1, .. }
    ));
    assert!(matches!(
        events_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
        DaemonEvent::ResyncRequired { .. }
    ));
}

#[test]
fn natural_exit_removes_handler_before_reconnect_replay() {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("daemon.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let hello = read_frame(&mut stream);
        write_json(
            &mut stream,
            MessageKind::HelloAck,
            hello.header.request_or_sequence,
            &HelloAckPayload {
                protocol_version: 1,
            },
        );
        let attach = read_frame(&mut stream);
        assert_eq!(attach.header.message_kind, MessageKind::Attach);
        write_json(
            &mut stream,
            MessageKind::SessionExited,
            1,
            &SessionExitedPayload {
                id: "natural-exit".into(),
                exit_code: Some(0),
            },
        );
        drop(stream);

        listener.set_nonblocking(true).unwrap();
        let deadline = std::time::Instant::now() + Duration::from_millis(400);
        while std::time::Instant::now() < deadline {
            match listener.accept() {
                Ok(_) => panic!("natural exit left a stale handler that reconnected"),
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    std::thread::sleep(Duration::from_millis(10));
                }
                Err(error) => panic!("accept reconnect probe: {error}"),
            }
        }
    });

    let client = DaemonSessions::new(socket);
    let (events_tx, events_rx) = mpsc::channel();
    client
        .attach_session(
            "natural-exit",
            None,
            Arc::new(move |event| events_tx.send(event).unwrap()),
        )
        .unwrap();
    assert!(matches!(
        events_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        DaemonEvent::Exited {
            exit_code: Some(0),
            ..
        }
    ));
    server.join().unwrap();
}

#[test]
fn session_manager_attaches_during_create_so_early_exit_is_observed() {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("daemon.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let server = std::thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let hello = read_frame(&mut stream);
        write_json(
            &mut stream,
            MessageKind::HelloAck,
            hello.header.request_or_sequence,
            &HelloAckPayload {
                protocol_version: 1,
            },
        );
        let list = read_frame(&mut stream);
        write_json(
            &mut stream,
            MessageKind::SessionList,
            list.header.request_or_sequence,
            &SessionListPayload { sessions: vec![] },
        );
        let create = read_frame(&mut stream);
        let create_payload: CreateSession = serde_json::from_slice(&create.payload).unwrap();
        write_json(
            &mut stream,
            MessageKind::SessionCreated,
            create.header.request_or_sequence,
            &SessionCreatedPayload {
                id: create_payload.id.clone(),
            },
        );

        let attach = read_frame(&mut stream);
        assert_eq!(attach.header.message_kind, MessageKind::Attach);
        write_frame(
            &mut stream,
            Frame::new(
                MessageKind::Snapshot,
                1,
                encode_raw_payload(&create_payload.id, b"final output").unwrap(),
            ),
        );
        write_json(
            &mut stream,
            MessageKind::SessionStatus,
            2,
            &SessionStatusPayload {
                id: create_payload.id.clone(),
                status: ProtocolSessionStatus::ToolExecution,
                engine: "shell".into(),
                notify: false,
            },
        );
        write_json(
            &mut stream,
            MessageKind::Attention,
            3,
            &AttentionPayload {
                id: create_payload.id.clone(),
            },
        );
        write_json(
            &mut stream,
            MessageKind::SessionExited,
            4,
            &SessionExitedPayload {
                id: create_payload.id,
                exit_code: Some(7),
            },
        );
    });

    let (ended_tx, ended_rx) = mpsc::channel();
    let (output_tx, output_rx) = mpsc::channel();
    let (status_tx, status_rx) = mpsc::channel();
    let (attention_tx, attention_rx) = mpsc::channel();
    let end_hook: SessionEndHook = Arc::new(move |event| {
        ended_tx.send(event.id.clone()).unwrap();
    });
    let output_sink: OutputSink = Arc::new(move |_, bytes| {
        output_tx.send(bytes.to_vec()).unwrap();
    });
    let status_sink: StatusSink = Arc::new(move |event| {
        status_tx.send(event.status).unwrap();
    });
    let attention_sink: AttentionSink = Arc::new(move |id| {
        attention_tx.send(id.to_string()).unwrap();
    });
    let manager = SessionManager::new(temp.path().to_path_buf(), output_sink)
        .with_daemon_sessions(Some(DaemonSessions::new(socket)))
        .with_end_hook(end_hook)
        .with_status_sink(status_sink)
        .with_attention_sink(attention_sink);
    let info = manager
        .create(CreateSessionRequest {
            project: "early-exit".into(),
            engine: "shell".into(),
            cwd: temp.path().display().to_string(),
            briefing: None,
            restore_id: None,
        })
        .unwrap();

    assert_eq!(
        ended_rx.recv_timeout(Duration::from_secs(2)).unwrap(),
        info.id
    );
    assert_eq!(
        status_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
        SessionStatus::ToolExecution
    );
    assert_eq!(
        attention_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
        info.id
    );
    assert!(
        manager.status(&info.id).is_none(),
        "natural exit must remove the Tauri compatibility handle"
    );
    assert!(
        output_rx.try_recv().is_err(),
        "display bytes must wait until the frontend listener is ready"
    );
    manager.resize(&info.id, 80, 24).unwrap();
    assert_eq!(
        output_rx.recv_timeout(Duration::from_secs(1)).unwrap(),
        b"final output"
    );
    server.join().unwrap();
}

struct RealServer {
    stop: tokio::sync::oneshot::Sender<()>,
    thread: std::thread::JoinHandle<()>,
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
        Self { stop, thread }
    }

    fn stop(self) {
        let _ = self.stop.send(());
        self.thread.join().unwrap();
    }
}

#[test]
fn session_manager_is_a_daemon_compatibility_adapter_not_a_second_pty_owner() {
    let temp = tempfile::tempdir().unwrap();
    let socket = temp.path().join("runtime/daemon.sock");
    let server = RealServer::start(socket.clone());
    let daemon = DaemonSessions::new(socket);
    let (output_tx, output_rx) = mpsc::channel();
    let sink: OutputSink = Arc::new(move |id, bytes| {
        output_tx.send((id.to_string(), bytes.to_vec())).unwrap();
    });
    let manager = SessionManager::new(temp.path().to_path_buf(), sink)
        .with_daemon_sessions(Some(daemon.clone()));

    let info = manager
        .create(CreateSessionRequest {
            project: "compatibility".into(),
            engine: "shell".into(),
            cwd: temp.path().display().to_string(),
            briefing: None,
            restore_id: None,
        })
        .unwrap();
    assert!(info.persistent);
    assert_eq!(
        manager.pid(&info.id),
        None,
        "Tauri must not own a proxy child process"
    );

    // Creation subscribes the compatibility layer immediately. The first
    // resize only marks renderer delivery ready and flushes the snapshot that
    // was buffered while the frontend installed `session-output:{id}`.
    manager.resize(&info.id, 132, 43).unwrap();
    manager
        .write(&info.id, "printf 'DAEMON_ONLY:%s\\n' \"$(tput cols)\"\n")
        .unwrap();

    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    let mut output = Vec::new();
    while std::time::Instant::now() < deadline {
        if let Ok((id, bytes)) = output_rx.recv_timeout(Duration::from_millis(100)) {
            assert_eq!(id, info.id);
            output.extend(bytes);
            if String::from_utf8_lossy(&output).contains("DAEMON_ONLY:132") {
                break;
            }
        }
    }
    assert!(
        String::from_utf8_lossy(&output).contains("DAEMON_ONLY:132"),
        "daemon output/resize did not reach the compatibility sink: {:?}",
        String::from_utf8_lossy(&output)
    );
    assert_eq!(daemon.list_sessions(), vec![session_name(&info.id)]);

    manager.kill(&info.id).unwrap();
    drop(manager);
    drop(daemon);
    server.stop();
}
