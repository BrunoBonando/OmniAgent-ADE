//! The remote trust boundary (`docs/superpowers/specs/2026-08-30-remote-session-control-design.md`
//! §2 "What a remote connection may do"): the daemon's per-frame authorizer
//! confines a `ClientTrust::Remote` client to an allowlist of message kinds
//! and to the session ids listed in the `remote_control` projection row.
//! These tests run the real `serve_client` handler over an in-memory
//! `tokio::io::duplex` pipe — no unix socket, no peer-UID path.

use omniagent_pty_daemon::protocol::{
    read_frame, write_frame, Frame, MessageKind, SessionListPayload, SettingKey,
};
use omniagent_pty_daemon::{serve_client, ClientContext, ClientTrust, CreateSession, DaemonServer};
use std::collections::HashMap;
use std::collections::HashSet;
use std::time::Duration;
use tokio::io::DuplexStream;
use tokio::sync::oneshot;

/// A `remote_control` projection sharing workspace `w1` with only session `s1`.
const PROJECTION: &str = r#"{"workspaces":[{"id":"w1","name":"w1","sessions":[{"id":"s1","title":"one","engine":"shell","group":null}]}]}"#;
/// The same machine after `w1` is toggled off while `w2` (session `s2`)
/// stays shared — a non-empty projection, so the relay keeps every
/// connection open and only `serve_client` can cut `s1` off.
const PROJECTION_ONLY_S2: &str = r#"{"workspaces":[{"id":"w2","name":"w2","sessions":[{"id":"s2","title":"two","engine":"shell","group":null}]}]}"#;

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

struct Duplex {
    stream: DuplexStream,
    request: u64,
}

impl Duplex {
    async fn hello(mut self) -> Self {
        self.send(
            MessageKind::Hello,
            serde_json::json!({"client": "remote-test"}),
        )
        .await;
        assert_eq!(self.read().await.header.message_kind, MessageKind::HelloAck);
        self
    }

    async fn send(&mut self, kind: MessageKind, payload: impl serde::Serialize) -> u64 {
        self.request += 1;
        let frame = Frame::new(kind, self.request, serde_json::to_vec(&payload).unwrap());
        write_frame(&mut self.stream, &frame).await.unwrap();
        self.request
    }

    async fn read(&mut self) -> Frame {
        self.try_read(Duration::from_secs(4)).await.unwrap()
    }

    /// `None` when nothing arrives within `wait`; a closed stream panics,
    /// because no test here expects the daemon to hang up.
    async fn try_read(&mut self, wait: Duration) -> Option<Frame> {
        tokio::time::timeout(wait, read_frame(&mut self.stream))
            .await
            .ok()
            .map(|frame| frame.unwrap())
    }
}

/// Boots a daemon with sessions `s1` (running `s1_script`) and `s2`, shares
/// only `s1` through the projection, and hands back a `Remote`-trust client
/// already past `Hello`, plus the context the test drives the store with.
async fn remote_client(
    root: &std::path::Path,
    s1_script: &str,
) -> (Duplex, ClientContext, oneshot::Sender<()>) {
    let server = DaemonServer::bind_with_data_dir(
        root.join("runtime").join("daemon.sock"),
        root.join("brain-data"),
    )
    .await
    .unwrap();
    let ctx = server.client_context();
    let (stop, stopped) = oneshot::channel();
    tokio::spawn(server.run_until(stopped));
    ctx.registry
        .create_session(command_session("s1", s1_script))
        .unwrap();
    ctx.registry
        .create_session(command_session("s2", "cat"))
        .unwrap();
    ctx.settings
        .lock()
        .unwrap()
        .set_setting("remote_control", PROJECTION)
        .unwrap();
    ctx.settings
        .lock()
        .unwrap()
        .set_setting("auth_signed_in", "true")
        .unwrap();
    let (client_side, server_side) = tokio::io::duplex(64 * 1024);
    tokio::spawn(serve_client(server_side, ctx.clone(), ClientTrust::Remote));
    (
        Duplex {
            stream: client_side,
            request: 0,
        }
        .hello()
        .await,
        ctx,
        stop,
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn remote_clients_only_list_and_attach_projected_sessions() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _ctx, _stop) = remote_client(root.path(), "cat").await;

    client
        .send(MessageKind::ListSessions, serde_json::json!({}))
        .await;
    let list = client.read().await;
    assert_eq!(list.header.message_kind, MessageKind::SessionList);
    let list: SessionListPayload = serde_json::from_slice(&list.payload).unwrap();
    assert_eq!(list.sessions, vec!["s1".to_string()]);

    client
        .send(
            MessageKind::Attach,
            serde_json::json!({"id": "s2", "after_sequence": null}),
        )
        .await;
    assert_eq!(client.read().await.header.message_kind, MessageKind::Error);

    client
        .send(
            MessageKind::Attach,
            serde_json::json!({"id": "s1", "after_sequence": null}),
        )
        .await;
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::Snapshot
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn remote_clients_cannot_kill_create_or_read_other_settings() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _ctx, _stop) = remote_client(root.path(), "cat").await;
    for (kind, payload) in [
        (MessageKind::Kill, serde_json::json!({"id": "s1"})),
        (
            MessageKind::CreateSession,
            serde_json::json!(command_session("s3", "cat")),
        ),
        (
            MessageKind::SetSetting,
            serde_json::json!({"key": "remote_control", "value": "{}"}),
        ),
        (
            MessageKind::GetSetting,
            serde_json::json!(SettingKey {
                key: "auth_signed_in".into()
            }),
        ),
        (MessageKind::BrainListProjects, serde_json::json!({})),
    ] {
        client.send(kind, payload).await;
        let reply = client.read().await;
        assert_eq!(
            reply.header.message_kind,
            MessageKind::Error,
            "{kind:?} must be refused remotely"
        );
    }
    client
        .send(
            MessageKind::GetSetting,
            serde_json::json!(SettingKey {
                key: "remote_control".into()
            }),
        )
        .await;
    let reply = client.read().await;
    assert_eq!(reply.header.message_kind, MessageKind::Response);
    let reply: serde_json::Value = serde_json::from_slice(&reply.payload).unwrap();
    assert_eq!(reply["value"].as_str(), Some(PROJECTION));
}

/// Un-sharing a session while a remote viewer is attached to it must cut
/// its output at once — even though the viewer sends nothing, and even
/// though the projection stays non-empty (so the relay's close-everything
/// rule does not fire). Before the fix the per-frame authorizer blocked new
/// `Input`/`Resize`/`Interrupt`, but the forwarding task spawned by the
/// earlier `Attach` kept streaming until `Detach` or disconnect.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn un_sharing_an_attached_session_stops_its_output_without_a_frame_from_the_viewer() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, ctx, _stop) =
        remote_client(root.path(), "while true; do echo tick; sleep 0.05; done").await;

    client
        .send(
            MessageKind::Attach,
            serde_json::json!({"id": "s1", "after_sequence": null}),
        )
        .await;
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::Snapshot
    );
    while client.read().await.header.message_kind != MessageKind::Output {}

    ctx.settings
        .lock()
        .unwrap()
        .set_setting("remote_control", PROJECTION_ONLY_S2)
        .unwrap();
    ctx.settings_changed.notify_one();

    // Let the prune land and drain whatever was already in flight ...
    let settled = tokio::time::Instant::now() + Duration::from_millis(250);
    while client
        .try_read(settled.saturating_duration_since(tokio::time::Instant::now()))
        .await
        .is_some()
    {}
    // ... after which nothing at all may arrive: the ticker would otherwise
    // deliver about ten more `Output` frames in this window.
    if let Some(frame) = client.try_read(Duration::from_millis(500)).await {
        panic!(
            "{:?} (sequence {}) leaked after s1 was un-shared",
            frame.header.message_kind, frame.header.request_or_sequence
        );
    }

    client
        .send(
            MessageKind::Attach,
            serde_json::json!({"id": "s1", "after_sequence": null}),
        )
        .await;
    assert_eq!(client.read().await.header.message_kind, MessageKind::Error);
}

#[test]
fn authorize_remote_checks_the_raw_input_session_id() {
    use omniagent_pty_daemon::protocol::encode_raw_payload;
    let allowed: HashSet<String> = ["s1".to_string()].into_iter().collect();
    let ok = Frame::new(
        MessageKind::Input,
        1,
        encode_raw_payload("s1", b"x").unwrap(),
    );
    let bad = Frame::new(
        MessageKind::Input,
        2,
        encode_raw_payload("s2", b"x").unwrap(),
    );
    assert!(omniagent_pty_daemon::authorize_remote(&ok, &allowed).is_ok());
    assert!(omniagent_pty_daemon::authorize_remote(&bad, &allowed).is_err());
}
