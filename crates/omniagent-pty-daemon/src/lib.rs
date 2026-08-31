//! Versioned persistent PTY daemon transport for OmniAgent ADE.

pub mod protocol;
mod relay;
mod server;
mod session;

pub use relay::{relay_config, run_relay, run_relay_with, DeviceCredential, DEVICE_TOKEN_KEY};
pub use server::{
    authorize_remote, peer_uid_allowed, remote_control_active, remote_session_ids, run_daemon,
    serve_client, ClientContext, ClientTrust, DaemonServer, SharedWriter, REMOTE_CONTROL_KEY,
};
pub use session::{
    AttachState, CreateSession, ManagedSession, SessionEvent, SessionRegistry, SessionSubscription,
    MAX_SESSIONS, SCROLLBACK_LINES,
};

pub const DEFAULT_SOCKET_NAME: &str = "omniagent-pty.sock";
