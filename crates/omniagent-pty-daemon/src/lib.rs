//! Versioned persistent PTY daemon transport for OmniAgent ADE.

mod activity;
mod connections;
pub mod protocol;
mod relay;
mod server;
mod session;

pub use activity::{append, ActivityContext, ActivityEntry, ActivityLog, RemoteActivityPayload};
pub use connections::{AssertedIdentity, ConnectionRegistry, LeaseHolder, ViewerIdentity};
pub use relay::{relay_config, run_relay, run_relay_with, DeviceCredential, DEVICE_TOKEN_KEY};
pub use server::{
    authorize_remote, peer_uid_allowed, protected_setting_key, remote_control_active, run_daemon,
    serve_client, sharing_should_be_live, ClientContext, ClientTrust, DaemonServer, SharedWriter,
    AUTH_ACCOUNT_EMAIL_KEY, BLOCKED_VIEWERS_KEY, LOCAL_ABSENCE_GRACE, REMOTE_SHARING_KEY,
};
pub use session::{
    AttachState, CreateSession, ManagedSession, SessionEvent, SessionRegistry, SessionSubscription,
    MAX_SESSIONS, SCROLLBACK_LINES,
};

pub const DEFAULT_SOCKET_NAME: &str = "omniagent-pty.sock";
