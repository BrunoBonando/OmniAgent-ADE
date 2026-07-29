//! Persistent framed-protocol client for `omniagent-pty-daemon`.

use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex, Weak};
use std::time::Duration;

use omniagent_pty_daemon::protocol::{
    decode_raw_payload, encode_raw_payload, AttachPayload, AttentionPayload, ErrorPayload, Frame,
    Header, HelloAckPayload, HelloPayload, MessageKind, ResizePayload, SessionExitedPayload,
    SessionIdPayload, SessionListPayload, SessionStatusPayload, HEADER_LEN, PROTOCOL_VERSION,
};
use omniagent_pty_daemon::{CreateSession, DEFAULT_SOCKET_NAME};

pub const DEFAULT_SOCKET: &str = "omniagent-ade";
pub const SESSION_NAME_PREFIX: &str = "omniagent-";
const MAX_SESSION_NAME_LEN: usize = 128;
const DAEMON_START_TIMEOUT: Duration = Duration::from_secs(3);
const DAEMON_START_POLL: Duration = Duration::from_millis(50);
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(5);

/// Kept for compatibility with existing references.
pub const CONFIG_BODY: &str = "";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DaemonEvent {
    Snapshot {
        id: String,
        sequence: u64,
        bytes: Vec<u8>,
    },
    Output {
        id: String,
        sequence: u64,
        bytes: Vec<u8>,
    },
    Status(SessionStatusPayload),
    Attention {
        id: String,
    },
    ResyncRequired {
        id: String,
        sequence: u64,
    },
    Exited {
        id: String,
        sequence: u64,
        exit_code: Option<u32>,
    },
}

pub type DaemonEventSink = Arc<dyn Fn(DaemonEvent) + Send + Sync>;

#[derive(Clone)]
struct Handler {
    sequence: Option<u64>,
    sink: DaemonEventSink,
}

struct ClientRuntime {
    writer: Mutex<Option<(u64, UnixStream)>>,
    pending: Mutex<HashMap<u64, mpsc::Sender<Result<Frame, String>>>>,
    handlers: Mutex<HashMap<String, Handler>>,
    next_request: AtomicU64,
    generation: AtomicU64,
    connect: Mutex<()>,
}

impl Default for ClientRuntime {
    fn default() -> Self {
        Self {
            writer: Mutex::new(None),
            pending: Mutex::new(HashMap::new()),
            handlers: Mutex::new(HashMap::new()),
            next_request: AtomicU64::new(1),
            generation: AtomicU64::new(0),
            connect: Mutex::new(()),
        }
    }
}

#[derive(Clone)]
pub struct DaemonSessions {
    bin: PathBuf,
    socket: String,
    config: Option<PathBuf>,
    socket_path: PathBuf,
    runtime: Arc<ClientRuntime>,
}

impl std::fmt::Debug for DaemonSessions {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("DaemonSessions")
            .field("bin", &self.bin)
            .field("socket", &self.socket)
            .field("config", &self.config)
            .field("socket_path", &self.socket_path)
            .finish()
    }
}

impl DaemonSessions {
    pub fn new(socket_path: PathBuf) -> Self {
        Self {
            bin: resolve_daemon_binary().unwrap_or_default(),
            socket: DEFAULT_SOCKET.to_string(),
            config: None,
            socket_path,
            runtime: Arc::new(ClientRuntime::default()),
        }
    }

    pub fn default_for_data_dir(data_dir: &Path) -> Self {
        Self::new(data_dir.join(DEFAULT_SOCKET_NAME))
    }

    pub fn resolve(socket: &str, _search_path: Option<&str>) -> Option<Self> {
        let bin = resolve_daemon_binary()?;
        Some(Self {
            bin,
            socket: socket.to_string(),
            config: None,
            socket_path: resolve_socket_path(socket, None),
            runtime: Arc::new(ClientRuntime::default()),
        })
    }

    pub fn with_binary(bin: impl Into<PathBuf>, socket: &str) -> Self {
        Self {
            bin: bin.into(),
            socket: socket.to_string(),
            config: None,
            socket_path: resolve_socket_path(socket, None),
            runtime: Arc::new(ClientRuntime::default()),
        }
    }

    pub fn with_config(mut self, config: impl Into<PathBuf>) -> Self {
        let cfg = config.into();
        self.socket_path = resolve_socket_path(&self.socket, Some(&cfg));
        self.config = Some(cfg);
        self.runtime = Arc::new(ClientRuntime::default());
        self
    }

    pub fn socket(&self) -> &str {
        &self.socket
    }

    pub fn binary(&self) -> &Path {
        &self.bin
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    pub fn has_session(&self, name: &str) -> bool {
        self.list_sessions().iter().any(|s| s == name)
    }

    pub fn ensure_session(
        &self,
        name: &str,
        cwd: &Path,
        env: &[(String, String)],
        argv: &[String],
    ) -> Result<bool, String> {
        if self.has_session(name) {
            return Ok(true);
        }

        self.create_session(CreateSession {
            id: name.to_string(),
            command: argv.to_vec(),
            cwd: Some(cwd.to_string_lossy().into_owned()),
            env: env.iter().cloned().collect::<HashMap<_, _>>(),
            cols: 80,
            rows: 24,
            transcript_path: None,
        })
        .map(|_| false)
    }

    pub fn kill_session(&self, name: &str) -> bool {
        self.kill(name).is_ok()
    }

    pub fn resize_session(&self, name: &str, cols: u16, rows: u16) -> bool {
        self.resize(name, cols, rows).is_ok()
    }

    pub fn kill_server(&self) -> bool {
        let names = self.list_sessions();
        let mut ok = true;
        for name in names {
            ok &= self.kill_session(&name);
        }
        ok
    }

    pub fn list_sessions(&self) -> Vec<String> {
        self.list().unwrap_or_default()
    }

    pub fn list(&self) -> Result<Vec<String>, String> {
        let response = self.request_json(MessageKind::ListSessions, &serde_json::json!({}))?;
        expect_kind(&response, MessageKind::SessionList)?;
        serde_json::from_slice::<SessionListPayload>(&response.payload)
            .map(|payload| payload.sessions)
            .map_err(|error| format!("decode session list: {error}"))
    }

    pub fn create_session(&self, create: CreateSession) -> Result<(), String> {
        let response = self.request_json(MessageKind::CreateSession, &create)?;
        expect_kind(&response, MessageKind::SessionCreated)
    }

    pub fn attach_session(
        &self,
        id: &str,
        after_sequence: Option<u64>,
        sink: DaemonEventSink,
    ) -> Result<(), String> {
        self.ensure_daemon_running()?;
        self.runtime.handlers.lock().unwrap().insert(
            id.to_string(),
            Handler {
                sequence: after_sequence,
                sink,
            },
        );
        self.send_attach(id, after_sequence)
    }

    pub fn detach_session(&self, id: &str) -> Result<(), String> {
        let response =
            self.request_json(MessageKind::Detach, &SessionIdPayload { id: id.into() })?;
        expect_kind(&response, MessageKind::Response)?;
        self.runtime.handlers.lock().unwrap().remove(id);
        Ok(())
    }

    pub fn reattach_session(&self, id: &str, after_sequence: Option<u64>) -> Result<(), String> {
        if !self.runtime.handlers.lock().unwrap().contains_key(id) {
            return Err(format!("session {id} is not attached"));
        }
        self.send_attach(id, after_sequence)
    }

    pub fn send_input(&self, id: &str, bytes: &[u8]) -> Result<(), String> {
        let response = self.request_frame(Frame::new(
            MessageKind::Input,
            self.next_request(),
            encode_raw_payload(id, bytes).map_err(|error| error.to_string())?,
        ))?;
        expect_kind(&response, MessageKind::Response)
    }

    pub fn send_interrupt(&self, id: &str) -> Result<(), String> {
        let response =
            self.request_json(MessageKind::Interrupt, &SessionIdPayload { id: id.into() })?;
        expect_kind(&response, MessageKind::Response)
    }

    pub fn resize(&self, id: &str, cols: u16, rows: u16) -> Result<(), String> {
        let response = self.request_json(
            MessageKind::Resize,
            &ResizePayload {
                id: id.into(),
                cols,
                rows,
            },
        )?;
        expect_kind(&response, MessageKind::Response)
    }

    pub fn kill(&self, id: &str) -> Result<(), String> {
        let response = self.request_json(MessageKind::Kill, &SessionIdPayload { id: id.into() })?;
        expect_kind(&response, MessageKind::Response)?;
        self.runtime.handlers.lock().unwrap().remove(id);
        Ok(())
    }

    pub fn is_alive(&self) -> bool {
        self.ensure_daemon_running().is_ok()
    }

    pub fn ensure_daemon_running(&self) -> Result<(), String> {
        let _connect = self.runtime.connect.lock().unwrap();
        if self.runtime.writer.lock().unwrap().is_some() {
            return Ok(());
        }

        if let Ok(stream) = self.connect_stream() {
            return self.install_connection(stream);
        }
        self.remove_stale_socket_if_unreachable();
        if let Some(parent) = self.socket_path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|error| format!("create daemon runtime directory: {error}"))?;
        }
        if self.bin.as_os_str().is_empty() {
            return Err("omniagent-pty-daemon binary not found".into());
        }
        Command::new(&self.bin)
            .env("OMNIAGENT_PTY_SOCKET", &self.socket_path)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| format!("spawn daemon: {error}"))?;

        let deadline = std::time::Instant::now() + DAEMON_START_TIMEOUT;
        while std::time::Instant::now() < deadline {
            if let Ok(stream) = self.connect_stream() {
                return self.install_connection(stream);
            }
            std::thread::sleep(DAEMON_START_POLL);
        }
        Err(format!(
            "daemon socket {} not ready",
            self.socket_path.display()
        ))
    }

    fn connect_stream(&self) -> Result<UnixStream, String> {
        let mut stream = UnixStream::connect(&self.socket_path)
            .map_err(|error| format!("connect daemon: {error}"))?;
        stream
            .set_read_timeout(Some(Duration::from_secs(1)))
            .map_err(|error| format!("set daemon handshake timeout: {error}"))?;
        let request = self.next_request();
        write_sync_frame(
            &mut stream,
            &Frame::new(
                MessageKind::Hello,
                request,
                serde_json::to_vec(&HelloPayload {
                    client: "omniagent-ade-tauri".into(),
                })
                .map_err(|error| format!("encode daemon hello: {error}"))?,
            ),
        )?;
        let response = read_sync_frame(&mut stream)?;
        expect_kind(&response, MessageKind::HelloAck)?;
        if response.header.request_or_sequence != request {
            return Err("daemon hello response used the wrong request id".into());
        }
        let ack: HelloAckPayload = serde_json::from_slice(&response.payload)
            .map_err(|error| format!("decode daemon hello: {error}"))?;
        if ack.protocol_version != PROTOCOL_VERSION {
            return Err(format!(
                "daemon protocol version {} is unsupported",
                ack.protocol_version
            ));
        }
        stream
            .set_read_timeout(None)
            .map_err(|error| format!("clear daemon handshake timeout: {error}"))?;
        Ok(stream)
    }

    fn install_connection(&self, stream: UnixStream) -> Result<(), String> {
        let reader = stream
            .try_clone()
            .map_err(|error| format!("clone daemon socket: {error}"))?;
        let generation = self.runtime.generation.fetch_add(1, Ordering::Relaxed) + 1;
        let runtime = Arc::downgrade(&self.runtime);
        std::thread::spawn(move || read_loop(reader, runtime, generation));

        // Publish while holding the writer lock, then replay subscriptions
        // through that same guard. Other callers cannot interleave a frame
        // until every restored session has reattached at its last sequence.
        let mut writer = self.runtime.writer.lock().unwrap();
        *writer = Some((generation, stream));
        let handlers = self.runtime.handlers.lock().unwrap().clone();
        for (id, handler) in handlers {
            let request = self.next_request();
            let (_, stream) = writer.as_mut().expect("writer installed above");
            if let Err(error) = write_sync_frame(
                stream,
                &Frame::new(
                    MessageKind::Attach,
                    request,
                    serde_json::to_vec(&AttachPayload {
                        id,
                        after_sequence: handler.sequence,
                    })
                    .map_err(|error| format!("encode daemon reattach: {error}"))?,
                ),
            ) {
                writer.take();
                return Err(error);
            }
        }
        Ok(())
    }

    fn request_json(
        &self,
        kind: MessageKind,
        value: &impl serde::Serialize,
    ) -> Result<Frame, String> {
        self.request_frame(Frame::new(
            kind,
            self.next_request(),
            serde_json::to_vec(value).map_err(|error| format!("encode daemon request: {error}"))?,
        ))
    }

    fn request_frame(&self, frame: Frame) -> Result<Frame, String> {
        self.ensure_daemon_running()?;
        let request = frame.header.request_or_sequence;
        let (tx, rx) = mpsc::channel();
        self.runtime.pending.lock().unwrap().insert(request, tx);
        if let Err(error) = self.write(&frame) {
            self.runtime.pending.lock().unwrap().remove(&request);
            return Err(error);
        }
        let response = match rx.recv_timeout(RESPONSE_TIMEOUT) {
            Ok(response) => response?,
            Err(error) => {
                self.runtime.pending.lock().unwrap().remove(&request);
                return Err(format!("daemon response timed out: {error}"));
            }
        };
        if response.header.message_kind == MessageKind::Error {
            let payload: ErrorPayload = serde_json::from_slice(&response.payload)
                .map_err(|error| format!("decode daemon error: {error}"))?;
            return Err(payload.message);
        }
        Ok(response)
    }

    fn send_attach(&self, id: &str, after_sequence: Option<u64>) -> Result<(), String> {
        self.write(&Frame::new(
            MessageKind::Attach,
            self.next_request(),
            serde_json::to_vec(&AttachPayload {
                id: id.into(),
                after_sequence,
            })
            .map_err(|error| format!("encode daemon attach: {error}"))?,
        ))
    }

    fn write(&self, frame: &Frame) -> Result<(), String> {
        let mut writer = self.runtime.writer.lock().unwrap();
        let (_, stream) = writer
            .as_mut()
            .ok_or_else(|| "daemon connection is not available".to_string())?;
        if let Err(error) = write_sync_frame(stream, frame) {
            writer.take();
            return Err(error);
        }
        Ok(())
    }

    fn next_request(&self) -> u64 {
        self.runtime.next_request.fetch_add(1, Ordering::Relaxed)
    }

    fn remove_stale_socket_if_unreachable(&self) {
        if self.socket_path.exists() && UnixStream::connect(&self.socket_path).is_err() {
            let _ = std::fs::remove_file(&self.socket_path);
        }
    }
}

fn expect_kind(frame: &Frame, expected: MessageKind) -> Result<(), String> {
    if frame.header.message_kind == expected {
        Ok(())
    } else {
        Err(format!(
            "expected daemon {:?}, received {:?}",
            expected, frame.header.message_kind
        ))
    }
}

fn read_sync_frame(stream: &mut UnixStream) -> Result<Frame, String> {
    let mut header = [0; HEADER_LEN];
    stream
        .read_exact(&mut header)
        .map_err(|error| format!("read daemon frame header: {error}"))?;
    let header = Header::decode(header).map_err(|error| error.to_string())?;
    let mut payload = vec![0; header.payload_length as usize];
    stream
        .read_exact(&mut payload)
        .map_err(|error| format!("read daemon frame payload: {error}"))?;
    Ok(Frame { header, payload })
}

fn write_sync_frame(stream: &mut UnixStream, frame: &Frame) -> Result<(), String> {
    stream
        .write_all(&frame.encode().map_err(|error| error.to_string())?)
        .map_err(|error| format!("write daemon frame: {error}"))?;
    stream
        .flush()
        .map_err(|error| format!("flush daemon frame: {error}"))
}

fn read_loop(mut stream: UnixStream, runtime: Weak<ClientRuntime>, generation: u64) {
    while let Ok(frame) = read_sync_frame(&mut stream) {
        let Some(runtime) = runtime.upgrade() else {
            return;
        };
        match frame.header.message_kind {
            MessageKind::SessionList
            | MessageKind::SessionCreated
            | MessageKind::Response
            | MessageKind::Error => {
                if let Some(pending) = runtime
                    .pending
                    .lock()
                    .unwrap()
                    .remove(&frame.header.request_or_sequence)
                {
                    let _ = pending.send(Ok(frame));
                }
            }
            MessageKind::Snapshot | MessageKind::Output => {
                if let Ok((id, bytes)) = decode_raw_payload(&frame.payload) {
                    let event = if frame.header.message_kind == MessageKind::Snapshot {
                        DaemonEvent::Snapshot {
                            id: id.into(),
                            sequence: frame.header.request_or_sequence,
                            bytes: bytes.to_vec(),
                        }
                    } else {
                        DaemonEvent::Output {
                            id: id.into(),
                            sequence: frame.header.request_or_sequence,
                            bytes: bytes.to_vec(),
                        }
                    };
                    dispatch_event(&runtime, id, frame.header.request_or_sequence, event);
                }
            }
            MessageKind::SessionStatus => {
                if let Ok(status) = serde_json::from_slice::<SessionStatusPayload>(&frame.payload) {
                    let id = status.id.clone();
                    dispatch_event(
                        &runtime,
                        &id,
                        frame.header.request_or_sequence,
                        DaemonEvent::Status(status),
                    );
                }
            }
            MessageKind::Attention => {
                if let Ok(attention) = serde_json::from_slice::<AttentionPayload>(&frame.payload) {
                    let id = attention.id;
                    dispatch_event(
                        &runtime,
                        &id,
                        frame.header.request_or_sequence,
                        DaemonEvent::Attention { id: id.clone() },
                    );
                }
            }
            MessageKind::ResyncRequired => {
                if let Ok(payload) = serde_json::from_slice::<
                    omniagent_pty_daemon::protocol::ResyncRequiredPayload,
                >(&frame.payload)
                {
                    let id = payload.id;
                    dispatch_event(
                        &runtime,
                        &id,
                        frame.header.request_or_sequence,
                        DaemonEvent::ResyncRequired {
                            id: id.clone(),
                            sequence: frame.header.request_or_sequence,
                        },
                    );
                }
            }
            MessageKind::SessionExited => {
                if let Ok(payload) = serde_json::from_slice::<SessionExitedPayload>(&frame.payload)
                {
                    let id = payload.id;
                    dispatch_event(
                        &runtime,
                        &id,
                        frame.header.request_or_sequence,
                        DaemonEvent::Exited {
                            id: id.clone(),
                            sequence: frame.header.request_or_sequence,
                            exit_code: payload.exit_code,
                        },
                    );
                }
            }
            _ => {}
        }
    }

    let Some(runtime) = runtime.upgrade() else {
        return;
    };
    let mut writer = runtime.writer.lock().unwrap();
    if matches!(writer.as_ref(), Some((current, _)) if *current == generation) {
        writer.take();
        for (_, pending) in runtime.pending.lock().unwrap().drain() {
            let _ = pending.send(Err("daemon connection closed".into()));
        }
    }
}

fn dispatch_event(runtime: &ClientRuntime, id: &str, sequence: u64, event: DaemonEvent) {
    let sink = {
        let mut handlers = runtime.handlers.lock().unwrap();
        let Some(handler) = handlers.get_mut(id) else {
            return;
        };
        handler.sequence = Some(sequence);
        handler.sink.clone()
    };
    sink(event);
}

pub(crate) fn is_executable_file(path: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(path)
            .map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    }
    #[cfg(not(unix))]
    {
        path.is_file()
    }
}

pub fn write_config(_data_dir: &Path) -> Option<PathBuf> {
    let path = _data_dir.join("daemon.conf");
    let _ = std::fs::create_dir_all(_data_dir);
    std::fs::write(&path, CONFIG_BODY).ok()?;
    Some(path)
}

pub fn session_name(id: &str) -> String {
    let mut name = String::with_capacity(SESSION_NAME_PREFIX.len() + id.len());
    name.push_str(SESSION_NAME_PREFIX);
    for c in id.chars() {
        if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
            name.push(c);
        } else {
            name.push('_');
        }
    }
    name.truncate(MAX_SESSION_NAME_LEN);
    name
}

fn resolve_socket_path(socket: &str, config: Option<&Path>) -> PathBuf {
    if let Some(cfg) = config {
        let parent = cfg.parent().unwrap_or_else(|| Path::new("/tmp"));
        return parent.join(format!("{socket}.sock"));
    }

    let mut base = home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
    base.push(".omniagent-ade");
    if socket == DEFAULT_SOCKET {
        base.push(DEFAULT_SOCKET_NAME);
    } else {
        base.push(format!("{socket}.sock"));
    }
    base
}

fn resolve_daemon_binary() -> Option<PathBuf> {
    if let Ok(path) = std::env::var("OMNIAGENT_PTY_DAEMON_BIN") {
        let p = PathBuf::from(path);
        if is_executable_file(&p) {
            return Some(p);
        }
    }
    if let Ok(path) = std::env::var("CARGO_BIN_EXE_omniagent-pty-daemon") {
        let p = PathBuf::from(path);
        if is_executable_file(&p) {
            return Some(p);
        }
    }

    if let Ok(current_exe) = std::env::current_exe() {
        if let Some(path) = resolve_daemon_binary_from(&current_exe) {
            return Some(path);
        }
    }
    if let Some(workspace_root) = find_workspace_root() {
        let status = Command::new("cargo")
            .arg("build")
            .arg("-p")
            .arg("omniagent-pty-daemon")
            .arg("--bin")
            .arg("omniagent-pty-daemon")
            .current_dir(&workspace_root)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .ok();
        if matches!(status, Some(s) if s.success()) {
            let built = workspace_root.join("target/debug/omniagent-pty-daemon");
            if is_executable_file(&built) {
                return Some(built);
            }
        }
    }
    which::which("omniagent-pty-daemon").ok()
}

/// Finds the daemon next to a development executable or in a packaged app's
/// resources. The app-bundle path is deliberately checked before any PATH
/// fallback in [`resolve_daemon_binary`].
pub fn resolve_daemon_binary_from(exe: &Path) -> Option<PathBuf> {
    let parent = exe.parent()?;
    let sibling = parent.join("omniagent-pty-daemon");
    if is_executable_file(&sibling) {
        return Some(sibling);
    }

    let resources = parent.parent()?.join("Resources/omniagent-pty-daemon");
    is_executable_file(&resources).then_some(resources)
}

fn home_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

fn find_workspace_root() -> Option<PathBuf> {
    let mut dir = std::env::current_dir().ok()?;
    loop {
        if dir.join("Cargo.toml").is_file() && dir.join("src-tauri").is_dir() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn session_name_is_deterministic_and_prefixed() {
        assert_eq!(session_name("sess-abc-1"), "omniagent-sess-abc-1");
        assert_eq!(session_name("sess-abc-1"), session_name("sess-abc-1"));
        assert_ne!(session_name("sess-abc-1"), session_name("sess-abc-2"));
    }

    #[test]
    fn session_name_replaces_special_chars() {
        assert_eq!(session_name("a.b:c d/e"), "omniagent-a_b_c_d_e");
    }

    #[test]
    fn session_name_is_length_bounded() {
        let long = "x".repeat(500);
        assert!(session_name(&long).len() <= MAX_SESSION_NAME_LEN);
    }

    #[test]
    fn resolves_packaged_daemon_from_app_resources() {
        let tmp = tempfile::tempdir().unwrap();
        let macos_dir = tmp.path().join("OmniAgent.app/Contents/MacOS");
        let resources_dir = tmp.path().join("OmniAgent.app/Contents/Resources");
        std::fs::create_dir_all(&macos_dir).unwrap();
        std::fs::create_dir_all(&resources_dir).unwrap();
        let exe = macos_dir.join("omniagent-ade");
        let daemon = resources_dir.join("omniagent-pty-daemon");
        std::fs::write(&exe, b"fake").unwrap();
        std::fs::write(&daemon, b"fake").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&daemon, std::fs::Permissions::from_mode(0o755)).unwrap();
        }

        assert_eq!(resolve_daemon_binary_from(&exe), Some(daemon));
    }
}
