//! Compatibility adapter that preserves the old `tmux` interface while
//! backing persistence with `omniagent-pty-daemon`.

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

use omniagent_pty_daemon::{DaemonRequest, DaemonResponse, DEFAULT_SOCKET_NAME};

pub const DEFAULT_SOCKET: &str = "omniagent-ade";
pub const SESSION_NAME_PREFIX: &str = "omniagent-";
const MAX_SESSION_NAME_LEN: usize = 128;
const DAEMON_START_TIMEOUT: Duration = Duration::from_secs(3);
const DAEMON_START_POLL: Duration = Duration::from_millis(50);
const DAEMON_HEALTH_RETRY_WINDOW: Duration = Duration::from_millis(200);

/// Kept for compatibility with existing references.
pub const CONFIG_BODY: &str = "";

#[derive(Clone, Debug)]
pub struct Tmux {
    bin: PathBuf,
    socket: String,
    config: Option<PathBuf>,
    socket_path: PathBuf,
}

impl Tmux {
    pub fn resolve(socket: &str, _search_path: Option<&str>) -> Option<Self> {
        let bin = resolve_daemon_binary().unwrap_or_else(|| PathBuf::from("omniagent-pty-daemon"));
        Some(Self {
            bin,
            socket: socket.to_string(),
            config: None,
            socket_path: resolve_socket_path(socket, None),
        })
    }

    pub fn with_binary(bin: impl Into<PathBuf>, socket: &str) -> Self {
        Self {
            bin: bin.into(),
            socket: socket.to_string(),
            config: None,
            socket_path: resolve_socket_path(socket, None),
        }
    }

    pub fn with_config(mut self, config: impl Into<PathBuf>) -> Self {
        let cfg = config.into();
        self.socket_path = resolve_socket_path(&self.socket, Some(&cfg));
        self.config = Some(cfg);
        self
    }

    pub fn socket(&self) -> &str {
        &self.socket
    }

    pub fn binary(&self) -> &Path {
        &self.bin
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
        self.ensure_daemon_running()?;
        if self.has_session(name) {
            return Ok(true);
        }

        let req = DaemonRequest::CreateSession {
            id: name.to_string(),
            command: argv.to_vec(),
            cwd: Some(cwd.to_string_lossy().into_owned()),
            env: env.iter().cloned().collect::<HashMap<_, _>>(),
            cols: 80,
            rows: 24,
        };
        self.send_request(&req).map(|_| false)
    }

    /// argv for a PTY-side bridge client implemented by the daemon binary.
    pub fn attach_argv(&self, name: &str) -> Vec<String> {
        vec![
            self.bin.to_string_lossy().into_owned(),
            "attach".to_string(),
            "--id".to_string(),
            name.to_string(),
            "--socket".to_string(),
            self.socket_path.to_string_lossy().into_owned(),
        ]
    }

    pub fn kill_session(&self, name: &str) -> bool {
        let Ok(_) = self.ensure_daemon_running() else {
            return false;
        };
        let req = DaemonRequest::KillSession {
            id: name.to_string(),
        };
        self.send_request(&req)
            .ok()
            .and_then(|r| r.result)
            .and_then(|r| r.get("killed").and_then(|k| k.as_bool()))
            .unwrap_or(false)
    }

    pub fn pane_current_command(&self, _name: &str) -> Option<String> {
        let screen = self.capture_pane(_name)?;
        let last_line = screen
            .lines()
            .rev()
            .find(|l| !l.trim().is_empty())
            .unwrap_or("")
            .trim_end();
        let is_prompt = last_line.ends_with("%")
            || last_line.ends_with("% ")
            || last_line.ends_with("$")
            || last_line.ends_with("$ ")
            || last_line.ends_with("> ");
        if is_prompt {
            Some("zsh".to_string())
        } else {
            Some("running".to_string())
        }
    }

    pub fn capture_pane(&self, name: &str) -> Option<String> {
        let Ok(_) = self.ensure_daemon_running() else {
            return None;
        };
        let req = DaemonRequest::AttachSession {
            id: name.to_string(),
        };
        self.send_request(&req)
            .ok()
            .and_then(|r| r.result)
            .and_then(|r| r.get("screen").and_then(|s| s.as_str()).map(str::to_string))
    }

    pub fn resize_session(&self, name: &str, cols: u16, rows: u16) -> bool {
        let Ok(_) = self.ensure_daemon_running() else {
            return false;
        };
        let req = DaemonRequest::ResizeSession {
            id: name.to_string(),
            cols,
            rows,
        };
        self.send_request(&req).is_ok()
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
        let Ok(_) = self.ensure_daemon_running() else {
            return Vec::new();
        };
        let req = DaemonRequest::ListSessions;
        self.send_request(&req)
            .ok()
            .and_then(|r| r.result)
            .and_then(|r| {
                r.get("sessions").and_then(|v| {
                    v.as_array().map(|arr| {
                        arr.iter()
                            .filter_map(|v| v.as_str().map(str::to_string))
                            .collect::<Vec<_>>()
                    })
                })
            })
            .unwrap_or_default()
    }

    fn ensure_daemon_running(&self) -> Result<(), String> {
        if self.wait_until_alive(DAEMON_HEALTH_RETRY_WINDOW) {
            return Ok(());
        }

        self.remove_stale_socket_if_unreachable();
        if let Some(parent) = self.socket_path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }

        Command::new(&self.bin)
            .env("OMNIAGENT_PTY_SOCKET", &self.socket_path)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|e| format!("spawn daemon: {e}"))?;

        if self.wait_until_alive(DAEMON_START_TIMEOUT) {
            return Ok(());
        }

        Err(format!(
            "daemon socket {} not ready",
            self.socket_path.display()
        ))
    }

    fn is_alive(&self) -> bool {
        self.send_request(&DaemonRequest::ListSessions).is_ok()
    }

    fn send_request(&self, req: &DaemonRequest) -> Result<DaemonResponse, String> {
        let mut stream =
            UnixStream::connect(&self.socket_path).map_err(|e| format!("connect daemon: {e}"))?;

        let mut payload = serde_json::to_vec(req).map_err(|e| format!("encode request: {e}"))?;
        payload.push(b'\n');
        stream
            .write_all(&payload)
            .map_err(|e| format!("write request: {e}"))?;
        stream.flush().map_err(|e| format!("flush request: {e}"))?;

        let mut reader = BufReader::new(stream);
        let mut line = String::new();
        reader
            .read_line(&mut line)
            .map_err(|e| format!("read response: {e}"))?;
        let response: DaemonResponse =
            serde_json::from_str(&line).map_err(|e| format!("decode response: {e}"))?;
        if response.success {
            Ok(response)
        } else {
            Err(response
                .error
                .unwrap_or_else(|| "daemon request failed".to_string()))
        }
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
    let path = _data_dir.join("tmux.conf");
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
        if let Some(parent) = current_exe.parent() {
            let candidates = [
                parent.join("omniagent-pty-daemon"),
                parent.join("../omniagent-pty-daemon"),
                parent.join("../../omniagent-pty-daemon"),
            ];
            for c in candidates {
                if is_executable_file(&c) {
                    return Some(c);
                }
            }
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
}
