//! The remote trust boundary (`docs/superpowers/specs/2026-08-30-remote-session-control-design.md`
//! §2 "What a remote connection may do"): the daemon's per-frame authorizer
//! confines a `ClientTrust::Remote` client to an allowlist of message kinds
//! and to the session ids listed in the `remote_control` projection row.
//! These tests run the real `serve_client` handler over an in-memory
//! `tokio::io::duplex` pipe — no unix socket, no peer-UID path.

use omniagent_pty_daemon::protocol::{
    read_frame, write_frame, Frame, MessageKind, SessionListPayload, SessionSizePayload, SettingKey,
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
/// The phase-2 shape (spec §2 "Projection schema v2"): the host's real tree,
/// where the attachable id is the **pane** id, not the session-group id.
const PROJECTION_V2: &str = r#"{"version":2,"workspaces":[{"id":"/a","name":"Alpha","tint":null,"order":0,
"sessions":[{"id":"g1","label":"Session 1","order":0,
"panes":[{"id":"s1","title":"claude","engine":"claude","kind":"terminal","order":0},
         {"id":"s3","title":"shell","engine":"shell","kind":"terminal","order":1}]}]}]}"#;
/// A v2 projection whose session group also holds a **non-terminal** pane.
/// Editor and browser panes carry ids in the projection just like terminals
/// do, so the allowlist is a list of pane ids and not a promise that each one
/// is a PTY — the registry is what makes that second claim.
const PROJECTION_V2_WITH_EDITOR: &str = r#"{"version":2,"workspaces":[{"id":"/a","name":"Alpha","tint":null,"order":0,
"sessions":[{"id":"g1","label":"Session 1","order":0,
"panes":[{"id":"s1","title":"claude","engine":"claude","kind":"terminal","order":0},
         {"id":"e1","title":"README.md","engine":null,"kind":"editor","order":1}]}]}]}"#;

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
    remote_client_sharing(root, s1_script, PROJECTION).await
}

/// [`remote_client`] with the projection row spelled out — the phase-2 tests
/// below need the v2 shape, where the attachable ids sit a level deeper.
async fn remote_client_sharing(
    root: &std::path::Path,
    s1_script: &str,
    projection: &str,
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
        .set_setting("remote_control", projection)
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
    // An accepted attach opens with the host's grid, then the screen on it.
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::SessionResized
    );
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
        MessageKind::SessionResized
    );
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

/// Phase 2 §1: one grid exists and it belongs to the host. Before this, any
/// viewer could resize any shared session — which is both the defect that
/// collapsed the host's terminal and a trust-boundary hole.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_remote_client_may_not_resize_a_shared_session() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _ctx, _stop) = remote_client(root.path(), "cat").await;
    client
        .send(
            MessageKind::Resize,
            serde_json::json!({"id": "s1", "cols": 40, "rows": 10}),
        )
        .await;
    let reply = client.read().await;
    assert_eq!(
        reply.header.message_kind,
        MessageKind::Error,
        "the host owns the grid: a viewer's window must never resize it"
    );
}

/// A viewer renders the host's grid scaled to fit, so it must be told that
/// grid before the snapshot it has to lay out.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn attaching_tells_the_client_the_session_size_before_the_snapshot() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, ctx, _stop) = remote_client(root.path(), "cat").await;
    ctx.registry
        .get("s1")
        .unwrap()
        .resize(120, 40, 0, 0)
        .unwrap();

    client
        .send(
            MessageKind::Attach,
            serde_json::json!({"id": "s1", "after_sequence": null}),
        )
        .await;

    let size = client.read().await;
    assert_eq!(size.header.message_kind, MessageKind::SessionResized);
    let size: SessionSizePayload = serde_json::from_slice(&size.payload).unwrap();
    assert_eq!((size.id.as_str(), size.cols, size.rows), ("s1", 120, 40));
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::Snapshot
    );
}

/// The host resizing its own window must re-pin every attached viewer, with
/// no request from the viewer.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_resize_reaches_every_attached_client() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, ctx, _stop) = remote_client(root.path(), "cat").await;
    client
        .send(
            MessageKind::Attach,
            serde_json::json!({"id": "s1", "after_sequence": null}),
        )
        .await;
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::SessionResized
    );
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::Snapshot
    );

    ctx.registry
        .get("s1")
        .unwrap()
        .resize(100, 30, 0, 0)
        .unwrap();

    // The attached viewer is told, without asking.
    let pushed = loop {
        let frame = client.read().await;
        if frame.header.message_kind == MessageKind::SessionResized {
            break frame;
        }
        assert_ne!(frame.header.message_kind, MessageKind::Error);
    };
    let pushed: SessionSizePayload = serde_json::from_slice(&pushed.payload).unwrap();
    assert_eq!((pushed.cols, pushed.rows), (100, 30));
}

/// Phase 2 §2: the reader walks the pane level. Missing these ids denies
/// every remote attach, so this is the load-bearing assertion of the change —
/// and a v1 row from a Mac that has not updated yet must still parse.
#[test]
fn projection_v2_shares_every_pane_and_v1_still_parses() {
    let store = brain_core::Store::open_in_memory().unwrap();
    store.set_setting("remote_control", PROJECTION_V2).unwrap();
    let ids = omniagent_pty_daemon::remote_session_ids(&store);
    assert_eq!(
        ids,
        ["s1".to_string(), "s3".to_string()].into_iter().collect(),
        "a pane is what a viewer attaches to"
    );
    assert!(omniagent_pty_daemon::remote_control_active(&store));

    // A phase-1 row from a Mac that has not updated yet.
    store.set_setting("remote_control", PROJECTION).unwrap();
    assert_eq!(
        omniagent_pty_daemon::remote_session_ids(&store),
        ["s1".to_string()].into_iter().collect()
    );
}

/// An idle Mac: a workspace is shared, its session has no panes open. Nothing
/// is attachable, but the machine must stay reachable — that pairing is the
/// whole reason `remote_control_active` counts workspaces and not sessions.
#[test]
fn a_v2_session_with_no_panes_shares_nothing_yet_keeps_the_machine_reachable() {
    const IDLE: &str = r#"{"version":2,"workspaces":[{"id":"/a","name":"Alpha","tint":null,"order":0,
    "sessions":[{"id":"g1","label":"Session 1","order":0,"panes":[]}]}]}"#;
    let store = brain_core::Store::open_in_memory().unwrap();
    store.set_setting("remote_control", IDLE).unwrap();
    assert!(omniagent_pty_daemon::remote_session_ids(&store).is_empty());
    assert!(omniagent_pty_daemon::remote_control_active(&store));
}

/// Phase 2 §2, driven through the real handler rather than the reader alone:
/// with a v2 row active, a **pane** id attaches and the session-**group** id
/// that contains it does not. `projection_v2_shares_every_pane_and_v1_still_parses`
/// pins `remote_session_ids`; this pins that `serve_client`/`authorize_remote`
/// act on what it returns.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_v2_projection_attaches_panes_and_refuses_the_session_group() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _ctx, _stop) = remote_client_sharing(root.path(), "cat", PROJECTION_V2).await;

    client
        .send(
            MessageKind::Attach,
            serde_json::json!({"id": "g1", "after_sequence": null}),
        )
        .await;
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::Error,
        "a session group is a UI grouping, never an attachable daemon session"
    );

    client
        .send(
            MessageKind::Attach,
            serde_json::json!({"id": "s1", "after_sequence": null}),
        )
        .await;
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::SessionResized
    );
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::Snapshot
    );
}

/// The safety net under the projection reader: not every pane id it collects
/// is a PTY — editor and browser panes carry ids too. They are harmless
/// because the registry never holds a session under them, and this is what
/// says so out loud, so a future change that starts registering something
/// under a non-terminal pane id fails here rather than silently sharing it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_shared_pane_with_no_session_behind_it_cannot_be_attached() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _ctx, _stop) =
        remote_client_sharing(root.path(), "cat", PROJECTION_V2_WITH_EDITOR).await;

    client
        .send(
            MessageKind::Attach,
            serde_json::json!({"id": "e1", "after_sequence": null}),
        )
        .await;
    let reply = client.read().await;
    assert_eq!(reply.header.message_kind, MessageKind::Error);
    let reply: serde_json::Value = serde_json::from_slice(&reply.payload).unwrap();
    assert!(
        reply["message"]
            .as_str()
            .is_some_and(|message| message.contains("not found")),
        "the projection allowed it; the session registry is what refuses it: {reply}"
    );
}

// Phase 2 §7 invariant 3 — `RemoteViewers` reaches local connections only —
// is pinned in `remote_presence.rs`, by
// `a_viewer_is_never_told_about_other_viewers`. It has to live there: proving
// a viewer is not told requires roster pushes to actually happen while its
// stream is watched, which needs a *named* viewer (an anonymous one is never
// listed, so nothing is ever published) and a local connection subscribed to
// the feed. This file's clients are anonymous, so the same test written here
// would pass against a daemon that pushed the roster to everybody.

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
