//! The remote trust boundary (`docs/superpowers/specs/2026-08-30-remote-session-control-design.md`
//! §2 "What a remote connection may do"): the daemon's per-frame authorizer
//! confines a `ClientTrust::Remote` client to an allowlist of message kinds
//! and to the session ids listed in the `remote_control` projection row.
//! These tests run the real `serve_client` handler over an in-memory
//! `tokio::io::duplex` pipe — no unix socket, no peer-UID path.

use omniagent_pty_daemon::protocol::{
    read_frame, write_frame, Frame, MessageKind, SessionListPayload, SettingKey,
};
use omniagent_pty_daemon::{serve_client, ClientTrust, CreateSession, DaemonServer};
use std::collections::HashMap;
use std::collections::HashSet;
use tokio::io::DuplexStream;
use tokio::sync::oneshot;

/// A `remote_control` projection sharing workspace `w1` with only session `s1`.
const PROJECTION: &str = r#"{"workspaces":[{"id":"w1","name":"w1","sessions":[{"id":"s1","title":"one","engine":"shell","group":null}]}]}"#;

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
        tokio::time::timeout(
            std::time::Duration::from_secs(4),
            read_frame(&mut self.stream),
        )
        .await
        .unwrap()
        .unwrap()
    }
}

/// Boots a daemon with sessions `s1` and `s2`, shares only `s1` through the
/// projection, and hands back a `Remote`-trust client already past `Hello`.
async fn remote_client(root: &std::path::Path) -> (Duplex, oneshot::Sender<()>) {
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
        .create_session(command_session("s1", "cat"))
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
    tokio::spawn(serve_client(server_side, ctx, ClientTrust::Remote));
    (
        Duplex {
            stream: client_side,
            request: 0,
        }
        .hello()
        .await,
        stop,
    )
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn remote_clients_only_list_and_attach_projected_sessions() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _stop) = remote_client(root.path()).await;

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
    let (mut client, _stop) = remote_client(root.path()).await;
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
    assert!(String::from_utf8_lossy(&reply.payload).contains("w1"));
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
