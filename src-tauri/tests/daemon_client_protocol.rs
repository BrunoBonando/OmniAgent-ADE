use omniagent_ade_lib::daemon::{session_name, DaemonEvent, DaemonSessions};
use omniagent_ade_lib::sessions::{CreateSessionRequest, OutputSink, SessionManager};
use omniagent_pty_daemon::protocol::{
    decode_raw_payload, encode_raw_payload, AttachPayload, Frame, Header, HelloAckPayload,
    MessageKind, ResizePayload, ResponsePayload, SessionCreatedPayload, SessionExitedPayload,
    SessionListPayload, HEADER_LEN,
};
use omniagent_pty_daemon::{CreateSession, DaemonServer};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::{mpsc, Arc};
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
        let input = read_frame(&mut second);
        let (id, bytes) = decode_raw_payload(&input.payload).unwrap();
        assert_eq!(id, "session-reconnect");
        assert_eq!(bytes, b"input");
        write_json(
            &mut second,
            MessageKind::Response,
            input.header.request_or_sequence,
            &ResponsePayload { ok: true },
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

    std::thread::sleep(Duration::from_millis(100));
    client.send_input("session-reconnect", b"input").unwrap();
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

    // Terminal mounts subscribe before their first resize. That resize is the
    // compatibility layer's attach point, so the initial snapshot cannot race
    // ahead of the existing `session-output:{id}` frontend listener.
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
