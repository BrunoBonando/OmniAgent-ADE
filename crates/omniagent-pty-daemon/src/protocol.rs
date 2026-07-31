use serde::{Deserialize, Serialize};
use std::fmt;
use std::io;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const PROTOCOL_VERSION: u8 = 1;
pub const HEADER_LEN: usize = 16;
pub const MAX_PAYLOAD_LEN: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HelloPayload {
    pub client: String,
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
        let payload_length = u32::from_be_bytes(bytes[0..4].try_into().unwrap());
        if payload_length as usize > MAX_PAYLOAD_LEN {
            return Err(FrameError::PayloadTooLarge(payload_length as usize));
        }
        if bytes[4] != PROTOCOL_VERSION {
            return Err(FrameError::UnsupportedVersion(bytes[4]));
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
    let mut header_bytes = [0; HEADER_LEN];
    reader.read_exact(&mut header_bytes).await?;
    let header = Header::decode(header_bytes)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
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
