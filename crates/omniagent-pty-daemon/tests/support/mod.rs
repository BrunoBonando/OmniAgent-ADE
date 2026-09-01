//! A daemon driven over `tokio::io::duplex`, for the tests that are about
//! **who may connect** rather than about what a connection can then do.
//!
//! It is the same shape `remote_authz.rs` uses inline — a real
//! [`DaemonServer`], its [`ClientContext`] cloned into [`serve_client`] over
//! an in-memory pipe, no unix socket and no peer-UID path — with two additions
//! the connection-admission tests all need: the sharing rows are written
//! (`remote_sharing` on, a `relay_device_token`), and a `ClientTrust::Local`
//! client is attached and past `Hello` **before** any remote one connects.
//! Those three things are exactly the condition of spec §2, and the daemon now
//! enforces them: without them every remote `Hello` here is refused with
//! "‹machine› is not available" instead of reaching the behaviour under test.
//!
//! [`daemon_without_local_client`] is the same arrangement minus the third
//! condition — the shape of a Mac whose app is away, which is a Mac that is
//! driving another one.
//!
//! Not a test target itself: `tests/support/` is a directory module, so cargo
//! compiles it into each test binary that says `mod support;` rather than
//! running it as one.

#![allow(dead_code)]

use std::time::Duration;

use brain_core::Store;
use omniagent_pty_daemon::protocol::{
    read_handshake_frame, write_frame, ErrorPayload, Frame, HelloAckPayload, MessageKind,
};
use omniagent_pty_daemon::{
    serve_client, sharing_should_be_live, AssertedIdentity, ClientContext, ClientTrust,
    DaemonServer, DEVICE_TOKEN_KEY, LOCAL_ABSENCE_GRACE, REMOTE_SHARING_KEY,
};
use tokio::io::DuplexStream;
use tokio::sync::oneshot;

/// How long any wait in this harness gives the daemon before it calls the
/// behaviour missing rather than slow.
const PATIENCE: Duration = Duration::from_secs(4);

/// The account every daemon in these tests is signed in to and serving.
pub const HOST_ACCOUNT_EMAIL: &str = "bruno@bonando.com";

/// What the relay asserts about a viewer signed in as `email` — the trusted
/// half of an identity, as it arrives on the control channel's `open` message
/// (spec §9). The `ip`/`country`/`client` fields are filled in so that a test
/// asserting on them is asserting on something.
pub fn asserted_as(email: &str) -> AssertedIdentity {
    AssertedIdentity {
        user_sub: None,
        account_email: Some(email.to_owned()),
        ip: Some("203.0.113.7".into()),
        country: Some("DE".into()),
        client: Some("OmniAgent/1.7.22 macOS 27.0".into()),
    }
}

/// A relayed connection carrying the relay's assertion for `email`.
pub fn remote_trust_for(email: &str) -> ClientTrust {
    ClientTrust::Remote(Box::new(asserted_as(email)))
}

/// A relayed connection the relay described only partially — no
/// `account_email` at all, the shape the account check has to fail closed on.
pub fn remote_trust_asserting_nothing() -> ClientTrust {
    ClientTrust::Remote(Box::default())
}

/// A running daemon, sharing switched on, with or without a local client.
pub struct Daemon {
    pub ctx: ClientContext,
    /// The local app's connection. Held because dropping it closes the pipe —
    /// which is exactly what [`Daemon::drop_local_client`] does on purpose.
    /// `None` once it has, and from the start for
    /// [`daemon_without_local_client`].
    local: Option<Client>,
    /// Ends [`DaemonServer::run_until`] when the harness drops.
    _stop: oneshot::Sender<()>,
    /// The data directory, which must outlive the store the daemon opened in
    /// it.
    _root: tempfile::TempDir,
}

/// The two settings conditions of spec §2 — the switch on, a device token
/// present — written straight into the store.
///
/// This harness never starts the relay, so the token's `relay_url` names a
/// port nothing listens on: the row is here to be *present*, and to give the
/// daemon this Mac's own name for the refusal it writes.
pub fn enable_sharing(ctx: &ClientContext) {
    let store = ctx.settings.lock().unwrap();
    store
        .set_setting(REMOTE_SHARING_KEY, r#"{"enabled":true}"#)
        .unwrap();
    store
        .set_setting(
            DEVICE_TOKEN_KEY,
            r#"{"device_id":"dev","token":"tok","name":"Mac Studio","relay_url":"http://127.0.0.1:1"}"#,
        )
        .unwrap();
}

/// Attaches a local client to `ctx` and keeps it attached for as long as the
/// test runtime lives.
///
/// For the harnesses that hold no handle on the host's own app and only need
/// one to exist, since every remote `Hello` now does (spec §2 condition 3). It
/// is owned by a task that never speaks on it, and nothing drains it, which is
/// safe by construction — a local connection's roster feed is its own task and
/// can stall only itself.
///
/// **Abort the returned handle to quit the app**: that drops the client and
/// with it the pipe, which is what an app quitting looks like to the daemon.
/// Merely dropping the handle does not (a `JoinHandle` is not an owner), so a
/// caller that wants the app to stay may discard it.
pub async fn hold_local_client(ctx: &ClientContext) -> tokio::task::JoinHandle<()> {
    let mut local = connect(ctx, ClientTrust::Local, "Mac Studio", None);
    match local.hello().await {
        HelloResult::Ack(_) => {}
        other => panic!("the host's own connection was refused: {other:?}"),
    }
    tokio::spawn(async move {
        let _local = local;
        std::future::pending::<()>().await;
    })
}

/// The directory a daemon signed in as `email` runs in: `<root>/accounts/<id>`
/// with `<id> = Store::account_dir_id(email)`, which is exactly what
/// `Store::default_data_dir()` resolves to while the `current-account` pointer
/// names that account (2026-08-30 account-scoped-workspace spec).
///
/// Every harness here boots into one, because that path *is* what the daemon's
/// account check compares the relay's assertion against — a daemon booted into
/// a plain directory is a signed-out one, and refuses every viewer.
pub fn account_data_dir(root: &std::path::Path, email: &str) -> std::path::PathBuf {
    root.join("accounts").join(Store::account_dir_id(email))
}

pub async fn daemon_with_local_client() -> Daemon {
    let mut daemon = daemon_without_local_client().await;
    daemon.reconnect_local_client().await;
    daemon
}

/// A daemon serving `email`'s account directory, with the host's app attached.
pub async fn daemon_for_account(email: &str) -> Daemon {
    let mut daemon = boot(HostAccount::SignedIn(email)).await;
    daemon.reconnect_local_client().await;
    daemon
}

/// A daemon that is sharing and paired but has **no app attached** — the shape
/// of a Mac whose app has gone to drive another one, and therefore of a Mac
/// that must refuse everyone (spec §3, "One remote session per machine, in
/// either direction").
pub async fn daemon_without_local_client() -> Daemon {
    boot(HostAccount::SignedIn(HOST_ACCOUNT_EMAIL)).await
}

/// A **signed-out** host: the data directory is the root itself, with no
/// `accounts/<id>` segment, so there is no account for an assertion to match.
/// It has no device token in the real world either, but the check must fail
/// closed here on its own rather than lean on that.
pub async fn daemon_signed_out() -> Daemon {
    let mut daemon = boot(HostAccount::SignedOut).await;
    daemon.reconnect_local_client().await;
    daemon
}

/// Which account a booted daemon is serving.
enum HostAccount<'a> {
    SignedIn(&'a str),
    SignedOut,
}

async fn boot(account: HostAccount<'_>) -> Daemon {
    let root = tempfile::tempdir().unwrap();
    let data_root = root.path().join("brain-data");
    let data_dir = match account {
        HostAccount::SignedIn(email) => account_data_dir(&data_root, email),
        HostAccount::SignedOut => data_root,
    };
    let server =
        DaemonServer::bind_with_data_dir(root.path().join("runtime").join("daemon.sock"), data_dir)
            .await
            .unwrap();
    let ctx = server.client_context();
    let (stop, stopped) = oneshot::channel();
    tokio::spawn(server.run_until(stopped));
    enable_sharing(&ctx);

    Daemon {
        ctx,
        local: None,
        _stop: stop,
        _root: root,
    }
}

impl Daemon {
    /// A remote client that has not said `Hello` yet, speaking this build's
    /// protocol version, and which the relay asserts is this daemon's own
    /// account — the ordinary case every other admission test is about.
    pub fn connect_remote(&self, machine: &str) -> Client {
        self.connect_remote_asserting(machine, HOST_ACCOUNT_EMAIL)
    }

    /// A remote client the **relay** says is signed in as `email`. The email
    /// is not sent by the client and there is no way for it to be: it rides
    /// the `ClientTrust::Remote` value, exactly as `relay.rs` builds it from
    /// the control channel's `open` message.
    pub fn connect_remote_asserting(&self, machine: &str, email: &str) -> Client {
        connect(&self.ctx, remote_trust_for(email), machine, None)
    }

    /// A remote client the relay opened without saying who it is.
    pub fn connect_remote_asserting_nothing(&self, machine: &str) -> Client {
        connect(&self.ctx, remote_trust_asserting_nothing(), machine, None)
    }

    /// [`Self::connect_remote`], but claiming `version` on the wire — the Mac
    /// that has not been updated.
    pub fn connect_remote_with_version(&self, machine: &str, version: u8) -> Client {
        connect(
            &self.ctx,
            remote_trust_for(HOST_ACCOUNT_EMAIL),
            machine,
            Some(version),
        )
    }

    /// Whether this daemon would hold a relay control channel right now —
    /// spec §2's three-way condition, asked exactly as `relay.rs` asks it.
    pub fn sharing_is_live(&self) -> bool {
        let store = self.ctx.settings.lock().unwrap();
        sharing_should_be_live(&store, &self.ctx.connections)
    }

    /// Closes the host app's connection, the way quitting the app or
    /// `rebuild-app.sh` does — and, in the case this whole condition exists
    /// for, the way an app that has gone to drive *another* Mac does.
    ///
    /// Waits for the daemon to notice, because the grace starts when the
    /// connection leaves the registry rather than when the pipe closes, and a
    /// test that measured from the wrong moment would be measuring nothing.
    pub async fn drop_local_client(&mut self) {
        drop(
            self.local
                .take()
                .expect("there was no local client to drop"),
        );
        let deadline = tokio::time::Instant::now() + PATIENCE;
        while self.ctx.connections.has_local() {
            assert!(
                tokio::time::Instant::now() < deadline,
                "the daemon still had a local connection {PATIENCE:?} after the pipe closed"
            );
            // A millisecond of a paused clock, auto-advanced the moment the
            // daemon's task has nothing left to do — so this costs a
            // negligible slice of the grace rather than a real sleep.
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    }

    /// The app coming back: a fresh local connection past `Hello`.
    pub async fn reconnect_local_client(&mut self) {
        let mut local = connect(&self.ctx, ClientTrust::Local, "Mac Studio", None);
        match local.hello().await {
            HelloResult::Ack(_) => {}
            other => panic!("the host's own connection was refused: {other:?}"),
        }
        self.local = Some(local);
    }

    /// Moves the paused clock on — only meaningful under
    /// `#[tokio::test(start_paused = true)]`, which is how the grace is tested
    /// rather than by sleeping through five real seconds.
    pub async fn advance(&self, by: Duration) {
        tokio::time::advance(by).await;
    }

    /// Past [`LOCAL_ABSENCE_GRACE`], with a second to spare.
    pub async fn advance_past_the_grace(&self) {
        self.advance(LOCAL_ABSENCE_GRACE + Duration::from_secs(1))
            .await;
    }

    /// Blocks until no connection holds the lease.
    ///
    /// A dropped client frees the lease only once the daemon's task notices
    /// the closed pipe and unwinds, which is a scheduling beat away rather
    /// than immediate — so the alternative to polling here is a fixed sleep,
    /// flaky in whichever direction it is wrong.
    pub async fn wait_for_no_lease(&self) {
        let deadline = tokio::time::Instant::now() + PATIENCE;
        while self.ctx.connections.lease_holder().is_some() {
            assert!(
                tokio::time::Instant::now() < deadline,
                "the lease was still held {PATIENCE:?} after the connection ended"
            );
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
    }
}

fn connect(ctx: &ClientContext, trust: ClientTrust, machine: &str, version: Option<u8>) -> Client {
    let (client_side, server_side) = tokio::io::duplex(64 * 1024);
    tokio::spawn(serve_client(server_side, ctx.clone(), trust));
    Client {
        stream: client_side,
        request: 0,
        version,
        machine: machine.to_owned(),
        claimed: None,
    }
}

/// One client connection: the near end of the pipe `serve_client` is reading.
pub struct Client {
    stream: DuplexStream,
    request: u64,
    /// The protocol version to stamp on outgoing frames, or `None` for this
    /// build's.
    version: Option<u8>,
    machine: String,
    /// Extra identity keys smuggled into the client's own `Hello` payload —
    /// see [`Client::claiming_in_hello`].
    claimed: Option<String>,
}

/// What the daemon answered a `Hello` with. There are only two answers, and
/// which one arrived is the whole subject of the admission tests.
#[derive(Debug)]
pub enum HelloResult {
    Ack(HelloAckPayload),
    Error(String),
}

impl Client {
    /// Sends `Hello` and reads the one frame that answers it.
    pub async fn hello(&mut self) -> HelloResult {
        let viewer_id = format!("v-{}", self.machine.to_lowercase().replace(' ', "-"));
        self.say_hello(Some(viewer_id)).await
    }

    /// Whether the daemon still has this connection open.
    ///
    /// **Terminal**: it reads, so any frame that arrives during the check is
    /// consumed. Call it last. A closed pipe fails the read at once; an open
    /// one simply has nothing to say, which under a paused clock costs no real
    /// time at all.
    pub async fn is_open(&mut self) -> bool {
        tokio::time::timeout(
            Duration::from_millis(50),
            read_handshake_frame(&mut self.stream),
        )
        .await
        .map_or(true, |read| read.is_ok())
    }

    /// [`Self::hello`] from a client that sends no `viewer_id` — an app older
    /// than phase 2, which the daemon can label but never kick by id.
    pub async fn hello_without_naming_itself(&mut self) -> HelloResult {
        self.say_hello(None).await
    }

    /// Makes this client's own `Hello` claim to be signed in as `email`, by
    /// putting every identity key the relay asserts into the payload the
    /// *client* controls — `account_email`, `user_sub`, and a whole nested
    /// `viewer` object of the shape `relay.rs` parses.
    ///
    /// It is a lie by construction. `HelloPayload` has no such fields and
    /// serde drops what it does not know, so this is exactly what an attacker
    /// gets to do: write anything into the one message it owns. A daemon that
    /// ever grew an account check reading `identity.*` would start passing a
    /// test it must fail, which is the point of asserting on it from out here.
    pub fn claiming_in_hello(mut self, email: &str) -> Self {
        self.claimed = Some(email.to_owned());
        self
    }

    async fn say_hello(&mut self, viewer_id: Option<String>) -> HelloResult {
        self.request += 1;
        let mut payload = serde_json::json!({
            "client": "harness",
            // Omitted entirely when `None` — the daemon declares both
            // identity fields `Option`, so this is the pre-phase-2 shape.
            "viewer_id": viewer_id,
            "machine_name": self.machine,
        });
        if let Some(email) = self.claimed.clone() {
            let object = payload.as_object_mut().unwrap();
            object.insert("account_email".into(), serde_json::json!(email));
            object.insert("user_sub".into(), serde_json::json!("whoever-i-say"));
            object.insert(
                "viewer".into(),
                serde_json::json!({"account_email": email, "user_sub": "whoever-i-say"}),
            );
        }
        let mut frame = Frame::new(
            MessageKind::Hello,
            self.request,
            serde_json::to_vec(&payload).unwrap(),
        );
        if let Some(version) = self.version {
            frame.header.protocol_version = version;
        }
        write_frame(&mut self.stream, &frame).await.unwrap();

        // Read the reply with the version-tolerant decoder: a refusal aimed at
        // a Mac on the old protocol is written in *that* Mac's version, which
        // is the only way it can be decoded by the app it is meant for.
        let reply = tokio::time::timeout(PATIENCE, read_handshake_frame(&mut self.stream))
            .await
            .expect("the daemon answered nothing")
            .expect("the daemon closed without answering");
        match reply.header.message_kind {
            MessageKind::HelloAck => {
                HelloResult::Ack(serde_json::from_slice(&reply.payload).unwrap())
            }
            MessageKind::Error => HelloResult::Error(
                serde_json::from_slice::<ErrorPayload>(&reply.payload)
                    .unwrap()
                    .message,
            ),
            other => panic!("{other:?} is not an answer to Hello"),
        }
    }
}
