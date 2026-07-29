use omniagent_pty_daemon::protocol::{
    decode_raw_payload, encode_raw_payload, read_frame, write_frame, Frame, MessageKind,
    MAX_PAYLOAD_LEN, PROTOCOL_VERSION,
};
use omniagent_pty_daemon::{CreateSession, DaemonServer};
use serde::Serialize;
use std::collections::HashMap;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::Path;
use std::time::Duration;
use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;
use tokio::sync::oneshot;

struct TestServer {
    socket: std::path::PathBuf,
    stop: Option<oneshot::Sender<()>>,
    task: tokio::task::JoinHandle<anyhow::Result<()>>,
}

impl TestServer {
    async fn start(root: &Path) -> Self {
        let socket = root.join("runtime").join("daemon.sock");
        let server = DaemonServer::bind(socket.clone()).await.unwrap();
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(server.run_until(stopped));
        Self {
            socket,
            stop: Some(stop),
            task,
        }
    }

    async fn stop(mut self) {
        let _ = self.stop.take().unwrap().send(());
        self.task.await.unwrap().unwrap();
        assert!(!self.socket.exists());
    }
}

struct Client {
    stream: UnixStream,
    request: u64,
}

impl Client {
    async fn connect(socket: &Path) -> Self {
        let mut client = Self {
            stream: UnixStream::connect(socket).await.unwrap(),
            request: 1,
        };
        client
            .send_json(MessageKind::Hello, &serde_json::json!({"client":"test"}))
            .await;
        let ack = client.read().await;
        assert_eq!(ack.header.message_kind, MessageKind::HelloAck);
        assert_eq!(ack.header.request_or_sequence, 1);
        client
    }

    async fn send_json(&mut self, kind: MessageKind, payload: &impl Serialize) -> u64 {
        let request = self.request;
        self.request += 1;
        write_frame(
            &mut self.stream,
            &Frame::new(kind, request, serde_json::to_vec(payload).unwrap()),
        )
        .await
        .unwrap();
        request
    }

    async fn send_raw(&mut self, session: &str, raw: &[u8]) -> u64 {
        let request = self.request;
        self.request += 1;
        write_frame(
            &mut self.stream,
            &Frame::new(
                MessageKind::Input,
                request,
                encode_raw_payload(session, raw).unwrap(),
            ),
        )
        .await
        .unwrap();
        request
    }

    async fn read(&mut self) -> Frame {
        tokio::time::timeout(Duration::from_secs(4), read_frame(&mut self.stream))
            .await
            .unwrap()
            .unwrap()
    }

    async fn read_kind(&mut self, kind: MessageKind) -> Frame {
        loop {
            let frame = self.read().await;
            if frame.header.message_kind == kind {
                return frame;
            }
        }
    }
}

fn command_session(id: &str, script: &str) -> CreateSession {
    CreateSession {
        id: id.into(),
        command: vec!["/bin/sh".into(), "-c".into(), script.into()],
        cwd: None,
        env: HashMap::new(),
        cols: 80,
        rows: 24,
        transcript_path: None,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn one_persistent_connection_streams_raw_bytes_and_applies_resize() {
    let temp = tempfile::tempdir().unwrap();
    let server = TestServer::start(temp.path()).await;
    let mut client = Client::connect(&server.socket).await;

    let create = command_session(
        "raw",
        "sleep 0.2; stty raw -echo; printf READY; dd bs=6 count=1 2>/dev/null; while IFS= read -r line; do if [ \"$line\" = size ]; then stty size; else printf %s \"$line\"; fi; done",
    );
    let create_request = client.send_json(MessageKind::CreateSession, &create).await;
    let created = client.read().await;
    assert_eq!(created.header.message_kind, MessageKind::SessionCreated);
    assert_eq!(created.header.request_or_sequence, create_request);

    client
        .send_json(
            MessageKind::Attach,
            &serde_json::json!({"id":"raw","after_sequence":null}),
        )
        .await;
    let snapshot = client.read_kind(MessageKind::Snapshot).await;
    assert_eq!(decode_raw_payload(&snapshot.payload).unwrap().0, "raw");
    let ready = client.read_kind(MessageKind::Output).await;
    assert_eq!(
        decode_raw_payload(&ready.payload).unwrap(),
        ("raw", b"READY".as_slice())
    );
    client
        .send_json(MessageKind::Detach, &serde_json::json!({"id":"raw"}))
        .await;
    client.read_kind(MessageKind::Response).await;
    let resume_request = client
        .send_json(
            MessageKind::Attach,
            &serde_json::json!({
                "id":"raw",
                "after_sequence":ready.header.request_or_sequence
            }),
        )
        .await;
    let resumed = client.read_kind(MessageKind::Response).await;
    assert_eq!(resumed.header.request_or_sequence, resume_request);

    let raw = [0, 0xff, 0x1b, b'[', b'2', b'J'];
    client.send_raw("raw", &raw).await;
    let echoed = client.read_kind(MessageKind::Output).await;
    assert_eq!(
        decode_raw_payload(&echoed.payload).unwrap(),
        ("raw", raw.as_slice())
    );

    let resize_request = client
        .send_json(
            MessageKind::Resize,
            &serde_json::json!({"id":"raw","cols":132,"rows":43}),
        )
        .await;
    let resized = client.read_kind(MessageKind::Response).await;
    assert_eq!(resized.header.request_or_sequence, resize_request);
    client.send_raw("raw", b"size\n").await;
    let size = client.read_kind(MessageKind::Output).await;
    assert_eq!(decode_raw_payload(&size.payload).unwrap().1, b"43 132\n");

    client
        .send_json(MessageKind::Detach, &serde_json::json!({"id":"raw"}))
        .await;
    assert_eq!(
        client
            .read_kind(MessageKind::Response)
            .await
            .header
            .message_kind,
        MessageKind::Response
    );
    client
        .send_json(
            MessageKind::Attach,
            &serde_json::json!({"id":"raw","after_sequence":null}),
        )
        .await;
    client.read_kind(MessageKind::Snapshot).await;
    client
        .send_json(MessageKind::Kill, &serde_json::json!({"id":"raw"}))
        .await;
    let mut kill_kinds = vec![client.read().await.header.message_kind];
    kill_kinds.push(client.read().await.header.message_kind);
    kill_kinds.sort_by_key(|kind| *kind as u8);
    assert_eq!(
        kill_kinds,
        vec![MessageKind::SessionExited, MessageKind::Response]
    );
    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn runtime_permissions_peer_policy_and_bad_frames_are_enforced() {
    let temp = tempfile::tempdir().unwrap();
    let server = TestServer::start(temp.path()).await;
    let runtime = server.socket.parent().unwrap();
    let metadata = std::fs::metadata(runtime).unwrap();
    assert_eq!(metadata.permissions().mode() & 0o777, 0o700);
    assert!(omniagent_pty_daemon::peer_uid_allowed(
        metadata.uid(),
        metadata.uid()
    ));
    assert!(!omniagent_pty_daemon::peer_uid_allowed(
        metadata.uid() + 1,
        metadata.uid()
    ));

    for mutation in ["oversize", "version"] {
        let mut stream = UnixStream::connect(&server.socket).await.unwrap();
        let mut header = [0; 16];
        header[..4].copy_from_slice(
            &(if mutation == "oversize" {
                MAX_PAYLOAD_LEN as u32 + 1
            } else {
                0
            })
            .to_be_bytes(),
        );
        header[4] = if mutation == "version" {
            PROTOCOL_VERSION + 1
        } else {
            PROTOCOL_VERSION
        };
        header[5] = MessageKind::Hello as u8;
        stream.write_all(&header).await.unwrap();
        assert!(
            tokio::time::timeout(Duration::from_secs(2), read_frame(&mut stream))
                .await
                .unwrap()
                .is_err()
        );
    }

    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_control_json_closes_an_attached_connection() {
    let temp = tempfile::tempdir().unwrap();
    let server = TestServer::start(temp.path()).await;
    let mut client = Client::connect(&server.socket).await;
    client
        .send_json(
            MessageKind::CreateSession,
            &command_session("malformed", "sleep 30"),
        )
        .await;
    client.read_kind(MessageKind::SessionCreated).await;
    client
        .send_json(
            MessageKind::Attach,
            &serde_json::json!({"id":"malformed","after_sequence":null}),
        )
        .await;
    client.read_kind(MessageKind::Snapshot).await;

    let request = client.request;
    write_frame(
        &mut client.stream,
        &Frame::new(MessageKind::Resize, request, b"{".to_vec()),
    )
    .await
    .unwrap();
    assert!(
        tokio::time::timeout(Duration::from_secs(2), read_frame(&mut client.stream))
            .await
            .unwrap()
            .is_err()
    );

    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn eight_sessions_survive_creator_disconnects_and_reattach() {
    let temp = tempfile::tempdir().unwrap();
    let server = TestServer::start(temp.path()).await;
    let mut tasks = Vec::new();
    for index in 0..8 {
        let socket = server.socket.clone();
        tasks.push(tokio::spawn(async move {
            let mut client = Client::connect(&socket).await;
            let id = format!("session-{index}");
            let marker = format!("ready-{index}");
            let request = command_session(
                &id,
                &format!("sleep 0.2; stty raw -echo; printf {marker}; cat"),
            );
            client.send_json(MessageKind::CreateSession, &request).await;
            assert_eq!(
                client.read().await.header.message_kind,
                MessageKind::SessionCreated
            );
        }));
    }
    for task in tasks {
        task.await.unwrap();
    }

    tokio::time::sleep(Duration::from_millis(500)).await;
    let mut client = Client::connect(&server.socket).await;
    client
        .send_json(MessageKind::ListSessions, &serde_json::json!({}))
        .await;
    let list = client.read_kind(MessageKind::SessionList).await;
    let sessions = serde_json::from_slice::<serde_json::Value>(&list.payload).unwrap();
    assert_eq!(sessions["sessions"].as_array().unwrap().len(), 8);

    for index in 0..8 {
        let id = format!("session-{index}");
        client
            .send_json(
                MessageKind::Attach,
                &serde_json::json!({"id":id,"after_sequence":null}),
            )
            .await;
        let snapshot = client.read_kind(MessageKind::Snapshot).await;
        let (snapshot_id, bytes) = decode_raw_payload(&snapshot.payload).unwrap();
        assert_eq!(snapshot_id, id);
        assert!(bytes
            .windows(format!("ready-{index}").len())
            .any(|window| window == format!("ready-{index}").as_bytes()));
        client
            .send_json(MessageKind::Detach, &serde_json::json!({"id":id}))
            .await;
        client.read_kind(MessageKind::Response).await;
    }

    for index in 0..8 {
        client
            .send_json(
                MessageKind::Kill,
                &serde_json::json!({"id":format!("session-{index}")}),
            )
            .await;
        client.read_kind(MessageKind::Response).await;
    }
    server.stop().await;
}
