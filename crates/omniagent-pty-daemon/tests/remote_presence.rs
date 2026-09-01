//! Viewer presence and the kick (`docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md`
//! §5 "Presence, and disconnecting a viewer", §7 invariants 2-4).
//!
//! Bruno's finding 4: when his second Mac connects, nothing on the host shows
//! it and there is no way to end the connection. These tests drive the real
//! `serve_client` handler over in-memory `tokio::io::duplex` pipes — one
//! `Local` connection standing in for the host app, one `Remote` connection
//! standing in for the viewer relayed from the other Mac. The host's app is
//! attached first, which since Task 10 is a precondition of the viewer being
//! admitted at all (spec §2 condition 3) rather than only the arrangement
//! these tests want.

mod support;

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

    /// The reply to one request, skipping any server push that interleaves
    /// with it.
    ///
    /// This is what a real client does, and here it is what keeps the test
    /// honest rather than lucky: a host's roster pushes are written by its own
    /// `PresenceFeed` task, so they race the dispatch loop's replies for the
    /// connection's writer. "The next frame" is not a claim the protocol
    /// makes; "the reply to request N" is.
    async fn read_reply(&mut self, request: u64) -> Frame {
        loop {
            let frame = self.read().await;
            if frame.header.request_or_sequence == request
                && matches!(
                    frame.header.message_kind,
                    MessageKind::Response | MessageKind::Error
                )
            {
                return frame;
            }
        }
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
    // Signed in, so the viewer below gets past the account check (spec §9)
    // to reach the presence behaviour this file is about.
    let server = DaemonServer::bind_with_data_dir(
        root.join("runtime").join("daemon.sock"),
        support::account_data_dir(&root.join("brain-data"), support::HOST_ACCOUNT_EMAIL),
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
    // The switch and the token: the other two thirds of spec §2's condition,
    // without which the viewer below is refused before it can be seen.
    support::enable_sharing(&ctx);

    let host = connect(&ctx, ClientTrust::Local)
        .hello(serde_json::json!({"client": "omniagent-native-macos"}))
        .await;
    let viewer = connect(&ctx, support::remote_trust_for(support::HOST_ACCOUNT_EMAIL))
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

    // The pane is already on the roster by the time the viewer has its
    // snapshot: the registry learns of an attachment before the client is
    // told about it, so this cannot disagree with what the viewer can see.
    let request = host
        .send(MessageKind::ListViewers, serde_json::json!({}))
        .await;
    let reply = host.read_reply(request).await;
    assert_eq!(reply.header.message_kind, MessageKind::Response);
    let roster: RemoteViewersPayload = serde_json::from_slice(&reply.payload).unwrap();
    assert_eq!(roster.viewers.len(), 1);
    assert_eq!(roster.viewers[0].machine_name, "Air");
    assert_eq!(roster.viewers[0].sessions, vec!["s1".to_string()]);

    let request = host
        .send(
            MessageKind::DisconnectViewer,
            serde_json::json!({"viewer_id": "v-air"}),
        )
        .await;
    assert_eq!(
        host.read_reply(request).await.header.message_kind,
        MessageKind::Response
    );

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
    tokio::spawn(serve_client(
        server_side,
        ctx.clone(),
        support::remote_trust_for(support::HOST_ACCOUNT_EMAIL),
    ));
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

/// Spec §7 invariant 3: `RemoteViewers` reaches **local** connections only —
/// a viewer never learns who else is watching, itself included.
///
/// The whole test is arranged so that real roster frames are written while the
/// viewer's stream is watched, because otherwise it proves nothing: an
/// anonymous remote connection is never listed, so no roster is ever
/// published, and a "no `RemoteViewers` arrived" assertion would hold against
/// a daemon that pushed the roster to every writer it had. So the viewer names
/// itself and attaches, and the host's stream is checked first to confirm the
/// pushes really happened.
///
/// Phase 3 note: this used to connect a **second** machine, so there was
/// another viewer to be told about. The lease (spec §3) makes that
/// arrangement impossible — the second `Hello` is refused — and the invariant
/// is unchanged by that: the roster is the host's view of who is on its
/// machine, and it is not a viewer's to read at all.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_viewer_is_never_told_about_other_viewers() {
    let root = tempfile::tempdir().unwrap();
    let (mut host, mut air, ctx, _stop) = local_and_remote_clients(root.path()).await;

    air.send(
        MessageKind::Attach,
        serde_json::json!({"id": "s1", "after_sequence": null}),
    )
    .await;
    drain_until(&mut air, MessageKind::Snapshot).await;

    // The host really is being pushed rosters — without this the assertions
    // below would pass on a daemon that never published anything at all.
    let mut named_the_viewer = false;
    while let Some(frame) = host.try_read(Duration::from_millis(500)).await {
        assert_eq!(frame.header.message_kind, MessageKind::RemoteViewers);
        let roster: RemoteViewersPayload = serde_json::from_slice(&frame.payload).unwrap();
        named_the_viewer |= roster
            .viewers
            .iter()
            .any(|viewer| viewer.machine_name == "Air");
    }
    assert!(
        named_the_viewer,
        "the host must have been pushed a roster naming the machine watching it"
    );

    // A local resize is the positive control: server pushes really are
    // reaching the viewer's connection while the roster is not.
    ctx.registry
        .get("s1")
        .unwrap()
        .resize(90, 20, 0, 0)
        .unwrap();

    let mut saw_the_resize = false;
    while let Some(frame) = air.try_read(Duration::from_millis(500)).await {
        assert_ne!(
            frame.header.message_kind,
            MessageKind::RemoteViewers,
            "Air was told who is watching this machine"
        );
        saw_the_resize |= frame.header.message_kind == MessageKind::SessionResized;
    }
    assert!(saw_the_resize, "Air's connection was live throughout");
}

/// One local client that stops draining its socket must wedge only itself.
///
/// Presence used to be written by a loop that held a registry-wide lock across
/// every client's `write_frame` in turn, awaited inline in the dispatch loops.
/// A same-UID client that simply stopped reading — a hung app, a stopped
/// process — would then pend that write forever and take presence bookkeeping,
/// and with it the attach/detach dispatch of every other connection including
/// remote viewers, down with it. Each connection now owns its feed task, so
/// this is structurally impossible rather than merely unlikely.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_local_client_that_stops_reading_cannot_wedge_anyone_else() {
    let root = tempfile::tempdir().unwrap();
    let (mut host, mut viewer, ctx, _stop) = local_and_remote_clients(root.path()).await;

    // A second host with a tiny socket buffer that never reads a byte after
    // its `Hello`, so its feed blocks inside `write_frame` almost at once.
    let (stalled_client, server_side) = tokio::io::duplex(256);
    tokio::spawn(serve_client(server_side, ctx.clone(), ClientTrust::Local));
    let mut stalled = Duplex {
        stream: stalled_client,
        request: 0,
    };
    stalled
        .send(
            MessageKind::Hello,
            serde_json::json!({"client": "omniagent-native-macos"}),
        )
        .await;

    // Churn the roster hard enough to fill that 256-byte pipe several times
    // over. Every one of these attach/detach round trips is a dispatch that
    // the old design would have run through the stalled client's writer.
    for _ in 0..8 {
        viewer
            .send(
                MessageKind::Attach,
                serde_json::json!({"id": "s1", "after_sequence": null}),
            )
            .await;
        drain_until(&mut viewer, MessageKind::Snapshot).await;
        let request = viewer
            .send(MessageKind::Detach, serde_json::json!({"id": "s1"}))
            .await;
        assert_eq!(
            viewer.read_reply(request).await.header.message_kind,
            MessageKind::Response,
            "the viewer's dispatch must not wait on a stalled local client"
        );
    }

    // And the healthy host is still served, presence included.
    let request = host
        .send(MessageKind::ListViewers, serde_json::json!({}))
        .await;
    let reply = host.read_reply(request).await;
    assert_eq!(reply.header.message_kind, MessageKind::Response);
    let roster: RemoteViewersPayload = serde_json::from_slice(&reply.payload).unwrap();
    assert_eq!(
        roster.viewers.len(),
        1,
        "still exactly one machine watching"
    );
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
