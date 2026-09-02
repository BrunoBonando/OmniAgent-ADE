//! The remote trust boundary (`docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
//! §3, §12): the daemon's per-frame authorizer.
//!
//! Phase 3 widened it from "a viewer may attach to a few shared panes" to "a
//! lease holder drives the whole machine". Two things did **not** change, and
//! they are what this file is for:
//!
//! 1. [`authorize_remote`] is an **explicit allowlist**, never a denylist. A
//!    message kind added to the dispatch next month is unreachable remotely
//!    until someone deliberately lists it, and
//!    `every_message_kind_is_deliberately_classified` will not *compile* until
//!    someone writes down which it is.
//! 2. The protected settings rows are unreachable on **both** get and set: a
//!    remote client may not grant itself access, unblock itself, or read the
//!    host's credentials.
//!
//! The end-to-end cases run the real `serve_client` handler over an in-memory
//! `tokio::io::duplex` pipe — no unix socket, no peer-UID path — with the
//! machine arranged to be sharing at all (spec §2: the switch on, a device
//! token, and the host's own app attached), since without that every remote
//! `Hello` here would be refused before any of this file's subject came up.

mod support;

use omniagent_pty_daemon::protocol::{
    read_frame, write_frame, Frame, MessageKind, SessionListPayload, SessionSizePayload,
};
use omniagent_pty_daemon::{
    authorize_remote, protected_setting_key, serve_client, ClientContext, CreateSession,
    DaemonServer,
};
use std::collections::HashMap;
use std::time::Duration;
use tokio::io::DuplexStream;
use tokio::sync::oneshot;

/// A phase-1 `remote_control` projection naming only session `s1`. Phase 3
/// keeps writing this row (the viewer's sidebar still reads it) but the
/// authorizer no longer consults it — which is exactly why the end-to-end
/// cases below set it: reaching `s2` *through* a projection that names only
/// `s1` is the proof that confinement is gone.
const PROJECTION: &str = r#"{"workspaces":[{"id":"w1","name":"w1","sessions":[{"id":"s1","title":"one","engine":"shell","group":null}]}]}"#;
/// The phase-2 shape (`2026-08-31` spec §2 "Projection schema v2"): the host's
/// real tree, where the id a client names is the **pane** id, not the
/// session-group id.
const PROJECTION_V2: &str = r#"{"version":2,"workspaces":[{"id":"/a","name":"Alpha","tint":null,"order":0,
"sessions":[{"id":"g1","label":"Session 1","order":0,
"panes":[{"id":"s1","title":"claude","engine":"claude","kind":"terminal","order":0},
         {"id":"s3","title":"shell","engine":"shell","kind":"terminal","order":1}]}]}]}"#;

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

fn frame(kind: MessageKind, payload: &[u8]) -> Frame {
    Frame::new(kind, 1, payload.to_vec())
}

// ---------------------------------------------------------------------------
// The authorizer itself
// ---------------------------------------------------------------------------

/// Phase 3 §3: the lease holder is driving the whole machine, so the allowlist
/// grew to the length of the environment. Session-id confinement went with the
/// projection — confining someone who may create and kill sessions to a list
/// of sessions is confining them to nothing.
#[test]
fn a_lease_holder_may_drive_the_whole_environment() {
    for kind in [
        MessageKind::Hello,
        MessageKind::ListSessions,
        MessageKind::Attach,
        MessageKind::Detach,
        MessageKind::Input,
        MessageKind::Resize,
        MessageKind::Interrupt,
        MessageKind::CreateSession,
        MessageKind::Kill,
        MessageKind::ListDirectory,
        MessageKind::RootsStartIngest,
        MessageKind::RootsIngestionStatus,
        MessageKind::RootsList,
        MessageKind::RootsBiggestProject,
        MessageKind::RootsAddProject,
        MessageKind::RootsRenameProject,
        MessageKind::RootsPausedProjects,
        MessageKind::RootsSetPaused,
        MessageKind::RootsStaleness,
        MessageKind::RootsReingestProject,
        MessageKind::RootsRebuild,
        MessageKind::BrainListProjects,
        MessageKind::BrainGetContext,
        MessageKind::BrainSearch,
    ] {
        assert!(
            authorize_remote(&frame(kind, b"{}")).is_ok(),
            "{kind:?} must be allowed"
        );
    }
}

/// §12 invariant 3. Presence is the host's view of who is watching *it*, and
/// the kick is the host's power over them; neither is a viewer's to reach.
/// `PublishHostState` (Task 21, spec §4) joins them: a viewer must never be
/// able to overwrite what the host says about itself.
#[test]
fn the_local_only_kinds_stay_local() {
    for kind in [
        MessageKind::ListViewers,
        MessageKind::DisconnectViewer,
        MessageKind::PublishHostState,
    ] {
        assert!(
            authorize_remote(&frame(kind, b"{}")).is_err(),
            "{kind:?} must be denied"
        );
    }
}

/// §12 invariant 2, at the authorizer. **Both** arms consult the protected
/// set: a read-only leak of a device token is as bad as a write, and a token
/// that only leaks is a machine anyone can go on reaching.
#[test]
fn protected_rows_are_refused_on_both_get_and_set() {
    for key in [
        "remote_sharing",
        "relay_device_token",
        "remote_control_blocked",
        "auth_account_email",
    ] {
        let get = frame(
            MessageKind::GetSetting,
            format!(r#"{{"key":"{key}"}}"#).as_bytes(),
        );
        let set = frame(
            MessageKind::SetSetting,
            format!(r#"{{"key":"{key}","value":"x"}}"#).as_bytes(),
        );
        assert!(authorize_remote(&get).is_err(), "get {key}");
        assert!(authorize_remote(&set).is_err(), "set {key}");
    }
    // Everything else about the environment is the lease holder's to drive.
    assert!(authorize_remote(&frame(
        MessageKind::SetSetting,
        br#"{"key":"layout","value":"{}"}"#
    ))
    .is_ok());
    assert!(authorize_remote(&frame(MessageKind::GetSetting, br#"{"key":"layout"}"#)).is_ok());
}

/// The protected settings rows (phase 3 spec §3 and §12 invariant 2). This is
/// the whole security argument in five keys: a remote client that could write
/// `remote_sharing` or `relay_device_token` would be granting itself access,
/// one that could write `remote_control_blocked` would be unblocking itself,
/// and one that could *read* `auth_*` would be walking off with the host's
/// credentials. The `auth_` case is a prefix on purpose — the sixth key below
/// does not exist today, and is protected anyway.
#[test]
fn protected_keys_are_the_ones_that_would_grant_more_access() {
    for key in [
        "remote_sharing",
        "relay_device_token",
        "remote_control_blocked",
        "auth_signed_in",
        "auth_account_email",
        "auth_anything_added_later",
    ] {
        assert!(protected_setting_key(key), "{key} must be protected");
    }
    for key in ["layout", "editor_panes_native", "roots", "persona"] {
        assert!(!protected_setting_key(key), "{key} must stay reachable");
    }
}

/// The standing rule, pinned: **nothing becomes remote-reachable merely by
/// being added to the dispatch.**
///
/// The guarantee is the `match` below being **exhaustive with no wildcard
/// arm**. That is what makes the rule enforceable rather than aspirational: a
/// new `MessageKind` does not compile until someone writes down, here, whether
/// a remote client may send it — and writing `true` next to it is a visible,
/// reviewable act in a file about the trust boundary. A wildcard arm would
/// quietly classify every future kind as denied and pass whatever
/// `authorize_remote` happened to do, which is the same test failing to say
/// anything at all.
///
/// The sweep over the byte space is the other half: `TryFrom<u8>` is the
/// complete set of assigned discriminants, since a kind that is not there
/// cannot arrive on the wire, so every wire-reachable variant is checked
/// against the decision recorded for it.
#[test]
fn every_message_kind_is_deliberately_classified() {
    for byte in 0..=u8::MAX {
        let Ok(kind) = MessageKind::try_from(byte) else {
            continue;
        };
        let may_a_remote_client_send_it = match kind {
            // Allowed: the lease holder drives the whole environment (§3).
            MessageKind::Hello
            | MessageKind::ListSessions
            | MessageKind::Attach
            | MessageKind::Detach
            | MessageKind::Input
            | MessageKind::Resize
            | MessageKind::Interrupt
            | MessageKind::CreateSession
            | MessageKind::Kill
            | MessageKind::ListDirectory
            | MessageKind::RootsStartIngest
            | MessageKind::RootsIngestionStatus
            | MessageKind::RootsList
            | MessageKind::RootsBiggestProject
            | MessageKind::RootsAddProject
            | MessageKind::RootsRenameProject
            | MessageKind::RootsPausedProjects
            | MessageKind::RootsSetPaused
            | MessageKind::RootsStaleness
            | MessageKind::RootsReingestProject
            | MessageKind::RootsRebuild
            | MessageKind::BrainListProjects
            | MessageKind::BrainGetContext
            | MessageKind::BrainSearch => true,

            // Conditional on the key, so the answer depends on the payload.
            // With no `key` in `{}` there is nothing to check against the
            // protected set and it is refused; the real decision is pinned by
            // `protected_rows_are_refused_on_both_get_and_set`.
            MessageKind::GetSetting | MessageKind::SetSetting => false,

            // Local-only (§12 invariant 3): the host's view of who is watching
            // it, and the host's power to throw them off. `PublishHostState`
            // (Task 21, spec §4) joins them for the same reason: a viewer
            // must never be able to overwrite what the host says about
            // itself.
            MessageKind::ListViewers
            | MessageKind::DisconnectViewer
            | MessageKind::PublishHostState => false,

            // Server → client. A client may never send one at all, remote or
            // local; the dispatch answers "clients cannot send server message
            // kinds" and the authorizer refuses them first.
            MessageKind::HelloAck
            | MessageKind::SessionList
            | MessageKind::SessionCreated
            | MessageKind::Snapshot
            | MessageKind::Output
            | MessageKind::SessionStatus
            | MessageKind::Attention
            | MessageKind::SessionExited
            | MessageKind::Response
            | MessageKind::ResyncRequired
            | MessageKind::Error
            | MessageKind::SessionResized
            | MessageKind::RemoteViewers
            // `RemoteActivity` (Task 19, spec §8/§12 invariant 3): a push to
            // local connections only. A remote viewer must never learn what
            // the log says about it, so this is deliberately absent from
            // `authorize_remote`'s allowlist rather than merely unreachable
            // by convention — the same treatment `RemoteViewers` gets.
            | MessageKind::RemoteActivity
            // `HostState` (Task 21, spec §4): a push to the lease holder
            // only. It is never sent *to* the daemon by any client, remote or
            // local — `authorize_remote` refusing it is belt-and-suspenders
            // for a frame a real client never emits, since the dispatch's own
            // catch-all already answers "clients cannot send server message
            // kinds" for it.
            | MessageKind::HostState => false,
        };
        assert_eq!(
            authorize_remote(&frame(kind, b"{}")).is_ok(),
            may_a_remote_client_send_it,
            "{kind:?} (0x{byte:02x}) is classified differently by `authorize_remote` \
             than by this test; whichever one is wrong, they must agree deliberately"
        );
    }
}

// ---------------------------------------------------------------------------
// Through the real handler
// ---------------------------------------------------------------------------

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
        tokio::time::timeout(Duration::from_secs(4), read_frame(&mut self.stream))
            .await
            .expect("the daemon answered nothing")
            .unwrap()
    }

    /// Sends one frame and returns the reply — the shape almost every case
    /// below wants.
    async fn round_trip(&mut self, kind: MessageKind, payload: impl serde::Serialize) -> Frame {
        self.send(kind, payload).await;
        self.read().await
    }
}

/// Boots a daemon with sessions `s1` (running `s1_script`) and `s2`, writes
/// the projection row, and hands back a `Remote`-trust client already past
/// `Hello`, plus the context the test drives the store with.
async fn remote_client(
    root: &std::path::Path,
    s1_script: &str,
) -> (Duplex, ClientContext, oneshot::Sender<()>) {
    remote_client_sharing(root, s1_script, PROJECTION).await
}

/// [`remote_client`] with the projection row spelled out.
async fn remote_client_sharing(
    root: &std::path::Path,
    s1_script: &str,
    projection: &str,
) -> (Duplex, ClientContext, oneshot::Sender<()>) {
    // Signed in, so the viewer below gets past the account check (spec §9)
    // to reach the trust boundary this file is about.
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
    // Spec §2: a machine that is not sharing refuses every remote `Hello`
    // before the trust boundary this file tests is ever reached.
    support::enable_sharing(&ctx);
    support::sign_in_as(&ctx, support::HOST_ACCOUNT_EMAIL);
    support::hold_local_client(&ctx).await;
    let (client_side, server_side) = tokio::io::duplex(64 * 1024);
    tokio::spawn(serve_client(
        server_side,
        ctx.clone(),
        support::remote_trust_for(support::HOST_ACCOUNT_EMAIL),
    ));
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

/// The widening, end to end. The projection row names `s1` alone; the lease
/// holder sees both sessions and attaches to the one it never mentioned.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_lease_holder_sees_every_session_not_a_projection_of_them() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _ctx, _stop) = remote_client(root.path(), "cat").await;

    let list = client
        .round_trip(MessageKind::ListSessions, serde_json::json!({}))
        .await;
    assert_eq!(list.header.message_kind, MessageKind::SessionList);
    let mut list: SessionListPayload = serde_json::from_slice(&list.payload).unwrap();
    list.sessions.sort();
    assert_eq!(list.sessions, vec!["s1".to_string(), "s2".to_string()]);

    let reply = client
        .round_trip(
            MessageKind::Attach,
            serde_json::json!({"id": "s2", "after_sequence": null}),
        )
        .await;
    // An accepted attach opens with the host's grid, then the screen on it.
    assert_eq!(reply.header.message_kind, MessageKind::SessionResized);
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::Snapshot
    );
}

/// The kinds phase 2 refused and phase 3 grants, through the handler rather
/// than the authorizer alone — the widening has to mean the daemon actually
/// does the thing, not merely that it does not answer `Error`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_lease_holder_may_create_resize_and_kill() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, ctx, _stop) = remote_client(root.path(), "cat").await;

    let created = client
        .round_trip(
            MessageKind::CreateSession,
            serde_json::json!(command_session("s3", "cat")),
        )
        .await;
    assert_eq!(created.header.message_kind, MessageKind::SessionCreated);
    assert!(ctx.registry.get("s3").is_some());

    // Phase 3 §5 inverts phase 2's rule: whoever drives owns the grid, so
    // `Resize` is back in the allowlist and it must move the real PTY.
    let resized = client
        .round_trip(
            MessageKind::Resize,
            serde_json::json!({"id": "s3", "cols": 132, "rows": 43}),
        )
        .await;
    assert_eq!(resized.header.message_kind, MessageKind::Response);
    assert_eq!(ctx.registry.get("s3").unwrap().size(), (132, 43));

    let killed = client
        .round_trip(MessageKind::Kill, serde_json::json!({"id": "s3"}))
        .await;
    assert_eq!(killed.header.message_kind, MessageKind::Response);
}

/// §12 invariant 2, through the handler. The `auth_signed_in` row really is
/// in the store (`remote_client_sharing` wrote it), so this is a refusal and
/// not a miss.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_lease_holder_can_neither_read_nor_write_a_protected_row() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, ctx, _stop) = remote_client(root.path(), "cat").await;
    ctx.settings
        .lock()
        .unwrap()
        .set_setting("relay_device_token", r#"{"token":"hunter2"}"#)
        .unwrap();

    for key in [
        "remote_sharing",
        "relay_device_token",
        "remote_control_blocked",
        "auth_signed_in",
    ] {
        let get = client
            .round_trip(MessageKind::GetSetting, serde_json::json!({"key": key}))
            .await;
        assert_eq!(
            get.header.message_kind,
            MessageKind::Error,
            "get {key} must be refused"
        );
        let set = client
            .round_trip(
                MessageKind::SetSetting,
                serde_json::json!({"key": key, "value": "{}"}),
            )
            .await;
        assert_eq!(
            set.header.message_kind,
            MessageKind::Error,
            "set {key} must be refused"
        );
        assert!(
            !String::from_utf8_lossy(&get.payload).contains("hunter2"),
            "the refusal must not quote the row it refused"
        );
    }

    // The refusals left the rows alone, and the connection alive.
    assert_eq!(
        ctx.settings
            .lock()
            .unwrap()
            .get_setting("relay_device_token")
            .unwrap()
            .as_deref(),
        Some(r#"{"token":"hunter2"}"#)
    );
    let layout = client
        .round_trip(
            MessageKind::SetSetting,
            serde_json::json!({"key": "layout", "value": "{}"}),
        )
        .await;
    assert_eq!(layout.header.message_kind, MessageKind::Response);
}

/// A viewer renders the host's grid, so it must be told that grid before the
/// snapshot it has to lay out.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn attaching_tells_the_client_the_session_size_before_the_snapshot() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, ctx, _stop) = remote_client(root.path(), "cat").await;
    ctx.registry
        .get("s1")
        .unwrap()
        .resize(120, 40, 0, 0)
        .unwrap();

    let size = client
        .round_trip(
            MessageKind::Attach,
            serde_json::json!({"id": "s1", "after_sequence": null}),
        )
        .await;
    assert_eq!(size.header.message_kind, MessageKind::SessionResized);
    let size: SessionSizePayload = serde_json::from_slice(&size.payload).unwrap();
    assert_eq!((size.id.as_str(), size.cols, size.rows), ("s1", 120, 40));
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::Snapshot
    );
}

/// A resize made anywhere re-pins every attached client, with no request from
/// the client.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_resize_reaches_every_attached_client() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, ctx, _stop) = remote_client(root.path(), "cat").await;
    let opened = client
        .round_trip(
            MessageKind::Attach,
            serde_json::json!({"id": "s1", "after_sequence": null}),
        )
        .await;
    assert_eq!(opened.header.message_kind, MessageKind::SessionResized);
    assert_eq!(
        client.read().await.header.message_kind,
        MessageKind::Snapshot
    );

    ctx.registry
        .get("s1")
        .unwrap()
        .resize(100, 30, 0, 0)
        .unwrap();

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

/// With the projection out of the authorizer, the **session registry** is the
/// only thing standing between a named id and an attachment — so what it does
/// with an id that names nothing is now load-bearing rather than a backstop.
/// An editor pane's id is the realistic case: it is a real id in the host's
/// tree that was never a PTY.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_id_with_no_session_behind_it_cannot_be_attached() {
    let root = tempfile::tempdir().unwrap();
    let (mut client, _ctx, _stop) = remote_client(root.path(), "cat").await;

    let reply = client
        .round_trip(
            MessageKind::Attach,
            serde_json::json!({"id": "e1", "after_sequence": null}),
        )
        .await;
    assert_eq!(reply.header.message_kind, MessageKind::Error);
    let reply: serde_json::Value = serde_json::from_slice(&reply.payload).unwrap();
    assert!(
        reply["message"]
            .as_str()
            .is_some_and(|message| message.contains("not found")),
        "the session registry is what refuses it: {reply}"
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

// ---------------------------------------------------------------------------
// The projection reader, which no longer takes part in authorization
// ---------------------------------------------------------------------------

/// `remote_session_ids` survives phase 3 only because the viewer's sidebar
/// still reads the row it parses; it is no longer consulted by
/// [`authorize_remote`], and it goes with the projection in a later task.
/// Until then it stays covered: it walks the **pane** level of a v2 row, and
/// a v1 row from a Mac that has not updated yet must still parse.
#[test]
fn projection_v2_shares_every_pane_and_v1_still_parses() {
    let store = brain_core::Store::open_in_memory().unwrap();
    store.set_setting("remote_control", PROJECTION_V2).unwrap();
    assert_eq!(
        omniagent_pty_daemon::remote_session_ids(&store),
        ["s1".to_string(), "s3".to_string()].into_iter().collect(),
        "a pane is what a viewer attaches to; the session group is a UI grouping"
    );

    // A phase-1 row from a Mac that has not updated yet.
    store.set_setting("remote_control", PROJECTION).unwrap();
    assert_eq!(
        omniagent_pty_daemon::remote_session_ids(&store),
        ["s1".to_string()].into_iter().collect()
    );

    // An idle session group: nothing to attach to, and — since phase 3 —
    // nothing about reachability either, which `remote_sharing.rs` owns.
    const IDLE: &str = r#"{"version":2,"workspaces":[{"id":"/a","name":"Alpha","tint":null,"order":0,
    "sessions":[{"id":"g1","label":"Session 1","order":0,"panes":[]}]}]}"#;
    store.set_setting("remote_control", IDLE).unwrap();
    assert!(omniagent_pty_daemon::remote_session_ids(&store).is_empty());
}
