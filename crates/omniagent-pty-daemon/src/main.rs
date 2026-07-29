use anyhow::Result;
use omniagent_pty_daemon::{run_daemon, DEFAULT_SOCKET_NAME};
use std::path::PathBuf;

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();
    let socket_path = std::env::var_os("OMNIAGENT_PTY_SOCKET")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/tmp"))
                .join(".omniagent-ade")
                .join(DEFAULT_SOCKET_NAME)
        });
    run_daemon(socket_path).await
}
