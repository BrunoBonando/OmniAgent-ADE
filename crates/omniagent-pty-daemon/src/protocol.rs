use serde::{Deserialize, Serialize};
use std::fmt;
use std::io;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// The wire version both ends must agree on.
///
/// **2** since environment sharing
/// (`docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`
/// §3 "Protocol version"). Local skew does not happen — the app and the daemon
/// ship in one bundle and `rebuild-app.sh` restarts the daemon with the app —
/// but *remote* skew does: Mac A updated, Mac B not. That is what the bump is
/// for, and it is only useful because the daemon can now say so; see
/// [`read_handshake_frame`].
pub const PROTOCOL_VERSION: u8 = 2;
pub const HEADER_LEN: usize = 16;
pub const MAX_PAYLOAD_LEN: usize = 1024 * 1024;

/// The first frame of every connection.
///
/// `viewer_id`/`machine_name` are what a viewer calls itself (phase 2 spec
/// §5). Both are `Option` so a client older than phase 2 — which sends
/// `{"client": …}` alone — still parses. **Both are self-reported**: what is
/// in this payload is what the connecting client chose to write, and nothing
/// here is ever an account boundary. The daemon records them only for a
/// `ClientTrust::Remote` connection, and they are what its presence roster and
/// its blocklist are keyed on.
///
/// **`viewer_id` is nonetheless decision-bearing in exactly one place, and the
/// scope of that is the whole point.** It is the discriminator on the lease
/// reclaim (`connections::LeaseHolder::is_the_same_viewer_as`): a viewer coming
/// back after a network blip may take the lease from the socket it left
/// behind, and this id is how "the same machine" is recognised. It decides
/// *which machine inside an account that has already been verified* — never
/// which account. `server::viewer_owns_this_account` runs first, on the
/// relay's assertion, and refuses everyone who is not the account this daemon
/// serves; both sides of that comparison are therefore the same person by the
/// time the id is read, and a forged id cannot cross an account boundary.
///
/// Which is also the rule for whatever is added here next: the moment a check
/// reads a field of this struct *before* `viewer_owns_this_account` has run,
/// it is a check the caller gets to answer for itself. The trusted half of an
/// identity is [`crate::AssertedIdentity`]; it never travels in this payload
/// and cannot be reached from it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HelloPayload {
    pub client: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub viewer_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub machine_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HelloAckPayload {
    pub protocol_version: u8,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionListPayload {
    pub sessions: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionCreatedPayload {
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttachPayload {
    pub id: String,
    pub after_sequence: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionIdPayload {
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResizePayload {
    pub id: String,
    pub cols: u16,
    pub rows: u16,
    #[serde(default)]
    pub pixel_width: u16,
    #[serde(default)]
    pub pixel_height: u16,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettingKey {
    pub key: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SettingValue {
    pub key: String,
    pub value: String,
}

/// `BrainGetContext` request payload — the project id, mirroring
/// `mcp_server::tools::get_context`'s frozen `{project}` argument shape.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrainGetContextPayload {
    pub project: String,
}

/// `BrainSearch` request payload — mirrors `mcp_server::tools::search_brain`'s
/// frozen `{query, scope?}` argument shape (Task 6a-2).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrainSearchPayload {
    pub query: String,
    #[serde(default)]
    pub scope: Option<String>,
}

/// `RootsStartIngest` request payload — the root folder to scan for
/// projects (Task 6a-2, mirrors `src-tauri`'s `roots_start_ingest` command's
/// `path` argument).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RootsStartIngestPayload {
    pub path: String,
}

/// `RootsAddProject` request payload (Task 6a-2, mirrors `add_project`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RootsAddProjectPayload {
    pub path: String,
    #[serde(default)]
    pub name: Option<String>,
}

/// `RootsRenameProject` request payload (Task 6a-2, mirrors `rename_project`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RootsRenameProjectPayload {
    pub id: String,
    pub new_label: String,
}

/// `RootsSetPaused` request payload (Task 6a-2, mirrors `roots_set_paused`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RootsSetPausedPayload {
    pub project: String,
    pub paused: bool,
}

/// `RootsReingestProject` request payload (Task 6a-2, mirrors
/// `roots_reingest_project`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RootsReingestProjectPayload {
    pub project: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResponsePayload {
    pub ok: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorPayload {
    pub message: String,
    /// A stable, machine-readable reason for a `Hello` refusal (Task 14 item
    /// 2; spec §3, §9, §12 invariant 10), carried alongside — never instead
    /// of — `message`.
    ///
    /// **Why this exists**: `message` is display text, free to reword, and
    /// `server.rs`'s `Hello` arm composes five different sentences for it
    /// (six call sites — the blocklist is checked twice, once before a viewer
    /// is registered and once after, for the race window between the two).
    /// Before this field, `SessionConnection.isTerminalRefusal` decided
    /// whether to keep retrying by prefix-matching that prose — a copy edit
    /// to any sentence could silently misclassify a refusal, and nothing
    /// would catch it, because the two sides shared no contract but an
    /// English string one of them composes and the other guesses at. `code`
    /// is that contract instead: [`RefusalCode`], not a sentence.
    ///
    /// Present on every refusal `server.rs`'s `Hello` arm sends; absent on
    /// every other `Error` this daemon ever sends (a `ListDirectory` failure,
    /// a malformed request, and so on — refusing a *connection* is not the
    /// same thing as failing one *request* on an admitted connection, and
    /// only the former carries a code), and absent on any `Error` a daemon
    /// built before this field existed sends. A decoder must treat "no code"
    /// and "a code this build does not recognise" identically — see
    /// [`RefusalCode`]'s doc comment for why, and
    /// `SessionConnection.isTerminalRefusal`
    /// (`macos/OmniAgent/SessionConnection.swift`) for where that rule lives
    /// on the other end of this wire.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub code: Option<RefusalCode>,
}

/// The machine-readable reason behind one `Hello` refusal (Task 14 item 2).
/// See [`ErrorPayload::code`] for why this exists at all.
///
/// **Only [`RefusalCode::VersionSkew`] is terminal** — the one refusal a
/// retry cannot fix, because nothing changes until a human updates the Mac
/// named in the sentence next to it. Every other variant clears itself:
/// the machine currently driving disconnects, the blocklist is lifted, the
/// host signs in, or the account you dialled with catches up to the one the
/// Mac is actually serving. `SessionConnection.isTerminalRefusal` is the one
/// place that reads this type, and it must keep exactly that classification.
///
/// Wire values are `snake_case` (`#[serde(rename_all = "snake_case")]`) and
/// mirrored — as a set of raw string literals, not a shared source of truth;
/// there is no codegen between this crate and the Swift app — by a private
/// `RefusalCode` enum next to `SessionConnection.isTerminalRefusal`. **A new
/// variant here needs its Swift counterpart added in the same change**, but
/// the reverse mistake (Swift running ahead, or simply older) is
/// deliberately harmless: an app that receives a code string it does not
/// recognise, or receives no `code` field at all, treats it as non-terminal
/// and keeps retrying rather than guessing wrong and parking a connection
/// that could have healed itself. See `crates/omniagent-pty-daemon/tests/remote_refusal_codes.rs`
/// for the daemon-side pin that each refusal in the `Hello` arm carries the
/// code this comment promises, independent of its sentence's wording.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RefusalCode {
    /// The peer speaks a different [`PROTOCOL_VERSION`]. Terminal: dialling
    /// again cannot change what version the other Mac's daemon speaks.
    VersionSkew,
    /// Another machine currently holds the lease (spec §3 "The lease").
    LeaseHeld,
    /// This machine is not reachable right now — sharing is off, or no local
    /// app is attached (spec §2 condition 3, §3 "One remote session per
    /// machine, in either direction").
    MachineUnavailable,
    /// Nobody is signed in to OmniAgent on this Mac.
    HostSignedOut,
    /// This Mac is signed in to an OmniAgent account other than the one
    /// asserted for the caller.
    WrongAccount,
    /// This viewer id is on `remote_control_blocked`.
    Blocked,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionStatus {
    Ready,
    Thinking,
    ToolExecution,
    AwaitingApproval,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionStatusPayload {
    pub id: String,
    pub status: SessionStatus,
    pub notify: bool,
    pub engine: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AttentionPayload {
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResyncRequiredPayload {
    pub id: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionExitedPayload {
    pub id: String,
    pub exit_code: Option<u32>,
}

/// The grid a session is currently running at — the one the host owns
/// (phase 2 spec §1). Sent on `Attach` and pushed on every accepted resize
/// so a remote viewer can render that grid scaled instead of imposing its
/// own window's size on the host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionSizePayload {
    pub id: String,
    pub cols: u16,
    pub rows: u16,
}

/// One machine currently watching sessions on this daemon — an entry of both
/// the `RemoteViewers` push and the `ListViewers` reply (phase 2 §5).
///
/// **Two halves, kept apart on the wire the way they are kept apart in the
/// registry.** `viewer_id` and `machine_name` are what the connecting app
/// said about itself in `Hello`
/// ([`crate::connections::ViewerIdentity`]); the four `Option` fields below
/// are what the *relay* asserted about the connection
/// ([`crate::connections::AssertedIdentity`], spec §9), which is a different
/// kind of fact and is marked as such in the host's takeover panel (§7:
/// "A small verified glyph marks the fields the relay asserted"). A panel
/// that could not tell the two apart would be worse than no panel, so the
/// distinction survives the trip rather than being flattened into one bag of
/// strings here.
///
/// Every asserted field is optional and omitted when absent, never
/// stringified into `""`: the relay sends what it knows and does not invent
/// the rest (§9, "City is omitted, not faked"), and a row with no value is
/// omitted from the panel entirely rather than drawn blank.
///
/// This payload only ever reaches **local** connections
/// ([`crate::connections::ConnectionRegistry::presence_updates`]), so
/// carrying an identity here tells a viewer nothing about itself or anyone
/// else.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ViewerSummaryPayload {
    pub viewer_id: String,
    pub machine_name: String,
    /// The pane ids this viewer is attached to right now.
    pub sessions: Vec<String>,
    /// RFC 3339, when this viewer connected.
    pub since: String,
    /// Relay-asserted: the account the viewer's JWT is signed in as.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_email: Option<String>,
    /// Relay-asserted: `CF-Connecting-IP` at the edge.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ip: Option<String>,
    /// Relay-asserted: `CF-IPCountry` at the edge.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub country: Option<String>,
    /// The viewer app's user agent as the relay saw it. Relayed, but *set by
    /// the client* — unlike `ip`/`country` (Cloudflare's) and
    /// `account_email` (a verified JWT's), nobody checked it. The host's
    /// panel therefore shows what it carries (app version, OS) unmarked,
    /// beside the self-reported machine name.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client: Option<String>,
}

/// The presence roster: the `RemoteViewers` push payload and, on the same
/// shape, the `ListViewers` reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct RemoteViewersPayload {
    pub viewers: Vec<ViewerSummaryPayload>,
}

/// `DisconnectViewer` request payload — kick, and optionally block, one
/// machine (phase 2 §5; `block` since Task 14, spec §7).
///
/// Terminate and Block are two different verbs: `block: false` drops the
/// socket and leaves the machine free to reconnect at once; `block: true`
/// additionally appends `viewer_id` to `remote_control_blocked`, so it is
/// refused on its next `Hello` too. `#[serde(default = "default_true")]`
/// keeps `block` absent meaning what `DisconnectViewer` always meant before
/// this field existed — a caller built before Task 14 sends no `block` at
/// all, and must go on getting phase 2's behaviour rather than silently
/// switching to Terminate underneath it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DisconnectViewerPayload {
    pub viewer_id: String,
    #[serde(default = "default_true")]
    pub block: bool,
}

fn default_true() -> bool {
    true
}

/// `ListDirectory` request payload — one absolute path on the host (phase 3
/// spec §4). `show_hidden` defaults to false, so a client that does not know
/// about the flag gets a folder picker's list rather than the host's dotfiles.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ListDirectoryPayload {
    pub path: String,
    #[serde(default)]
    pub show_hidden: bool,
}

/// One entry of a [`DirectoryListingPayload`]: a name and whether it is a
/// directory. **That is the whole shape, and it is a boundary, not an
/// oversight** — no size, no mode, no timestamp, and above all no contents.
/// `ListDirectory` exists so a remote can pick a folder; there is no file-read
/// RPC in this system, which is what lets phase 3 spec §12 invariant 8 say the
/// activity log is not remotely readable.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DirectoryEntryPayload {
    pub name: String,
    pub is_dir: bool,
}

/// The `ListDirectory` reply, carried by the ordinary [`MessageKind::Response`]
/// like every other Roots RPC's answer — there is deliberately no new response
/// kind for it. Sorted directories-first, then case-insensitively by name.
///
/// `truncated` says the directory held more than [`LIST_DIRECTORY_MAX_ENTRIES`]
/// and the tail was dropped. A caller must render it: silently showing part of
/// a directory as if it were the whole one is how a folder picker lies.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct DirectoryListingPayload {
    pub entries: Vec<DirectoryEntryPayload>,
    pub truncated: bool,
}

/// The most entries one `ListDirectory` reply carries.
///
/// This is a frame-size limit, not a taste one. A reply larger than
/// [`MAX_PAYLOAD_LEN`] cannot be written at all, and the failure is ugly: the
/// dispatch's `send_json` errors, the connection is dropped, and the remote
/// gets no `Error` frame — it just dies. `node_modules` and `/usr/bin` reach
/// these sizes, so this is a real directory, not an adversarial one.
///
/// The number comes from the worst case, which a lease holder can create on
/// purpose (it has a shell): macOS caps a filename at 255 bytes, and a name of
/// 255 control bytes JSON-escapes to `\u00XX` six bytes apiece — 1530 bytes,
/// plus about 30 for `{"name":…,"is_dir":false},`. At 1561 bytes an entry,
/// 512 entries is roughly 799 KB, comfortably inside the 1 MiB cap with the
/// envelope. Ordinary names run about 50 bytes, so the real ceiling this
/// imposes is the count, not the bytes.
pub const LIST_DIRECTORY_MAX_ENTRIES: usize = 512;

/// The arithmetic above, enforced by the compiler rather than trusted: raising
/// [`LIST_DIRECTORY_MAX_ENTRIES`] past what a frame can hold fails the build
/// instead of failing a connection. A worst-case entry is a 255-byte name of
/// control bytes at six bytes apiece, plus about 30 for the surrounding JSON.
const _: () = assert!(LIST_DIRECTORY_MAX_ENTRIES * (255 * 6 + 30) < MAX_PAYLOAD_LEN);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum MessageKind {
    Hello = 0x01,
    ListSessions = 0x02,
    CreateSession = 0x03,
    Attach = 0x04,
    Input = 0x05,
    Resize = 0x06,
    Interrupt = 0x07,
    Kill = 0x08,
    Detach = 0x09,
    GetSetting = 0x0a,
    SetSetting = 0x0b,
    /// Brain-store read: every ingested project, `mcp_server::tools::list_projects`'s
    /// `{id, label, path}` shape (Task 6a — appended, never renumbering an
    /// existing kind).
    BrainListProjects = 0x0c,
    /// Brain-store read: one project's briefing block, `mcp_server::tools::get_context`'s
    /// `{summary, recent_decisions, related_projects, memory_notes}` shape
    /// (Task 6a — appended, never renumbering an existing kind).
    BrainGetContext = 0x0d,
    /// Persists a project root and kicks off background ingestion under it
    /// (Task 6a-2 — appended, never renumbering an existing kind). Mirrors
    /// `src-tauri`'s `roots_start_ingest` command.
    RootsStartIngest = 0x0e,
    /// Polls the daemon's own `IngestionState` snapshot (Task 6a-2). Mirrors
    /// `ingestion_status`.
    RootsIngestionStatus = 0x0f,
    /// Every persisted project root (Task 6a-2). Mirrors `roots_list`.
    RootsList = 0x10,
    /// The project with the most nodes in the store (Task 6a-2). Mirrors
    /// `roots_biggest_project`.
    RootsBiggestProject = 0x11,
    /// Adds exactly one project directory, synchronously creating its node
    /// and kicking off background ingestion (Task 6a-2). Mirrors
    /// `add_project`.
    RootsAddProject = 0x12,
    /// Overrides a project's display label (Task 6a-2). Mirrors
    /// `rename_project`.
    RootsRenameProject = 0x13,
    /// Every project id currently marked paused (Task 6a-2). Mirrors
    /// `roots_paused_projects`.
    RootsPausedProjects = 0x14,
    /// Marks a project paused/unpaused for future ingest/rebuild passes
    /// (Task 6a-2). Mirrors `roots_set_paused`.
    RootsSetPaused = 0x15,
    /// Every project's staleness reading (Task 6a-2). Mirrors
    /// `roots_staleness`.
    RootsStaleness = 0x16,
    /// Manual "re-check" for one already-known project (Task 6a-2). Mirrors
    /// `roots_reingest_project`.
    RootsReingestProject = 0x17,
    /// "Rebuild brain": wipes and re-ingests the whole store (Task 6a-2).
    /// Mirrors `roots_rebuild`.
    RootsRebuild = 0x18,
    /// Full-text search over the local knowledge graph (Task 6a-2) —
    /// `mcp_server::tools::search_brain`, left unwired by Task 6a and closed
    /// here so the native command palette's brain search has a route.
    BrainSearch = 0x19,
    /// The roster of remote viewers attached to this daemon, on demand
    /// (phase 2 §5 — appended, never renumbering an existing kind).
    /// Local-only: it is nowhere in [`crate::authorize_remote`]'s allow
    /// arms, so a remote client is answered with `Error`.
    ListViewers = 0x1a,
    /// Kicks one remote viewer and blocks it until Remote Control is turned
    /// on again (phase 2 §5). Local-only, like `ListViewers`.
    DisconnectViewer = 0x1b,
    // 0x1c is reserved for phase 3's `PublishHostState` (spec §4), which
    // lands with the host-state feed. Left as a hole rather than reused:
    // discriminants are appended and never renumbered, and a hole costs
    // nothing next to two Macs disagreeing about what a byte means.
    /// One directory's entries on the host — `[{name, is_dir}]` via the
    /// ordinary `Response` (phase 3 spec §4). Remote-reachable: it is what
    /// makes "Add local folder…" browse the *host's* disk instead of the
    /// viewer's. It returns names and kinds only — no contents, no sizes,
    /// no modes — and it is deliberately the closest this protocol comes to
    /// a remote file read.
    ListDirectory = 0x1d,
    HelloAck = 0x81,
    SessionList = 0x82,
    SessionCreated = 0x83,
    Snapshot = 0x84,
    Output = 0x85,
    SessionStatus = 0x86,
    Attention = 0x87,
    SessionExited = 0x88,
    Response = 0x89,
    ResyncRequired = 0x8a,
    Error = 0x8b,
    /// The session's current grid, `SessionSizePayload` (phase 2 §1 —
    /// appended, never renumbering an existing kind). Sent on `Attach` and
    /// pushed to a session's subscribers whenever its size changes; a local
    /// client ignores it, a remote viewer re-pins its scaled render to it.
    SessionResized = 0x8c,
    /// The presence roster, [`RemoteViewersPayload`] (phase 2 §5 — appended,
    /// never renumbering an existing kind). Pushed to **local** connections
    /// only, whenever the set of identified remote viewers or what they are
    /// attached to changes: a viewer never learns about other viewers.
    RemoteViewers = 0x8d,
    // 0x8e is reserved for phase 5's `HostState` push (spec §4), which lands
    // with the host-state feed — the same reasoning 0x1c is left as a hole
    // for `PublishHostState`: discriminants are appended and never
    // renumbered, and a hole costs nothing next to two Macs disagreeing
    // about what a byte means.
    /// One batch of daemon-witnessed activity rows,
    /// [`crate::activity::RemoteActivityPayload`] (phase 3 spec §8 — Task
    /// 19). Pushed to **local** connections only, exactly like
    /// `RemoteViewers`: a remote viewer must never learn what the log says
    /// about it, so this is deliberately absent from
    /// `crate::authorize_remote`'s allowlist rather than merely unreachable
    /// by convention.
    RemoteActivity = 0x8f,
}

impl TryFrom<u8> for MessageKind {
    type Error = FrameError;

    fn try_from(value: u8) -> Result<Self, FrameError> {
        Ok(match value {
            0x01 => Self::Hello,
            0x02 => Self::ListSessions,
            0x03 => Self::CreateSession,
            0x04 => Self::Attach,
            0x05 => Self::Input,
            0x06 => Self::Resize,
            0x07 => Self::Interrupt,
            0x08 => Self::Kill,
            0x09 => Self::Detach,
            0x0a => Self::GetSetting,
            0x0b => Self::SetSetting,
            0x0c => Self::BrainListProjects,
            0x0d => Self::BrainGetContext,
            0x0e => Self::RootsStartIngest,
            0x0f => Self::RootsIngestionStatus,
            0x10 => Self::RootsList,
            0x11 => Self::RootsBiggestProject,
            0x12 => Self::RootsAddProject,
            0x13 => Self::RootsRenameProject,
            0x14 => Self::RootsPausedProjects,
            0x15 => Self::RootsSetPaused,
            0x16 => Self::RootsStaleness,
            0x17 => Self::RootsReingestProject,
            0x18 => Self::RootsRebuild,
            0x19 => Self::BrainSearch,
            0x1a => Self::ListViewers,
            0x1b => Self::DisconnectViewer,
            0x1d => Self::ListDirectory,
            0x81 => Self::HelloAck,
            0x82 => Self::SessionList,
            0x83 => Self::SessionCreated,
            0x84 => Self::Snapshot,
            0x85 => Self::Output,
            0x86 => Self::SessionStatus,
            0x87 => Self::Attention,
            0x88 => Self::SessionExited,
            0x89 => Self::Response,
            0x8a => Self::ResyncRequired,
            0x8b => Self::Error,
            0x8c => Self::SessionResized,
            0x8d => Self::RemoteViewers,
            0x8f => Self::RemoteActivity,
            other => return Err(FrameError::UnknownMessageKind(other)),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Header {
    pub payload_length: u32,
    pub protocol_version: u8,
    pub message_kind: MessageKind,
    pub flags: u16,
    pub request_or_sequence: u64,
}

impl Header {
    pub fn decode(bytes: [u8; HEADER_LEN]) -> Result<Self, FrameError> {
        let header = Self::decode_any_version(bytes)?;
        if header.protocol_version != PROTOCOL_VERSION {
            return Err(FrameError::UnsupportedVersion(header.protocol_version));
        }
        Ok(header)
    }

    /// [`Self::decode`] without the version check — everything else about the
    /// envelope is still validated.
    ///
    /// Used for exactly one frame, the handshake ([`read_handshake_frame`]),
    /// because a version byte that cannot be read is a version skew that
    /// cannot be reported: the strict decoder's answer to an old peer is a
    /// dropped stream, which the peer reads as an outage and answers with a
    /// reconnect loop. Every subsequent frame goes through [`Self::decode`]
    /// and a mismatch still ends the connection.
    fn decode_any_version(bytes: [u8; HEADER_LEN]) -> Result<Self, FrameError> {
        let payload_length = u32::from_be_bytes(bytes[0..4].try_into().unwrap());
        if payload_length as usize > MAX_PAYLOAD_LEN {
            return Err(FrameError::PayloadTooLarge(payload_length as usize));
        }
        let flags = u16::from_be_bytes(bytes[6..8].try_into().unwrap());
        if flags != 0 {
            return Err(FrameError::UnsupportedFlags(flags));
        }
        Ok(Self {
            payload_length,
            protocol_version: bytes[4],
            message_kind: bytes[5].try_into()?,
            flags,
            request_or_sequence: u64::from_be_bytes(bytes[8..16].try_into().unwrap()),
        })
    }

    fn encode(&self) -> [u8; HEADER_LEN] {
        let mut bytes = [0; HEADER_LEN];
        bytes[0..4].copy_from_slice(&self.payload_length.to_be_bytes());
        bytes[4] = self.protocol_version;
        bytes[5] = self.message_kind as u8;
        bytes[6..8].copy_from_slice(&self.flags.to_be_bytes());
        bytes[8..16].copy_from_slice(&self.request_or_sequence.to_be_bytes());
        bytes
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub header: Header,
    pub payload: Vec<u8>,
}

impl Frame {
    pub fn new(message_kind: MessageKind, request_or_sequence: u64, payload: Vec<u8>) -> Self {
        Self {
            header: Header {
                payload_length: payload.len() as u32,
                protocol_version: PROTOCOL_VERSION,
                message_kind,
                flags: 0,
                request_or_sequence,
            },
            payload,
        }
    }

    pub fn encode(&self) -> Result<Vec<u8>, FrameError> {
        if self.payload.len() > MAX_PAYLOAD_LEN {
            return Err(FrameError::PayloadTooLarge(self.payload.len()));
        }
        let mut bytes = Vec::with_capacity(HEADER_LEN + self.payload.len());
        let mut header = self.header.clone();
        header.payload_length = self.payload.len() as u32;
        bytes.extend_from_slice(&header.encode());
        bytes.extend_from_slice(&self.payload);
        Ok(bytes)
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, FrameError> {
        if bytes.len() < HEADER_LEN {
            return Err(FrameError::TruncatedHeader);
        }
        let header = Header::decode(bytes[..HEADER_LEN].try_into().unwrap())?;
        let actual = bytes.len() - HEADER_LEN;
        let expected = header.payload_length as usize;
        if actual < expected {
            return Err(FrameError::TruncatedPayload { expected, actual });
        }
        if actual > expected {
            return Err(FrameError::TrailingBytes(actual - expected));
        }
        Ok(Self {
            header,
            payload: bytes[HEADER_LEN..].to_vec(),
        })
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FrameError {
    TruncatedHeader,
    TruncatedPayload { expected: usize, actual: usize },
    TrailingBytes(usize),
    PayloadTooLarge(usize),
    UnsupportedVersion(u8),
    UnknownMessageKind(u8),
    UnsupportedFlags(u16),
    InvalidRawPayload,
    InvalidSessionId,
    SessionIdTooLong(usize),
}

impl fmt::Display for FrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}

impl std::error::Error for FrameError {}

pub fn encode_raw_payload(session_id: &str, raw: &[u8]) -> Result<Vec<u8>, FrameError> {
    let id_len = u16::try_from(session_id.len())
        .map_err(|_| FrameError::SessionIdTooLong(session_id.len()))?;
    let payload_len = 2usize
        .checked_add(session_id.len())
        .and_then(|len| len.checked_add(raw.len()))
        .ok_or(FrameError::PayloadTooLarge(usize::MAX))?;
    if payload_len > MAX_PAYLOAD_LEN {
        return Err(FrameError::PayloadTooLarge(payload_len));
    }
    let mut payload = Vec::with_capacity(payload_len);
    payload.extend_from_slice(&id_len.to_be_bytes());
    payload.extend_from_slice(session_id.as_bytes());
    payload.extend_from_slice(raw);
    Ok(payload)
}

pub fn decode_raw_payload(payload: &[u8]) -> Result<(&str, &[u8]), FrameError> {
    if payload.len() < 2 {
        return Err(FrameError::InvalidRawPayload);
    }
    let id_len = u16::from_be_bytes(payload[..2].try_into().unwrap()) as usize;
    let raw_start = 2usize
        .checked_add(id_len)
        .filter(|start| *start <= payload.len())
        .ok_or(FrameError::InvalidRawPayload)?;
    let session_id =
        std::str::from_utf8(&payload[2..raw_start]).map_err(|_| FrameError::InvalidSessionId)?;
    Ok((session_id, &payload[raw_start..]))
}

pub async fn read_frame(reader: &mut (impl AsyncRead + Unpin)) -> io::Result<Frame> {
    read_with(reader, Header::decode).await
}

/// Reads a connection's **first** frame, whatever protocol version it claims.
///
/// The handshake is the one frame that has to cross a version boundary, in
/// both directions: a peer on the old protocol must be readable enough to be
/// told to update, and the refusal must be written back in *its* version or it
/// is bytes that peer's decoder throws away. `serve_client` reads the `Hello`
/// with this and then decides; the rest of the connection is
/// [`read_frame`], where a mismatched version still ends the stream.
pub async fn read_handshake_frame(reader: &mut (impl AsyncRead + Unpin)) -> io::Result<Frame> {
    read_with(reader, Header::decode_any_version).await
}

async fn read_with(
    reader: &mut (impl AsyncRead + Unpin),
    decode: fn([u8; HEADER_LEN]) -> Result<Header, FrameError>,
) -> io::Result<Frame> {
    let mut header_bytes = [0; HEADER_LEN];
    reader.read_exact(&mut header_bytes).await?;
    let header =
        decode(header_bytes).map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    let mut payload = vec![0; header.payload_length as usize];
    reader.read_exact(&mut payload).await?;
    Ok(Frame { header, payload })
}

pub async fn write_frame(writer: &mut (impl AsyncWrite + Unpin), frame: &Frame) -> io::Result<()> {
    let bytes = frame
        .encode()
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
    writer.write_all(&bytes).await?;
    writer.flush().await
}
