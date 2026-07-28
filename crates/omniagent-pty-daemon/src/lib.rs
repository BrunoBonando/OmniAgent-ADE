//! Native PTY Daemon for OmniAgent-ADE.
//!
//! Provides process decoupling across app restarts without external dependencies.
//! Spawns master PTY instances via `portable_pty`, tracks virtual terminal state via `vt100`,
//! and listens on a local Unix socket (`omniagent-pty.sock`) for client connections.

use anyhow::{anyhow, Context, Result};
use base64::Engine as _;
use portable_pty::{CommandBuilder, NativePtySystem, PtySize, PtySystem};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::io::{BufRead, BufReader as StdBufReader, Read, Write};
use std::os::unix::net::UnixStream as StdUnixStream;
use std::path::Path;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tracing::{error, info, warn};

/// Default socket path relative to data_dir
pub const DEFAULT_SOCKET_NAME: &str = "omniagent-pty.sock";

/// Daemon Request Frame
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "snake_case")]
pub enum DaemonRequest {
    CreateSession {
        id: String,
        command: Vec<String>,
        cwd: Option<String>,
        env: HashMap<String, String>,
        cols: u16,
        rows: u16,
    },
    AttachSession {
        id: String,
    },
    SendInput {
        id: String,
        data_base64: String,
    },
    SendInterrupt {
        id: String,
    },
    ResizeSession {
        id: String,
        cols: u16,
        rows: u16,
    },
    ListSessions,
    KillSession {
        id: String,
    },
}

/// Daemon Response Frame
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DaemonResponse {
    pub success: bool,
    pub error: Option<String>,
    pub result: Option<Value>,
}

impl DaemonResponse {
    pub fn ok(result: Value) -> Self {
        Self {
            success: true,
            error: None,
            result: Some(result),
        }
    }

    pub fn err(msg: impl Into<String>) -> Self {
        Self {
            success: false,
            error: Some(msg.into()),
            result: None,
        }
    }
}

/// A running PTY session inside the daemon
pub struct ManagedSession {
    pub id: String,
    pub master: Arc<Mutex<Box<dyn portable_pty::MasterPty + Send>>>,
    pub writer: Arc<Mutex<Box<dyn Write + Send>>>,
    pub vt_parser: Arc<Mutex<vt100::Parser>>,
    pub child: Arc<Mutex<Box<dyn portable_pty::Child + Send + Sync>>>,
}

fn resize_virtual_terminal(parser: &mut vt100::Parser, cols: u16, rows: u16) {
    parser.set_size(rows, cols);
}

#[cfg(test)]
mod tests {
    #[test]
    fn virtual_terminal_resize_tracks_the_pty_size() {
        let mut parser = vt100::Parser::new(24, 80, 1000);

        super::resize_virtual_terminal(&mut parser, 140, 42);

        assert_eq!(parser.screen().size(), (42, 140));
    }
}

impl ManagedSession {
    pub fn write_input(&self, data: &[u8]) -> Result<()> {
        let mut writer = self
            .writer
            .lock()
            .map_err(|e| anyhow!("mutex poison: {e}"))?;
        writer.write_all(data).context("write to master PTY")?;
        writer.flush().context("flush master PTY")?;
        Ok(())
    }

    pub fn send_interrupt(&self) -> Result<()> {
        // Send SIGINT byte (\x03 / Ctrl+C)
        self.write_input(b"\x03")
    }

    pub fn resize(&self, cols: u16, rows: u16) -> Result<()> {
        let master = self
            .master
            .lock()
            .map_err(|e| anyhow!("mutex poison: {e}"))?;
        master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("resize PTY")?;
        let mut parser = self
            .vt_parser
            .lock()
            .map_err(|e| anyhow!("mutex poison: {e}"))?;
        resize_virtual_terminal(&mut parser, cols, rows);
        Ok(())
    }

    pub fn screen_contents(&self) -> String {
        if let Ok(vt) = self.vt_parser.lock() {
            let screen = vt.screen();
            screen.contents()
        } else {
            String::new()
        }
    }
}

/// Registry of all active PTY sessions managed by the daemon
#[derive(Clone, Default)]
pub struct SessionRegistry {
    sessions: Arc<Mutex<HashMap<String, Arc<ManagedSession>>>>,
}

impl SessionRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn create_session(
        &self,
        id: String,
        command: Vec<String>,
        cwd: Option<String>,
        env: HashMap<String, String>,
        cols: u16,
        rows: u16,
    ) -> Result<Arc<ManagedSession>> {
        let pty_system = NativePtySystem::default();
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("openpty failed")?;

        let mut cmd = if command.is_empty() {
            CommandBuilder::new("/bin/zsh")
        } else {
            let mut builder = CommandBuilder::new(&command[0]);
            for arg in &command[1..] {
                builder.arg(arg);
            }
            builder
        };

        if let Some(dir) = cwd {
            cmd.cwd(dir);
        }

        for (k, v) in env {
            cmd.env(k, v);
        }

        let child = pair
            .slave
            .spawn_command(cmd)
            .context("spawn command in slave PTY")?;
        let master = pair.master;
        let writer = master.take_writer().context("take master writer")?;
        let mut reader = master.try_clone_reader().context("take master reader")?;

        let vt_parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, 1000)));
        let vt_clone = Arc::clone(&vt_parser);

        // Spawn background reader thread to update virtual terminal state
        std::thread::spawn(move || {
            let mut buf = [0u8; 4096];
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => break, // EOF
                    Ok(n) => {
                        if let Ok(mut vt) = vt_clone.lock() {
                            vt.process(&buf[..n]);
                        }
                    }
                    Err(_) => break,
                }
            }
        });

        let session = Arc::new(ManagedSession {
            id: id.clone(),
            master: Arc::new(Mutex::new(master)),
            writer: Arc::new(Mutex::new(writer)),
            vt_parser,
            child: Arc::new(Mutex::new(child)),
        });

        let mut lock = self
            .sessions
            .lock()
            .map_err(|e| anyhow!("mutex poison: {e}"))?;
        lock.insert(id, Arc::clone(&session));

        Ok(session)
    }

    pub fn get(&self, id: &str) -> Option<Arc<ManagedSession>> {
        self.sessions.lock().ok()?.get(id).cloned()
    }

    pub fn list(&self) -> Vec<String> {
        self.sessions
            .lock()
            .map(|s| s.keys().cloned().collect())
            .unwrap_or_default()
    }

    pub fn kill(&self, id: &str) -> bool {
        if let Ok(mut sessions) = self.sessions.lock() {
            if let Some(session) = sessions.remove(id) {
                if let Ok(mut child) = session.child.lock() {
                    let _ = child.kill();
                }
                return true;
            }
        }
        false
    }
}

/// Runs the IPC listener loop on a Unix domain socket
pub async fn run_daemon(socket_path: PathBuf) -> Result<()> {
    if let Some(parent) = socket_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    if socket_path.exists() {
        if socket_responds_to_list_sessions(&socket_path) {
            info!(
                "OmniAgent PTY Daemon already running at {}; reusing existing instance",
                socket_path.display()
            );
            return Ok(());
        }
        let _ = std::fs::remove_file(&socket_path);
    }

    let listener = match UnixListener::bind(&socket_path) {
        Ok(listener) => listener,
        Err(_bind_err) if socket_responds_to_list_sessions(&socket_path) => {
            info!(
                "OmniAgent PTY Daemon raced with another starter at {}; reusing existing \
                 instance",
                socket_path.display()
            );
            return Ok(());
        }
        Err(bind_err) => {
            return Err(bind_err)
                .with_context(|| format!("Failed to bind socket at {}", socket_path.display()));
        }
    };

    info!(
        "OmniAgent PTY Daemon listening on {}",
        socket_path.display()
    );
    let registry = SessionRegistry::new();

    loop {
        match listener.accept().await {
            Ok((stream, _)) => {
                let reg = registry.clone();
                tokio::spawn(async move {
                    if let Err(e) = handle_client(stream, reg).await {
                        warn!("Client connection error: {e}");
                    }
                });
            }
            Err(e) => {
                error!("UnixListener accept error: {e}");
            }
        }
    }
}

fn socket_responds_to_list_sessions(socket_path: &Path) -> bool {
    let mut stream = match StdUnixStream::connect(socket_path) {
        Ok(s) => s,
        Err(_) => return false,
    };
    let mut payload = match serde_json::to_vec(&DaemonRequest::ListSessions) {
        Ok(p) => p,
        Err(_) => return false,
    };
    payload.push(b'\n');
    if stream.write_all(&payload).is_err() || stream.flush().is_err() {
        return false;
    }

    let mut line = String::new();
    let mut reader = StdBufReader::new(stream);
    if reader.read_line(&mut line).is_err() {
        return false;
    }
    serde_json::from_str::<DaemonResponse>(&line)
        .map(|resp| resp.success)
        .unwrap_or(false)
}

async fn handle_client(stream: UnixStream, registry: SessionRegistry) -> Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut lines = BufReader::new(reader).lines();

    while let Some(line) = lines.next_line().await? {
        if line.trim().is_empty() {
            continue;
        }

        let request: DaemonRequest = match serde_json::from_str(&line) {
            Ok(req) => req,
            Err(e) => {
                let resp = DaemonResponse::err(format!("Invalid JSON request: {e}"));
                let mut bytes = serde_json::to_vec(&resp)?;
                bytes.push(b'\n');
                writer.write_all(&bytes).await?;
                continue;
            }
        };

        let response = match request {
            DaemonRequest::CreateSession {
                id,
                command,
                cwd,
                env,
                cols,
                rows,
            } => match registry.create_session(id.clone(), command, cwd, env, cols, rows) {
                Ok(_) => DaemonResponse::ok(serde_json::json!({ "id": id, "created": true })),
                Err(e) => DaemonResponse::err(e.to_string()),
            },
            DaemonRequest::AttachSession { id } => match registry.get(&id) {
                Some(sess) => DaemonResponse::ok(serde_json::json!({
                    "id": id,
                    "screen": sess.screen_contents(),
                })),
                None => DaemonResponse::err(format!("Session {id} not found")),
            },
            DaemonRequest::SendInput { id, data_base64 } => match registry.get(&id) {
                Some(sess) => {
                    match base64::engine::general_purpose::STANDARD.decode(&data_base64) {
                        Ok(bytes) => match sess.write_input(&bytes) {
                            Ok(_) => DaemonResponse::ok(serde_json::json!({ "sent": bytes.len() })),
                            Err(e) => DaemonResponse::err(e.to_string()),
                        },
                        Err(e) => DaemonResponse::err(format!("Invalid base64: {e}")),
                    }
                }
                None => DaemonResponse::err(format!("Session {id} not found")),
            },
            DaemonRequest::SendInterrupt { id } => match registry.get(&id) {
                Some(sess) => match sess.send_interrupt() {
                    Ok(_) => DaemonResponse::ok(serde_json::json!({ "interrupted": true })),
                    Err(e) => DaemonResponse::err(e.to_string()),
                },
                None => DaemonResponse::err(format!("Session {id} not found")),
            },
            DaemonRequest::ResizeSession { id, cols, rows } => match registry.get(&id) {
                Some(sess) => match sess.resize(cols, rows) {
                    Ok(_) => DaemonResponse::ok(serde_json::json!({ "resized": true })),
                    Err(e) => DaemonResponse::err(e.to_string()),
                },
                None => DaemonResponse::err(format!("Session {id} not found")),
            },
            DaemonRequest::ListSessions => {
                DaemonResponse::ok(serde_json::json!({ "sessions": registry.list() }))
            }
            DaemonRequest::KillSession { id } => {
                let killed = registry.kill(&id);
                DaemonResponse::ok(serde_json::json!({ "id": id, "killed": killed }))
            }
        };

        let mut bytes = serde_json::to_vec(&response)?;
        bytes.push(b'\n');
        writer.write_all(&bytes).await?;
    }

    Ok(())
}
