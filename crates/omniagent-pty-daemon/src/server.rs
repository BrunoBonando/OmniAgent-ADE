use crate::protocol::{
    decode_raw_payload, encode_raw_payload, read_frame, write_frame, AttachPayload,
    BrainGetContextPayload, BrainSearchPayload, ErrorPayload, Frame, HelloAckPayload, HelloPayload,
    MessageKind, ResizePayload, ResponsePayload, ResyncRequiredPayload, RootsAddProjectPayload,
    RootsReingestProjectPayload, RootsRenameProjectPayload, RootsSetPausedPayload,
    RootsStartIngestPayload, SessionCreatedPayload, SessionExitedPayload, SessionIdPayload,
    SessionListPayload, SessionStatusPayload, SettingKey, SettingValue, PROTOCOL_VERSION,
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
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{oneshot, Mutex, Notify};
use tokio::task::{JoinHandle, JoinSet};

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
}

/// The write half of a client connection, shared between the dispatch loop
/// and every attachment's forwarding task.
pub type SharedWriter = Arc<Mutex<Box<dyn AsyncWrite + Unpin + Send>>>;

/// The settings row holding the remote-control projection — the only
/// workspaces (and their sessions) a remote client may ever see.
pub const REMOTE_CONTROL_KEY: &str = "remote_control";

/// The session ids the `remote_control` projection currently shares.
/// Missing row, unparsable JSON or an unexpected shape all mean "nothing".
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
        .flat_map(|workspace| {
            workspace["sessions"]
                .as_array()
                .cloned()
                .unwrap_or_default()
        })
        .filter_map(|session| session["id"].as_str().map(str::to_owned))
        .collect()
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
/// `Resize`/`Interrupt` whose session id is in `allowed`; `GetSetting`
/// only for the projection row itself. Everything else — `Kill`,
/// `CreateSession`, `SetSetting`, every Brain/Roots RPC — is refused.
pub fn authorize_remote(frame: &Frame, allowed: &HashSet<String>) -> Result<(), String> {
    let shared = |id: &str| {
        allowed
            .contains(id)
            .then_some(())
            .ok_or_else(|| format!("session {id} is not shared"))
    };
    match frame.header.message_kind {
        MessageKind::Hello | MessageKind::ListSessions | MessageKind::Detach => Ok(()),
        MessageKind::Attach | MessageKind::Resize | MessageKind::Interrupt => shared(
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
    pub async fn bind(socket_path: PathBuf) -> Result<Self> {
        Self::bind_with_data_dir(socket_path, Store::default_data_dir()).await
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
    } = ctx;
    let (mut reader, writer) = tokio::io::split(stream);
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(writer)));
    let hello = read_frame(&mut reader).await.context("read hello")?;
    if hello.header.message_kind != MessageKind::Hello {
        return Err(anyhow!("first client frame must be Hello"));
    }
    parse_json::<HelloPayload>(&hello.payload)?;
    send_json(
        &writer,
        MessageKind::HelloAck,
        hello.header.request_or_sequence,
        &HelloAckPayload {
            protocol_version: PROTOCOL_VERSION,
        },
    )
    .await?;

    let mut attachments = HashMap::<String, Attachment>::new();
    while let Ok(frame) = read_frame(&mut reader).await {
        let request = frame.header.request_or_sequence;
        // The remote trust boundary: a point read of the projection per
        // frame (microseconds; nothing to cache or invalidate), then the
        // authorizer. `None` for local clients, so the dispatch below is
        // byte-for-byte the local path unless it consults `allowed`.
        let allowed = (trust == ClientTrust::Remote).then(|| {
            lock_store(&settings)
                .map(|store| remote_session_ids(&store))
                .unwrap_or_default()
        });
        if let Some(allowed) = &allowed {
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
    }

    Ok(())
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

    /// Task 6a regression: `bind()` — the real entry point `run_daemon`/
    /// `main.rs` use in production — must resolve the shared brain-store
    /// data directory via `brain_core::Store::default_data_dir()`, honoring
    /// `OMNIAGENT_ADE_DATA_DIR` exactly like `src-tauri`'s `BrainState`
    /// does, and NOT derive it from the socket path's own parent directory.
    /// The bug this catches: `bind()` used to open `Store::open(runtime_dir)`
    /// (the socket's directory), which silently pointed every brain read —
    /// and the `layout` setting — at an unshared, essentially-empty
    /// `brain.db` instead of the one the app/web UI actually read and write.
    ///
    /// This is the only test in this crate that mutates the process-global
    /// `OMNIAGENT_ADE_DATA_DIR` env var. It lives here (a unit test inside
    /// `src/server.rs`, its own separate test binary) rather than in
    /// `tests/server_protocol.rs`, which runs many concurrent
    /// multi-threaded tests that would otherwise race a global env var
    /// mutation — `brain-core/tests/store_test.rs` documents the same
    /// concern for its own env-var test.
    #[tokio::test]
    async fn bind_resolves_the_shared_data_dir_via_default_data_dir_not_the_socket_path() {
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
}
