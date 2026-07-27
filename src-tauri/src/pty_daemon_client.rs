//! Client module for `omniagent-pty-daemon`.
//!
//! Provides IPC communication over Unix Domain Sockets to the background
//! PTY daemon process, ensuring daemon liveness and process auto-launch.

use anyhow::{anyhow, Context, Result};
use base64::Engine as _;
use omniagent_pty_daemon::{DaemonRequest, DaemonResponse, DEFAULT_SOCKET_NAME};
use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const DAEMON_START_TIMEOUT: Duration = Duration::from_secs(3);
const DAEMON_START_POLL: Duration = Duration::from_millis(50);
const DAEMON_HEALTH_RETRY_WINDOW: Duration = Duration::from_millis(200);

pub struct PtyDaemonClient {
    socket_path: PathBuf,
}

impl PtyDaemonClient {
    pub fn new(socket_path: PathBuf) -> Self {
        Self { socket_path }
    }

    pub fn default_for_data_dir(data_dir: &Path) -> Self {
        Self::new(data_dir.join(DEFAULT_SOCKET_NAME))
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Sends a request to the daemon, auto-launching the daemon binary if not running.
    pub fn send_request(&self, req: &DaemonRequest) -> Result<DaemonResponse> {
        self.ensure_daemon_running()?;

        let mut stream = UnixStream::connect(&self.socket_path).with_context(|| {
            format!(
                "failed to connect to pty daemon at {}",
                self.socket_path.display()
            )
        })?;

        let mut payload = serde_json::to_vec(req)?;
        payload.push(b'\n');
        stream
            .write_all(&payload)
            .context("failed to send RPC request to daemon")?;
        stream.flush()?;

        let mut reader = BufReader::new(stream);
        let mut response_line = String::new();
        reader
            .read_line(&mut response_line)
            .context("failed to read RPC response from daemon")?;

        let resp: DaemonResponse = serde_json::from_str(&response_line)
            .with_context(|| format!("invalid JSON response from daemon: {response_line}"))?;

        if !resp.success {
            return Err(anyhow!(
                "Daemon RPC error: {}",
                resp.error.unwrap_or_else(|| "unknown error".into())
            ));
        }

        Ok(resp)
    }

    /// Verifies socket liveness and auto-launches daemon if absent.
    pub fn ensure_daemon_running(&self) -> Result<()> {
        if self.wait_until_alive(DAEMON_HEALTH_RETRY_WINDOW) {
            return Ok(());
        }

        self.remove_stale_socket_if_unreachable();

        self.spawn_daemon_process()?;

        if self.wait_until_alive(DAEMON_START_TIMEOUT) {
            return Ok(());
        }

        Err(anyhow!(
            "Failed to start omniagent-pty-daemon; socket {} not ready after spawn",
            self.socket_path.display()
        ))
    }

    pub fn is_alive(&self) -> bool {
        if let Ok(mut stream) = UnixStream::connect(&self.socket_path) {
            let req = DaemonRequest::ListSessions;
            if let Ok(mut payload) = serde_json::to_vec(&req) {
                payload.push(b'\n');
                if stream.write_all(&payload).is_ok() && stream.flush().is_ok() {
                    let mut reader = BufReader::new(stream);
                    let mut line = String::new();
                    if reader.read_line(&mut line).is_ok() {
                        if let Ok(resp) = serde_json::from_str::<DaemonResponse>(&line) {
                            return resp.success;
                        }
                    }
                }
            }
        }
        false
    }

    fn spawn_daemon_process(&self) -> Result<()> {
        let exe = resolve_daemon_binary()?;
        if let Some(parent) = self.socket_path.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!("failed to create daemon socket parent {}", parent.display())
            })?;
        }
        let mut cmd = Command::new(&exe);
        cmd.env("OMNIAGENT_PTY_SOCKET", &self.socket_path)
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        cmd.spawn().with_context(|| {
            format!(
                "Failed to spawn omniagent-pty-daemon from {}",
                exe.display()
            )
        })?;

        Ok(())
    }

    fn wait_until_alive(&self, timeout: Duration) -> bool {
        let start = Instant::now();
        while start.elapsed() < timeout {
            if self.is_alive() {
                return true;
            }
            thread::sleep(DAEMON_START_POLL);
        }
        false
    }

    fn remove_stale_socket_if_unreachable(&self) {
        if !self.socket_path.exists() {
            return;
        }
        if UnixStream::connect(&self.socket_path).is_err() {
            let _ = std::fs::remove_file(&self.socket_path);
        }
    }

    // High-level RPC operations

    pub fn create_session(
        &self,
        id: impl Into<String>,
        command: Vec<String>,
        cwd: Option<String>,
        env: HashMap<String, String>,
        cols: u16,
        rows: u16,
    ) -> Result<()> {
        let req = DaemonRequest::CreateSession {
            id: id.into(),
            command,
            cwd,
            env,
            cols,
            rows,
        };
        self.send_request(&req)?;
        Ok(())
    }

    pub fn attach_session(&self, id: impl Into<String>) -> Result<String> {
        let req = DaemonRequest::AttachSession { id: id.into() };
        let resp = self.send_request(&req)?;
        let screen = resp
            .result
            .and_then(|r| {
                r.get("screen")
                    .and_then(|s| s.as_str())
                    .map(|s| s.to_string())
            })
            .unwrap_or_default();
        Ok(screen)
    }

    pub fn send_input(&self, id: impl Into<String>, bytes: &[u8]) -> Result<()> {
        let data_base64 = base64::engine::general_purpose::STANDARD.encode(bytes);
        let req = DaemonRequest::SendInput {
            id: id.into(),
            data_base64,
        };
        self.send_request(&req)?;
        Ok(())
    }

    pub fn send_interrupt(&self, id: impl Into<String>) -> Result<()> {
        let req = DaemonRequest::SendInterrupt { id: id.into() };
        self.send_request(&req)?;
        Ok(())
    }

    pub fn resize_session(&self, id: impl Into<String>, cols: u16, rows: u16) -> Result<()> {
        let req = DaemonRequest::ResizeSession {
            id: id.into(),
            cols,
            rows,
        };
        self.send_request(&req)?;
        Ok(())
    }

    pub fn list_sessions(&self) -> Result<Vec<String>> {
        let req = DaemonRequest::ListSessions;
        let resp = self.send_request(&req)?;
        let sessions = resp
            .result
            .and_then(|r| {
                r.get("sessions").and_then(|s| s.as_array()).map(|arr| {
                    arr.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
            })
            .unwrap_or_default();
        Ok(sessions)
    }

    pub fn kill_session(&self, id: impl Into<String>) -> Result<bool> {
        let req = DaemonRequest::KillSession { id: id.into() };
        let resp = self.send_request(&req)?;
        let killed = resp
            .result
            .and_then(|r| r.get("killed").and_then(|k| k.as_bool()))
            .unwrap_or(false);
        Ok(killed)
    }
}

/// Resolves path to the `omniagent-pty-daemon` binary.
fn resolve_daemon_binary() -> Result<PathBuf> {
    if let Ok(current_exe) = std::env::current_exe() {
        if let Some(parent) = current_exe.parent() {
            let candidates = [
                parent.join("omniagent-pty-daemon"),
                parent.join("../Resources/omniagent-pty-daemon"),
            ];
            for candidate in candidates {
                if candidate.exists() {
                    return Ok(candidate);
                }
            }
        }
    }

    if let Ok(path) = which::which("omniagent-pty-daemon") {
        return Ok(path);
    }

    Err(anyhow!(
        "omniagent-pty-daemon binary not found near current executable or in PATH"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_path_resolution() {
        let dir = tempfile::tempdir().unwrap();
        let client = PtyDaemonClient::default_for_data_dir(dir.path());
        assert_eq!(client.socket_path(), dir.path().join("omniagent-pty.sock"));
    }
}
