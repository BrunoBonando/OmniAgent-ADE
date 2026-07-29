use crate::protocol::{
    decode_raw_payload, encode_raw_payload, read_frame, write_frame, AttachPayload, ErrorPayload,
    Frame, HelloAckPayload, HelloPayload, MessageKind, ResizePayload, ResponsePayload,
    ResyncRequiredPayload, SessionCreatedPayload, SessionExitedPayload, SessionIdPayload,
    SessionListPayload, SettingKey, SettingValue, PROTOCOL_VERSION,
};
use crate::{AttachState, CreateSession, SessionEvent, SessionRegistry, SessionSubscription};
use anyhow::{anyhow, Context, Result};
use serde::de::DeserializeOwned;
use std::collections::HashMap;
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::PathBuf;
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
}

impl DaemonServer {
    pub async fn bind(socket_path: PathBuf) -> Result<Self> {
        let runtime_dir = socket_path
            .parent()
            .ok_or_else(|| anyhow!("socket path needs a parent directory"))?;
        std::fs::create_dir_all(runtime_dir).context("create daemon runtime directory")?;
        std::fs::set_permissions(runtime_dir, std::fs::Permissions::from_mode(0o700))
            .context("secure daemon runtime directory")?;
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
                    let owner_uid = self.runtime_owner_uid;
                    clients.spawn(async move {
                        let _ = handle_client(stream, registry, owner_uid).await;
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
    runtime_owner_uid: u32,
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
                match registry.get(&attach.id) {
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
                        Ok(()) => send_response(&writer, request).await,
                        Err(error) => send_error(&writer, request, error).await,
                    },
                    None => send_error(&writer, request, anyhow!("session {id} not found")).await,
                },
                Err(error) => send_error(&writer, request, error).await,
            },
            MessageKind::Resize => {
                let resize = parse_json::<ResizePayload>(&frame.payload)?;
                match registry.get(&resize.id) {
                    Some(session) => match session.resize(resize.cols, resize.rows) {
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
                parse_json::<SettingKey>(&frame.payload)?;
                send_error(
                    &writer,
                    request,
                    anyhow!("settings backend is unavailable in protocol phase 1"),
                )
                .await
            }
            MessageKind::SetSetting => {
                parse_json::<SettingValue>(&frame.payload)?;
                send_error(
                    &writer,
                    request,
                    anyhow!("settings backend is unavailable in protocol phase 1"),
                )
                .await
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
