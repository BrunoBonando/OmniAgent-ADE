//! Versioned persistent PTY daemon transport for OmniAgent ADE.

pub mod protocol;
mod server;
mod session;

pub use server::{peer_uid_allowed, run_daemon, DaemonServer};
pub use session::{
    AttachState, CreateSession, ManagedSession, SessionEvent, SessionRegistry, SessionSubscription,
    MAX_SESSIONS, SCROLLBACK_LINES,
};

pub const DEFAULT_SOCKET_NAME: &str = "omniagent-pty.sock";
