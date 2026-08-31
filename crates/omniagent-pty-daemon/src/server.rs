use crate::connections::{ConnectionRegistry, ViewerIdentity};
use crate::protocol::{
    decode_raw_payload, encode_raw_payload, read_frame, write_frame, AttachPayload,
    BrainGetContextPayload, BrainSearchPayload, DisconnectViewerPayload, ErrorPayload, Frame,
    HelloAckPayload, HelloPayload, MessageKind, RemoteViewersPayload, ResizePayload,
    ResponsePayload, ResyncRequiredPayload, RootsAddProjectPayload, RootsReingestProjectPayload,
    RootsRenameProjectPayload, RootsSetPausedPayload, RootsStartIngestPayload,
    SessionCreatedPayload, SessionExitedPayload, SessionIdPayload, SessionListPayload,
    SessionSizePayload, SessionStatusPayload, SettingKey, SettingValue, PROTOCOL_VERSION,
};
use crate::{AttachState, CreateSession, SessionEvent, SessionRegistry, SessionSubscription};
use anyhow::{anyhow, Context, Result};
use brain_core::Store;
use brain_ingest::roots::{self, IngestionState};
use mcp_server::tools::{self, ToolContext};
use serde::de::DeserializeOwned;
use std::collections::{HashMap, HashSet};
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{oneshot, Mutex, Notify};
use tokio::task::{JoinHandle, JoinSet};
use tokio_util::sync::CancellationToken;

const CLIENT_QUEUE_CAPACITY: usize = 64;

pub fn peer_uid_allowed(peer_uid: u32, runtime_owner_uid: u32) -> bool {
    peer_uid == runtime_owner_uid
}

/// How much a client connection is trusted.
///
/// `Local` is the unix-socket path: the accept loop has already checked
/// the peer UID, and the client may do everything the protocol offers.
/// `Remote` is a connection relayed from another device
/// (`docs/superpowers/specs/2026-08-30-remote-session-control-design.md`
/// §2): it never took the peer-UID path, so every frame passes
/// [`authorize_remote`] before dispatch and is confined to the sessions
/// the `remote_control` projection row shares.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ClientTrust {
    Local,
    Remote,
}

/// Everything one client connection needs from the daemon — cloned out of
/// [`DaemonServer`] per connection by [`DaemonServer::client_context`] so
/// [`serve_client`] can run over any byte stream, not only the unix socket.
#[derive(Clone)]
pub struct ClientContext {
    pub registry: SessionRegistry,
    pub settings: Arc<std::sync::Mutex<Store>>,
    pub data_dir: PathBuf,
    pub ingestion: IngestionState,
    /// Poked after every successful `SetSetting`; the relay task watches it
    /// to notice `remote_control` / device-token changes without polling.
    pub settings_changed: Arc<Notify>,
    /// Every live client connection (phase 2 spec §5) — what makes presence
    /// and the kick possible at all. Constructed once by
    /// [`DaemonServer::bind_with_data_dir`] and cloned into every connection.
    pub connections: ConnectionRegistry,
}

/// The write half of a client connection, shared between the dispatch loop
/// and every attachment's forwarding task.
pub type SharedWriter = Arc<Mutex<Box<dyn AsyncWrite + Unpin + Send>>>;

/// The settings row holding the remote-control projection — the only
/// workspaces (and their sessions) a remote client may ever see.
pub const REMOTE_CONTROL_KEY: &str = "remote_control";

/// The settings row listing viewer ids the host has disconnected — a JSON
/// array of strings, `["<viewer_id>", …]` (phase 2 spec §5).
///
/// **The daemon writes this row.** A kick that only dropped the socket would
/// not hold: a viewer with a valid device token re-dials within 30 s, and it
/// has to be refused even with the host app closed, so the enforcer has to be
/// the one keeping the list.
///
/// **The app clears the whole row** — a single `SetSetting(…, "[]")` — when
/// Remote Control is switched on for any workspace. The list is global rather
/// than per-workspace because it answers "which machines may not reach this
/// Mac", and turning sharing back on anywhere is the deliberate act that
/// forgives them. Both sides writing one small array is safe here: the two
/// writes are a human action apart.
pub const BLOCKED_VIEWERS_KEY: &str = "remote_control_blocked";

/// The viewer ids currently blocked. An unreadable store, a missing row or
/// unparsable JSON all mean "nobody is blocked": this list only ever *adds*
/// refusals, so failing open here refuses nothing that the trust boundary in
/// [`authorize_remote`] would have let through anyway.
fn blocked_viewers(settings: &std::sync::Mutex<Store>) -> HashSet<String> {
    lock_store(settings)
        .ok()
        .and_then(|store| store.get_setting(BLOCKED_VIEWERS_KEY).ok().flatten())
        .and_then(|raw| serde_json::from_str::<Vec<String>>(&raw).ok())
        .map(|ids| ids.into_iter().collect())
        .unwrap_or_default()
}

/// Adds one viewer id to [`BLOCKED_VIEWERS_KEY`], read-modify-write. A row
/// that does not parse as an array of ids is replaced rather than inherited —
/// the alternative is a kick that silently does not hold.
fn block_viewer(store: &Store, viewer_id: &str) -> Result<()> {
    let mut ids: Vec<String> = store
        .get_setting(BLOCKED_VIEWERS_KEY)?
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
    if !ids.iter().any(|id| id == viewer_id) {
        ids.push(viewer_id.to_owned());
    }
    store
        .set_setting(BLOCKED_VIEWERS_KEY, &serde_json::to_string(&ids)?)
        .map_err(Into::into)
}

/// The session ids the `remote_control` projection currently shares — the
/// allowlist every remote `Attach`/`Input`/`Interrupt` is checked against.
/// Missing row, unparsable JSON or an unexpected shape all mean "nothing".
///
/// Two projection shapes are read, because a Mac that has not updated yet
/// still writes the first one (phase 2 spec §2, "Compatibility"):
///
/// - **v2** (`"version": 2`) carries the host's real tree, so a `sessions[]`
///   entry is a session *group* whose `panes[]` hold the attachable ids. The
///   group's own id is a UI grouping and is never a daemon session, so it is
///   deliberately not collected — an idle group (`"panes": []`) shares
///   nothing at all, and the machine stays reachable through
///   [`remote_control_active`] instead.
/// - **v1** flattened panes into `sessions[]`, so there each entry *is* the
///   attachable id. The absence of a `panes` array is what selects this.
///
/// Either way the id collected is a **pane** id rather than a session-group
/// id. Not every pane is a PTY, though: an editor or browser pane carries an
/// id in the projection exactly like a terminal pane does. Those are harmless
/// because the daemon never registers a session under them — a remote `Attach`
/// passes the allowlist and then gets "session not found" from the registry
/// (`a_shared_pane_with_no_session_behind_it_cannot_be_attached`) — but what
/// this returns is a set of shared pane ids, not a promise that each one names
/// a terminal.
pub fn remote_session_ids(store: &Store) -> HashSet<String> {
    let Some(raw) = store.get_setting(REMOTE_CONTROL_KEY).ok().flatten() else {
        return HashSet::new();
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else {
        return HashSet::new();
    };
    value["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|workspace| workspace["sessions"].as_array())
        .flatten()
        .flat_map(|session| {
            let panes = session["panes"].as_array();
            let v2 = panes.into_iter().flatten();
            let v1 = panes.is_none().then_some(session);
            v2.chain(v1)
        })
        .filter_map(|pane| pane["id"].as_str().map(str::to_owned))
        .collect()
}

/// Whether the projection shares at least one **workspace** — the daemon's
/// half of "the tunnel should be up" (spec §2: the control channel is open
/// *iff* `remote_control` lists ≥ 1 workspace **and** `relay_device_token`
/// exists). Deliberately not `!remote_session_ids(store).is_empty()`: the app
/// emits an enabled workspace with an empty `sessions` array on purpose, so a
/// Mac with nothing running is still reachable — a viewer has to be able to
/// see an idle machine *before* there is a session on it to open.
pub fn remote_control_active(store: &Store) -> bool {
    let Some(raw) = store.get_setting(REMOTE_CONTROL_KEY).ok().flatten() else {
        return false;
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else {
        return false;
    };
    value["workspaces"]
        .as_array()
        .is_some_and(|workspaces| !workspaces.is_empty())
}

/// The one field every session-bound control payload (`AttachPayload`,
/// `ResizePayload`, `SessionIdPayload`) has in common.
#[derive(serde::Deserialize)]
struct SessionRef {
    id: String,
}

/// The trust boundary for relayed clients (spec §2). `Err(reason)` means
/// "answer with `Error`, skip dispatch". Allowed: `Hello`, `ListSessions`
/// (the dispatch arm filters the list), `Detach`, and `Attach`/`Input`/
/// `Interrupt` whose session id is in `allowed`; `GetSetting`
/// only for the projection row itself. Everything else — `Kill`,
/// `CreateSession`, `SetSetting`, `Resize`, every Brain/Roots RPC — is
/// refused.
pub fn authorize_remote(frame: &Frame, allowed: &HashSet<String>) -> Result<(), String> {
    let shared = |id: &str| {
        allowed
            .contains(id)
            .then_some(())
            .ok_or_else(|| format!("session {id} is not shared"))
    };
    match frame.header.message_kind {
        MessageKind::Hello | MessageKind::ListSessions | MessageKind::Detach => Ok(()),
        // `Resize` is deliberately absent: the host owns the grid (phase 2
        // spec §1). One session is one screen buffer, so honouring a
        // viewer's window size would collapse the host's terminal — and
        // any viewer being able to resize any shared session was a
        // trust-boundary hole besides. It falls through to the deny arm.
        MessageKind::Attach | MessageKind::Interrupt => shared(
            &parse_json::<SessionRef>(&frame.payload)
                .map_err(|error| error.to_string())?
                .id,
        ),
        MessageKind::Input => shared(
            decode_raw_payload(&frame.payload)
                .map_err(|error| error.to_string())?
                .0,
        ),
        MessageKind::GetSetting => {
            let key = parse_json::<SettingKey>(&frame.payload)
                .map_err(|error| error.to_string())?
                .key;
            (key == REMOTE_CONTROL_KEY)
                .then_some(())
                .ok_or_else(|| format!("setting {key} is not readable remotely"))
        }
        other => Err(format!("{other:?} is not allowed for remote clients")),
    }
}

pub struct DaemonServer {
    listener: UnixListener,
    socket_path: PathBuf,
    runtime_owner_uid: u32,
    registry: SessionRegistry,
    settings: Arc<std::sync::Mutex<Store>>,
    /// The shared brain-store data directory (`data_dir/brain.db`) —
    /// threaded into `mcp_server::tools::ToolContext` for `BrainListProjects`/
    /// `BrainGetContext` dispatch (Task 6a). Resolved by [`Self::bind`] via
    /// `brain_core::Store::default_data_dir()`, the **same** function
    /// `src-tauri`'s `BrainState` (`src-tauri/src/lib.rs`) calls to open its
    /// own `Store` — this is deliberately *not* derived from the socket
    /// path/runtime dir (see [`Self::bind_with_data_dir`]'s doc), which
    /// would silently point every brain read and every `settings` row
    /// (including `layout`) at a different, unshared `brain.db`.
    data_dir: PathBuf,
    /// The daemon's own ingestion-progress state machine (Task 6a-2),
    /// constructed once here and cloned into every client connection —
    /// mirroring how the Tauri app's process owns exactly one
    /// `IngestionState` for its whole lifetime (`lib.rs`'s `app.manage(..)`).
    /// The daemon and the Tauri app each hold an independent instance
    /// against the same `brain.db`; this crate makes no attempt to
    /// coordinate ingestion progress *across* the two processes (out of
    /// scope per the brief — same reasoning as both processes already
    /// holding independent `Store` connections to one WAL-mode file).
    ingestion: IngestionState,
    /// See [`ClientContext::settings_changed`].
    settings_changed: Arc<Notify>,
    /// See [`ClientContext::connections`].
    connections: ConnectionRegistry,
    /// Whether [`Self::serve`] spawns the relay client (`relay.rs`). Off
    /// for [`Self::bind_with_data_dir`] so tests drive `run_relay` directly;
    /// [`run_daemon`] turns it on with [`Self::with_relay`].
    relay_enabled: bool,
}

impl DaemonServer {
    /// Binds the daemon socket at `socket_path` and opens the shared brain
    /// store at `brain_core::Store::default_data_dir()` — honoring
    /// `OMNIAGENT_ADE_DATA_DIR` exactly like every other crate in this
    /// workspace does (PLAN.md's Local-first constraint: "Env override
    /// `OMNIAGENT_ADE_DATA_DIR` for tests — every crate must honor it").
    ///
    /// The directory is account-scoped: `root/current-account` selects
    /// `root/accounts/<id>` (2026-08-30 account-scoped-workspace spec). The
    /// pointer is read exactly once, here — the app restarts the daemon to
    /// move it between accounts. Before the store is opened, and so before
    /// any file is held open, a pre-account install's data is moved into
    /// the first account directory (`Store::adopt_legacy_data`).
    pub async fn bind(socket_path: PathBuf) -> Result<Self> {
        let root = Store::data_root();
        let data_dir = Store::default_data_dir();
        if data_dir != root
            && Store::adopt_legacy_data(&root, &data_dir)
                .context("move the pre-account brain data into the account directory")?
        {
            tracing::info!(
                root = %root.display(),
                account_dir = %data_dir.display(),
                "adopted the pre-account brain data into the account directory"
            );
        }
        Self::bind_with_data_dir(socket_path, data_dir).await
    }

    /// Same as [`Self::bind`], but takes the brain-store data directory
    /// explicitly rather than resolving it internally — the injection point
    /// tests use. A test must never open a real
    /// `~/Library/Application Support/OmniAgent-ADE/brain.db`, and mutating
    /// the process-global `OMNIAGENT_ADE_DATA_DIR` env var per test would
    /// race against every other test running concurrently in the same
    /// binary (`cargo test` runs different test functions on separate
    /// threads by default) — passing the directory as a plain argument
    /// avoids both.
    ///
    /// `data_dir` is intentionally independent of `socket_path`'s parent
    /// directory (the "runtime dir"). The runtime dir is only ever the
    /// socket's own home — its permissions and the peer-UID check below are
    /// about who may *connect*, nothing to do with where the shared brain
    /// data lives. Conflating the two (this crate's bug prior to the Task 6a
    /// fix) silently pointed `BrainListProjects`/`BrainGetContext`, and even
    /// `GetSetting`/`SetSetting`'s `layout` row, at `~/.omniagent-ade/`
    /// (the socket's directory) instead of the app's real, shared
    /// `brain.db` — every brain read came back empty and `layout` was never
    /// actually the row the web/Tauri app reads and writes.
    pub async fn bind_with_data_dir(socket_path: PathBuf, data_dir: PathBuf) -> Result<Self> {
        let runtime_dir = socket_path
            .parent()
            .ok_or_else(|| anyhow!("socket path needs a parent directory"))?;
        std::fs::create_dir_all(runtime_dir).context("create daemon runtime directory")?;
        std::fs::set_permissions(runtime_dir, std::fs::Permissions::from_mode(0o700))
            .context("secure daemon runtime directory")?;
        let settings = Store::open(&data_dir)
            .context("open daemon settings in the shared brain data directory")?;
        let runtime_owner_uid = std::fs::metadata(runtime_dir)
            .context("inspect daemon runtime directory")?
            .uid();

        if socket_path.exists() {
            if UnixStream::connect(&socket_path).await.is_ok() {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    format!("daemon already listening at {}", socket_path.display()),
                )
                .into());
            }
            std::fs::remove_file(&socket_path).context("remove stale daemon socket")?;
        }
        let listener = UnixListener::bind(&socket_path)
            .with_context(|| format!("bind daemon socket at {}", socket_path.display()))?;
        std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))
            .context("secure daemon socket")?;
        Ok(Self {
            listener,
            socket_path,
            runtime_owner_uid,
            registry: SessionRegistry::new(),
            settings: Arc::new(std::sync::Mutex::new(settings)),
            data_dir,
            ingestion: IngestionState::new(),
            settings_changed: Arc::new(Notify::new()),
            connections: ConnectionRegistry::default(),
            relay_enabled: false,
        })
    }

    /// Makes [`Self::serve`] spawn the relay client alongside the unix
    /// accept loop — the daemon's outbound side of remote session control.
    pub fn with_relay(mut self) -> Self {
        self.relay_enabled = true;
        self
    }

    pub fn registry(&self) -> SessionRegistry {
        self.registry.clone()
    }

    /// The per-connection handle [`serve_client`] needs — what the unix
    /// accept loop hands every local client, and what the relay hands
    /// every remote one.
    pub fn client_context(&self) -> ClientContext {
        ClientContext {
            registry: self.registry.clone(),
            settings: Arc::clone(&self.settings),
            data_dir: self.data_dir.clone(),
            ingestion: self.ingestion.clone(),
            settings_changed: Arc::clone(&self.settings_changed),
            connections: self.connections.clone(),
        }
    }

    pub async fn run_until(self, shutdown: oneshot::Receiver<()>) -> Result<()> {
        self.serve(async {
            let _ = shutdown.await;
        })
        .await
    }

    pub async fn run(self) -> Result<()> {
        self.serve(std::future::pending::<()>()).await
    }

    async fn serve(self, shutdown: impl std::future::Future<Output = ()>) -> Result<()> {
        tokio::pin!(shutdown);
        let relay = self
            .relay_enabled
            .then(|| tokio::spawn(crate::relay::run_relay(self.client_context())));
        let mut clients = JoinSet::new();
        loop {
            tokio::select! {
                accepted = self.listener.accept() => {
                    let (stream, _) = accepted.context("accept daemon client")?;
                    // The peer-UID check is the unix socket's own gate and
                    // lives here, not in `serve_client`: a relayed stream
                    // has no peer credentials, it has `ClientTrust::Remote`.
                    let peer_uid = match stream.peer_cred() {
                        Ok(credentials) => credentials.uid(),
                        Err(error) => {
                            tracing::warn!(
                                "rejecting daemon client: read peer credentials: {error}"
                            );
                            continue;
                        }
                    };
                    if !peer_uid_allowed(peer_uid, self.runtime_owner_uid) {
                        tracing::warn!(
                            "rejecting daemon client: peer UID {peer_uid} does not own daemon runtime"
                        );
                        continue;
                    }
                    let ctx = self.client_context();
                    clients.spawn(async move {
                        let _ = serve_client(stream, ctx, ClientTrust::Local).await;
                    });
                }
                _ = &mut shutdown => break,
                Some(_) = clients.join_next(), if !clients.is_empty() => {}
            }
        }
        self.registry.shutdown();
        if let Some(relay) = relay {
            relay.abort();
        }
        clients.abort_all();
        while clients.join_next().await.is_some() {}
        Ok(())
    }
}

impl Drop for DaemonServer {
    fn drop(&mut self) {
        self.registry.shutdown();
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

pub async fn run_daemon(socket_path: PathBuf) -> Result<()> {
    let server = DaemonServer::bind(socket_path).await?.with_relay();
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .context("install SIGTERM handler")?;
    let (send_shutdown, receive_shutdown) = oneshot::channel();
    tokio::spawn(async move {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
        let _ = send_shutdown.send(());
    });
    server.run_until(receive_shutdown).await
}

struct Attachment {
    subscription: SessionSubscription,
    task: JoinHandle<()>,
}

impl Drop for Attachment {
    fn drop(&mut self) {
        self.subscription.close();
        self.task.abort();
    }
}

/// Serves one client connection over any byte stream until it closes.
///
/// The unix accept loop calls this with [`ClientTrust::Local`] after its
/// peer-UID check; the relay calls it with [`ClientTrust::Remote`] over a
/// WebSocket adapted to a byte stream, in which case every frame after
/// `Hello` passes [`authorize_remote`] before the dispatch below sees it.
pub async fn serve_client<S>(stream: S, ctx: ClientContext, trust: ClientTrust) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let ClientContext {
        registry,
        settings,
        data_dir,
        ingestion,
        settings_changed,
        connections,
    } = ctx;
    let (mut reader, writer) = tokio::io::split(stream);
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(writer)));
    let hello = read_frame(&mut reader).await.context("read hello")?;
    if hello.header.message_kind != MessageKind::Hello {
        return Err(anyhow!("first client frame must be Hello"));
    }
    let identity = parse_json::<HelloPayload>(&hello.payload)?;
    // The blocklist is checked here — before the ack, and by the daemon rather
    // than the app — because a kick has to hold against a viewer that still
    // holds a valid device token and re-dials on its own (spec §5).
    if trust == ClientTrust::Remote {
        if let Some(viewer_id) = identity.viewer_id.as_deref() {
            if blocked_viewers(&settings).contains(viewer_id) {
                send_error(
                    &writer,
                    hello.header.request_or_sequence,
                    anyhow!(
                        "viewer {viewer_id} is disconnected until Remote Control \
                         is turned off and on again"
                    ),
                )
                .await?;
                return Ok(());
            }
        }
    }
    send_json(
        &writer,
        MessageKind::HelloAck,
        hello.header.request_or_sequence,
        &HelloAckPayload {
            protocol_version: PROTOCOL_VERSION,
        },
    )
    .await?;

    // Registration starts here, past the point where a connection can be
    // refused, and the guard is what takes it back out however this function
    // ends — including an early `?` and an aborted task.
    let cancel = CancellationToken::new();
    let connection =
        ConnectionGuard::register(&connections, trust, Arc::clone(&writer), cancel.clone());
    let named_itself = match identity.viewer_id {
        Some(viewer_id) => connections.set_viewer(
            connection.id,
            ViewerIdentity {
                viewer_id,
                // A viewer that gives an id but no name is still a machine the
                // host must be able to see and kick.
                machine_name: identity
                    .machine_name
                    .unwrap_or_else(|| "Unknown Mac".into()),
            },
        ),
        None => false,
    };
    // A host is told the roster on its own `Hello`, so an app that has just
    // opened is immediately correct rather than correct at the next change —
    // but only when there is something to tell it. An empty roster is what a
    // client already believes, and sending it anyway would put an unsolicited
    // frame between every local `Hello` and the reply to its first request,
    // for the overwhelmingly common case of nobody watching at all.
    let nobody_is_watching = connections.viewers().is_empty();
    if (trust == ClientTrust::Local && !nobody_is_watching) || named_itself {
        connections.broadcast_presence().await;
    }

    let mut attachments = HashMap::<String, Attachment>::new();
    loop {
        let frame = tokio::select! {
            // A kicked connection stops mid-frame. Dropping a partly-read
            // frame would desynchronise the stream, which is exactly why
            // `next_frame` keeps one read future across its own wakes — but
            // here the stream is being torn down, so there is nothing left to
            // desynchronise.
            _ = cancel.cancelled() => break,
            frame = next_frame(
                &mut reader,
                trust,
                &settings,
                &settings_changed,
                &mut attachments,
                &connections,
                connection.id,
            ) => match frame {
                Ok(frame) => frame,
                Err(_) => break,
            },
        };
        let request = frame.header.request_or_sequence;
        // The remote trust boundary: a point read of the projection per
        // frame (microseconds; nothing to cache or invalidate), then the
        // authorizer. `None` for local clients, so the dispatch below is
        // byte-for-byte the local path unless it consults `allowed`.
        let allowed = (trust == ClientTrust::Remote).then(|| shared_sessions(&settings));
        if let Some(allowed) = &allowed {
            // A session un-shared since this client attached stops streaming
            // here too, in case `next_frame`'s wake was consumed elsewhere.
            attachments.retain(|id, _| allowed.contains(id));
            if let Err(reason) = authorize_remote(&frame, allowed) {
                if send_error(&writer, request, reason).await.is_err() {
                    break;
                }
                continue;
            }
        }
        /// Decodes this frame's JSON payload, or answers with an `Error`
        /// frame and moves on to the next frame.
        ///
        /// A malformed *payload* inside a structurally valid *frame* is a bad
        /// request, not a broken connection — one bad control frame used to
        /// propagate out of `handle_client` via `?` and drop the socket,
        /// blanking every pane in the native app until it reconnected
        /// (final whole-branch review, Minor #7). `MessageKind::Input`
        /// already got this right; this is that same shape, applied to every
        /// JSON-payload kind without re-indenting each arm.
        ///
        /// Envelope-level validation (the 1 MiB cap, the protocol-version
        /// byte, unknown message kinds, the peer-UID check) is deliberately
        /// untouched and still terminates the connection: those say the
        /// *stream* cannot be trusted, which is a different claim.
        ///
        /// Defined inside the loop so it can reach `frame`/`request`/`writer`
        /// — `macro_rules!` resolves outer identifiers at its definition
        /// site, not its call site.
        macro_rules! decode_payload {
            ($ty:ty) => {
                match parse_json::<$ty>(&frame.payload) {
                    Ok(value) => value,
                    Err(error) => {
                        if send_error(&writer, request, error).await.is_err() {
                            break;
                        }
                        continue;
                    }
                }
            };
        }
        let result = match frame.header.message_kind {
            MessageKind::ListSessions => {
                decode_payload!(serde_json::Value);
                let mut sessions = registry.list();
                if let Some(allowed) = &allowed {
                    sessions.retain(|id| allowed.contains(id));
                }
                send_json(
                    &writer,
                    MessageKind::SessionList,
                    request,
                    &SessionListPayload { sessions },
                )
                .await
            }
            MessageKind::CreateSession => {
                let create = decode_payload!(CreateSession);
                let id = create.id.clone();
                match registry.create_session(create) {
                    Ok(_) => {
                        send_json(
                            &writer,
                            MessageKind::SessionCreated,
                            request,
                            &SessionCreatedPayload { id },
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::Attach => {
                let attach = decode_payload!(AttachPayload);
                attachments.remove(&attach.id);
                match registry.get_attachable(&attach.id) {
                    Some(session) => {
                        let (state, subscription) = session
                            .attach_and_subscribe(attach.after_sequence, CLIENT_QUEUE_CAPACITY);
                        let empty_resume =
                            matches!(&state, AttachState::Resume(events) if events.is_empty());
                        // Presence learns about this attachment *before* the
                        // client is told about it, so "the viewer has its
                        // snapshot" implies "the host's roster names the pane":
                        // a `ListViewers` can never disagree with what the
                        // viewer can already see on screen.
                        sync_attached(
                            &connections,
                            connection.id,
                            attachments
                                .keys()
                                .cloned()
                                .chain([attach.id.clone()])
                                .collect(),
                        )
                        .await;
                        // The grid before the screen drawn on it: a viewer
                        // scales the host's size rather than imposing its own
                        // (phase 2 §1), so it must know that size to lay the
                        // snapshot out. The header carries the session's
                        // current sequence, the same stamp `Snapshot` gets —
                        // never this attach's request id, which would give one
                        // message kind two meanings for the same header field.
                        let (cols, rows) = session.size();
                        send_json(
                            &writer,
                            MessageKind::SessionResized,
                            session.sequence(),
                            &SessionSizePayload {
                                id: attach.id.clone(),
                                cols,
                                rows,
                            },
                        )
                        .await?;
                        send_attach_state(&writer, &attach.id, state).await?;
                        if empty_resume {
                            send_response(&writer, request).await?;
                        }
                        let forward_subscription = subscription.clone();
                        let forward_writer = Arc::clone(&writer);
                        let id = attach.id.clone();
                        let task = tokio::spawn(async move {
                            forward_events(forward_writer, id, forward_subscription).await;
                        });
                        attachments.insert(attach.id, Attachment { subscription, task });
                        Ok(())
                    }
                    None => {
                        send_error(&writer, request, anyhow!("session {} not found", attach.id))
                            .await
                    }
                }
            }
            MessageKind::Input => match decode_raw_payload(&frame.payload) {
                Ok((id, bytes)) => match registry.get(id) {
                    Some(session) => match session.write_input(bytes) {
                        Ok(()) => {
                            tracing::debug!(
                                target: "omniagent_latency",
                                stage = "daemon_pty_write",
                                request,
                                session_id = id,
                                bytes = bytes.len()
                            );
                            send_response(&writer, request).await
                        }
                        Err(error) => send_error(&writer, request, error).await,
                    },
                    None => send_error(&writer, request, anyhow!("session {id} not found")).await,
                },
                Err(error) => send_error(&writer, request, error).await,
            },
            MessageKind::Resize => {
                let resize = decode_payload!(ResizePayload);
                match registry.get(&resize.id) {
                    Some(session) => match session.resize(
                        resize.cols,
                        resize.rows,
                        resize.pixel_width,
                        resize.pixel_height,
                    ) {
                        Ok(()) => send_response(&writer, request).await,
                        Err(error) => send_error(&writer, request, error).await,
                    },
                    None => {
                        send_error(&writer, request, anyhow!("session {} not found", resize.id))
                            .await
                    }
                }
            }
            MessageKind::Interrupt => {
                let session = decode_payload!(SessionIdPayload);
                match registry.get(&session.id) {
                    Some(session) => match session.send_interrupt() {
                        Ok(()) => send_response(&writer, request).await,
                        Err(error) => send_error(&writer, request, error).await,
                    },
                    None => {
                        send_error(
                            &writer,
                            request,
                            anyhow!("session {} not found", session.id),
                        )
                        .await
                    }
                }
            }
            MessageKind::Kill => {
                let session = decode_payload!(SessionIdPayload);
                if registry.kill(&session.id) {
                    send_response(&writer, request).await
                } else {
                    send_error(
                        &writer,
                        request,
                        anyhow!("session {} not found", session.id),
                    )
                    .await
                }
            }
            MessageKind::Detach => {
                let session = decode_payload!(SessionIdPayload);
                attachments.remove(&session.id);
                send_response(&writer, request).await
            }
            MessageKind::GetSetting => {
                let setting = decode_payload!(SettingKey);
                let value = lock_store(&settings)
                    .and_then(|store| store.get_setting(&setting.key).map_err(Into::into));
                match value {
                    Ok(value) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"value": value}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::SetSetting => {
                let setting = decode_payload!(SettingValue);
                let result = lock_store(&settings)
                    .and_then(|store| {
                        store
                            .set_setting(&setting.key, &setting.value)
                            .map_err(Into::into)
                    });
                match result {
                    Ok(()) => {
                        // Every current waiter — the relay and each remote
                        // client parked in `next_frame` — must see this,
                        // plus one permit for a waiter between waits.
                        settings_changed.notify_waiters();
                        settings_changed.notify_one();
                        send_response(&writer, request).await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::BrainListProjects => {
                decode_payload!(serde_json::Value);
                let result = lock_store(&settings)
                    .and_then(|store| {
                        tools::list_projects(&tool_context(&store, &data_dir), &serde_json::json!({}))
                            .map_err(|error| anyhow!("{error}"))
                    });
                match result {
                    Ok(projects) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"projects": projects}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::BrainGetContext => {
                let payload = decode_payload!(BrainGetContextPayload);
                let result = lock_store(&settings)
                    .and_then(|store| {
                        tools::get_context(
                            &tool_context(&store, &data_dir),
                            &serde_json::json!({"project": payload.project}),
                        )
                        .map_err(|error| anyhow!("{error}"))
                    });
                match result {
                    Ok(context) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"context": context}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsStartIngest => {
                let payload = decode_payload!(RootsStartIngestPayload);
                let result = lock_store(&settings)
                    .and_then(|store| {
                        roots::start_ingest(data_dir.clone(), &store, &ingestion, &payload.path)
                    });
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsIngestionStatus => {
                decode_payload!(serde_json::Value);
                send_json(
                    &writer,
                    MessageKind::Response,
                    request,
                    &serde_json::json!({"status": ingestion.snapshot()}),
                )
                .await
            }
            MessageKind::RootsList => {
                decode_payload!(serde_json::Value);
                let result = lock_store(&settings)
                    .and_then(|store| roots::get_roots(&store));
                match result {
                    Ok(list) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"roots": list}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsBiggestProject => {
                decode_payload!(serde_json::Value);
                let result = lock_store(&settings)
                    .and_then(|store| roots::biggest_project(&store));
                match result {
                    Ok(project) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"project": project}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsAddProject => {
                let payload = decode_payload!(RootsAddProjectPayload);
                let result = lock_store(&settings)
                    .and_then(|store| {
                        roots::add_project(
                            &store,
                            &data_dir,
                            &ingestion,
                            &payload.path,
                            payload.name.as_deref(),
                        )
                    });
                match result {
                    Ok(project) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"project": project}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsRenameProject => {
                let payload = decode_payload!(RootsRenameProjectPayload);
                let result = lock_store(&settings)
                    .and_then(|store| roots::rename_project(&store, &payload.id, &payload.new_label));
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsPausedProjects => {
                decode_payload!(serde_json::Value);
                let result = lock_store(&settings)
                    .and_then(|store| roots::paused_projects(&store));
                match result {
                    Ok(projects) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"projects": projects}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsSetPaused => {
                let payload = decode_payload!(RootsSetPausedPayload);
                let result = lock_store(&settings)
                    .and_then(|store| {
                        roots::set_paused(&store, &payload.project, payload.paused)
                    });
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsStaleness => {
                decode_payload!(serde_json::Value);
                let result = lock_store(&settings)
                    .and_then(|store| roots::staleness(&store));
                match result {
                    Ok(projects) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"projects": projects}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsReingestProject => {
                let payload = decode_payload!(RootsReingestProjectPayload);
                let result = lock_store(&settings)
                    .and_then(|store| roots::reingest_project(&store, &payload.project));
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsRebuild => {
                decode_payload!(serde_json::Value);
                let result = roots::rebuild_and_reingest(&data_dir, &settings, &ingestion);
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::BrainSearch => {
                let payload = decode_payload!(BrainSearchPayload);
                let result = lock_store(&settings)
                    .and_then(|store| {
                        tools::search_brain(
                            &tool_context(&store, &data_dir),
                            &serde_json::json!({"query": payload.query, "scope": payload.scope}),
                        )
                        .map_err(|error| anyhow!("{error}"))
                    });
                match result {
                    Ok(results) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"results": results}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            // Both viewer-presence kinds are local-only, and neither is in
            // `authorize_remote`'s allow arms — a remote client is answered
            // with `Error` before ever reaching this dispatch (spec §7
            // invariant 2, pinned by `presence_is_local_only`).
            MessageKind::ListViewers => {
                decode_payload!(serde_json::Value);
                send_json(
                    &writer,
                    MessageKind::Response,
                    request,
                    &RemoteViewersPayload {
                        viewers: connections.viewers(),
                    },
                )
                .await
            }
            MessageKind::DisconnectViewer => {
                let payload = decode_payload!(DisconnectViewerPayload);
                // Block first, then kick: a viewer dropped before the row is
                // written could re-dial into the gap.
                let blocked = lock_store(&settings)
                    .and_then(|store| block_viewer(&store, &payload.viewer_id));
                match blocked {
                    Ok(()) => {
                        connections.cancel_viewer(&payload.viewer_id);
                        let replied = send_response(&writer, request).await;
                        connections.broadcast_presence().await;
                        replied
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::Hello => {
                send_error(&writer, request, anyhow!("Hello is only valid once")).await
            }
            _ => {
                send_error(
                    &writer,
                    request,
                    anyhow!("clients cannot send server message kinds"),
                )
                .await
            }
        };
        if result.is_err() {
            break;
        }
        sync_attached(
            &connections,
            connection.id,
            attachments.keys().cloned().collect(),
        )
        .await;
    }

    if cancel.is_cancelled() {
        // End the socket here rather than whenever the last clone of the
        // shared writer happens to go — the attachments' forwarding tasks
        // hold clones, and `abort()` does not drop them synchronously. A kick
        // the viewer only notices a beat later is a kick that looks broken.
        let _ = writer.lock().await.shutdown().await;
    }
    // Leave the registry here, where the roster push can be awaited, rather
    // than in the guard's `Drop`, where it cannot.
    connection.close().await;
    Ok(())
}

/// Keeps one connection in the registry for as long as it is being served.
///
/// `serve_client` has half a dozen ways out — a returned `Err`, a `?` inside
/// the dispatch, the loop ending, and the accept loop aborting the whole task
/// on shutdown — and a connection left behind in the registry is a viewer the
/// host is told is still watching. A guard is the only thing that covers all
/// of them.
struct ConnectionGuard {
    connections: ConnectionRegistry,
    id: u64,
}

impl ConnectionGuard {
    fn register(
        connections: &ConnectionRegistry,
        trust: ClientTrust,
        writer: SharedWriter,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            connections: connections.clone(),
            id: connections.register(trust, writer, cancel),
        }
    }

    /// The orderly exit: remove the entry and, if that changed the roster,
    /// wait for the hosts to be told. Idempotent — `Drop` then finds nothing.
    async fn close(&self) {
        if self.connections.remove(self.id) {
            self.connections.broadcast_presence().await;
        }
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        if !self.connections.remove(self.id) {
            return;
        }
        // Only the disorderly exits reach here (`close` already ran on the
        // orderly one). `Drop` cannot await, so the push is fire-and-forget;
        // if the runtime is already gone there is nobody left to tell, and a
        // host that missed it is corrected by its next roster.
        if let Ok(handle) = tokio::runtime::Handle::try_current() {
            let connections = self.connections.clone();
            handle.spawn(async move { connections.broadcast_presence().await });
        }
    }
}

/// Mirrors one connection's attachments into the registry, telling the hosts
/// when that changed what they are shown. The single call-site pattern for
/// "this viewer is now watching a different set of panes".
async fn sync_attached(
    connections: &ConnectionRegistry,
    connection: u64,
    attached: HashSet<String>,
) {
    if connections.set_attached(connection, attached) {
        connections.broadcast_presence().await;
    }
}

/// The session ids the projection shares right now — empty when the store
/// cannot be read, so a remote client is refused rather than let through.
fn shared_sessions(settings: &std::sync::Mutex<Store>) -> HashSet<String> {
    lock_store(settings)
        .map(|store| remote_session_ids(&store))
        .unwrap_or_default()
}

/// Reads the client's next frame.
///
/// A `Remote` client also wakes on `settings_changed`: the projection is
/// re-read and every attachment whose session it no longer shares is
/// dropped — closing its subscription and aborting its forwarding task —
/// so a passive viewer that sends no frames stops receiving output the
/// moment a workspace is un-shared (spec §2), not at its next `Detach`.
/// The read future is polled across those wakes rather than recreated:
/// `read_exact` is not cancel-safe, and dropping it mid-frame would
/// desynchronise the stream. `Local` clients take the plain read.
async fn next_frame<R: AsyncRead + Unpin>(
    reader: &mut R,
    trust: ClientTrust,
    settings: &std::sync::Mutex<Store>,
    settings_changed: &Notify,
    attachments: &mut HashMap<String, Attachment>,
    connections: &ConnectionRegistry,
    connection: u64,
) -> io::Result<Frame> {
    let mut read = std::pin::pin!(read_frame(reader));
    if trust == ClientTrust::Local {
        return read.await;
    }
    loop {
        tokio::select! {
            frame = &mut read => return frame,
            _ = settings_changed.notified() => {
                let allowed = shared_sessions(settings);
                attachments.retain(|id, _| allowed.contains(id));
                // The host's roster follows the prune here rather than at this
                // viewer's next frame — a passive viewer may not send one.
                sync_attached(
                    connections,
                    connection,
                    attachments.keys().cloned().collect(),
                )
                .await;
            }
        }
    }
}

/// Decodes a control frame's JSON payload.
///
/// A **zero-length** payload decodes as `{}`. Eight of the client message
/// kinds take no arguments at all (`ListSessions`, `BrainListProjects`,
/// `RootsIngestionStatus`, `RootsList`, `RootsBiggestProject`,
/// `RootsPausedProjects`, `RootsStaleness`, `RootsRebuild`) and the natural
/// way for a client to encode "no arguments" is an empty payload rather than
/// the two bytes `{}`. Rejecting that used to drop the whole connection
/// (final whole-branch review, Minor #7). The empty frame is unambiguous —
/// there is no message kind for which "" is a meaningful, differently-shaped
/// payload — so accepting it here rather than per-arm keeps one rule instead
/// of eight. For a kind that *does* have required fields it simply produces
/// a clearer "missing field `id`" error than "EOF while parsing a value",
/// and either way the caller answers with an `Error` frame.
fn parse_json<T: DeserializeOwned>(payload: &[u8]) -> Result<T> {
    let payload = if payload.is_empty() {
        b"{}".as_slice()
    } else {
        payload
    };
    serde_json::from_slice(payload).context("decode control JSON")
}

/// Locks the shared brain store, reopening it first if `brain.db` was
/// replaced underneath this process.
///
/// The daemon is the *second* long-lived holder of a `Store` handle against
/// one `brain.db` (the Tauri app is the first, and Task 7 mandates a period
/// where both run side by side). "Rebuild brain" — from either app — goes
/// through `brain_ingest::roots::rebuild_store`, which `unlink`s `brain.db`
/// and creates a fresh file at the same path, swapping only *its own*
/// process's handle. Everything the other process subsequently writes
/// (`layout`, `notifications`, `usage_analytics_v1`, every `roots::*` row)
/// would keep succeeding against the now-nameless inode and vanish for good
/// the next time that process restarted.
///
/// One `stat(2)` of an almost-always-cached path per control request is a
/// rounding error next to the SQLite work each of these handlers goes on to
/// do, so this is checked on every store operation rather than on a timer:
/// no window, no background task, no extra state to get wrong.
fn lock_store(settings: &std::sync::Mutex<Store>) -> Result<std::sync::MutexGuard<'_, Store>> {
    let mut guard = settings
        .lock()
        .map_err(|error| anyhow!("settings lock poisoned: {error}"))?;
    guard
        .reopen_if_replaced()
        .context("reopen the shared brain.db after it was rebuilt")?;
    Ok(guard)
}

/// Builds the `mcp_server::tools` dispatch context for one brain-store
/// request (`BrainListProjects`/`BrainGetContext`) — same
/// `ToolContext { store, data_dir }` shape `src-tauri`'s `BrainState::tool_ctx`
/// builds, so `list_projects`/`get_context` behave identically from either
/// caller.
fn tool_context<'a>(store: &'a Store, data_dir: &'a Path) -> ToolContext<'a> {
    ToolContext { store, data_dir }
}

async fn send_attach_state(writer: &SharedWriter, id: &str, state: AttachState) -> Result<()> {
    match state {
        AttachState::Snapshot { sequence, bytes } => {
            send_frame(
                writer,
                Frame::new(
                    MessageKind::Snapshot,
                    sequence,
                    encode_raw_payload(id, &bytes)?,
                ),
            )
            .await
        }
        AttachState::Resume(events) => {
            for event in events {
                send_event(writer, id, event).await?;
            }
            Ok(())
        }
    }
}

async fn forward_events(writer: SharedWriter, id: String, subscription: SessionSubscription) {
    loop {
        let receiver = subscription.clone();
        let event =
            tokio::task::spawn_blocking(move || receiver.recv_timeout(Duration::from_millis(250)))
                .await;
        match event {
            Ok(Ok(event)) => {
                let exited = matches!(event, SessionEvent::Exited { .. });
                if send_event(&writer, &id, event).await.is_err() || exited {
                    break;
                }
            }
            Ok(Err(std::sync::mpsc::RecvTimeoutError::Timeout)) => continue,
            _ => break,
        }
    }
}

async fn send_event(writer: &SharedWriter, id: &str, event: SessionEvent) -> Result<()> {
    let frame = match event {
        SessionEvent::Output { sequence, bytes } => Frame::new(
            MessageKind::Output,
            sequence,
            encode_raw_payload(id, &bytes)?,
        ),
        SessionEvent::ResyncRequired { sequence } => Frame::new(
            MessageKind::ResyncRequired,
            sequence,
            serde_json::to_vec(&ResyncRequiredPayload { id: id.into() })?,
        ),
        SessionEvent::Status {
            sequence,
            status,
            engine,
        } => Frame::new(
            MessageKind::SessionStatus,
            sequence,
            serde_json::to_vec(&SessionStatusPayload {
                id: id.into(),
                status,
                notify: matches!(
                    status,
                    crate::protocol::SessionStatus::Ready
                        | crate::protocol::SessionStatus::AwaitingApproval
                        | crate::protocol::SessionStatus::Error
                ),
                engine,
            })?,
        ),
        SessionEvent::Resized {
            sequence,
            cols,
            rows,
        } => Frame::new(
            MessageKind::SessionResized,
            sequence,
            serde_json::to_vec(&SessionSizePayload {
                id: id.into(),
                cols,
                rows,
            })?,
        ),
        SessionEvent::Exited {
            sequence,
            exit_code,
        } => Frame::new(
            MessageKind::SessionExited,
            sequence,
            serde_json::to_vec(&SessionExitedPayload {
                id: id.into(),
                exit_code,
            })?,
        ),
    };
    send_frame(writer, frame).await
}

async fn send_response(writer: &SharedWriter, request: u64) -> Result<()> {
    send_json(
        writer,
        MessageKind::Response,
        request,
        &ResponsePayload { ok: true },
    )
    .await
}

async fn send_error(
    writer: &SharedWriter,
    request: u64,
    error: impl std::fmt::Display,
) -> Result<()> {
    send_json(
        writer,
        MessageKind::Error,
        request,
        &ErrorPayload {
            message: error.to_string(),
        },
    )
    .await
}

async fn send_json(
    writer: &SharedWriter,
    kind: MessageKind,
    request_or_sequence: u64,
    value: &impl serde::Serialize,
) -> Result<()> {
    send_frame(
        writer,
        Frame::new(kind, request_or_sequence, serde_json::to_vec(value)?),
    )
    .await
}

async fn send_frame(writer: &SharedWriter, frame: Frame) -> Result<()> {
    write_frame(&mut *writer.lock().await, &frame)
        .await
        .context("write daemon frame")
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Both tests below mutate the process-global `OMNIAGENT_ADE_DATA_DIR`.
    /// They live here (this unit-test binary) rather than in
    /// `tests/server_protocol.rs`, which runs many concurrent tests that
    /// would race the env var — and they serialize against each other
    /// through this lock, held across the awaits (a tokio mutex, so no
    /// `await_holding_lock` lint).
    static ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// Task 6a regression: `bind()` — the real entry point `run_daemon`/
    /// `main.rs` use in production — must resolve the shared brain-store
    /// data directory via `brain_core::Store::default_data_dir()`, honoring
    /// `OMNIAGENT_ADE_DATA_DIR` exactly like every other crate does, and
    /// NOT derive it from the socket path's own parent directory. The bug
    /// this catches: `bind()` used to open `Store::open(runtime_dir)` (the
    /// socket's directory), which silently pointed every brain read — and
    /// the `layout` setting — at an unshared, essentially-empty `brain.db`
    /// instead of the one the app actually reads and writes.
    #[tokio::test]
    async fn bind_resolves_the_shared_data_dir_via_default_data_dir_not_the_socket_path() {
        let _env = ENV_LOCK.lock().await;
        let scratch = tempfile::tempdir().unwrap();
        let data_dir = scratch.path().join("shared-brain-data");
        std::env::set_var("OMNIAGENT_ADE_DATA_DIR", &data_dir);

        let socket_path = scratch.path().join("elsewhere-entirely").join("daemon.sock");
        let server = DaemonServer::bind(socket_path).await.unwrap();

        assert_eq!(server.data_dir, data_dir);
        assert_eq!(server.data_dir, Store::default_data_dir());
        // Proves the socket's own directory played no part in the result.
        assert_ne!(server.data_dir, scratch.path().join("elsewhere-entirely"));
        assert!(data_dir.join("brain.db").exists());

        drop(server);
        std::env::remove_var("OMNIAGENT_ADE_DATA_DIR");
    }

    /// The account-scoped workspace (2026-08-30 spec): with a pointer at the
    /// root, `bind()` opens `root/accounts/<id>` — and on the first such
    /// start moves the pre-account `brain.db` there, so the developer's
    /// existing layout, roots and transcripts come back under the account
    /// instead of being left behind at the root.
    #[tokio::test]
    async fn bind_follows_the_current_account_pointer_and_adopts_legacy_data_once() {
        let _env = ENV_LOCK.lock().await;
        let scratch = tempfile::tempdir().unwrap();
        let root = scratch.path().join("root");
        // The pre-account install: a brain.db at the root with a row in it.
        Store::open(&root).unwrap().set_setting("layout", "legacy-layout").unwrap();
        std::fs::write(Store::current_account_file(&root), "fc44b18d5588b1d6\n").unwrap();
        std::env::set_var("OMNIAGENT_ADE_DATA_DIR", &root);

        let socket_path = scratch.path().join("run").join("daemon.sock");
        let server = DaemonServer::bind(socket_path).await.unwrap();

        let account_dir = root.join("accounts").join("fc44b18d5588b1d6");
        assert_eq!(server.data_dir, account_dir);
        assert!(!root.join("brain.db").exists(), "the legacy brain.db moved");
        assert_eq!(
            server.settings.lock().unwrap().get_setting("layout").unwrap().as_deref(),
            Some("legacy-layout"),
            "and the daemon is serving it from the account dir"
        );

        drop(server);
        std::env::remove_var("OMNIAGENT_ADE_DATA_DIR");
    }
}
