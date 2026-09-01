//! A daemon driven over `tokio::io::duplex`, for the tests that are about
//! **who may connect** rather than about what a connection can then do.
//!
//! It is the same shape `remote_authz.rs` uses inline — a real
//! [`DaemonServer`], its [`ClientContext`] cloned into [`serve_client`] over
//! an in-memory pipe, no unix socket and no peer-UID path — with one addition
//! the connection-admission tests all need: a `ClientTrust::Local` client is
//! attached and past `Hello` **before** any remote one connects. Nothing
//! enforces that as a precondition yet; the spec's condition ("a remote
//! connection is accepted only while a local app connection exists") lands
//! later, and every test written against this harness inherits the
//! arrangement it will need then.
//!
//! Not a test target itself: `tests/support/` is a directory module, so cargo
//! compiles it into each test binary that says `mod support;` rather than
//! running it as one.

#![allow(dead_code)]

use std::time::Duration;

use omniagent_pty_daemon::protocol::{
    read_handshake_frame, write_frame, ErrorPayload, Frame, HelloAckPayload, MessageKind,
};
use omniagent_pty_daemon::{serve_client, ClientContext, ClientTrust, DaemonServer};
use tokio::io::DuplexStream;
use tokio::sync::oneshot;

/// How long any wait in this harness gives the daemon before it calls the
/// behaviour missing rather than slow.
const PATIENCE: Duration = Duration::from_secs(4);

/// A running daemon with one local client on it.
pub struct Daemon {
    pub ctx: ClientContext,
    /// The local app's connection. Held because dropping it would close the
    /// pipe and take away the local client the harness exists to provide.
    _local: Client,
    /// Ends [`DaemonServer::run_until`] when the harness drops.
    _stop: oneshot::Sender<()>,
    /// The data directory, which must outlive the store the daemon opened in
    /// it.
    _root: tempfile::TempDir,
}

pub async fn daemon_with_local_client() -> Daemon {
    let root = tempfile::tempdir().unwrap();
    let server = DaemonServer::bind_with_data_dir(
        root.path().join("runtime").join("daemon.sock"),
        root.path().join("brain-data"),
    )
    .await
    .unwrap();
    let ctx = server.client_context();
    let (stop, stopped) = oneshot::channel();
    tokio::spawn(server.run_until(stopped));

    let mut local = connect(&ctx, ClientTrust::Local, "Mac Studio", None);
    match local.hello().await {
        HelloResult::Ack(_) => {}
        other => panic!("the host's own connection was refused: {other:?}"),
    }
    Daemon {
        ctx,
        _local: local,
        _stop: stop,
        _root: root,
    }
}

impl Daemon {
    /// A remote client that has not said `Hello` yet, speaking this build's
    /// protocol version.
    pub fn connect_remote(&self, machine: &str) -> Client {
        connect(&self.ctx, ClientTrust::Remote, machine, None)
    }

    /// [`Self::connect_remote`], but claiming `version` on the wire — the Mac
    /// that has not been updated.
    pub fn connect_remote_with_version(&self, machine: &str, version: u8) -> Client {
        connect(&self.ctx, ClientTrust::Remote, machine, Some(version))
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
        self.request += 1;
        let viewer_id = format!("v-{}", self.machine.to_lowercase().replace(' ', "-"));
        let mut frame = Frame::new(
            MessageKind::Hello,
            self.request,
            serde_json::to_vec(&serde_json::json!({
                "client": "harness",
                "viewer_id": viewer_id,
                "machine_name": self.machine,
            }))
            .unwrap(),
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
