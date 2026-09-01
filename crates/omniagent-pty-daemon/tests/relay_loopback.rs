//! The relay client (`docs/superpowers/specs/2026-08-30-remote-session-control-design.md`
//! §1 Topology, §3 Daemon changes): an in-test tungstenite server plays the
//! relay. The daemon must dial the control socket with the device token, send
//! its hello, dial a data socket for every `{"open": id}`, and run the real
//! `serve_client(…, ClientTrust::Remote)` over that data socket — so a viewer
//! gets `HelloAck`, an `Attach` gets `Snapshot`, a `Kill` goes through (phase
//! 3 §3: the lease holder drives the machine) and a `ListViewers` still does
//! not. Turning sharing off closes the control socket, a `401`
//! stops the daemon dialling until the token row changes, and a relay that
//! goes silent is dropped and re-dialled.

mod support;

use futures_util::{SinkExt, StreamExt};
use omniagent_pty_daemon::protocol::{Frame, MessageKind};
use omniagent_pty_daemon::{run_relay, run_relay_with, ClientContext, CreateSession, DaemonServer};
use std::collections::HashMap;
use std::time::{Duration, Instant};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

/// A `remote_control` projection sharing workspace `w` with session `s1`.
const PROJECTION: &str = r#"{"workspaces":[{"id":"w","name":"w","sessions":[{"id":"s1","title":"t","engine":"shell","group":null}]}]}"#;

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

/// Boots a daemon with shared session `s1`, writes the projection, turns
/// `remote_sharing` on, and writes a device token whose `relay_url` points
/// at `port`, then starts the relay task — with the production ping
/// interval, or `ping_every` when given.
async fn start_daemon_with_relay(
    root: &std::path::Path,
    port: u16,
    ping_every: Option<Duration>,
) -> (ClientContext, oneshot::Sender<()>) {
    start_daemon_with_projection(root, port, ping_every, PROJECTION, true).await
}

/// [`start_daemon_with_relay`] with the `remote_control` row and the
/// `remote_sharing` switch spelled out separately — the seam the "sharing is
/// decoupled from the projection" cases need. `remote_control` still gates
/// which sessions a connected viewer may attach to; `sharing_enabled` alone
/// gates whether the control socket dials at all.
async fn start_daemon_with_projection(
    root: &std::path::Path,
    port: u16,
    ping_every: Option<Duration>,
    projection: &str,
    sharing_enabled: bool,
) -> (ClientContext, oneshot::Sender<()>) {
    let (ctx, stop) = boot_daemon(root, port, projection, sharing_enabled).await;
    // The host's own app. Spec §2's third condition: the daemon holds no
    // control channel at all without a local connection, so every test here
    // that expects a dial has to arrange one — and the two tests that use
    // [`boot_daemon`] directly are the ones about not having it.
    support::hold_local_client(&ctx).await;
    match ping_every {
        Some(every) => tokio::spawn(run_relay_with(ctx.clone(), every)),
        None => tokio::spawn(run_relay(ctx.clone())),
    };
    (ctx, stop)
}

/// The daemon, the session, the settings rows — everything except the host's
/// own app and the relay task, which the local-app tests arrange themselves.
async fn boot_daemon(
    root: &std::path::Path,
    port: u16,
    projection: &str,
    sharing_enabled: bool,
) -> (ClientContext, oneshot::Sender<()>) {
    let server = DaemonServer::bind_with_data_dir(
        root.join("runtime").join("daemon.sock"),
        root.join("brain-data"),
    )
    .await
    .unwrap();
    let ctx = server.client_context();
    let (stop, stopped) = oneshot::channel::<()>();
    tokio::spawn(server.run_until(stopped));
    ctx.registry
        .create_session(command_session("s1", "cat"))
        .unwrap();
    {
        let store = ctx.settings.lock().unwrap();
        store.set_setting("remote_control", projection).unwrap();
        store
            .set_setting(
                "remote_sharing",
                if sharing_enabled {
                    r#"{"enabled":true}"#
                } else {
                    r#"{"enabled":false}"#
                },
            )
            .unwrap();
        store
            .set_setting(
                "relay_device_token",
                &format!(
                    r#"{{"device_id":"dev1","token":"tok","name":"Test Mac","relay_url":"http://127.0.0.1:{port}"}}"#
                ),
            )
            .unwrap();
    }
    ctx.settings_changed.notify_one();
    (ctx, stop)
}

/// The relay's `open` control message, carrying the identity it asserts for
/// the viewer on the other end (spec §9). Every `open` the real relay sends
/// has one; the tests that leave it out are the ones about what happens when
/// it does not.
fn open(conn_id: &str) -> String {
    serde_json::json!({
        "open": conn_id,
        "viewer": {
            "user_sub": "auth0|bruno",
            "account_email": support::HOST_ACCOUNT_EMAIL,
            "ip": "203.0.113.7",
            "country": "DE",
            "client": "OmniAgent/1.7.22 macOS 27.0",
        },
    })
    .to_string()
}

/// Accepts one TCP connection from the daemon and refuses the WebSocket
/// upgrade with `status`, the way the relay denies a bad device token.
#[allow(clippy::result_large_err)]
async fn reject_ws(listener: &TcpListener, status: u16) {
    let (tcp, _) = tokio::time::timeout(Duration::from_secs(4), listener.accept())
        .await
        .unwrap()
        .unwrap();
    let refused = tokio_tungstenite::accept_hdr_async(tcp, |_req: &Request, _resp: Response| {
        Err(tokio_tungstenite::tungstenite::http::Response::builder()
            .status(status)
            .body(None)
            .unwrap())
    })
    .await;
    assert!(refused.is_err(), "the upgrade must have been refused");
}

/// Writes a `relay_device_token` row for `token` and wakes the relay.
fn write_token(ctx: &ClientContext, token: &str, port: u16) {
    ctx.settings
        .lock()
        .unwrap()
        .set_setting(
            "relay_device_token",
            &format!(
                r#"{{"device_id":"dev1","token":"{token}","name":"Test Mac","relay_url":"http://127.0.0.1:{port}"}}"#
            ),
        )
        .unwrap();
    ctx.settings_changed.notify_one();
}

/// Accepts one WebSocket from the daemon, recording the request path and
/// `Authorization` header it arrived with. (The callback's `Err` type is
/// tungstenite's `ErrorResponse`; its size is not ours to choose.)
#[allow(clippy::result_large_err)]
async fn accept_ws(listener: &TcpListener) -> (WebSocketStream<TcpStream>, String, String) {
    let (tcp, _) = tokio::time::timeout(Duration::from_secs(4), listener.accept())
        .await
        .unwrap()
        .unwrap();
    let mut seen_path = String::new();
    let mut seen_auth = String::new();
    let ws = tokio_tungstenite::accept_hdr_async(tcp, |req: &Request, resp: Response| {
        seen_path = req.uri().path().to_string();
        seen_auth = req
            .headers()
            .get("authorization")
            .map(|v| v.to_str().unwrap().to_string())
            .unwrap_or_default();
        Ok(resp)
    })
    .await
    .unwrap();
    (ws, seen_path, seen_auth)
}

/// Accumulates binary messages until one whole frame decodes (frames may span messages).
async fn read_frame_from_ws<S>(ws: &mut S) -> Frame
where
    S: StreamExt<Item = Result<Message, tokio_tungstenite::tungstenite::Error>> + Unpin,
{
    let mut buf: Vec<u8> = Vec::new();
    loop {
        if buf.len() >= 16 {
            let len = u32::from_be_bytes([buf[0], buf[1], buf[2], buf[3]]) as usize;
            if buf.len() >= 16 + len {
                let frame = Frame::decode(&buf[..16 + len]).unwrap();
                buf.drain(..16 + len);
                return frame;
            }
        }
        match tokio::time::timeout(Duration::from_secs(4), ws.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap()
        {
            Message::Binary(b) => buf.extend_from_slice(&b),
            Message::Ping(_) | Message::Pong(_) => {}
            other => panic!("unexpected {other:?}"),
        }
    }
}

/// Sends one frame and returns the daemon's **reply** to it.
///
/// An attached viewer's socket carries pushes too (`SessionStatus`, `Output`,
/// and — now that a remote `Kill` goes through — `SessionExited`), so the
/// reply is picked out by kind rather than by skipping a list of pushes that
/// grows every time the allowlist does: a control frame is answered with
/// `Response` or `Error`, and nothing else is an answer.
async fn reply_over_ws(ws: &mut WebSocketStream<TcpStream>, frame: Frame) -> Frame {
    ws.send(Message::Binary(frame.encode().unwrap().into()))
        .await
        .unwrap();
    loop {
        let frame = read_frame_from_ws(ws).await;
        if matches!(
            frame.header.message_kind,
            MessageKind::Response | MessageKind::Error
        ) {
            return frame;
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn daemon_dials_the_relay_and_serves_a_viewer_over_the_data_socket() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (_ctx, _stop) = start_daemon_with_relay(root.path(), port, None).await;

    // --- play relay: control connection ---
    let (mut control, seen_path, seen_auth) = accept_ws(&listener).await;
    assert_eq!(seen_path, "/v1/device");
    assert_eq!(seen_auth, "Bearer tok");
    let hello = tokio::time::timeout(Duration::from_secs(4), control.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let hello_text = hello.to_text().unwrap();
    assert!(hello_text.contains("Test Mac"), "hello was {hello_text}");
    assert!(
        hello_text.contains("daemon_version"),
        "hello was {hello_text}"
    );
    control
        .send(Message::Text(open("c1").into()))
        .await
        .unwrap();

    // --- play relay: data connection, then act as the viewer ---
    let (mut data, path, auth) = accept_ws(&listener).await;
    assert_eq!(path, "/v1/device/conn/c1");
    assert_eq!(auth, "Bearer tok");

    let hello = Frame::new(
        MessageKind::Hello,
        1,
        serde_json::to_vec(&serde_json::json!({"client": "relay-loopback"})).unwrap(),
    );
    data.send(Message::Binary(hello.encode().unwrap().into()))
        .await
        .unwrap();
    let ack = read_frame_from_ws(&mut data).await;
    assert_eq!(ack.header.message_kind, MessageKind::HelloAck);

    let attach = Frame::new(
        MessageKind::Attach,
        2,
        serde_json::to_vec(&serde_json::json!({"id": "s1", "after_sequence": null})).unwrap(),
    );
    data.send(Message::Binary(attach.encode().unwrap().into()))
        .await
        .unwrap();
    // The host's grid crosses the relay ahead of the screen drawn on it.
    assert_eq!(
        read_frame_from_ws(&mut data).await.header.message_kind,
        MessageKind::SessionResized
    );
    assert_eq!(
        read_frame_from_ws(&mut data).await.header.message_kind,
        MessageKind::Snapshot
    );

    // The boundary still applies over the relay: `ListViewers` is the host's
    // view of who is watching it, and never a viewer's to ask for.
    let refused = reply_over_ws(
        &mut data,
        Frame::new(MessageKind::ListViewers, 3, b"{}".to_vec()),
    )
    .await;
    assert_eq!(refused.header.message_kind, MessageKind::Error);

    // ... and the phase-3 widening reaches through it too. `Kill` was refused
    // here in phase 2; a lease holder drives the machine (spec §3).
    let killed = reply_over_ws(
        &mut data,
        Frame::new(
            MessageKind::Kill,
            4,
            serde_json::to_vec(&serde_json::json!({"id": "s1"})).unwrap(),
        ),
    )
    .await;
    assert_eq!(killed.header.message_kind, MessageKind::Response);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn relay_disconnects_when_sharing_is_turned_off() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (ctx, _stop) = start_daemon_with_relay(root.path(), port, None).await;

    let (mut control, seen_path, _) = accept_ws(&listener).await;
    assert_eq!(seen_path, "/v1/device");
    let hello = tokio::time::timeout(Duration::from_secs(4), control.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(hello.to_text().unwrap().contains("Test Mac"));

    // An unrelated setting write must not disturb the control socket: the
    // relay re-reads its config and compares rather than reconnecting.
    ctx.settings
        .lock()
        .unwrap()
        .set_setting("unrelated", "1")
        .unwrap();
    ctx.settings_changed.notify_one();
    let quiet = tokio::time::timeout(Duration::from_millis(500), control.next()).await;
    assert!(
        quiet.is_err(),
        "control socket reacted to an unrelated setting: {quiet:?}"
    );

    ctx.settings
        .lock()
        .unwrap()
        .set_setting("remote_sharing", r#"{"enabled":false}"#)
        .unwrap();
    ctx.settings_changed.notify_one();

    let closed = tokio::time::timeout(Duration::from_secs(4), control.next())
        .await
        .expect("control socket must close within 4 s of sharing turning off");
    assert!(
        matches!(closed, None | Some(Ok(Message::Close(_))) | Some(Err(_))),
        "expected the control socket to close, got {closed:?}"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_rejected_token_stops_redialling_until_the_token_row_changes() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (ctx, _stop) = start_daemon_with_relay(root.path(), port, None).await;

    reject_ws(&listener, 401).await;

    // No retry on its own, and none for an unrelated setting write either.
    let redial = tokio::time::timeout(Duration::from_secs(2), listener.accept()).await;
    assert!(redial.is_err(), "daemon re-dialled after a 401");
    ctx.settings
        .lock()
        .unwrap()
        .set_setting("unrelated", "1")
        .unwrap();
    ctx.settings_changed.notify_one();
    let redial = tokio::time::timeout(Duration::from_secs(1), listener.accept()).await;
    assert!(
        redial.is_err(),
        "daemon re-dialled after an unrelated write"
    );

    // A new token row is worth one more attempt, with the new token.
    write_token(&ctx, "tok2", port);
    let (_control, path, auth) = accept_ws(&listener).await;
    assert_eq!(path, "/v1/device");
    assert_eq!(auth, "Bearer tok2");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_silent_relay_is_dropped_and_redialled() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let ping_every = Duration::from_millis(100);
    let (_ctx, _stop) = start_daemon_with_relay(root.path(), port, Some(ping_every)).await;

    let (mut control, _, _) = accept_ws(&listener).await;
    let hello = tokio::time::timeout(Duration::from_secs(4), control.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(hello.to_text().unwrap().contains("Test Mac"));
    let connected = Instant::now();

    // Hold the socket open but never poll it again: no pings from us, no
    // pongs to the daemon's pings — a half-open link as far as it can tell.
    // Liveness must give up after a few silent intervals and dial again.
    let (_control2, path, _) = accept_ws(&listener).await;
    assert_eq!(path, "/v1/device");
    assert!(
        connected.elapsed() >= 3 * ping_every,
        "dropped after only {:?}",
        connected.elapsed()
    );
    drop(control);
}

/// Spec §2: the control channel is up *iff* `remote_sharing` is on —
/// machine-wide, not gated on what `remote_control` lists. An empty
/// projection (no workspace, nothing running) still reaches the relay once
/// sharing is on, because that idle Mac is precisely the one a viewer wants
/// to find.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sharing_enabled_dials_the_relay_even_with_an_empty_projection() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (_ctx, _stop) =
        start_daemon_with_projection(root.path(), port, None, r#"{"workspaces":[]}"#, true).await;

    let (mut control, seen_path, seen_auth) = accept_ws(&listener).await;
    assert_eq!(seen_path, "/v1/device");
    assert_eq!(seen_auth, "Bearer tok");
    let hello = tokio::time::timeout(Duration::from_secs(4), control.next())
        .await
        .expect("an idle-but-shared machine must still reach the relay")
        .unwrap()
        .unwrap();
    assert!(hello.to_text().unwrap().contains("Test Mac"));
}

/// Spec §2 condition 3 at the tunnel, and with it the no-chaining property of
/// §3: with the switch on and the token written, a machine whose app is not
/// attached does not dial the relay at all — and it becomes reachable, with no
/// settings write of any kind, the moment its app connects.
///
/// That second half is the one a `Notify` alone cannot do: a local connection
/// appearing pokes nothing, so the relay has to be re-testing on a tick or an
/// app restart would leave the machine dark until the next time anything wrote
/// a setting.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn no_local_app_means_no_tunnel_until_one_connects() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();

    // Everything `start_daemon_with_relay` does, minus the host's own app.
    let (ctx, _stop) = boot_daemon(root.path(), port, PROJECTION, true).await;
    tokio::spawn(run_relay(ctx.clone()));

    let dialled = tokio::time::timeout(Duration::from_secs(2), listener.accept()).await;
    assert!(
        dialled.is_err(),
        "a Mac with no app attached dialled the relay"
    );

    support::hold_local_client(&ctx).await;
    let (mut control, path, _) = accept_ws(&listener).await;
    assert_eq!(path, "/v1/device");
    let hello = tokio::time::timeout(Duration::from_secs(4), control.next())
        .await
        .expect("the tunnel must come up once the app is attached")
        .unwrap()
        .unwrap();
    assert!(hello.to_text().unwrap().contains("Test Mac"));
}

/// The grace, at the tunnel: the app going away holds the control channel open
/// for a few seconds and then closes it.
///
/// Real seconds, deliberately — this is the one test that exercises the timer
/// wiring rather than the condition, and a paused clock cannot be mixed with
/// the real sockets this file is built on without making every I/O timeout
/// fire early.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_tunnel_closes_once_the_local_app_has_been_gone_past_the_grace() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (ctx, _stop) = boot_daemon(root.path(), port, PROJECTION, true).await;
    let app = support::hold_local_client(&ctx).await;
    tokio::spawn(run_relay(ctx.clone()));

    let (mut control, _, _) = accept_ws(&listener).await;
    let hello = tokio::time::timeout(Duration::from_secs(4), control.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(hello.to_text().unwrap().contains("Test Mac"));

    // The app quits — a `rebuild-app.sh` restart, or an app that has gone to
    // drive another Mac. Aborting the task that owns it drops its end of the
    // pipe, which is what quitting does.
    app.abort();
    let inside_the_grace = tokio::time::timeout(Duration::from_secs(2), control.next()).await;
    assert!(
        inside_the_grace.is_err(),
        "the control socket closed inside the grace: {inside_the_grace:?}"
    );

    let closed = tokio::time::timeout(Duration::from_secs(8), control.next())
        .await
        .expect("the control socket must close once the grace expires");
    assert!(
        matches!(closed, None | Some(Ok(Message::Close(_))) | Some(Err(_))),
        "expected the control socket to close, got {closed:?}"
    );
}

/// The other half of the same rule: sharing off, no tunnel — even with a
/// non-empty projection, because the projection no longer decides this.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn sharing_disabled_never_dials_the_relay_even_with_a_populated_projection() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (_ctx, _stop) =
        start_daemon_with_projection(root.path(), port, None, PROJECTION, false).await;

    let dialled = tokio::time::timeout(Duration::from_secs(2), listener.accept()).await;
    assert!(
        dialled.is_err(),
        "the daemon dialled the relay with sharing off"
    );
}

// ---------------------------------------------------------------------------
// The relay asserts who is connecting (spec §9)
// ---------------------------------------------------------------------------

/// The identity travels from the control channel's `open` message onto the
/// data connection it describes — and it is that identity, not the client's
/// own `Hello`, that the daemon records.
///
/// The viewer here lies in the one message it controls: its `Hello` carries an
/// `account_email` of its own choosing. `HelloPayload` has no such field, so
/// serde drops it, and what ends up on the lease is what the relay said. That
/// is the whole property — the trusted and the self-reported halves arrive by
/// different routes and only one of them is ever read.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_relay_asserted_identity_reaches_the_connection() {
    let root = tempfile::tempdir().unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let (ctx, _stop) = start_daemon_with_relay(root.path(), port, None).await;

    let (mut control, _, _) = accept_ws(&listener).await;
    tokio::time::timeout(Duration::from_secs(4), control.next())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    control
        .send(Message::Text(open("c1").into()))
        .await
        .unwrap();

    let (mut data, path, _) = accept_ws(&listener).await;
    assert_eq!(path, "/v1/device/conn/c1");
    let hello = Frame::new(
        MessageKind::Hello,
        1,
        serde_json::to_vec(&serde_json::json!({
            "client": "relay-loopback",
            "viewer_id": "v-air",
            "machine_name": "Air",
            // The lie. Nothing reads it; nothing may ever read it.
            "account_email": "someone@else.com",
            "user_sub": "auth0|someone-else",
        }))
        .unwrap(),
    );
    data.send(Message::Binary(hello.encode().unwrap().into()))
        .await
        .unwrap();
    assert_eq!(
        read_frame_from_ws(&mut data).await.header.message_kind,
        MessageKind::HelloAck
    );

    let held = ctx
        .connections
        .lease_holder()
        .expect("the admitted viewer holds the lease");
    assert_eq!(
        held.asserted.account_email.as_deref(),
        Some(support::HOST_ACCOUNT_EMAIL),
        "the client's own Hello reached the identity the daemon trusts"
    );
    assert_eq!(held.asserted.user_sub.as_deref(), Some("auth0|bruno"));
    assert_eq!(held.asserted.ip.as_deref(), Some("203.0.113.7"));
    assert_eq!(held.asserted.country.as_deref(), Some("DE"));
    // …and the self-reported half is still kept, still labelled as such.
    assert_eq!(held.machine_name, "Air");
    assert_eq!(held.viewer_id.as_deref(), Some("v-air"));
}

/// A data connection the relay never described is refused outright: the
/// account check has nothing to run on, and a check that can be skipped by
/// leaving a field out is not a check.
///
/// Both shapes of "not described" are covered — the key missing, and an
/// explicit `null` — because they arrive at `serde_json` as the same value and
/// must leave it as the same decision.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_data_connection_the_relay_did_not_describe_is_closed_unserved() {
    for undescribed in [r#"{"open":"c1"}"#, r#"{"open":"c1","viewer":null}"#] {
        let root = tempfile::tempdir().unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (ctx, _stop) = start_daemon_with_relay(root.path(), port, None).await;

        let (mut control, _, _) = accept_ws(&listener).await;
        tokio::time::timeout(Duration::from_secs(4), control.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        control
            .send(Message::Text(undescribed.into()))
            .await
            .unwrap();

        let (mut data, path, _) = accept_ws(&listener).await;
        assert_eq!(path, "/v1/device/conn/c1");
        let hello = Frame::new(
            MessageKind::Hello,
            1,
            serde_json::to_vec(&serde_json::json!({"client": "relay-loopback"})).unwrap(),
        );
        let _ = data
            .send(Message::Binary(hello.encode().unwrap().into()))
            .await;

        let closed = tokio::time::timeout(Duration::from_secs(4), async {
            while let Some(message) = data.next().await {
                match message {
                    Ok(Message::Close(_)) | Err(_) => return true,
                    Ok(Message::Binary(_)) => return false,
                    Ok(_) => {}
                }
            }
            true
        })
        .await;
        assert_eq!(
            closed,
            Ok(true),
            "an undescribed data connection was served: {undescribed}"
        );
        assert!(
            ctx.connections.lease_holder().is_none(),
            "an undescribed data connection took the lease: {undescribed}"
        );
    }
}
