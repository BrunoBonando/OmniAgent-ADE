//! Versioned persistent PTY daemon transport for OmniAgent ADE.

mod connections;
pub mod protocol;
mod relay;
mod server;
mod session;

pub use connections::{ConnectionRegistry, LeaseHolder, ViewerIdentity};
pub use relay::{relay_config, run_relay, run_relay_with, DeviceCredential, DEVICE_TOKEN_KEY};
pub use server::{
    authorize_remote, peer_uid_allowed, protected_setting_key, remote_control_active,
    remote_session_ids, run_daemon, serve_client, sharing_should_be_live, ClientContext,
    ClientTrust, DaemonServer, SharedWriter, BLOCKED_VIEWERS_KEY, LOCAL_ABSENCE_GRACE,
    REMOTE_CONTROL_KEY, REMOTE_SHARING_KEY,
};
pub use session::{
    AttachState, CreateSession, ManagedSession, SessionEvent, SessionRegistry, SessionSubscription,
    MAX_SESSIONS, SCROLLBACK_LINES,
};

pub const DEFAULT_SOCKET_NAME: &str = "omniagent-pty.sock";
