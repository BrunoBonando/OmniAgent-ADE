//! Viewer presence and the kick (`docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md`
//! §5 "Presence, and disconnecting a viewer", §7 invariants 2-4).
//!
//! Bruno's finding 4: when his second Mac connects, nothing on the host shows
//! it and there is no way to end the connection. These tests drive the real
//! `serve_client` handler over in-memory `tokio::io::duplex` pipes — one
//! `Local` connection standing in for the host app, one `Remote` connection
//! standing in for the viewer relayed from the other Mac.

use omniagent_pty_daemon::protocol::{
    read_frame, write_frame, Frame, MessageKind, RemoteViewersPayload,
};
use omniagent_pty_daemon::{
    serve_client, ClientContext, ClientTrust, CreateSession, DaemonServer, BLOCKED_VIEWERS_KEY,
};
use std::collections::HashMap;
use std::time::Duration;
use tokio::io::DuplexStream;
use tokio::sync::oneshot;

/// A phase-2 (v2) projection sharing workspace `/a`, whose one session group
/// holds the single attachable pane `s1`.
const PROJECTION: &str = r#"{"version":2,"workspaces":[{"id":"/a","name":"Alpha","tint":null,"order":0,
"sessions":[{"id":"g1","label":"Session 1","order":0,
"panes":[{"id":"s1","title":"shell","engine":"shell","kind":"terminal","order":0}]}]}]}"#;

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
    async fn hello(mut self, payload: serde_json::Value) -> Self {
        self.send(MessageKind::Hello, payload).await;
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
    /// because only `read_eof_within` expects the daemon to hang up.
    async fn try_read(&mut self, wait: Duration) -> Option<Frame> {
        tokio::time::timeout(wait, read_frame(&mut self.stream))
            .await
            .ok()
            .map(|frame| frame.unwrap())
    }

    /// Drains what the daemon has already pushed, so a test starts from a
    /// quiet stream. A host is told the roster on its own `Hello` and again
    /// when a viewer identifies itself; neither is what a test is asserting.
    async fn drain_quiet(&mut self) {
        while self.try_read(Duration::from_millis(200)).await.is_some() {}
    }

    /// Whether the daemon closes this connection within `wait` — frames still
    /// in flight are drained, EOF is the answer.
    async fn read_eof_within(&mut self, wait: Duration) -> bool {
        tokio::time::timeout(wait, async {
            while read_frame(&mut self.stream).await.is_ok() {}
        })
        .await
        .is_ok()
    }
}

async fn drain_until(client: &mut Duplex, kind: MessageKind) {
    loop {
        let frame = client.read().await;
        if frame.header.message_kind == kind {
            return;
        }
        assert_ne!(
            frame.header.message_kind,
            MessageKind::Error,
            "unexpected Error while waiting for {kind:?}"
        );
    }
}

fn connect(ctx: &ClientContext, trust: ClientTrust) -> Duplex {
    let (client_side, server_side) = tokio::io::duplex(64 * 1024);
    tokio::spawn(serve_client(server_side, ctx.clone(), trust));
    Duplex {
        stream: client_side,
        request: 0,
    }
}

/// Boots a daemon sharing session `s1`, then one `Local` connection (the host
/// app) and one `Remote` connection naming itself "Air" (the viewer on the
/// other Mac), both past `Hello`. The host's stream is drained first, so a
/// test reads only the frames its own actions cause.
async fn local_and_remote_clients(
    root: &std::path::Path,
) -> (Duplex, Duplex, ClientContext, oneshot::Sender<()>) {
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
    ctx.settings
        .lock()
        .unwrap()
        .set_setting("remote_control", PROJECTION)
        .unwrap();

    let host = connect(&ctx, ClientTrust::Local)
        .hello(serde_json::json!({"client": "omniagent-native-macos"}))
        .await;
    let viewer = connect(&ctx, ClientTrust::Remote)
        .hello(serde_json::json!({
            "client": "omniagent-native-macos", "viewer_id": "v-air", "machine_name": "Air"}))
        .await;
    let mut host = host;
    host.drain_quiet().await;
    (host, viewer, ctx, stop)
}

/// Spec §5: the host sees which machines are watching which panes, and
/// Disconnect both drops the socket and blocks the machine — a viewer holding
/// a valid device token would otherwise re-dial within 30 s.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_local_client_learns_who_is_watching_and_can_disconnect_them() {
    let root = tempfile::tempdir().unwrap();
    let (mut host, mut viewer, ctx, _stop) = local_and_remote_clients(root.path()).await;

    // The viewer names itself in Hello and attaches to a shared pane.
    viewer
        .send(
            MessageKind::Attach,
            serde_json::json!({"id": "s1", "after_sequence": null}),
        )
        .await;
    drain_until(&mut viewer, MessageKind::Snapshot).await;

    host.send(MessageKind::ListViewers, serde_json::json!({}))
        .await;
    // Either the presence push the attach caused or the `ListViewers` reply,
    // whichever the host reads first: both carry the same roster, because the
    // registry learns of an attachment before the viewer is told about it.
    let roster: RemoteViewersPayload = serde_json::from_slice(&host.read().await.payload).unwrap();
    assert_eq!(roster.viewers.len(), 1);
    assert_eq!(roster.viewers[0].machine_name, "Air");
    assert_eq!(roster.viewers[0].sessions, vec!["s1".to_string()]);

    host.send(
        MessageKind::DisconnectViewer,
        serde_json::json!({"viewer_id": "v-air"}),
    )
    .await;
    assert_eq!(host.read().await.header.message_kind, MessageKind::Response);

    // The viewer's connection is gone, and it is blocked from coming back.
    assert!(
        viewer
            .read_eof_within(std::time::Duration::from_secs(2))
            .await,
        "a kicked viewer's socket is dropped"
    );
    let blocked = ctx
        .settings
        .lock()
        .unwrap()
        .get_setting(BLOCKED_VIEWERS_KEY)
        .unwrap()
        .unwrap();
    assert!(blocked.contains("v-air"));
}

/// Spec §7 invariant 4: the block is the daemon's, so it holds with the app
/// closed — a blocked viewer id never gets past `Hello`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_blocked_viewer_cannot_say_hello() {
    let root = tempfile::tempdir().unwrap();
    let (_host, _viewer, ctx, _stop) = local_and_remote_clients(root.path()).await;
    ctx.settings
        .lock()
        .unwrap()
        .set_setting(BLOCKED_VIEWERS_KEY, r#"["v-air"]"#)
        .unwrap();

    let (client_side, server_side) = tokio::io::duplex(64 * 1024);
    tokio::spawn(serve_client(server_side, ctx.clone(), ClientTrust::Remote));
    let mut blocked = Duplex {
        stream: client_side,
        request: 0,
    };
    blocked
        .send(
            MessageKind::Hello,
            serde_json::json!({
                "client": "omniagent-native-macos", "viewer_id": "v-air", "machine_name": "Air"}),
        )
        .await;
    assert_eq!(blocked.read().await.header.message_kind, MessageKind::Error);
}

/// Spec §7 invariant 2: `ListViewers`/`DisconnectViewer` are local-only. They
/// were never added to `authorize_remote`, so they fall into its deny arm —
/// this is what proves nothing becomes remote-reachable by being dispatched.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn presence_is_local_only() {
    let root = tempfile::tempdir().unwrap();
    let (_host, mut viewer, _ctx, _stop) = local_and_remote_clients(root.path()).await;
    for kind in [MessageKind::ListViewers, MessageKind::DisconnectViewer] {
        viewer
            .send(kind, serde_json::json!({"viewer_id": "v-air"}))
            .await;
        assert_eq!(
            viewer.read().await.header.message_kind,
            MessageKind::Error,
            "{kind:?} must never be reachable from a viewer"
        );
    }
}
