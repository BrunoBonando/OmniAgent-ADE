use anyhow::Result;
use base64::Engine as _;
use omniagent_pty_daemon::{run_daemon, DaemonRequest, DaemonResponse, DEFAULT_SOCKET_NAME};
use std::io::{self, BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::thread;
use std::time::Duration;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let args = std::env::args().skip(1).collect::<Vec<_>>();
    if !args.is_empty() && args[0] == "-L" {
        return run_legacy_new_session_compat(&args);
    }
    if !args.is_empty() && args[0] == "attach" {
        return run_attach_mode(&args[1..]);
    }

    let socket_path = std::env::var("OMNIAGENT_PTY_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            let mut p = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
            p.push(".omniagent-ade");
            p.push(DEFAULT_SOCKET_NAME);
            p
        });

    run_daemon(socket_path).await
}

fn run_legacy_new_session_compat(args: &[String]) -> Result<()> {
    if args.len() < 2 {
        return Ok(());
    }
    let socket_name = args[1].clone();
    let mut config_path: Option<PathBuf> = None;
    let mut i = 2usize;
    while i < args.len() {
        if args[i] == "-f" && i + 1 < args.len() {
            config_path = Some(PathBuf::from(&args[i + 1]));
            i += 2;
            continue;
        }
        break;
    }

    if i >= args.len() || args[i] != "new-session" {
        return Ok(());
    }
    i += 1;
    let mut session_name: Option<String> = None;
    while i < args.len() {
        if args[i] == "-s" && i + 1 < args.len() {
            session_name = Some(args[i + 1].clone());
            i += 2;
            continue;
        }
        if args[i] == "--" {
            i += 1;
            break;
        }
        i += 1;
    }

    let id = match session_name {
        Some(s) => s,
        None => return Ok(()),
    };
    let command = args[i..].to_vec();
    if command.is_empty() {
        return Ok(());
    }

    let socket_path = compat_socket_path(&socket_name, config_path.as_deref());
    ensure_daemon_for_socket(&socket_path)?;
    let _ = send_request(
        &socket_path,
        &DaemonRequest::CreateSession {
            id,
            command,
            cwd: std::env::current_dir()
                .ok()
                .map(|p| p.display().to_string()),
            env: std::env::vars().collect(),
            cols: 80,
            rows: 24,
        },
    )?;
    Ok(())
}

fn run_attach_mode(args: &[String]) -> Result<()> {
    let mut id: Option<String> = None;
    let mut socket: Option<PathBuf> = None;
    let mut i = 0usize;
    while i < args.len() {
        match args[i].as_str() {
            "--id" if i + 1 < args.len() => {
                id = Some(args[i + 1].clone());
                i += 2;
            }
            "--socket" if i + 1 < args.len() => {
                socket = Some(PathBuf::from(&args[i + 1]));
                i += 2;
            }
            _ => {
                i += 1;
            }
        }
    }

    let id = id.ok_or_else(|| anyhow::anyhow!("attach requires --id <session>"))?;
    let socket = socket.ok_or_else(|| anyhow::anyhow!("attach requires --socket <path>"))?;

    let input_id = id.clone();
    let input_socket = socket.clone();
    thread::spawn(move || {
        let mut stdin = io::stdin();
        let mut buf = [0u8; 4096];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => {
                    let _ = send_request(
                        &input_socket,
                        &DaemonRequest::SendInput {
                            id: input_id.clone(),
                            data_base64: base64::engine::general_purpose::STANDARD
                                .encode(&buf[..n]),
                        },
                    );
                }
                Err(_) => break,
            }
        }
    });

    let mut prev = String::new();
    let mut stdout = io::stdout();
    loop {
        let resp = send_request(&socket, &DaemonRequest::AttachSession { id: id.clone() });
        let Ok(resp) = resp else {
            break;
        };
        let screen = resp
            .result
            .as_ref()
            .and_then(|r| r.get("screen").and_then(|s| s.as_str()))
            .unwrap_or_default();
        if screen != prev {
            // Repaint full screen snapshot from daemon.
            write!(stdout, "\x1b[H\x1b[2J{screen}")?;
            stdout.flush()?;
            prev.clear();
            prev.push_str(screen);
        }
        thread::sleep(Duration::from_millis(120));
    }
    Ok(())
}

fn send_request(socket_path: &PathBuf, req: &DaemonRequest) -> Result<DaemonResponse> {
    let mut stream = UnixStream::connect(socket_path)?;
    let mut payload = serde_json::to_vec(req)?;
    payload.push(b'\n');
    stream.write_all(&payload)?;
    stream.flush()?;

    let mut reader = BufReader::new(stream);
    let mut line = String::new();
    reader.read_line(&mut line)?;
    let resp: DaemonResponse = serde_json::from_str(&line)?;
    if resp.success {
        Ok(resp)
    } else {
        Err(anyhow::anyhow!(
            "{}",
            resp.error
                .unwrap_or_else(|| "daemon request failed".to_string())
        ))
    }
}

fn ensure_daemon_for_socket(socket_path: &PathBuf) -> Result<()> {
    if wait_until_alive(socket_path, Duration::from_millis(200)) {
        return Ok(());
    }

    if socket_path.exists() && UnixStream::connect(socket_path).is_err() {
        let _ = std::fs::remove_file(socket_path);
    }
    if let Some(parent) = socket_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    std::process::Command::new(std::env::current_exe()?)
        .env("OMNIAGENT_PTY_SOCKET", socket_path)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .spawn()?;

    if wait_until_alive(socket_path, Duration::from_secs(3)) {
        return Ok(());
    }
    Err(anyhow::anyhow!(
        "daemon not ready at {}",
        socket_path.display()
    ))
}

fn wait_until_alive(socket_path: &PathBuf, timeout: Duration) -> bool {
    let start = std::time::Instant::now();
    while start.elapsed() < timeout {
        if send_request(socket_path, &DaemonRequest::ListSessions).is_ok() {
            return true;
        }
        thread::sleep(Duration::from_millis(50));
    }
    false
}

fn compat_socket_path(socket_name: &str, config: Option<&std::path::Path>) -> PathBuf {
    if let Some(cfg) = config {
        let parent = cfg.parent().unwrap_or_else(|| std::path::Path::new("/tmp"));
        return parent.join(format!("{socket_name}.sock"));
    }
    let mut p = dirs_next::home_dir().unwrap_or_else(|| PathBuf::from("/tmp"));
    p.push(".omniagent-ade");
    if socket_name == "omniagent-ade" {
        p.push(DEFAULT_SOCKET_NAME);
    } else {
        p.push(format!("{socket_name}.sock"));
    }
    p
}

mod dirs_next {
    use std::path::PathBuf;
    pub fn home_dir() -> Option<PathBuf> {
        std::env::var_os("HOME").map(PathBuf::from)
    }
}
