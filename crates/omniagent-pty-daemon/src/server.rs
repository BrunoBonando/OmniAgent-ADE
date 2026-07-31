use crate::protocol::{
    decode_raw_payload, encode_raw_payload, read_frame, write_frame, AttachPayload,
    BrainGetContextPayload, ErrorPayload, Frame, HelloAckPayload, HelloPayload, MessageKind,
    ResizePayload, ResponsePayload, ResyncRequiredPayload, SessionCreatedPayload,
    SessionExitedPayload, SessionIdPayload, SessionListPayload, SessionStatusPayload, SettingKey,
    SettingValue, PROTOCOL_VERSION,
};
use crate::{AttachState, CreateSession, SessionEvent, SessionRegistry, SessionSubscription};
use anyhow::{anyhow, Context, Result};
use brain_core::Store;
use mcp_server::tools::{self, ToolContext};
use serde::de::DeserializeOwned;
use std::collections::HashMap;
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::unix::OwnedWriteHalf;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{oneshot, Mutex};
use tokio::task::{JoinHandle, JoinSet};

const CLIENT_QUEUE_CAPACITY: usize = 64;

pub fn peer_uid_allowed(peer_uid: u32, runtime_owner_uid: u32) -> bool {
    peer_uid == runtime_owner_uid
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
        })
    }

    pub fn registry(&self) -> SessionRegistry {
        self.registry.clone()
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
        let mut clients = JoinSet::new();
        loop {
            tokio::select! {
                accepted = self.listener.accept() => {
                    let (stream, _) = accepted.context("accept daemon client")?;
                    let registry = self.registry.clone();
                    let settings = Arc::clone(&self.settings);
                    let owner_uid = self.runtime_owner_uid;
                    let data_dir = self.data_dir.clone();
                    clients.spawn(async move {
                        let _ = handle_client(stream, registry, settings, owner_uid, data_dir).await;
                    });
                }
                _ = &mut shutdown => break,
                Some(_) = clients.join_next(), if !clients.is_empty() => {}
            }
        }
        self.registry.shutdown();
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
    let server = DaemonServer::bind(socket_path).await?;
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

async fn handle_client(
    stream: UnixStream,
    registry: SessionRegistry,
    settings: Arc<std::sync::Mutex<Store>>,
    runtime_owner_uid: u32,
    data_dir: PathBuf,
) -> Result<()> {
    let peer_uid = stream.peer_cred().context("read peer credentials")?.uid();
    if !peer_uid_allowed(peer_uid, runtime_owner_uid) {
        return Err(anyhow!("peer UID {peer_uid} does not own daemon runtime"));
    }

    let (mut reader, writer) = stream.into_split();
    let writer = Arc::new(Mutex::new(writer));
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
        let result = match frame.header.message_kind {
            MessageKind::ListSessions => {
                parse_json::<serde_json::Value>(&frame.payload)?;
                send_json(
                    &writer,
                    MessageKind::SessionList,
                    request,
                    &SessionListPayload {
                        sessions: registry.list(),
                    },
                )
                .await
            }
            MessageKind::CreateSession => {
                let create = parse_json::<CreateSession>(&frame.payload)?;
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
                let attach = parse_json::<AttachPayload>(&frame.payload)?;
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
                let resize = parse_json::<ResizePayload>(&frame.payload)?;
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
                let session = parse_json::<SessionIdPayload>(&frame.payload)?;
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
                let session = parse_json::<SessionIdPayload>(&frame.payload)?;
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
                let session = parse_json::<SessionIdPayload>(&frame.payload)?;
                attachments.remove(&session.id);
                send_response(&writer, request).await
            }
            MessageKind::GetSetting => {
                let setting = parse_json::<SettingKey>(&frame.payload)?;
                let value = settings
                    .lock()
                    .map_err(|error| anyhow!("settings lock poisoned: {error}"))
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
                let setting = parse_json::<SettingValue>(&frame.payload)?;
                let result = settings
                    .lock()
                    .map_err(|error| anyhow!("settings lock poisoned: {error}"))
                    .and_then(|store| {
                        store
                            .set_setting(&setting.key, &setting.value)
                            .map_err(Into::into)
                    });
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::BrainListProjects => {
                parse_json::<serde_json::Value>(&frame.payload)?;
                let result = settings
                    .lock()
                    .map_err(|error| anyhow!("settings lock poisoned: {error}"))
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
                let payload = parse_json::<BrainGetContextPayload>(&frame.payload)?;
                let result = settings
                    .lock()
                    .map_err(|error| anyhow!("settings lock poisoned: {error}"))
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

fn parse_json<T: DeserializeOwned>(payload: &[u8]) -> Result<T> {
    serde_json::from_slice(payload).context("decode control JSON")
}

/// Builds the `mcp_server::tools` dispatch context for one brain-store
/// request (`BrainListProjects`/`BrainGetContext`) — same
/// `ToolContext { store, data_dir }` shape `src-tauri`'s `BrainState::tool_ctx`
/// builds, so `list_projects`/`get_context` behave identically from either
/// caller.
fn tool_context<'a>(store: &'a Store, data_dir: &'a Path) -> ToolContext<'a> {
    ToolContext { store, data_dir }
}

async fn send_attach_state(
    writer: &Arc<Mutex<OwnedWriteHalf>>,
    id: &str,
    state: AttachState,
) -> Result<()> {
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

async fn forward_events(
    writer: Arc<Mutex<OwnedWriteHalf>>,
    id: String,
    subscription: SessionSubscription,
) {
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

async fn send_event(
    writer: &Arc<Mutex<OwnedWriteHalf>>,
    id: &str,
    event: SessionEvent,
) -> Result<()> {
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

async fn send_response(writer: &Arc<Mutex<OwnedWriteHalf>>, request: u64) -> Result<()> {
    send_json(
        writer,
        MessageKind::Response,
        request,
        &ResponsePayload { ok: true },
    )
    .await
}

async fn send_error(
    writer: &Arc<Mutex<OwnedWriteHalf>>,
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
    writer: &Arc<Mutex<OwnedWriteHalf>>,
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

async fn send_frame(writer: &Arc<Mutex<OwnedWriteHalf>>, frame: Frame) -> Result<()> {
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
