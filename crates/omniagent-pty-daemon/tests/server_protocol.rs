use brain_core::{now_ts, Node, NodeKind, Origin, Store};
use omniagent_pty_daemon::protocol::{
    decode_raw_payload, encode_raw_payload, read_frame, write_frame, Frame, MessageKind,
    SessionExitedPayload, SessionListPayload, MAX_PAYLOAD_LEN, PROTOCOL_VERSION,
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

/// The socket's runtime dir and the shared brain-store data dir are
/// deliberately two separate paths under `root` (Task 6a's data_dir fix —
/// see `DaemonServer::bind_with_data_dir`'s doc): a test that accidentally
/// reused one path for both would not catch a regression back to the bug
/// where the daemon opened its `Store` at the socket's own directory
/// instead of the app's real, shared `brain.db` location. Exposed as a
/// standalone function (not inlined into `TestServer::start`) so a test
/// that needs to pre-populate the store before the daemon starts derives
/// the exact same path, rather than duplicating the `"brain-data"` literal.
fn brain_data_dir(root: &Path) -> std::path::PathBuf {
    root.join("brain-data")
}

struct TestServer {
    socket: std::path::PathBuf,
    stop: Option<oneshot::Sender<()>>,
    task: tokio::task::JoinHandle<anyhow::Result<()>>,
}

impl TestServer {
    async fn start(root: &Path) -> Self {
        let socket = root.join("runtime").join("daemon.sock");
        let server = DaemonServer::bind_with_data_dir(socket.clone(), brain_data_dir(root))
            .await
            .unwrap();
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
    client.read_kind(MessageKind::SessionExited).await;
    client.read_kind(MessageKind::Response).await;
    server.stop().await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn exited_before_attach_still_replays_snapshot_and_exit() {
    let temp = tempfile::tempdir().unwrap();
    let server = TestServer::start(temp.path()).await;
    let mut client = Client::connect(&server.socket).await;
    client
        .send_json(
            MessageKind::CreateSession,
            &command_session("fast-exit", "printf ULTRA_EARLY; exit 7"),
        )
        .await;
    client.read_kind(MessageKind::SessionCreated).await;

    let mut observed_inactive = false;
    let deadline = tokio::time::Instant::now() + Duration::from_secs(2);
    while tokio::time::Instant::now() < deadline {
        client
            .send_json(MessageKind::ListSessions, &serde_json::json!({}))
            .await;
        let listed = client.read_kind(MessageKind::SessionList).await;
        let listed: SessionListPayload = serde_json::from_slice(&listed.payload).unwrap();
        if !listed.sessions.iter().any(|id| id == "fast-exit") {
            observed_inactive = true;
            break;
        }
        tokio::task::yield_now().await;
    }
    assert!(
        observed_inactive,
        "the regression must prove registry removal happened before Attach"
    );

    client
        .send_json(
            MessageKind::Attach,
            &serde_json::json!({"id":"fast-exit","after_sequence":null}),
        )
        .await;
    let snapshot = client.read().await;
    assert_eq!(snapshot.header.message_kind, MessageKind::Snapshot);
    let (_, bytes) = decode_raw_payload(&snapshot.payload).unwrap();
    assert!(
        bytes
            .windows(b"ULTRA_EARLY".len())
            .any(|window| window == b"ULTRA_EARLY"),
        "late attach lost the fast child's recoverable output"
    );
    let exited = client.read_kind(MessageKind::SessionExited).await;
    let exited: SessionExitedPayload = serde_json::from_slice(&exited.payload).unwrap();
    assert_eq!(exited.exit_code, Some(7));
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
    client.read_kind(MessageKind::SessionStatus).await;

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

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn settings_persist_across_connections_and_daemon_restarts() {
    let temp = tempfile::tempdir().unwrap();
    let server = TestServer::start(temp.path()).await;

    let mut setter = Client::connect(&server.socket).await;
    let set_request = setter
        .send_json(
            MessageKind::SetSetting,
            &serde_json::json!({
                "key": "layout",
                "value": r#"{"tabs":[{"id":"one"}]}"#
            }),
        )
        .await;
    let set = setter.read_kind(MessageKind::Response).await;
    assert_eq!(set.header.request_or_sequence, set_request);
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&set.payload).unwrap(),
        serde_json::json!({"ok": true})
    );
    drop(setter);

    let mut getter = Client::connect(&server.socket).await;
    let get_request = getter
        .send_json(
            MessageKind::GetSetting,
            &serde_json::json!({"key": "layout"}),
        )
        .await;
    let get = getter.read_kind(MessageKind::Response).await;
    assert_eq!(get.header.request_or_sequence, get_request);
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&get.payload).unwrap(),
        serde_json::json!({"value": r#"{"tabs":[{"id":"one"}]}"#})
    );
    drop(getter);
    server.stop().await;

    let restarted = TestServer::start(temp.path()).await;
    let mut getter = Client::connect(&restarted.socket).await;
    getter
        .send_json(
            MessageKind::GetSetting,
            &serde_json::json!({"key": "layout"}),
        )
        .await;
    let get = getter.read_kind(MessageKind::Response).await;
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&get.payload).unwrap(),
        serde_json::json!({"value": r#"{"tabs":[{"id":"one"}]}"#})
    );
    restarted.stop().await;
}

/// The cross-process "Rebuild brain" hazard (final whole-branch review,
/// Important #1). The daemon and the Tauri app each hold their own
/// long-lived `Store` against one `brain.db`; a rebuild from *either* side
/// unlinks that file and creates a new one at the same path, swapping only
/// the rebuilder's handle. Without `lock_store`'s inode check the daemon
/// would go on writing `layout`/`notifications`/`usage_analytics_v1` into
/// the orphaned inode — every write reported `{"ok": true}`, every one lost
/// on the next daemon restart.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn settings_written_after_another_process_rebuilt_brain_db_land_in_the_new_file() {
    let temp = tempfile::tempdir().unwrap();
    let server = TestServer::start(temp.path()).await;
    let data_dir = brain_data_dir(temp.path());

    let mut client = Client::connect(&server.socket).await;
    client
        .send_json(
            MessageKind::SetSetting,
            &serde_json::json!({"key": "layout", "value": "before-the-rebuild"}),
        )
        .await;
    client.read_kind(MessageKind::Response).await;

    // The *other* process's "Rebuild brain" — exactly what
    // `brain_ingest::roots::rebuild_store` does (unlink brain.db and its
    // WAL/SHM/journal siblings, open a fresh file at the same path), run
    // here from outside the daemon because the point is that the daemon is
    // not the process that did it.
    for suffix in ["", "-wal", "-shm", "-journal"] {
        let mut name = data_dir.join("brain.db").into_os_string();
        name.push(suffix);
        let _ = std::fs::remove_file(std::path::PathBuf::from(name));
    }
    let rebuilt = Store::open(&data_dir).unwrap();
    rebuilt
        .set_setting("notifications", "written-by-the-rebuilder")
        .unwrap();
    drop(rebuilt);

    client
        .send_json(
            MessageKind::SetSetting,
            &serde_json::json!({"key": "layout", "value": "after-the-rebuild"}),
        )
        .await;
    client.read_kind(MessageKind::Response).await;

    // Read back through the daemon...
    client
        .send_json(
            MessageKind::GetSetting,
            &serde_json::json!({"key": "notifications"}),
        )
        .await;
    let got = client.read_kind(MessageKind::Response).await;
    assert_eq!(
        serde_json::from_slice::<serde_json::Value>(&got.payload).unwrap(),
        serde_json::json!({"value": "written-by-the-rebuilder"}),
        "the daemon is still reading the pre-rebuild inode"
    );
    drop(client);
    server.stop().await;

    // ...and, decisively, off the file that actually lives on disk.
    let verify = Store::open(&data_dir).unwrap();
    assert_eq!(
        verify.get_setting("layout").unwrap().as_deref(),
        Some("after-the-rebuild"),
        "the daemon's write went to an orphaned inode instead of brain.db"
    );
    assert_eq!(
        verify.get_setting("notifications").unwrap().as_deref(),
        Some("written-by-the-rebuilder"),
        "and it must not have clobbered the rebuilt file"
    );
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

fn memory_node(id: &str, project: &str, label: &str) -> Node {
    Node {
        id: id.to_string(),
        kind: NodeKind::Memory,
        project: project.to_string(),
        label: label.to_string(),
        path: None,
        summary: None,
        origin: Origin::UserAuthored,
        updated: now_ts(),
    }
}

/// Task 6a: `BrainListProjects`/`BrainGetContext` dispatch against the same
/// `brain_core::Store` `GetSetting`/`SetSetting` already share, reusing the
/// frozen `mcp_server::tools::list_projects`/`get_context` projections
/// rather than a second implementation of the same query.
///
/// Seeds the store at `brain_data_dir(root)` — deliberately NOT the
/// socket's own `runtime` directory — so this test would have failed
/// against the pre-fix daemon (which opened `Store::open(runtime_dir)` and
/// therefore never saw these seeded nodes at all).
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn brain_list_projects_and_get_context_round_trip_through_the_daemon() {
    let temp = tempfile::tempdir().unwrap();
    {
        let store = Store::open(&brain_data_dir(temp.path())).unwrap();
        store
            .upsert_node(&Node {
                kind: NodeKind::Project,
                path: Some("/tmp/demo".to_string()),
                summary: Some("A demo project.".to_string()),
                ..memory_node("demo", "demo", "demo")
            })
            .unwrap();
        store
            .upsert_node(&Node {
                kind: NodeKind::Project,
                path: Some("/tmp/other".to_string()),
                ..memory_node("other", "other", "other")
            })
            .unwrap();
        store
            .upsert_node(&memory_node("demo:decision-1", "demo", "Decision: Use SQLite"))
            .unwrap();
        store
            .upsert_node(&memory_node("demo:note-1", "demo", "Note: remember this"))
            .unwrap();
    }

    let server = TestServer::start(temp.path()).await;
    let mut client = Client::connect(&server.socket).await;

    let list_request = client
        .send_json(MessageKind::BrainListProjects, &serde_json::json!({}))
        .await;
    let list = client.read_kind(MessageKind::Response).await;
    assert_eq!(list.header.request_or_sequence, list_request);
    let list_body: serde_json::Value = serde_json::from_slice(&list.payload).unwrap();
    let projects = list_body["projects"].as_array().unwrap();
    assert_eq!(projects.len(), 2);
    assert_eq!(projects[0]["id"], "demo");
    assert_eq!(projects[0]["label"], "demo");
    assert_eq!(projects[0]["path"], "/tmp/demo");
    assert_eq!(projects[1]["id"], "other");

    let context_request = client
        .send_json(
            MessageKind::BrainGetContext,
            &serde_json::json!({"project": "demo"}),
        )
        .await;
    let context = client.read_kind(MessageKind::Response).await;
    assert_eq!(context.header.request_or_sequence, context_request);
    let context_body: serde_json::Value = serde_json::from_slice(&context.payload).unwrap();
    let context = &context_body["context"];
    assert_eq!(context["summary"], "A demo project.");
    assert_eq!(context["recent_decisions"].as_array().unwrap().len(), 1);
    assert_eq!(context["memory_notes"].as_array().unwrap().len(), 2);

    // An unknown project is not an error — `get_context` degrades to an
    // empty briefing (`ToolContext::get_node` returns `None`), same as the
    // Tauri `brain_get_context` command backed by the same shared tool.
    client
        .send_json(
            MessageKind::BrainGetContext,
            &serde_json::json!({"project": "does-not-exist"}),
        )
        .await;
    let empty = client.read_kind(MessageKind::Response).await;
    let empty_body: serde_json::Value = serde_json::from_slice(&empty.payload).unwrap();
    assert_eq!(empty_body["context"]["summary"], "");
    assert!(empty_body["context"]["memory_notes"]
        .as_array()
        .unwrap()
        .is_empty());

    server.stop().await;
}

/// Envelope validation (malformed control JSON closes the connection) must
/// hold for the new brain kinds exactly as it already does for existing
/// ones (`malformed_control_json_closes_an_attached_connection` above) —
/// new message kinds go through the same `parse_json` gate, not a side
/// channel.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_brain_get_context_payload_closes_the_connection() {
    let temp = tempfile::tempdir().unwrap();
    let server = TestServer::start(temp.path()).await;
    let mut client = Client::connect(&server.socket).await;

    let request = client.request;
    write_frame(
        &mut client.stream,
        &Frame::new(MessageKind::BrainGetContext, request, b"{".to_vec()),
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

/// Task 6a-2: `RootsAddProject`/`RootsRenameProject`/`RootsSetPaused`/
/// `RootsPausedProjects`/`RootsStaleness`/`RootsReingestProject` dispatch
/// through to `brain_ingest::roots`'s Tauri-independent functions, exercised
/// end to end through the daemon exactly as a native client would drive
/// onboarding/settings — one project added, renamed, paused, and re-checked.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn roots_add_rename_pause_and_staleness_round_trip_through_the_daemon() {
    let temp = tempfile::tempdir().unwrap();
    let project_dir = tempfile::tempdir().unwrap();
    let project_path = project_dir.path().to_string_lossy().into_owned();

    let server = TestServer::start(temp.path()).await;
    let mut client = Client::connect(&server.socket).await;

    let add_request = client
        .send_json(
            MessageKind::RootsAddProject,
            &serde_json::json!({"path": project_path, "name": "My Project"}),
        )
        .await;
    let added = client.read_kind(MessageKind::Response).await;
    assert_eq!(added.header.request_or_sequence, add_request);
    let added_body: serde_json::Value = serde_json::from_slice(&added.payload).unwrap();
    assert_eq!(added_body["project"]["id"], "My Project");
    assert_eq!(added_body["project"]["path"], project_path);

    // Queryable immediately through the same brain-store read Task 6a wired.
    let list_request = client
        .send_json(MessageKind::BrainListProjects, &serde_json::json!({}))
        .await;
    let list = client.read_kind(MessageKind::Response).await;
    assert_eq!(list.header.request_or_sequence, list_request);
    let list_body: serde_json::Value = serde_json::from_slice(&list.payload).unwrap();
    assert_eq!(list_body["projects"][0]["id"], "My Project");

    let rename_request = client
        .send_json(
            MessageKind::RootsRenameProject,
            &serde_json::json!({"id": "My Project", "new_label": "Renamed Project"}),
        )
        .await;
    let renamed = client.read_kind(MessageKind::Response).await;
    assert_eq!(renamed.header.request_or_sequence, rename_request);

    let paused_before = client
        .send_json(MessageKind::RootsPausedProjects, &serde_json::json!({}))
        .await;
    let before = client.read_kind(MessageKind::Response).await;
    assert_eq!(before.header.request_or_sequence, paused_before);
    let before_body: serde_json::Value = serde_json::from_slice(&before.payload).unwrap();
    assert!(before_body["projects"].as_array().unwrap().is_empty());

    let set_paused_request = client
        .send_json(
            MessageKind::RootsSetPaused,
            &serde_json::json!({"project": "My Project", "paused": true}),
        )
        .await;
    let set_paused = client.read_kind(MessageKind::Response).await;
    assert_eq!(set_paused.header.request_or_sequence, set_paused_request);

    let paused_after = client
        .send_json(MessageKind::RootsPausedProjects, &serde_json::json!({}))
        .await;
    let after = client.read_kind(MessageKind::Response).await;
    assert_eq!(after.header.request_or_sequence, paused_after);
    let after_body: serde_json::Value = serde_json::from_slice(&after.payload).unwrap();
    assert_eq!(after_body["projects"], serde_json::json!(["My Project"]));

    let staleness_request = client
        .send_json(MessageKind::RootsStaleness, &serde_json::json!({}))
        .await;
    let staleness = client.read_kind(MessageKind::Response).await;
    assert_eq!(staleness.header.request_or_sequence, staleness_request);
    let staleness_body: serde_json::Value = serde_json::from_slice(&staleness.payload).unwrap();
    let projects = staleness_body["projects"].as_array().unwrap();
    assert_eq!(projects.len(), 1);
    assert_eq!(projects[0]["project"], "My Project");

    // `add_project` already stamped `last_ingested` via its background
    // ingest of the (empty) tempdir, so a manual re-check must succeed
    // against an already-known project rather than erroring "unknown".
    let reingest_request = client
        .send_json(
            MessageKind::RootsReingestProject,
            &serde_json::json!({"project": "My Project"}),
        )
        .await;
    let reingest = client.read_kind(MessageKind::Response).await;
    assert_eq!(reingest.header.request_or_sequence, reingest_request);

    let unknown_reingest = client
        .send_json(
            MessageKind::RootsReingestProject,
            &serde_json::json!({"project": "does-not-exist"}),
        )
        .await;
    let unknown = client.read_kind(MessageKind::Error).await;
    assert_eq!(unknown.header.request_or_sequence, unknown_reingest);

    server.stop().await;
}

/// Task 6a-2: `RootsStartIngest` persists the root and kicks off background
/// discovery; `RootsIngestionStatus` polls the daemon's own `IngestionState`
/// until it settles; `RootsList`/`RootsBiggestProject` read back what was
/// persisted/ingested — the first-run onboarding flow driven entirely
/// through the daemon.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn roots_start_ingest_list_and_ingestion_status_round_trip_through_the_daemon() {
    let temp = tempfile::tempdir().unwrap();
    let root_dir = tempfile::tempdir().unwrap();
    let root_path = root_dir.path().to_string_lossy().into_owned();

    let server = TestServer::start(temp.path()).await;
    let mut client = Client::connect(&server.socket).await;

    let start_request = client
        .send_json(
            MessageKind::RootsStartIngest,
            &serde_json::json!({"path": root_path}),
        )
        .await;
    let started = client.read_kind(MessageKind::Response).await;
    assert_eq!(started.header.request_or_sequence, start_request);

    // Poll until the background discovery/ingest pass (over an empty root,
    // so it settles almost immediately) reports done — bounded so a real
    // regression (stuck `running: true`) fails the test instead of hanging.
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        let poll_request = client
            .send_json(MessageKind::RootsIngestionStatus, &serde_json::json!({}))
            .await;
        let status = client.read_kind(MessageKind::Response).await;
        assert_eq!(status.header.request_or_sequence, poll_request);
        let status_body: serde_json::Value = serde_json::from_slice(&status.payload).unwrap();
        if status_body["status"]["running"] == serde_json::json!(false) {
            break;
        }
        assert!(
            tokio::time::Instant::now() < deadline,
            "ingestion never settled"
        );
        tokio::time::sleep(Duration::from_millis(20)).await;
    }

    let list_request = client
        .send_json(MessageKind::RootsList, &serde_json::json!({}))
        .await;
    let list = client.read_kind(MessageKind::Response).await;
    assert_eq!(list.header.request_or_sequence, list_request);
    let list_body: serde_json::Value = serde_json::from_slice(&list.payload).unwrap();
    assert_eq!(list_body["roots"], serde_json::json!([root_path]));

    // No projects were discovered under an empty root, so there is no
    // biggest project yet — `RootsBiggestProject` must degrade to `null`,
    // not error.
    let biggest_request = client
        .send_json(MessageKind::RootsBiggestProject, &serde_json::json!({}))
        .await;
    let biggest = client.read_kind(MessageKind::Response).await;
    assert_eq!(biggest.header.request_or_sequence, biggest_request);
    let biggest_body: serde_json::Value = serde_json::from_slice(&biggest.payload).unwrap();
    assert_eq!(biggest_body["project"], serde_json::Value::Null);

    server.stop().await;
}

/// Task 6a-2: `RootsRebuild` wipes and re-ingests the whole store, mirroring
/// the Tauri "Rebuild brain" button — dispatched through the daemon, it must
/// actually clear existing brain-store nodes (not just report success), and
/// a rebuild started while a bulk ingestion is already running must be
/// rejected rather than interleaving two passes.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn roots_rebuild_round_trips_through_the_daemon() {
    let temp = tempfile::tempdir().unwrap();
    {
        let store = Store::open(&brain_data_dir(temp.path())).unwrap();
        store
            .upsert_node(&Node {
                kind: NodeKind::Project,
                path: Some("/tmp/stale-project".to_string()),
                ..memory_node("stale-project", "stale-project", "Stale Project")
            })
            .unwrap();
    }

    let server = TestServer::start(temp.path()).await;
    let mut client = Client::connect(&server.socket).await;

    let before_request = client
        .send_json(MessageKind::BrainListProjects, &serde_json::json!({}))
        .await;
    let before = client.read_kind(MessageKind::Response).await;
    assert_eq!(before.header.request_or_sequence, before_request);
    let before_body: serde_json::Value = serde_json::from_slice(&before.payload).unwrap();
    assert_eq!(before_body["projects"].as_array().unwrap().len(), 1);

    let rebuild_request = client
        .send_json(MessageKind::RootsRebuild, &serde_json::json!({}))
        .await;
    let rebuilt = client.read_kind(MessageKind::Response).await;
    assert_eq!(rebuilt.header.request_or_sequence, rebuild_request);

    let after_request = client
        .send_json(MessageKind::BrainListProjects, &serde_json::json!({}))
        .await;
    let after = client.read_kind(MessageKind::Response).await;
    assert_eq!(after.header.request_or_sequence, after_request);
    let after_body: serde_json::Value = serde_json::from_slice(&after.payload).unwrap();
    assert!(after_body["projects"].as_array().unwrap().is_empty());

    server.stop().await;
}

/// Task 6a-2: `BrainSearch` closes the gap Task 6a's reviewer flagged —
/// `mcp_server::tools::search_brain` was defined but unwired — so the native
/// command palette's brain search has a route through the daemon.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn brain_search_round_trips_through_the_daemon() {
    let temp = tempfile::tempdir().unwrap();
    {
        let store = Store::open(&brain_data_dir(temp.path())).unwrap();
        store
            .upsert_node(&memory_node("demo:parse_config", "demo", "parse_config"))
            .unwrap();
    }

    let server = TestServer::start(temp.path()).await;
    let mut client = Client::connect(&server.socket).await;

    let search_request = client
        .send_json(
            MessageKind::BrainSearch,
            &serde_json::json!({"query": "parse_config"}),
        )
        .await;
    let results = client.read_kind(MessageKind::Response).await;
    assert_eq!(results.header.request_or_sequence, search_request);
    let results_body: serde_json::Value = serde_json::from_slice(&results.payload).unwrap();
    let hits = results_body["results"].as_array().unwrap();
    assert_eq!(hits.len(), 1);
    assert_eq!(hits[0]["id"], "demo:parse_config");

    // An unmatched query is not an error — an empty result list, same as
    // `search_brain`'s own contract.
    client
        .send_json(
            MessageKind::BrainSearch,
            &serde_json::json!({"query": "nothing-matches-this"}),
        )
        .await;
    let empty = client.read_kind(MessageKind::Response).await;
    let empty_body: serde_json::Value = serde_json::from_slice(&empty.payload).unwrap();
    assert!(empty_body["results"].as_array().unwrap().is_empty());

    server.stop().await;
}

/// Envelope validation must hold for every payload-bearing Task 6a-2 kind,
/// exactly as it already does for `BrainGetContext`
/// (`malformed_brain_get_context_payload_closes_the_connection` above) —
/// each new kind goes through the same `parse_json` gate, not a side
/// channel. One fresh connection per kind, since a malformed frame closes
/// the connection.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_roots_and_search_payloads_close_the_connection() {
    let temp = tempfile::tempdir().unwrap();
    let server = TestServer::start(temp.path()).await;

    for kind in [
        MessageKind::RootsStartIngest,
        MessageKind::RootsAddProject,
        MessageKind::RootsRenameProject,
        MessageKind::RootsSetPaused,
        MessageKind::RootsReingestProject,
        MessageKind::BrainSearch,
    ] {
        let mut client = Client::connect(&server.socket).await;
        let request = client.request;
        write_frame(
            &mut client.stream,
            &Frame::new(kind, request, b"{".to_vec()),
        )
        .await
        .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_secs(2), read_frame(&mut client.stream))
                .await
                .unwrap()
                .is_err(),
            "{kind:?} accepted a malformed payload instead of closing the connection"
        );
    }

    server.stop().await;
}

/// The no-required-field Task 6a-2 kinds (`RootsIngestionStatus`/`RootsList`/
/// `RootsBiggestProject`/`RootsPausedProjects`/`RootsStaleness`/
/// `RootsRebuild`) still decode their payload as JSON
/// (`parse_json::<serde_json::Value>`) before dispatching — invalid JSON
/// syntax must close the connection for these exactly as it does for every
/// typed payload above, confirming they are not a bypass of envelope
/// validation just because every field is optional.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn malformed_json_closes_the_connection_for_no_payload_roots_kinds() {
    let temp = tempfile::tempdir().unwrap();
    let server = TestServer::start(temp.path()).await;

    for kind in [
        MessageKind::RootsIngestionStatus,
        MessageKind::RootsList,
        MessageKind::RootsBiggestProject,
        MessageKind::RootsPausedProjects,
        MessageKind::RootsStaleness,
        MessageKind::RootsRebuild,
    ] {
        let mut client = Client::connect(&server.socket).await;
        let request = client.request;
        write_frame(
            &mut client.stream,
            &Frame::new(kind, request, b"{".to_vec()),
        )
        .await
        .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_secs(2), read_frame(&mut client.stream))
                .await
                .unwrap()
                .is_err(),
            "{kind:?} accepted invalid JSON instead of closing the connection"
        );
    }

    server.stop().await;
}
