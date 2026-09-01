use crate::connections::{
    AssertedIdentity, ConnectionRegistry, LeaseHolder, PresenceFeed, ViewerIdentity,
};
use crate::protocol::{
    decode_raw_payload, encode_raw_payload, read_frame, read_handshake_frame, write_frame,
    AttachPayload, BrainGetContextPayload, BrainSearchPayload, DirectoryEntryPayload,
    DirectoryListingPayload, DisconnectViewerPayload, ErrorPayload, Frame, HelloAckPayload,
    HelloPayload, ListDirectoryPayload, MessageKind, RemoteViewersPayload, ResizePayload,
    ResponsePayload, ResyncRequiredPayload, RootsAddProjectPayload, RootsReingestProjectPayload,
    RootsRenameProjectPayload, RootsSetPausedPayload, RootsStartIngestPayload,
    SessionCreatedPayload, SessionExitedPayload, SessionIdPayload, SessionListPayload,
    SessionSizePayload, SessionStatusPayload, SettingKey, SettingValue, LIST_DIRECTORY_MAX_ENTRIES,
    PROTOCOL_VERSION,
};
use crate::{AttachState, CreateSession, SessionEvent, SessionRegistry, SessionSubscription};
use anyhow::{anyhow, Context, Result};
use brain_core::Store;
use brain_ingest::roots::{self, IngestionState};
use mcp_server::tools::{self, ToolContext};
use serde::de::DeserializeOwned;
use std::collections::{HashMap, HashSet};
use std::io;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{oneshot, Mutex, Notify};
use tokio::task::{JoinHandle, JoinSet};
use tokio_util::sync::CancellationToken;

const CLIENT_QUEUE_CAPACITY: usize = 64;

pub fn peer_uid_allowed(peer_uid: u32, runtime_owner_uid: u32) -> bool {
    peer_uid == runtime_owner_uid
}

/// How much a client connection is trusted.
///
/// `Local` is the unix-socket path: the accept loop has already checked
/// the peer UID, and the client may do everything the protocol offers.
/// `Remote` is a connection relayed from another device
/// (`docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
/// §3): it never took the peer-UID path, so every frame passes
/// [`authorize_remote`] before dispatch. Since phase 3 that is a boundary
/// around *kinds* and the protected settings rows, not around a set of
/// sessions — the lease holder drives the whole machine.
///
/// **`Remote` carries the relay's assertion about who is connecting** (spec
/// §9), and that is a type-level decision rather than a convenience. The
/// alternative — a `Remote` unit variant plus an identity read out of the
/// client's `Hello` — puts the caller's own words within reach of every check
/// written downstream. Here there is nothing to reach for: the only
/// `AssertedIdentity` in the process arrived on the control channel, a remote
/// connection cannot be constructed without one, and a local connection has
/// none at all because the peer-UID check already answered the same question
/// better.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ClientTrust {
    Local,
    /// A connection the relay opened for a viewer, with what the relay and
    /// Cloudflare observed about it. Boxed so the common `Local` case does not
    /// pay for the payload on every connection and every registry entry.
    Remote(Box<AssertedIdentity>),
}

impl ClientTrust {
    /// Whether this connection came in over the relay. Prefer destructuring
    /// where the assertion is wanted; this is for the arms that only need to
    /// know which side of the boundary they are on.
    pub fn is_remote(&self) -> bool {
        matches!(self, Self::Remote(_))
    }

    /// Whether this connection came through the unix socket's peer-UID check.
    pub fn is_local(&self) -> bool {
        matches!(self, Self::Local)
    }

    /// What the relay asserted, or `None` for a local connection.
    pub fn asserted(&self) -> Option<&AssertedIdentity> {
        match self {
            Self::Local => None,
            Self::Remote(asserted) => Some(asserted),
        }
    }
}

/// Everything one client connection needs from the daemon — cloned out of
/// [`DaemonServer`] per connection by [`DaemonServer::client_context`] so
/// [`serve_client`] can run over any byte stream, not only the unix socket.
#[derive(Clone)]
pub struct ClientContext {
    pub registry: SessionRegistry,
    pub settings: Arc<std::sync::Mutex<Store>>,
    pub data_dir: PathBuf,
    pub ingestion: IngestionState,
    /// Poked after every successful `SetSetting`; the relay task watches it
    /// to notice `remote_control` / device-token changes without polling.
    pub settings_changed: Arc<Notify>,
    /// Every live client connection (phase 2 spec §5) — what makes presence
    /// and the kick possible at all. Constructed once by
    /// [`DaemonServer::bind_with_data_dir`] and cloned into every connection.
    pub connections: ConnectionRegistry,
}

/// The write half of a client connection, shared between the dispatch loop
/// and every attachment's forwarding task.
pub type SharedWriter = Arc<Mutex<Box<dyn AsyncWrite + Unpin + Send>>>;

/// The settings row holding the remote-control projection: the host's tree of
/// workspaces, session groups and panes.
///
/// It was the phase-1/2 authorization boundary — the only sessions a remote
/// client could see or attach to. **It is not any more** (phase 3 spec §3):
/// [`authorize_remote`] does not read it, and the lease holder reaches every
/// session on the host. The row survives only because the viewer's sidebar
/// still renders from it, and it goes with that sidebar in a later task.
pub const REMOTE_CONTROL_KEY: &str = "remote_control";

/// The settings row holding the machine-wide sharing switch (spec §2):
/// `{"enabled": true|false}`. It replaces the phase-1/2 pair of
/// `remote_control` (the projection) and `remote_control_workspaces` (the
/// intent) — sharing is no longer per-workspace, so there is no list.
pub const REMOTE_SHARING_KEY: &str = "remote_sharing";

/// The settings row listing viewer ids the host has disconnected — a JSON
/// array of strings, `["<viewer_id>", …]` (phase 2 spec §5).
///
/// **The daemon writes this row.** A kick that only dropped the socket would
/// not hold: a viewer with a valid device token re-dials within 30 s, and it
/// has to be refused even with the host app closed, so the enforcer has to be
/// the one keeping the list.
///
/// **The app clears the whole row** — a single `SetSetting(…, "[]")` — when
/// Remote Control is switched on for any workspace. The list is global rather
/// than per-workspace because it answers "which machines may not reach this
/// Mac", and turning sharing back on anywhere is the deliberate act that
/// forgives them. Both sides writing one small array is safe here: the two
/// writes are a human action apart.
pub const BLOCKED_VIEWERS_KEY: &str = "remote_control_blocked";

/// The viewer ids currently blocked. An unreadable store, a missing row or
/// unparsable JSON all mean "nobody is blocked": this list only ever *adds*
/// refusals, so failing open here refuses nothing that the trust boundary in
/// [`authorize_remote`] would have let through anyway.
fn blocked_viewers(settings: &std::sync::Mutex<Store>) -> HashSet<String> {
    lock_store(settings)
        .ok()
        .and_then(|store| store.get_setting(BLOCKED_VIEWERS_KEY).ok().flatten())
        .and_then(|raw| serde_json::from_str::<Vec<String>>(&raw).ok())
        .map(|ids| ids.into_iter().collect())
        .unwrap_or_default()
}

/// Adds one viewer id to [`BLOCKED_VIEWERS_KEY`], read-modify-write. A row
/// that does not parse as an array of ids is replaced rather than inherited —
/// the alternative is a kick that silently does not hold.
fn block_viewer(store: &Store, viewer_id: &str) -> Result<()> {
    let mut ids: Vec<String> = store
        .get_setting(BLOCKED_VIEWERS_KEY)?
        .and_then(|raw| serde_json::from_str(&raw).ok())
        .unwrap_or_default();
    if !ids.iter().any(|id| id == viewer_id) {
        ids.push(viewer_id.to_owned());
    }
    store
        .set_setting(BLOCKED_VIEWERS_KEY, &serde_json::to_string(&ids)?)
        .map_err(Into::into)
}

/// The session ids the `remote_control` projection names. Missing row,
/// unparsable JSON or an unexpected shape all mean "nothing".
///
/// **No longer an authorization input** (phase 3 spec §3): this was the
/// allowlist every remote `Attach`/`Input`/`Interrupt` was checked against,
/// and session-id confinement is gone. It is kept for the viewer's sidebar,
/// which still renders the projection, and goes with it in a later task.
///
/// Two projection shapes are read, because a Mac that has not updated yet
/// still writes the first one (phase 2 spec §2, "Compatibility"):
///
/// - **v2** (`"version": 2`) carries the host's real tree, so a `sessions[]`
///   entry is a session *group* whose `panes[]` hold the attachable ids. The
///   group's own id is a UI grouping and is never a daemon session, so it is
///   deliberately not collected — an idle group (`"panes": []`) shares
///   nothing at all, and the machine stays reachable through
///   [`remote_control_active`] instead.
/// - **v1** flattened panes into `sessions[]`, so there each entry *is* the
///   attachable id. The absence of a `panes` array is what selects this.
///
/// Either way the id collected is a **pane** id rather than a session-group
/// id. Not every pane is a PTY, though: an editor or browser pane carries an
/// id in the projection exactly like a terminal pane does. Those are harmless
/// because the daemon never registers a session under them — a remote `Attach`
/// passes the allowlist and then gets "session not found" from the registry
/// (`a_shared_pane_with_no_session_behind_it_cannot_be_attached`) — but what
/// this returns is a set of shared pane ids, not a promise that each one names
/// a terminal.
pub fn remote_session_ids(store: &Store) -> HashSet<String> {
    let Some(raw) = store.get_setting(REMOTE_CONTROL_KEY).ok().flatten() else {
        return HashSet::new();
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(&raw) else {
        return HashSet::new();
    };
    value["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|workspace| workspace["sessions"].as_array())
        .flatten()
        .flat_map(|session| {
            let panes = session["panes"].as_array();
            let v2 = panes.into_iter().flatten();
            let v1 = panes.is_none().then_some(session);
            v2.chain(v1)
        })
        .filter_map(|pane| pane["id"].as_str().map(str::to_owned))
        .collect()
}

/// How long sharing survives the last local connection going away (spec §2).
///
/// An app reconnect must not flap a live remote session, and a
/// `rebuild-app.sh` restart — which quits the app, replaces the bundle and
/// relaunches — is routine here. Five seconds is far longer than either takes
/// and far shorter than a machine's app staying away for any other reason.
pub const LOCAL_ABSENCE_GRACE: Duration = Duration::from_secs(5);

/// Whether this machine should be reachable at all: the three-way test of
/// spec §2, and the daemon's answer to "is the icon in the menu bar".
///
/// 1. the sharing switch is on ([`remote_control_active`]),
/// 2. a device token exists, so this Mac is paired with the relay,
/// 3. the host's own app is attached — or was, within
///    [`LOCAL_ABSENCE_GRACE`].
///
/// **Condition 3 is what makes chaining structurally impossible** (spec §3,
/// "One remote session per machine, in either direction"), and that is a
/// security property rather than a nicety. A Mac that is driving another has
/// swapped its single app connection away from its own daemon: it has no
/// local connection, so this test fails on it, its relay control channel
/// closes and it refuses everyone inbound. So a machine being driven can
/// never be made to reach onward to a third, and a machine that is driving
/// cannot simultaneously be driven — with no rule to enforce, no list to keep
/// and nothing to get out of sync. When the driving app comes home its local
/// connection returns and sharing resumes by itself.
///
/// The corollary is the thing to protect, and it is **the app's half of an
/// invariant this function cannot hold alone**: while it drives another
/// machine, the app must not still be attached to its own daemon. A second
/// connection kept for any reason satisfies condition 3 on a machine that is
/// busy driving, and chaining becomes possible again with nothing here
/// failing and no test going red. The phase-2 app model — a connection per
/// remote machine alongside the local one (`RemoteMachinesModel`,
/// `WorkspaceWindowController.connection(forPane:)`) — is exactly that shape,
/// which is why spec §1/§3 replace it with a single connection the window
/// *swaps*. Anyone adding a second local connection is undoing this.
///
/// Both callers pass the same two things: `relay.rs` asks it to decide
/// whether to hold the control channel, and the `Hello` arm asks it again
/// before admitting a remote client, because the relay's answer can be up to
/// a recheck interval stale and a refusal is cheap.
pub fn sharing_should_be_live(store: &Store, connections: &ConnectionRegistry) -> bool {
    remote_control_active(store)
        && store
            .get_setting(crate::relay::DEVICE_TOKEN_KEY)
            .ok()
            .flatten()
            .is_some()
        && local_app_attached(connections)
}

/// Condition 3 of [`sharing_should_be_live`], with its grace.
///
/// The grace is deliberately read off the registry rather than kept by a
/// timer: there is no task to cancel, nothing to reset on a reconnect, and no
/// state that can survive the connection it describes. `has_local` first, so
/// an attached app never consults a timestamp at all.
fn local_app_attached(connections: &ConnectionRegistry) -> bool {
    connections.has_local()
        || connections
            .local_gone_since()
            .is_some_and(|gone| gone.elapsed() < LOCAL_ABSENCE_GRACE)
}

/// `Some(name)` when a remote `Hello` has to be refused because this machine
/// is not sharing, `None` when it may proceed.
///
/// The name is **this Mac's own**, as it announced itself to the relay at
/// pairing, because "‹machine› is not available" is a sentence a viewer shows
/// about the machine it dialled — naming the caller instead would tell a
/// MacBook Pro that MacBook Pro is unavailable. Before pairing, or with a
/// token row that does not parse, the daemon does not know what it is called
/// and says so generically; both are states in which it is refusing anyway.
///
/// A store that cannot be locked refuses too: a sharing switch that fails
/// open is not a switch.
fn unavailable_as(
    settings: &std::sync::Mutex<Store>,
    connections: &ConnectionRegistry,
) -> Option<String> {
    const UNNAMED_HOST: &str = "This Mac";
    let Ok(store) = lock_store(settings) else {
        return Some(UNNAMED_HOST.to_owned());
    };
    if sharing_should_be_live(&store, connections) {
        return None;
    }
    Some(
        store
            .get_setting(crate::relay::DEVICE_TOKEN_KEY)
            .ok()
            .flatten()
            .and_then(|raw| serde_json::from_str::<crate::relay::DeviceCredential>(&raw).ok())
            .map(|credential| credential.name)
            .unwrap_or_else(|| UNNAMED_HOST.to_owned()),
    )
}

/// Whether this machine is sharing its environment — the daemon's half of
/// "the tunnel should be up". Phase 3 replaces the old "the projection lists
/// ≥ 1 workspace" test with one flag; a malformed or absent row is off,
/// because a sharing switch that fails open is not a switch.
///
/// This is the *settings* half only. The whole condition, local app included,
/// is [`sharing_should_be_live`], which wraps this.
pub fn remote_control_active(store: &Store) -> bool {
    store
        .get_setting(REMOTE_SHARING_KEY)
        .ok()
        .flatten()
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
        .and_then(|value| value["enabled"].as_bool())
        .unwrap_or(false)
}

/// Every settings row whose key starts with this belongs to the signed-in
/// account — `auth_signed_in`, `auth_account_email`, and whatever the app
/// adds next. A prefix rather than a list, deliberately: see
/// [`protected_setting_key`].
const AUTH_KEY_PREFIX: &str = "auth_";

/// The row the app writes when it signs in, naming the account whose data
/// directory this is (`SettingsKeys.authAccountEmail`).
///
/// It is inside the account directory, so it is the account directory's own
/// account of itself — which is why [`viewer_owns_this_account`] can use it as
/// a second fact without introducing a second *source* of truth. Being an
/// `auth_` row it is already unreadable and unwritable through the protocol by
/// a remote client ([`protected_setting_key`]).
pub const AUTH_ACCOUNT_EMAIL_KEY: &str = "auth_account_email";

/// Settings rows a remote client may neither read nor write (phase 3 spec §3,
/// §12 invariant 2).
///
/// A remote client must not be able to grant itself access
/// ([`REMOTE_SHARING_KEY`], [`crate::DEVICE_TOKEN_KEY`]), unblock itself
/// ([`BLOCKED_VIEWERS_KEY`]), or read the host's credentials (`auth_*`). The
/// `auth_` case is a **prefix** on purpose — a row added to that family next
/// month is protected the day it is added, without anyone remembering this
/// function exists.
///
/// Both the get **and** the set arm of [`authorize_remote`] consult it: a
/// read-only leak of a device token is as bad as a write, and a token that
/// only leaks is a machine anyone can go on reaching.
///
/// **This is an RPC-layer guarantee only, and deliberately so.** The lease
/// holder may `CreateSession`, so it has a shell, so it can read anything the
/// signed-in user can read — `brain.db` and these very rows included. Do not
/// read this list as a sandbox and do not try to make it one by narrowing the
/// allowlist: remote shell access *is* the feature (spec §12 invariant 2, as
/// amended). What contains these secrets is who may hold the lease — a device
/// token bound to one account, the daemon's independent account check, one
/// viewer at a time, and the host's Terminate/Block. This function's job is
/// narrower and still worth doing: the protocol does not hand them over for
/// free.
pub fn protected_setting_key(key: &str) -> bool {
    matches!(
        key,
        REMOTE_SHARING_KEY | crate::relay::DEVICE_TOKEN_KEY | BLOCKED_VIEWERS_KEY
    ) || key.starts_with(AUTH_KEY_PREFIX)
}

/// What [`viewer_owns_this_account`] concluded. Two refusals rather than one
/// because they are different sentences to a human: a Mac nobody is signed in
/// to is not "signed in to a different account", and telling its owner that
/// would send them looking for an account switch that does not exist.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum AccountMatch {
    /// The caller is the account this daemon serves.
    Owner,
    /// Nobody is signed in here, so there is no account for anyone to be.
    HostSignedOut,
    /// Somebody else — or a caller the relay did not identify well enough to
    /// tell apart from somebody else, which is the same refusal.
    Refused,
}

/// The second of two independent checks that nobody ever sees another
/// person's sessions (spec §9, §12 invariant 10).
///
/// The relay already refuses a viewer whose `sub` does not own the device.
/// This one does not trust that. Either check alone would be sufficient;
/// neither is relied on to be, so a relay bug, a mis-spliced connection or a
/// compromised relay still cannot hand this Mac's sessions to someone else.
///
/// The daemon serves exactly one account, and it is asked to agree with itself
/// **twice** about which one:
///
/// 1. `current-account` chose the data dir, so the dir is
///    `<root>/accounts/<id>/` with `<id> = Store::account_dir_id(email)`. Hash
///    the **relay-asserted** email with that same function and require
///    equality. No new identifier and no second hash to keep in step — this is
///    the function that decided whose files these are in the first place,
///    which is also where the case- and whitespace-normalization comes from.
/// 2. That directory's own store holds [`AUTH_ACCOUNT_EMAIL_KEY`], written by
///    the app when it signed in. Compare the asserted email against it as a
///    **string**.
///
/// Neither is redundant. (1) alone reads only the *shape and name* of a path,
/// so a directory fabricated at `…/accounts/<some id>` — an env-var override, a
/// stray copy — would look signed-in to it, and its 16 hex characters are a
/// truncated SHA-256 doing authorization duty. (2) closes both: a fabricated
/// directory has an empty store and no row to match, and the full email is
/// compared as text, so the truncation is no longer the only thing between two
/// accounts. (2) alone would be a row inside a directory that anyone able to
/// write the row could also have chosen — which is why both, and why (2) is
/// deliberately not a new source of truth but the account directory's own
/// account of itself.
///
/// **It reads the assertion and nothing else the caller can touch.** The
/// identity parameter is an [`AssertedIdentity`], which only `relay.rs` can
/// construct and only from the control channel; there is deliberately no
/// overload, no `&HelloPayload` nearby and no email field on the self-reported
/// type. `signed_in_email` comes off the daemon's own store and is an `auth_`
/// row, which [`protected_setting_key`] already keeps out of a remote client's
/// reach in both directions. A check run on a value the connecting client
/// supplies checks nothing.
///
/// Every uncertain case fails closed:
/// - no asserted email, or a blank one — nothing to compare, and a blank one
///   must never become "the hash of the empty string", which is a real
///   directory name;
/// - a data dir that is not `…/accounts/<id>`, or with no final component at
///   all — a **signed-out** host, which has no account for anyone to be;
/// - **no `auth_account_email` row, or an unreadable store** — including the
///   real window where a freshly created account directory has not been
///   written to yet. That window is bounded and self-healing (the app writes
///   the row as it signs in, long before a viewer could be admitted — spec §2
///   condition 3 requires the app to be attached at all), the refusal is a
///   `Hello` a viewer re-dials past within seconds, and failing open here
///   would give back exactly the fabricated-directory hole this exists to
///   close. A temporary refusal is the cheaper mistake.
fn viewer_owns_this_account(
    asserted: &AssertedIdentity,
    data_dir: &Path,
    signed_in_email: Option<&str>,
) -> AccountMatch {
    // The data dir is `<root>/accounts/<id>` while signed in, so its last
    // component *is* the account id and its parent is the accounts directory.
    // Signed out it is the root itself, and neither half holds. Asked first so
    // that a host with no account gives every caller the same answer, rather
    // than one that varies with what the caller asserted.
    let account_id = data_dir
        .file_name()
        .and_then(|name| name.to_str())
        .filter(|_| {
            data_dir
                .parent()
                .is_some_and(|parent| parent.ends_with(brain_core::store::ACCOUNTS_DIR))
        });
    let Some(account_id) = account_id else {
        return AccountMatch::HostSignedOut;
    };
    let Some(email) = asserted
        .account_email
        .as_deref()
        .map(str::trim)
        .filter(|email| !email.is_empty())
    else {
        return AccountMatch::Refused;
    };
    let hashes_to_this_directory = Store::account_dir_id(email) == account_id;
    let is_who_this_directory_says_it_is = signed_in_email
        .map(str::trim)
        .is_some_and(|signed_in| !signed_in.is_empty() && signed_in.eq_ignore_ascii_case(email));
    if hashes_to_this_directory && is_who_this_directory_says_it_is {
        AccountMatch::Owner
    } else {
        AccountMatch::Refused
    }
}

/// The trust boundary for relayed clients (phase 3 spec §3). `Err(reason)`
/// means "answer with `Error`, skip dispatch".
///
/// Still an **explicit allowlist**, and it must stay one: the standing repo
/// rule is that nothing becomes remote-reachable merely by being added to the
/// dispatch, so a kind nobody has thought about falls into the deny arm at the
/// bottom rather than through a hole. Never invert this into a denylist.
///
/// What phase 3 changed is its length and the loss of session-id confinement.
/// The lease holder is driving the whole machine — it may create and kill
/// sessions — so confining it to a projection of a few of them would be
/// confining it to nothing. `Resize` comes back with the same reasoning
/// (§5: whoever drives owns the grid, and under exclusive takeover that is
/// the viewer).
///
/// The line that is *not* redrawn is [`protected_setting_key`], consulted on
/// both the get and the set arm, so the protocol never hands over the device
/// token or the blocklist for free. Read its doc before treating that as
/// containment: a lease holder has a shell, and this function is not a sandbox
/// for one.
pub fn authorize_remote(frame: &Frame) -> Result<(), String> {
    use MessageKind::*;
    match frame.header.message_kind {
        Hello | ListSessions | Attach | Detach | Input | Resize | Interrupt | CreateSession
        | Kill | ListDirectory | RootsStartIngest | RootsIngestionStatus | RootsList
        | RootsBiggestProject | RootsAddProject | RootsRenameProject | RootsPausedProjects
        | RootsSetPaused | RootsStaleness | RootsReingestProject | RootsRebuild
        | BrainListProjects | BrainGetContext | BrainSearch => Ok(()),

        // One struct reads both payloads: `SetSetting`'s carries a `value`
        // alongside the `key`, which serde ignores. A malformed payload is a
        // refusal rather than a pass — there is no key to check, so there is
        // no way to know the row is not a protected one.
        GetSetting | SetSetting => {
            let key = parse_json::<SettingKey>(&frame.payload)
                .map_err(|error| error.to_string())?
                .key;
            (!protected_setting_key(&key))
                .then_some(())
                .ok_or_else(|| format!("setting {key} is not reachable remotely"))
        }

        other => Err(format!("{other:?} is not allowed for remote clients")),
    }
}

pub struct DaemonServer {
    listener: UnixListener,
    socket_path: PathBuf,
    runtime_owner_uid: u32,
    registry: SessionRegistry,
    settings: Arc<std::sync::Mutex<Store>>,
    /// The shared brain-store data directory (`data_dir/brain.db`) —
    /// threaded into `mcp_server::tools::ToolContext` for `BrainListProjects`/
    /// `BrainGetContext` dispatch (Task 6a). Resolved by [`Self::bind`] via
    /// `brain_core::Store::default_data_dir()`, the **same** function
    /// `src-tauri`'s `BrainState` (`src-tauri/src/lib.rs`) calls to open its
    /// own `Store` — this is deliberately *not* derived from the socket
    /// path/runtime dir (see [`Self::bind_with_data_dir`]'s doc), which
    /// would silently point every brain read and every `settings` row
    /// (including `layout`) at a different, unshared `brain.db`.
    data_dir: PathBuf,
    /// The daemon's own ingestion-progress state machine (Task 6a-2),
    /// constructed once here and cloned into every client connection —
    /// mirroring how the Tauri app's process owns exactly one
    /// `IngestionState` for its whole lifetime (`lib.rs`'s `app.manage(..)`).
    /// The daemon and the Tauri app each hold an independent instance
    /// against the same `brain.db`; this crate makes no attempt to
    /// coordinate ingestion progress *across* the two processes (out of
    /// scope per the brief — same reasoning as both processes already
    /// holding independent `Store` connections to one WAL-mode file).
    ingestion: IngestionState,
    /// See [`ClientContext::settings_changed`].
    settings_changed: Arc<Notify>,
    /// See [`ClientContext::connections`].
    connections: ConnectionRegistry,
    /// Whether [`Self::serve`] spawns the relay client (`relay.rs`). Off
    /// for [`Self::bind_with_data_dir`] so tests drive `run_relay` directly;
    /// [`run_daemon`] turns it on with [`Self::with_relay`].
    relay_enabled: bool,
}

impl DaemonServer {
    /// Binds the daemon socket at `socket_path` and opens the shared brain
    /// store at `brain_core::Store::default_data_dir()` — honoring
    /// `OMNIAGENT_ADE_DATA_DIR` exactly like every other crate in this
    /// workspace does (PLAN.md's Local-first constraint: "Env override
    /// `OMNIAGENT_ADE_DATA_DIR` for tests — every crate must honor it").
    ///
    /// The directory is account-scoped: `root/current-account` selects
    /// `root/accounts/<id>` (2026-08-30 account-scoped-workspace spec). The
    /// pointer is read exactly once, here — the app restarts the daemon to
    /// move it between accounts. Before the store is opened, and so before
    /// any file is held open, a pre-account install's data is moved into
    /// the first account directory (`Store::adopt_legacy_data`).
    pub async fn bind(socket_path: PathBuf) -> Result<Self> {
        let root = Store::data_root();
        let data_dir = Store::default_data_dir();
        if data_dir != root
            && Store::adopt_legacy_data(&root, &data_dir)
                .context("move the pre-account brain data into the account directory")?
        {
            tracing::info!(
                root = %root.display(),
                account_dir = %data_dir.display(),
                "adopted the pre-account brain data into the account directory"
            );
        }
        Self::bind_with_data_dir(socket_path, data_dir).await
    }

    /// Same as [`Self::bind`], but takes the brain-store data directory
    /// explicitly rather than resolving it internally — the injection point
    /// tests use. A test must never open a real
    /// `~/Library/Application Support/OmniAgent-ADE/brain.db`, and mutating
    /// the process-global `OMNIAGENT_ADE_DATA_DIR` env var per test would
    /// race against every other test running concurrently in the same
    /// binary (`cargo test` runs different test functions on separate
    /// threads by default) — passing the directory as a plain argument
    /// avoids both.
    ///
    /// `data_dir` is intentionally independent of `socket_path`'s parent
    /// directory (the "runtime dir"). The runtime dir is only ever the
    /// socket's own home — its permissions and the peer-UID check below are
    /// about who may *connect*, nothing to do with where the shared brain
    /// data lives. Conflating the two (this crate's bug prior to the Task 6a
    /// fix) silently pointed `BrainListProjects`/`BrainGetContext`, and even
    /// `GetSetting`/`SetSetting`'s `layout` row, at `~/.omniagent-ade/`
    /// (the socket's directory) instead of the app's real, shared
    /// `brain.db` — every brain read came back empty and `layout` was never
    /// actually the row the web/Tauri app reads and writes.
    pub async fn bind_with_data_dir(socket_path: PathBuf, data_dir: PathBuf) -> Result<Self> {
        let runtime_dir = socket_path
            .parent()
            .ok_or_else(|| anyhow!("socket path needs a parent directory"))?;
        std::fs::create_dir_all(runtime_dir).context("create daemon runtime directory")?;
        std::fs::set_permissions(runtime_dir, std::fs::Permissions::from_mode(0o700))
            .context("secure daemon runtime directory")?;
        let settings = Store::open(&data_dir)
            .context("open daemon settings in the shared brain data directory")?;
        let runtime_owner_uid = std::fs::metadata(runtime_dir)
            .context("inspect daemon runtime directory")?
            .uid();

        if socket_path.exists() {
            if UnixStream::connect(&socket_path).await.is_ok() {
                return Err(io::Error::new(
                    io::ErrorKind::AddrInUse,
                    format!("daemon already listening at {}", socket_path.display()),
                )
                .into());
            }
            std::fs::remove_file(&socket_path).context("remove stale daemon socket")?;
        }
        let listener = UnixListener::bind(&socket_path)
            .with_context(|| format!("bind daemon socket at {}", socket_path.display()))?;
        std::fs::set_permissions(&socket_path, std::fs::Permissions::from_mode(0o600))
            .context("secure daemon socket")?;
        Ok(Self {
            listener,
            socket_path,
            runtime_owner_uid,
            registry: SessionRegistry::new(),
            settings: Arc::new(std::sync::Mutex::new(settings)),
            data_dir,
            ingestion: IngestionState::new(),
            settings_changed: Arc::new(Notify::new()),
            connections: ConnectionRegistry::default(),
            relay_enabled: false,
        })
    }

    /// Makes [`Self::serve`] spawn the relay client alongside the unix
    /// accept loop — the daemon's outbound side of remote session control.
    pub fn with_relay(mut self) -> Self {
        self.relay_enabled = true;
        self
    }

    pub fn registry(&self) -> SessionRegistry {
        self.registry.clone()
    }

    /// The per-connection handle [`serve_client`] needs — what the unix
    /// accept loop hands every local client, and what the relay hands
    /// every remote one.
    pub fn client_context(&self) -> ClientContext {
        ClientContext {
            registry: self.registry.clone(),
            settings: Arc::clone(&self.settings),
            data_dir: self.data_dir.clone(),
            ingestion: self.ingestion.clone(),
            settings_changed: Arc::clone(&self.settings_changed),
            connections: self.connections.clone(),
        }
    }

    pub async fn run_until(self, shutdown: oneshot::Receiver<()>) -> Result<()> {
        self.serve(async {
            let _ = shutdown.await;
        })
        .await
    }

    pub async fn run(self) -> Result<()> {
        self.serve(std::future::pending::<()>()).await
    }

    async fn serve(self, shutdown: impl std::future::Future<Output = ()>) -> Result<()> {
        tokio::pin!(shutdown);
        let relay = self
            .relay_enabled
            .then(|| tokio::spawn(crate::relay::run_relay(self.client_context())));
        let mut clients = JoinSet::new();
        loop {
            tokio::select! {
                accepted = self.listener.accept() => {
                    let (stream, _) = accepted.context("accept daemon client")?;
                    // The peer-UID check is the unix socket's own gate and
                    // lives here, not in `serve_client`: a relayed stream
                    // has no peer credentials, it has `ClientTrust::Remote`.
                    let peer_uid = match stream.peer_cred() {
                        Ok(credentials) => credentials.uid(),
                        Err(error) => {
                            tracing::warn!(
                                "rejecting daemon client: read peer credentials: {error}"
                            );
                            continue;
                        }
                    };
                    if !peer_uid_allowed(peer_uid, self.runtime_owner_uid) {
                        tracing::warn!(
                            "rejecting daemon client: peer UID {peer_uid} does not own daemon runtime"
                        );
                        continue;
                    }
                    let ctx = self.client_context();
                    clients.spawn(async move {
                        let _ = serve_client(stream, ctx, ClientTrust::Local).await;
                    });
                }
                _ = &mut shutdown => break,
                Some(_) = clients.join_next(), if !clients.is_empty() => {}
            }
        }
        self.registry.shutdown();
        if let Some(relay) = relay {
            relay.abort();
        }
        clients.abort_all();
        while clients.join_next().await.is_some() {}
        Ok(())
    }
}

impl Drop for DaemonServer {
    fn drop(&mut self) {
        self.registry.shutdown();
        let _ = std::fs::remove_file(&self.socket_path);
    }
}

pub async fn run_daemon(socket_path: PathBuf) -> Result<()> {
    let server = DaemonServer::bind(socket_path).await?.with_relay();
    let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        .context("install SIGTERM handler")?;
    let (send_shutdown, receive_shutdown) = oneshot::channel();
    tokio::spawn(async move {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
        let _ = send_shutdown.send(());
    });
    server.run_until(receive_shutdown).await
}

struct Attachment {
    subscription: SessionSubscription,
    task: JoinHandle<()>,
}

impl Drop for Attachment {
    fn drop(&mut self) {
        self.subscription.close();
        self.task.abort();
    }
}

/// Serves one client connection over any byte stream until it closes.
///
/// The unix accept loop calls this with [`ClientTrust::Local`] after its
/// peer-UID check; the relay calls it with [`ClientTrust::Remote`] over a
/// WebSocket adapted to a byte stream, in which case every frame after
/// `Hello` passes [`authorize_remote`] before the dispatch below sees it.
pub async fn serve_client<S>(stream: S, ctx: ClientContext, trust: ClientTrust) -> Result<()>
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let ClientContext {
        registry,
        settings,
        data_dir,
        ingestion,
        settings_changed,
        connections,
    } = ctx;
    let (mut reader, writer) = tokio::io::split(stream);
    let writer: SharedWriter = Arc::new(Mutex::new(Box::new(writer)));
    // The handshake is read with the version-tolerant decoder so that a peer
    // this daemon cannot speak to can still be *told* so; see below.
    let hello = read_handshake_frame(&mut reader)
        .await
        .context("read hello")?;
    if hello.header.message_kind != MessageKind::Hello {
        return Err(anyhow!("first client frame must be Hello"));
    }
    let identity = parse_json::<HelloPayload>(&hello.payload)?;
    let request = hello.header.request_or_sequence;
    // A viewer that gives an id but no name is still a machine the host must
    // be able to see, kick, and be told the lease is held by.
    let machine_name = identity
        .machine_name
        .clone()
        .unwrap_or_else(|| "Unknown Mac".into());
    // Version skew, first of every refusal (spec §3 "Protocol version").
    //
    // First because it is the only one whose answer this peer can be relied on
    // to understand: any other refusal, written in a dialect the peer's decoder
    // rejects, is a dropped stream — which is phase 1's failure exactly, a
    // 0.25 s reconnect loop with a dead keyboard. So the refusal goes back
    // stamped with the *peer's* version, and it is deliberately ahead of the
    // lease: a skewed peer that took the lease on its way to being refused
    // would lock out the machine that could have used it, and a skewed peer
    // arriving second would be told about the lease instead of about the
    // update it actually needs.
    //
    // A *local* client on the wrong version is a different situation with no
    // sentence worth writing: the app and the daemon ship together, so this
    // means the bundle was replaced under a running daemon, and the app's
    // answer is to reconnect until the daemon it is talking to is the new one.
    if hello.header.protocol_version != PROTOCOL_VERSION {
        if !trust.is_remote() {
            return Err(anyhow!(
                "client speaks protocol {}, this daemon speaks {PROTOCOL_VERSION}",
                hello.header.protocol_version
            ));
        }
        send_handshake_error(
            &writer,
            request,
            hello.header.protocol_version,
            anyhow!("update OmniAgent on {machine_name}"),
        )
        .await?;
        return Ok(());
    }
    // **Is this caller the account this daemon serves** (spec §9, §12
    // invariant 10)? The second of the two independent checks that nobody ever
    // sees another person's sessions.
    //
    // **First of the viewer-specific refusals**, and that placement is the
    // decision, not an accident of where it was easy to add. Every refusal
    // below this line answers with a fact: "‹machine› is not available" names
    // *this Mac* as it announced itself to the relay, the blocklist confirms
    // that a viewer id is one this host has kicked, and the lease names the
    // machine currently driving. A caller who is not this account is entitled
    // to none of them — so it is told the one thing it may know, that it is
    // not this account, and told it before anything else has spoken.
    //
    // The version check stays ahead, because it is the only refusal whose
    // *encoding* the peer might not understand, and because the sentence it
    // sends back contains nothing but the caller's own name for itself.
    //
    // It runs on the trust value, which is to say on what the relay asserted,
    // and there is nothing else here it could run on: `identity` is the
    // client's own `Hello` and has no email in it at all.
    if let ClientTrust::Remote(asserted) = &trust {
        // The account directory's own account of itself. An unreadable store
        // yields `None`, which the check treats as no row — a refusal, because
        // failing open on a store this daemon cannot read is failing open on
        // the question of whose data it is holding.
        let signed_in_email = lock_store(&settings)
            .ok()
            .and_then(|store| store.get_setting(AUTH_ACCOUNT_EMAIL_KEY).ok().flatten());
        let verdict = viewer_owns_this_account(asserted, &data_dir, signed_in_email.as_deref());
        if verdict != AccountMatch::Owner {
            tracing::warn!(
                verdict = ?verdict,
                asserted_email = asserted.account_email.as_deref().unwrap_or("<none>"),
                asserted_ip = asserted.ip.as_deref().unwrap_or("<none>"),
                asserted_country = asserted.country.as_deref().unwrap_or("<none>"),
                serving = %data_dir.display(),
                "refused a relayed connection: the asserted account is not the one this daemon serves"
            );
            // Two sentences, because a Mac nobody is signed in to is not a Mac
            // signed in to somebody else, and only one of those is worth
            // sending its owner to the account switcher over.
            let refusal = match verdict {
                AccountMatch::HostSignedOut => "no one is signed in to OmniAgent on this Mac",
                _ => "this Mac is signed in to a different OmniAgent account",
            };
            send_error(&writer, request, anyhow!("{refusal}")).await?;
            return Ok(());
        }
    }
    // Is this machine reachable at all (spec §2 condition 3, §3 "One remote
    // session per machine, in either direction")? See
    // [`sharing_should_be_live`] for why the local-app condition is what makes
    // chaining impossible rather than merely forbidden.
    //
    // Asked here as well as in `relay.rs` because the relay's answer is a
    // second old at worst — it re-tests on a tick — and because a daemon that
    // enforced this only where the tunnel is opened would be relying on the
    // tunnel to be the only way in.
    //
    // **Before the lease.** A machine that is not sharing owes every caller of
    // its own account the same sentence: whether this particular viewer is
    // also blocked, or whether someone else is driving, is not something an
    // unshared Mac should be answering. And a refusal must never take the
    // lease on its way out (`remote_lease.rs`).
    if trust.is_remote() {
        if let Some(host) = unavailable_as(&settings, &connections) {
            send_error(&writer, request, anyhow!("{host} is not available")).await?;
            return Ok(());
        }
    }
    // The blocklist is checked here — before the ack, and by the daemon rather
    // than the app — because a kick has to hold against a viewer that still
    // holds a valid device token and re-dials on its own (spec §5).
    if trust.is_remote() {
        if let Some(viewer_id) = identity.viewer_id.as_deref() {
            if blocked_viewers(&settings).contains(viewer_id) {
                send_error(
                    &writer,
                    request,
                    anyhow!(
                        "viewer {viewer_id} is disconnected until Remote Control \
                         is turned off and on again"
                    ),
                )
                .await?;
                return Ok(());
            }
        }
    }

    // Registration comes before the ack because the lease below is taken under
    // a connection id, and a refused `Hello` has to be answered *instead of*
    // the ack rather than after it. A registered connection that has not yet
    // named itself is invisible to a host (`is_listed_viewer`), which is what
    // makes it safe to register one that may still be refused.
    //
    // The guard is what takes the entry — and the lease with it — back out
    // however this function ends, including an early `?` and an aborted task.
    let cancel = CancellationToken::new();
    let connection = ConnectionGuard::register(&connections, trust.clone(), cancel.clone());
    // The lease (spec §3, §12 invariant 4): one remote connection drives this
    // machine at a time. Released by the guard above on every way out of this
    // function, because a lease that leaks is a daemon that refuses every
    // future viewer until it restarts.
    //
    // **Ahead of the roster, and therefore ahead of the blocklist re-check
    // below.** A second Mac knocking while the first is driving is the routine
    // event this whole lease exists for, and taking the lease after
    // `set_viewer` would put that machine on the host's roster for the moment
    // between being registered and being refused — a viewer that was never
    // admitted, flickering through the host's takeover panel. The re-check
    // cannot move above `set_viewer` (see its comment), so the lease moves
    // above both. The cost is the mirror case: a viewer blocked in the sliver
    // *while it is connecting* holds the machine for two synchronous calls
    // before its guard frees it. That path needs a kick to land inside a
    // window with no await in it; the roster one happened every time a second
    // Mac knocked.
    //
    // The holder is built by **destructuring the trust value**, so the
    // assertion recorded against the lease is necessarily the relay's own: a
    // `Local` connection cannot reach this block at all, and a `Remote` one
    // has nowhere else to get an `AssertedIdentity` from.
    if let ClientTrust::Remote(asserted) = &trust {
        match connections.take_lease(
            connection.id,
            LeaseHolder {
                viewer_id: identity.viewer_id.clone(),
                machine_name: machine_name.clone(),
                asserted: (**asserted).clone(),
            },
        ) {
            Ok(None) => {}
            // The same viewer coming back after a blip (spec §11). It now
            // holds the machine; the socket it left behind is cancelled here
            // rather than left to time out, because that socket is still
            // attached to the sessions this connection is about to drive.
            Ok(Some(stale)) => {
                tracing::info!(
                    "{machine_name} reclaimed the lease from the connection it left behind"
                );
                if connections.cancel_connection(stale) {
                    connections.notify_presence();
                }
            }
            Err(machine) => {
                send_error(&writer, request, anyhow!("in use by {machine}")).await?;
                return Ok(());
            }
        }
    }
    let viewer_id = identity.viewer_id.clone();
    let named_itself = match identity.viewer_id {
        Some(viewer_id) => connections.set_viewer(
            connection.id,
            ViewerIdentity {
                viewer_id,
                machine_name: machine_name.clone(),
            },
        ),
        None => false,
    };
    // The kick's other half. A `DisconnectViewer` that lands between the check
    // above and this registration would write the blocklist row and find
    // nothing to cancel, and this connection would then sit there kicked-but-
    // connected. Re-reading the row once we are visible to `cancel_viewer`
    // closes that sliver from the other side: either the kick sees us, or we
    // see the kick. That is why it cannot move above `set_viewer`.
    if trust.is_remote() {
        if let Some(viewer_id) = viewer_id.as_deref() {
            if blocked_viewers(&settings).contains(viewer_id) {
                send_error(
                    &writer,
                    request,
                    anyhow!("viewer {viewer_id} was disconnected while connecting"),
                )
                .await?;
                return Ok(());
            }
        }
    }
    send_json(
        &writer,
        MessageKind::HelloAck,
        request,
        &HelloAckPayload {
            protocol_version: PROTOCOL_VERSION,
        },
    )
    .await?;

    // A host is told the roster on its own `Hello`, so an app that has just
    // opened is immediately correct rather than correct at the next change.
    // The feed writes it to this one connection — never a broadcast to all —
    // and only when it is news; see `PresenceFeed::spawn`.
    let _presence = connections
        .presence_updates(&trust)
        .map(|updates| PresenceFeed::spawn(updates, Arc::clone(&writer)));
    if named_itself {
        connections.notify_presence();
    }

    let mut attachments = HashMap::<String, Attachment>::new();
    loop {
        let frame = tokio::select! {
            // A kicked connection stops mid-frame. Dropping a partly-read
            // frame would normally desynchronise the stream — `read_exact` is
            // not cancel-safe — but here the stream is being torn down, so
            // there is nothing left to desynchronise.
            _ = cancel.cancelled() => break,
            frame = read_frame(&mut reader) => match frame {
                Ok(frame) => frame,
                Err(_) => break,
            },
        };
        let request = frame.header.request_or_sequence;
        // The remote trust boundary. The dispatch below is byte-for-byte the
        // local path: nothing in it consults trust, which is what keeps the
        // decision in one readable place.
        if trust.is_remote() {
            if let Err(reason) = authorize_remote(&frame) {
                if send_error(&writer, request, reason).await.is_err() {
                    break;
                }
                continue;
            }
        }
        /// Decodes this frame's JSON payload, or answers with an `Error`
        /// frame and moves on to the next frame.
        ///
        /// A malformed *payload* inside a structurally valid *frame* is a bad
        /// request, not a broken connection — one bad control frame used to
        /// propagate out of `handle_client` via `?` and drop the socket,
        /// blanking every pane in the native app until it reconnected
        /// (final whole-branch review, Minor #7). `MessageKind::Input`
        /// already got this right; this is that same shape, applied to every
        /// JSON-payload kind without re-indenting each arm.
        ///
        /// Envelope-level validation (the 1 MiB cap, the protocol-version
        /// byte, unknown message kinds, the peer-UID check) is deliberately
        /// untouched and still terminates the connection: those say the
        /// *stream* cannot be trusted, which is a different claim.
        ///
        /// Defined inside the loop so it can reach `frame`/`request`/`writer`
        /// — `macro_rules!` resolves outer identifiers at its definition
        /// site, not its call site.
        macro_rules! decode_payload {
            ($ty:ty) => {
                match parse_json::<$ty>(&frame.payload) {
                    Ok(value) => value,
                    Err(error) => {
                        if send_error(&writer, request, error).await.is_err() {
                            break;
                        }
                        continue;
                    }
                }
            };
        }
        let result = match frame.header.message_kind {
            MessageKind::ListSessions => {
                decode_payload!(serde_json::Value);
                // Unfiltered for every trust level since phase 3: a lease
                // holder is driving this machine, not peering at a projection
                // of part of it.
                send_json(
                    &writer,
                    MessageKind::SessionList,
                    request,
                    &SessionListPayload {
                        sessions: registry.list(),
                    },
                )
                .await
            }
            MessageKind::CreateSession => {
                let create = decode_payload!(CreateSession);
                let id = create.id.clone();
                match registry.create_session(create) {
                    Ok(_) => {
                        send_json(
                            &writer,
                            MessageKind::SessionCreated,
                            request,
                            &SessionCreatedPayload { id },
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::Attach => {
                let attach = decode_payload!(AttachPayload);
                attachments.remove(&attach.id);
                match registry.get_attachable(&attach.id) {
                    Some(session) => {
                        let (state, subscription) = session
                            .attach_and_subscribe(attach.after_sequence, CLIENT_QUEUE_CAPACITY);
                        let empty_resume =
                            matches!(&state, AttachState::Resume(events) if events.is_empty());
                        // Presence learns about this attachment *before* the
                        // client is told about it, so "the viewer has its
                        // snapshot" implies "the host's roster names the pane":
                        // a `ListViewers` can never disagree with what the
                        // viewer can already see on screen.
                        sync_attached(
                            &connections,
                            connection.id,
                            attachments
                                .keys()
                                .cloned()
                                .chain([attach.id.clone()])
                                .collect(),
                        );
                        // The grid before the screen drawn on it: a viewer
                        // scales the host's size rather than imposing its own
                        // (phase 2 §1), so it must know that size to lay the
                        // snapshot out. The header carries the session's
                        // current sequence, the same stamp `Snapshot` gets —
                        // never this attach's request id, which would give one
                        // message kind two meanings for the same header field.
                        let (cols, rows) = session.size();
                        send_json(
                            &writer,
                            MessageKind::SessionResized,
                            session.sequence(),
                            &SessionSizePayload {
                                id: attach.id.clone(),
                                cols,
                                rows,
                            },
                        )
                        .await?;
                        send_attach_state(&writer, &attach.id, state).await?;
                        if empty_resume {
                            send_response(&writer, request).await?;
                        }
                        let forward_subscription = subscription.clone();
                        let forward_writer = Arc::clone(&writer);
                        let id = attach.id.clone();
                        let task = tokio::spawn(async move {
                            forward_events(forward_writer, id, forward_subscription).await;
                        });
                        attachments.insert(attach.id, Attachment { subscription, task });
                        Ok(())
                    }
                    None => {
                        send_error(&writer, request, anyhow!("session {} not found", attach.id))
                            .await
                    }
                }
            }
            MessageKind::Input => match decode_raw_payload(&frame.payload) {
                Ok((id, bytes)) => match registry.get(id) {
                    Some(session) => match session.write_input(bytes) {
                        Ok(()) => {
                            tracing::debug!(
                                target: "omniagent_latency",
                                stage = "daemon_pty_write",
                                request,
                                session_id = id,
                                bytes = bytes.len()
                            );
                            send_response(&writer, request).await
                        }
                        Err(error) => send_error(&writer, request, error).await,
                    },
                    None => send_error(&writer, request, anyhow!("session {id} not found")).await,
                },
                Err(error) => send_error(&writer, request, error).await,
            },
            MessageKind::Resize => {
                let resize = decode_payload!(ResizePayload);
                match registry.get(&resize.id) {
                    Some(session) => match session.resize(
                        resize.cols,
                        resize.rows,
                        resize.pixel_width,
                        resize.pixel_height,
                    ) {
                        Ok(()) => send_response(&writer, request).await,
                        Err(error) => send_error(&writer, request, error).await,
                    },
                    None => {
                        send_error(&writer, request, anyhow!("session {} not found", resize.id))
                            .await
                    }
                }
            }
            MessageKind::Interrupt => {
                let session = decode_payload!(SessionIdPayload);
                match registry.get(&session.id) {
                    Some(session) => match session.send_interrupt() {
                        Ok(()) => send_response(&writer, request).await,
                        Err(error) => send_error(&writer, request, error).await,
                    },
                    None => {
                        send_error(
                            &writer,
                            request,
                            anyhow!("session {} not found", session.id),
                        )
                        .await
                    }
                }
            }
            MessageKind::Kill => {
                let session = decode_payload!(SessionIdPayload);
                if registry.kill(&session.id) {
                    send_response(&writer, request).await
                } else {
                    send_error(
                        &writer,
                        request,
                        anyhow!("session {} not found", session.id),
                    )
                    .await
                }
            }
            MessageKind::Detach => {
                let session = decode_payload!(SessionIdPayload);
                attachments.remove(&session.id);
                send_response(&writer, request).await
            }
            MessageKind::GetSetting => {
                let setting = decode_payload!(SettingKey);
                let value = lock_store(&settings)
                    .and_then(|store| store.get_setting(&setting.key).map_err(Into::into));
                match value {
                    Ok(value) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"value": value}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::SetSetting => {
                let setting = decode_payload!(SettingValue);
                let result = lock_store(&settings).and_then(|store| {
                    store
                        .set_setting(&setting.key, &setting.value)
                        .map_err(Into::into)
                });
                match result {
                    Ok(()) => {
                        // Every current waiter — the relay task watching
                        // for sharing and device-token changes — must see
                        // this, plus one permit for a waiter between waits.
                        settings_changed.notify_waiters();
                        settings_changed.notify_one();
                        send_response(&writer, request).await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::BrainListProjects => {
                decode_payload!(serde_json::Value);
                let result = lock_store(&settings).and_then(|store| {
                    tools::list_projects(&tool_context(&store, &data_dir), &serde_json::json!({}))
                        .map_err(|error| anyhow!("{error}"))
                });
                match result {
                    Ok(projects) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"projects": projects}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::BrainGetContext => {
                let payload = decode_payload!(BrainGetContextPayload);
                let result = lock_store(&settings).and_then(|store| {
                    tools::get_context(
                        &tool_context(&store, &data_dir),
                        &serde_json::json!({"project": payload.project}),
                    )
                    .map_err(|error| anyhow!("{error}"))
                });
                match result {
                    Ok(context) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"context": context}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsStartIngest => {
                let payload = decode_payload!(RootsStartIngestPayload);
                let result = lock_store(&settings).and_then(|store| {
                    roots::start_ingest(data_dir.clone(), &store, &ingestion, &payload.path)
                });
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsIngestionStatus => {
                decode_payload!(serde_json::Value);
                send_json(
                    &writer,
                    MessageKind::Response,
                    request,
                    &serde_json::json!({"status": ingestion.snapshot()}),
                )
                .await
            }
            MessageKind::RootsList => {
                decode_payload!(serde_json::Value);
                let result = lock_store(&settings).and_then(|store| roots::get_roots(&store));
                match result {
                    Ok(list) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"roots": list}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsBiggestProject => {
                decode_payload!(serde_json::Value);
                let result = lock_store(&settings).and_then(|store| roots::biggest_project(&store));
                match result {
                    Ok(project) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"project": project}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsAddProject => {
                let payload = decode_payload!(RootsAddProjectPayload);
                let result = lock_store(&settings).and_then(|store| {
                    roots::add_project(
                        &store,
                        &data_dir,
                        &ingestion,
                        &payload.path,
                        payload.name.as_deref(),
                    )
                });
                match result {
                    Ok(project) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"project": project}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsRenameProject => {
                let payload = decode_payload!(RootsRenameProjectPayload);
                let result = lock_store(&settings).and_then(|store| {
                    roots::rename_project(&store, &payload.id, &payload.new_label)
                });
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsPausedProjects => {
                decode_payload!(serde_json::Value);
                let result = lock_store(&settings).and_then(|store| roots::paused_projects(&store));
                match result {
                    Ok(projects) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"projects": projects}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsSetPaused => {
                let payload = decode_payload!(RootsSetPausedPayload);
                let result = lock_store(&settings)
                    .and_then(|store| roots::set_paused(&store, &payload.project, payload.paused));
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsStaleness => {
                decode_payload!(serde_json::Value);
                let result = lock_store(&settings).and_then(|store| roots::staleness(&store));
                match result {
                    Ok(projects) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"projects": projects}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsReingestProject => {
                let payload = decode_payload!(RootsReingestProjectPayload);
                let result = lock_store(&settings)
                    .and_then(|store| roots::reingest_project(&store, &payload.project));
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::RootsRebuild => {
                decode_payload!(serde_json::Value);
                let result = roots::rebuild_and_reingest(&data_dir, &settings, &ingestion);
                match result {
                    Ok(()) => send_response(&writer, request).await,
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::BrainSearch => {
                let payload = decode_payload!(BrainSearchPayload);
                let result = lock_store(&settings).and_then(|store| {
                    tools::search_brain(
                        &tool_context(&store, &data_dir),
                        &serde_json::json!({"query": payload.query, "scope": payload.scope}),
                    )
                    .map_err(|error| anyhow!("{error}"))
                });
                match result {
                    Ok(results) => {
                        send_json(
                            &writer,
                            MessageKind::Response,
                            request,
                            &serde_json::json!({"results": results}),
                        )
                        .await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::ListDirectory => {
                let payload = decode_payload!(ListDirectoryPayload);
                match list_directory(&payload) {
                    Ok(listing) => {
                        send_json(&writer, MessageKind::Response, request, &listing).await
                    }
                    // Every way a listing can fail — a missing path, a regular
                    // file, permissions — is answered with an `Error` frame.
                    // None of them may drop the connection: the entry cap is
                    // what keeps the success path inside `MAX_PAYLOAD_LEN`, and
                    // an oversized `send_json` is the one failure here that
                    // *would* take the socket with it.
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            // Both viewer-presence kinds are local-only, and neither is in
            // `authorize_remote`'s allow arms — a remote client is answered
            // with `Error` before ever reaching this dispatch (spec §7
            // invariant 2, pinned by `presence_is_local_only`).
            MessageKind::ListViewers => {
                decode_payload!(serde_json::Value);
                send_json(
                    &writer,
                    MessageKind::Response,
                    request,
                    &RemoteViewersPayload {
                        viewers: connections.viewers(),
                    },
                )
                .await
            }
            MessageKind::DisconnectViewer => {
                let payload = decode_payload!(DisconnectViewerPayload);
                // Block first, then kick: a viewer dropped before the row is
                // written could re-dial into the gap. Terminate (`block:
                // false`, Task 14) skips the write entirely, so there is
                // nothing here for a re-dial to race — the machine is simply
                // free to come straight back.
                let blocked = if payload.block {
                    lock_store(&settings).and_then(|store| block_viewer(&store, &payload.viewer_id))
                } else {
                    Ok(())
                };
                match blocked {
                    Ok(()) => {
                        connections.cancel_viewer(&payload.viewer_id);
                        connections.notify_presence();
                        send_response(&writer, request).await
                    }
                    Err(error) => send_error(&writer, request, error).await,
                }
            }
            MessageKind::Hello => {
                send_error(&writer, request, anyhow!("Hello is only valid once")).await
            }
            _ => {
                send_error(
                    &writer,
                    request,
                    anyhow!("clients cannot send server message kinds"),
                )
                .await
            }
        };
        if result.is_err() {
            break;
        }
        sync_attached(
            &connections,
            connection.id,
            attachments.keys().cloned().collect(),
        );
    }

    if cancel.is_cancelled() {
        // End the socket here rather than whenever the last clone of the
        // shared writer happens to go — the attachments' forwarding tasks
        // hold clones, and `abort()` does not drop them synchronously. A kick
        // the viewer only notices a beat later is a kick that looks broken.
        let _ = writer.lock().await.shutdown().await;
    }
    Ok(())
}

/// Keeps one connection in the registry for as long as it is being served.
///
/// `serve_client` has half a dozen ways out — a returned `Err`, a `?` inside
/// the dispatch, the loop ending, and the accept loop aborting the whole task
/// on shutdown — and a connection left behind in the registry is a viewer the
/// host is told is still watching. A guard is the only thing that covers all
/// of them.
struct ConnectionGuard {
    connections: ConnectionRegistry,
    id: u64,
}

impl ConnectionGuard {
    fn register(
        connections: &ConnectionRegistry,
        trust: ClientTrust,
        cancel: CancellationToken,
    ) -> Self {
        Self {
            connections: connections.clone(),
            id: connections.register(trust, cancel),
        }
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        // Publishing is synchronous and cannot block, so `Drop` — which cannot
        // await — is a complete place to do this rather than a partial one.
        if self.connections.remove(self.id) {
            self.connections.notify_presence();
        }
    }
}

/// Mirrors one connection's attachments into the registry, telling the hosts
/// when that changed what they are shown. The single call-site pattern for
/// "this viewer is now watching a different set of panes".
fn sync_attached(connections: &ConnectionRegistry, connection: u64, attached: HashSet<String>) {
    if connections.set_attached(connection, attached) {
        connections.notify_presence();
    }
}

/// One directory's entries, for `ListDirectory` (phase 3 spec §4).
///
/// **What it deliberately does not do** is the point of the function: no
/// recursion, and per entry only a name and an is-directory flag. No size, no
/// mode, no timestamp, and above all no contents — this exists so a remote can
/// pick a folder on the host, and it is the closest this protocol comes to a
/// remote file read. Anything richer here would quietly retire §12 invariant 8
/// ("the activity log is not remotely readable"), which rests on there being
/// no file-read RPC at all.
///
/// Hidden entries are skipped unless the request asks: a folder picker showing
/// `.ssh` and `.aws` by default is both noise and the part of the host a
/// viewer has least business browsing.
///
/// `is_dir` follows a symlink, because `Path::is_dir` does and a picker that
/// cannot descend into a symlinked folder is broken. That is the *only*
/// following done — there is no recursion for a loop to run away in.
fn list_directory(request: &ListDirectoryPayload) -> Result<DirectoryListingPayload> {
    let path = Path::new(&request.path);
    let mut entries = Vec::new();
    for entry in std::fs::read_dir(path).with_context(|| format!("read {}", request.path))? {
        let entry = entry.with_context(|| format!("read an entry of {}", request.path))?;
        let name = entry.file_name().to_string_lossy().into_owned();
        if !request.show_hidden && name.starts_with('.') {
            continue;
        }
        entries.push(DirectoryEntryPayload {
            is_dir: entry.path().is_dir(),
            name,
        });
    }
    // Directories first, then case-insensitively by name — the order the
    // folder browser renders without re-sorting. The exact-name tiebreak keeps
    // `README` and `readme` in a stable order rather than whatever `read_dir`
    // happened to yield.
    entries.sort_by(|a, b| {
        b.is_dir
            .cmp(&a.is_dir)
            .then_with(|| a.name.to_lowercase().cmp(&b.name.to_lowercase()))
            .then_with(|| a.name.cmp(&b.name))
    });
    // The cap is applied **after** the sort, never during the walk, and that
    // ordering is the whole point: directories sort first, so a directory too
    // big to send loses files rather than folders — which is what a folder
    // picker needs to keep working. Capping during `read_dir` would drop
    // whichever names the filesystem happened to yield last, folders included.
    let truncated = entries.len() > LIST_DIRECTORY_MAX_ENTRIES;
    entries.truncate(LIST_DIRECTORY_MAX_ENTRIES);
    Ok(DirectoryListingPayload { entries, truncated })
}

// Phase 2 read the client's next frame through a `next_frame` helper that
// also woke on `settings_changed`, re-read the `remote_control` projection,
// and dropped every attachment whose session it no longer shared — so a
// passive viewer stopped receiving output the moment a workspace was
// un-shared. It went with session-id confinement in phase 3 (spec §3): the
// projection no longer decides anything, and pruning against it would have
// silently killed attachments the authorizer had just allowed. Sharing is one
// machine-wide switch now, and turning it off closes the relay connection
// itself (`relay.rs`), so there is no longer a mid-connection narrowing to
// enforce. Both trust levels take the plain `read_frame`.

/// Decodes a control frame's JSON payload.
///
/// A **zero-length** payload decodes as `{}`. Eight of the client message
/// kinds take no arguments at all (`ListSessions`, `BrainListProjects`,
/// `RootsIngestionStatus`, `RootsList`, `RootsBiggestProject`,
/// `RootsPausedProjects`, `RootsStaleness`, `RootsRebuild`) and the natural
/// way for a client to encode "no arguments" is an empty payload rather than
/// the two bytes `{}`. Rejecting that used to drop the whole connection
/// (final whole-branch review, Minor #7). The empty frame is unambiguous —
/// there is no message kind for which "" is a meaningful, differently-shaped
/// payload — so accepting it here rather than per-arm keeps one rule instead
/// of eight. For a kind that *does* have required fields it simply produces
/// a clearer "missing field `id`" error than "EOF while parsing a value",
/// and either way the caller answers with an `Error` frame.
fn parse_json<T: DeserializeOwned>(payload: &[u8]) -> Result<T> {
    let payload = if payload.is_empty() {
        b"{}".as_slice()
    } else {
        payload
    };
    serde_json::from_slice(payload).context("decode control JSON")
}

/// Locks the shared brain store, reopening it first if `brain.db` was
/// replaced underneath this process.
///
/// The daemon is the *second* long-lived holder of a `Store` handle against
/// one `brain.db` (the Tauri app is the first, and Task 7 mandates a period
/// where both run side by side). "Rebuild brain" — from either app — goes
/// through `brain_ingest::roots::rebuild_store`, which `unlink`s `brain.db`
/// and creates a fresh file at the same path, swapping only *its own*
/// process's handle. Everything the other process subsequently writes
/// (`layout`, `notifications`, `usage_analytics_v1`, every `roots::*` row)
/// would keep succeeding against the now-nameless inode and vanish for good
/// the next time that process restarted.
///
/// One `stat(2)` of an almost-always-cached path per control request is a
/// rounding error next to the SQLite work each of these handlers goes on to
/// do, so this is checked on every store operation rather than on a timer:
/// no window, no background task, no extra state to get wrong.
fn lock_store(settings: &std::sync::Mutex<Store>) -> Result<std::sync::MutexGuard<'_, Store>> {
    let mut guard = settings
        .lock()
        .map_err(|error| anyhow!("settings lock poisoned: {error}"))?;
    guard
        .reopen_if_replaced()
        .context("reopen the shared brain.db after it was rebuilt")?;
    Ok(guard)
}

/// Builds the `mcp_server::tools` dispatch context for one brain-store
/// request (`BrainListProjects`/`BrainGetContext`) — same
/// `ToolContext { store, data_dir }` shape `src-tauri`'s `BrainState::tool_ctx`
/// builds, so `list_projects`/`get_context` behave identically from either
/// caller.
fn tool_context<'a>(store: &'a Store, data_dir: &'a Path) -> ToolContext<'a> {
    ToolContext { store, data_dir }
}

async fn send_attach_state(writer: &SharedWriter, id: &str, state: AttachState) -> Result<()> {
    match state {
        AttachState::Snapshot { sequence, bytes } => {
            send_frame(
                writer,
                Frame::new(
                    MessageKind::Snapshot,
                    sequence,
                    encode_raw_payload(id, &bytes)?,
                ),
            )
            .await
        }
        AttachState::Resume(events) => {
            for event in events {
                send_event(writer, id, event).await?;
            }
            Ok(())
        }
    }
}

async fn forward_events(writer: SharedWriter, id: String, subscription: SessionSubscription) {
    loop {
        let receiver = subscription.clone();
        let event =
            tokio::task::spawn_blocking(move || receiver.recv_timeout(Duration::from_millis(250)))
                .await;
        match event {
            Ok(Ok(event)) => {
                let exited = matches!(event, SessionEvent::Exited { .. });
                if send_event(&writer, &id, event).await.is_err() || exited {
                    break;
                }
            }
            Ok(Err(std::sync::mpsc::RecvTimeoutError::Timeout)) => continue,
            _ => break,
        }
    }
}

async fn send_event(writer: &SharedWriter, id: &str, event: SessionEvent) -> Result<()> {
    let frame = match event {
        SessionEvent::Output { sequence, bytes } => Frame::new(
            MessageKind::Output,
            sequence,
            encode_raw_payload(id, &bytes)?,
        ),
        SessionEvent::ResyncRequired { sequence } => Frame::new(
            MessageKind::ResyncRequired,
            sequence,
            serde_json::to_vec(&ResyncRequiredPayload { id: id.into() })?,
        ),
        SessionEvent::Status {
            sequence,
            status,
            engine,
        } => Frame::new(
            MessageKind::SessionStatus,
            sequence,
            serde_json::to_vec(&SessionStatusPayload {
                id: id.into(),
                status,
                notify: matches!(
                    status,
                    crate::protocol::SessionStatus::Ready
                        | crate::protocol::SessionStatus::AwaitingApproval
                        | crate::protocol::SessionStatus::Error
                ),
                engine,
            })?,
        ),
        SessionEvent::Resized {
            sequence,
            cols,
            rows,
        } => Frame::new(
            MessageKind::SessionResized,
            sequence,
            serde_json::to_vec(&SessionSizePayload {
                id: id.into(),
                cols,
                rows,
            })?,
        ),
        SessionEvent::Exited {
            sequence,
            exit_code,
        } => Frame::new(
            MessageKind::SessionExited,
            sequence,
            serde_json::to_vec(&SessionExitedPayload {
                id: id.into(),
                exit_code,
            })?,
        ),
    };
    send_frame(writer, frame).await
}

async fn send_response(writer: &SharedWriter, request: u64) -> Result<()> {
    send_json(
        writer,
        MessageKind::Response,
        request,
        &ResponsePayload { ok: true },
    )
    .await
}

async fn send_error(
    writer: &SharedWriter,
    request: u64,
    error: impl std::fmt::Display,
) -> Result<()> {
    send_json(
        writer,
        MessageKind::Error,
        request,
        &ErrorPayload {
            message: error.to_string(),
        },
    )
    .await
}

/// [`send_error`], written in the version the *peer* speaks.
///
/// The only frame this daemon ever writes outside its own protocol version,
/// and only ever as the last one on that connection. A refusal aimed at a Mac
/// running the old app is worth nothing stamped with the new version: that
/// app's decoder rejects the header and never reads the sentence inside.
async fn send_handshake_error(
    writer: &SharedWriter,
    request: u64,
    protocol_version: u8,
    error: impl std::fmt::Display,
) -> Result<()> {
    let mut frame = Frame::new(
        MessageKind::Error,
        request,
        serde_json::to_vec(&ErrorPayload {
            message: error.to_string(),
        })?,
    );
    frame.header.protocol_version = protocol_version;
    send_frame(writer, frame).await
}

async fn send_json(
    writer: &SharedWriter,
    kind: MessageKind,
    request_or_sequence: u64,
    value: &impl serde::Serialize,
) -> Result<()> {
    send_frame(
        writer,
        Frame::new(kind, request_or_sequence, serde_json::to_vec(value)?),
    )
    .await
}

async fn send_frame(writer: &SharedWriter, frame: Frame) -> Result<()> {
    write_frame(&mut *writer.lock().await, &frame)
        .await
        .context("write daemon frame")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn asserting(email: Option<&str>) -> AssertedIdentity {
        AssertedIdentity {
            account_email: email.map(str::to_owned),
            ..AssertedIdentity::default()
        }
    }

    /// The shapes of `data_dir` the account check has to tell apart, next to
    /// each other — the integration tests can only reach the realistic ones,
    /// and the rest are exactly where a path-shaped check goes wrong.
    #[test]
    fn the_account_check_matches_the_account_directory_and_nothing_else() {
        let root = Path::new("/Users/b/Library/Application Support/OmniAgent-ADE");
        let mine = root
            .join("accounts")
            .join(Store::account_dir_id("bruno@bonando.com"));
        let signed_in = Some("bruno@bonando.com");

        assert_eq!(
            viewer_owns_this_account(&asserting(Some("bruno@bonando.com")), &mine, signed_in),
            AccountMatch::Owner
        );
        // Normalized on both halves the way the directory name was chosen,
        // because it is the same function that chose it.
        assert_eq!(
            viewer_owns_this_account(&asserting(Some("  Bruno@Bonando.COM ")), &mine, signed_in),
            AccountMatch::Owner
        );
        assert_eq!(
            viewer_owns_this_account(
                &asserting(Some("bruno@bonando.com")),
                &mine,
                Some(" BRUNO@bonando.com  ")
            ),
            AccountMatch::Owner
        );
        assert_eq!(
            viewer_owns_this_account(&asserting(Some("someone@else.com")), &mine, signed_in),
            AccountMatch::Refused
        );

        // Nothing asserted, and nothing meaningful asserted.
        assert_eq!(
            viewer_owns_this_account(&asserting(None), &mine, signed_in),
            AccountMatch::Refused
        );
        assert_eq!(
            viewer_owns_this_account(&asserting(Some("   ")), &mine, signed_in),
            AccountMatch::Refused
        );

        // Signed out: the data dir is the root, so there is no account — and
        // the answer does not vary with what the caller asserted.
        assert_eq!(
            viewer_owns_this_account(&asserting(Some("bruno@bonando.com")), root, signed_in),
            AccountMatch::HostSignedOut
        );
        assert_eq!(
            viewer_owns_this_account(&asserting(Some("someone@else.com")), root, None),
            AccountMatch::HostSignedOut
        );
        // A directory that merely *ends* in the right name is not an account
        // directory — the parent has to be `accounts`.
        assert_eq!(
            viewer_owns_this_account(
                &asserting(Some("bruno@bonando.com")),
                &root.join(Store::account_dir_id("bruno@bonando.com")),
                signed_in
            ),
            AccountMatch::HostSignedOut
        );
        // …and a path with no final component at all is not one either.
        assert_eq!(
            viewer_owns_this_account(&asserting(Some("bruno@bonando.com")), Path::new("/"), None),
            AccountMatch::HostSignedOut
        );
    }

    /// The second fact, and what it is for (fix round 1, FIX 2).
    ///
    /// The hash half reads only the *shape and name* of a path, so a directory
    /// fabricated at `…/accounts/<the right id>` satisfies it — an env-var
    /// override, a stray copy. Its store is empty, so the row half refuses it.
    /// This is also what stops a truncated 64-bit hash being the only thing
    /// standing between two accounts: the full email is compared as text.
    #[test]
    fn a_directory_that_hashes_right_but_has_no_row_is_still_refused() {
        let fabricated =
            Path::new("/tmp/anywhere/accounts").join(Store::account_dir_id("bruno@bonando.com"));
        let asserted = asserting(Some("bruno@bonando.com"));

        // The hash half alone would say yes to this.
        assert_eq!(
            Store::account_dir_id("bruno@bonando.com"),
            fabricated.file_name().unwrap().to_str().unwrap()
        );
        // No row (an empty store) — refused.
        assert_eq!(
            viewer_owns_this_account(&asserted, &fabricated, None),
            AccountMatch::Refused
        );
        // A blank row is the same case as a missing one.
        assert_eq!(
            viewer_owns_this_account(&asserted, &fabricated, Some("  ")),
            AccountMatch::Refused
        );
        // A row naming somebody else — the directory disagreeing with its own
        // name — is refused too, rather than the hash being allowed to win.
        assert_eq!(
            viewer_owns_this_account(&asserted, &fabricated, Some("someone@else.com")),
            AccountMatch::Refused
        );
        // And with the row present and agreeing, it is the ordinary case.
        assert_eq!(
            viewer_owns_this_account(&asserted, &fabricated, Some("bruno@bonando.com")),
            AccountMatch::Owner
        );
    }

    /// Both tests below mutate the process-global `OMNIAGENT_ADE_DATA_DIR`.
    /// They live here (this unit-test binary) rather than in
    /// `tests/server_protocol.rs`, which runs many concurrent tests that
    /// would race the env var — and they serialize against each other
    /// through this lock, held across the awaits (a tokio mutex, so no
    /// `await_holding_lock` lint).
    static ENV_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    /// Task 6a regression: `bind()` — the real entry point `run_daemon`/
    /// `main.rs` use in production — must resolve the shared brain-store
    /// data directory via `brain_core::Store::default_data_dir()`, honoring
    /// `OMNIAGENT_ADE_DATA_DIR` exactly like every other crate does, and
    /// NOT derive it from the socket path's own parent directory. The bug
    /// this catches: `bind()` used to open `Store::open(runtime_dir)` (the
    /// socket's directory), which silently pointed every brain read — and
    /// the `layout` setting — at an unshared, essentially-empty `brain.db`
    /// instead of the one the app actually reads and writes.
    #[tokio::test]
    async fn bind_resolves_the_shared_data_dir_via_default_data_dir_not_the_socket_path() {
        let _env = ENV_LOCK.lock().await;
        let scratch = tempfile::tempdir().unwrap();
        let data_dir = scratch.path().join("shared-brain-data");
        std::env::set_var("OMNIAGENT_ADE_DATA_DIR", &data_dir);

        let socket_path = scratch
            .path()
            .join("elsewhere-entirely")
            .join("daemon.sock");
        let server = DaemonServer::bind(socket_path).await.unwrap();

        assert_eq!(server.data_dir, data_dir);
        assert_eq!(server.data_dir, Store::default_data_dir());
        // Proves the socket's own directory played no part in the result.
        assert_ne!(server.data_dir, scratch.path().join("elsewhere-entirely"));
        assert!(data_dir.join("brain.db").exists());

        drop(server);
        std::env::remove_var("OMNIAGENT_ADE_DATA_DIR");
    }

    /// The account-scoped workspace (2026-08-30 spec): with a pointer at the
    /// root, `bind()` opens `root/accounts/<id>` — and on the first such
    /// start moves the pre-account `brain.db` there, so the developer's
    /// existing layout, roots and transcripts come back under the account
    /// instead of being left behind at the root.
    #[tokio::test]
    async fn bind_follows_the_current_account_pointer_and_adopts_legacy_data_once() {
        let _env = ENV_LOCK.lock().await;
        let scratch = tempfile::tempdir().unwrap();
        let root = scratch.path().join("root");
        // The pre-account install: a brain.db at the root with a row in it.
        Store::open(&root)
            .unwrap()
            .set_setting("layout", "legacy-layout")
            .unwrap();
        std::fs::write(Store::current_account_file(&root), "fc44b18d5588b1d6\n").unwrap();
        std::env::set_var("OMNIAGENT_ADE_DATA_DIR", &root);

        let socket_path = scratch.path().join("run").join("daemon.sock");
        let server = DaemonServer::bind(socket_path).await.unwrap();

        let account_dir = root.join("accounts").join("fc44b18d5588b1d6");
        assert_eq!(server.data_dir, account_dir);
        assert!(!root.join("brain.db").exists(), "the legacy brain.db moved");
        assert_eq!(
            server
                .settings
                .lock()
                .unwrap()
                .get_setting("layout")
                .unwrap()
                .as_deref(),
            Some("legacy-layout"),
            "and the daemon is serving it from the account dir"
        );

        drop(server);
        std::env::remove_var("OMNIAGENT_ADE_DATA_DIR");
    }
}
