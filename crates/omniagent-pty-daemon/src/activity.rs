//! Frames become rows, then rows survive the connection — spec §8
//! (`docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`).
//!
//! **The whole argument for this file is who witnesses what.** Nothing here
//! is reported by the viewer about itself: [`ActivityLog::record`] maps a
//! [`Frame`] the daemon actually received into an [`ActivityEntry`], and
//! [`append`] persists it. A self-reported audit trail on a security surface
//! is worse than none, because it looks like evidence — so a row exists only
//! when the wire carried the frame that caused it.
//!
//! [`ActivityLog::record`] is one `match` on [`MessageKind`], producing
//! exactly the mutating frames a remote client can reach
//! (`crate::authorize_remote`'s allowlist): every kind that only *reads* the
//! machine (`ListSessions`, `GetSetting`, `BrainListProjects`,
//! `BrainGetContext`, the read-only `Roots*` status queries) produces no row,
//! because nothing happened to log. `Resize` and `Detach` are mutating-ish
//! but deliberately silent too: a live grid follows the driver's window
//! continuously, and a row for every frame of a window drag is exactly the
//! "Input 12 bytes" noise this log exists to avoid; `Detach` drops a
//! subscription, not the session underneath it. Every other reachable kind —
//! `Attach`, `CreateSession`, `Input` (coalesced), `Interrupt`, `Kill`,
//! `SetSetting`, every mutating `Roots*` kind, `ListDirectory`, `BrainSearch`
//! — produces one.
//!
//! Connection-opened/closed rows (spec §8's other two table rows) are not
//! built here: by the time a frame reaches [`ActivityLog::record`], `Hello`
//! has already been consumed by the handshake and a close is not a frame at
//! all. Both are events the dispatch loop itself observes directly, with
//! the connection's own [`crate::AssertedIdentity`]/timing in hand — Task 19
//! builds those two rows at the point it already has that context, rather
//! than this module inventing a second, frame-shaped API for events that
//! are not frames.

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{self, Write};
use std::path::Path;
use std::time::{Duration, Instant, SystemTime};

use brain_core::redact::redact;
use serde::{Deserialize, Serialize};

use crate::protocol::{
    decode_raw_payload, AttachPayload, BrainSearchPayload, Frame, ListDirectoryPayload,
    MessageKind, RootsAddProjectPayload, RootsReingestProjectPayload, RootsRenameProjectPayload,
    RootsSetPausedPayload, RootsStartIngestPayload, SessionIdPayload, SettingValue,
};
use crate::CreateSession;

/// One row of the daemon-witnessed remote activity log.
///
/// `detail` is `None` exactly when `summary` already says everything there
/// is to say — a row with nothing more does not expand (spec §8: "clicking a
/// session is one line and no detail"). Task 19 pushes these as
/// `RemoteActivity` (`0x8f`) and Task 20 renders them, so the shape is a
/// contract those two consume: keep it small and stable.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ActivityEntry {
    pub ts: SystemTime,
    /// A short, stable machine tag — `"attach"`, `"create_session"`,
    /// `"input"`, `"interrupt"`, `"kill"`, `"set_setting"`, `"roots"`,
    /// `"list_directory"`, `"brain_search"` — for Task 20 to group or icon
    /// rows by, never itself shown as the row's text.
    pub kind: &'static str,
    /// One line, human, no ids.
    pub summary: String,
    /// Shown when the row is expanded.
    pub detail: Option<String>,
}

/// Resolves protocol ids into the words a person reads — pane titles,
/// session names, workspace names, engines — by reading the daemon's own
/// `layout` settings row (`PersistedLayoutCodec`'s JSON shape,
/// `macos/OmniAgent/PersistedLayout.swift`: `{"tabs":[{"project","engine",
/// "cwd","id","label","group","groupLabel",…}]}`). Never by asking the
/// connecting client, and never anything the app itself is asked for live.
///
/// **Caching is the caller's job, not this type's.** [`Self::from_layout`]
/// is a pure function of the row's text — the daemon reads the row lazily
/// per connection and caches the resulting context for the connection's
/// life, rebuilding it when a `SetSetting("layout")` frame arrives (that
/// invalidation lives in Task 19's per-connection dispatch state, which
/// already owns the settings store this row comes from).
///
/// A pane id absent from the row — not yet persisted, or a session created
/// moments ago — resolves to itself rather than being dropped: an
/// unattributable action is exactly the one worth logging (spec §8).
#[derive(Debug, Clone, Default)]
pub struct ActivityContext {
    panes: HashMap<String, PaneInfo>,
}

#[derive(Debug, Clone)]
struct PaneInfo {
    title: String,
    session: String,
    workspace: String,
    engine: String,
}

#[derive(Debug, Default, Deserialize)]
struct LayoutFile {
    #[serde(default)]
    tabs: Vec<LayoutTab>,
}

#[derive(Debug, Default, Deserialize)]
struct LayoutTab {
    #[serde(default)]
    project: String,
    #[serde(default)]
    engine: String,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    label: Option<String>,
    #[serde(default)]
    group: Option<String>,
    #[serde(default, rename = "groupLabel")]
    group_label: Option<String>,
}

impl ActivityContext {
    /// Builds a context from the raw `layout` settings row (`GetSetting`'s
    /// `value`, i.e. `Store::get_setting("layout")`'s result). `None`, empty,
    /// or malformed JSON all resolve to an empty context — the safe
    /// direction, since every lookup then falls back to the raw id it was
    /// asked about rather than the daemon guessing at a shape it could not
    /// parse.
    pub fn from_layout(raw: Option<&str>) -> Self {
        let Some(file) = raw
            .filter(|raw| !raw.is_empty())
            .and_then(|raw| serde_json::from_str::<LayoutFile>(raw).ok())
        else {
            return Self::default();
        };

        // Two passes, the same shape as the app's own `SessionOutline.group`/
        // `paneLabel`: group tabs by (workspace, session) in first-seen
        // order, then hand a derived "Session N"/"Terminal N" to whichever
        // ones nobody named.
        let mut workspace_order: Vec<String> = Vec::new();
        let mut group_order: HashMap<String, Vec<String>> = HashMap::new();
        let mut group_tabs: HashMap<(String, String), Vec<&LayoutTab>> = HashMap::new();
        let mut group_label: HashMap<(String, String), String> = HashMap::new();

        for tab in &file.tabs {
            let workspace = tab.project.clone();
            let group = tab.group.clone().unwrap_or_default();
            let key = (workspace.clone(), group.clone());
            if !group_tabs.contains_key(&key) {
                if !group_order.contains_key(&workspace) {
                    workspace_order.push(workspace.clone());
                }
                group_order
                    .entry(workspace.clone())
                    .or_default()
                    .push(group);
            }
            group_tabs.entry(key.clone()).or_default().push(tab);
            if let std::collections::hash_map::Entry::Vacant(slot) = group_label.entry(key) {
                if let Some(label) = tab
                    .group_label
                    .as_deref()
                    .map(str::trim)
                    .filter(|label| !label.is_empty())
                {
                    slot.insert(label.to_string());
                }
            }
        }

        let mut panes = HashMap::new();
        for workspace in &workspace_order {
            let workspace_name = last_path_segment(workspace);
            for (session_index, group) in group_order[workspace].iter().enumerate() {
                let key = (workspace.clone(), group.clone());
                let session_name = group_label
                    .get(&key)
                    .cloned()
                    .unwrap_or_else(|| format!("Session {}", session_index + 1));
                for (pane_index, tab) in group_tabs[&key].iter().enumerate() {
                    let Some(id) = tab.id.clone() else {
                        continue;
                    };
                    let title = tab
                        .label
                        .as_deref()
                        .map(str::trim)
                        .filter(|label| !label.is_empty())
                        .map(str::to_string)
                        .unwrap_or_else(|| format!("Terminal {}", pane_index + 1));
                    panes.insert(
                        id,
                        PaneInfo {
                            title,
                            session: session_name.clone(),
                            workspace: workspace_name.clone(),
                            engine: tab.engine.clone(),
                        },
                    );
                }
            }
        }

        Self { panes }
    }

    /// A fixture for this module's tests and `tests/remote_activity.rs`: one
    /// pane, `pane-1`, an unnamed `claude` terminal — "Terminal 1" — in the
    /// workspace's first, unnamed session — "Session 1" — of workspace
    /// "OmniAgent-ADE". The same shape a real `layout` row with one session
    /// and one pane, neither ever renamed, produces.
    pub fn fixture() -> Self {
        Self::from_layout(Some(
            r#"{"tabs":[{"project":"/Users/bruno/Bruno.Digital/OmniAgent-ADE","engine":"claude","cwd":"/tmp","id":"pane-1","group":"g1"}]}"#,
        ))
    }

    /// The pane's own name, e.g. "Terminal 1" — or the raw id when the pane
    /// is not (yet, or no longer) in the layout row.
    fn pane_title(&self, id: &str) -> String {
        self.panes
            .get(id)
            .map(|pane| pane.title.clone())
            .unwrap_or_else(|| id.to_string())
    }

    /// "Terminal 1 (claude)" — an `Input` row's pane name. Falls back to the
    /// bare pane name (in turn falling back to the raw id) when the engine
    /// is not on record.
    fn pane_with_engine(&self, id: &str) -> String {
        match self.panes.get(id) {
            Some(pane) if !pane.engine.is_empty() => format!("{} ({})", pane.title, pane.engine),
            _ => self.pane_title(id),
        }
    }

    /// "Terminal 1 in Session 1 · OmniAgent-ADE" — an `Attach` row's full
    /// location. Falls back to the raw id when the pane is unknown, rather
    /// than a half-filled sentence about a session and workspace nobody can
    /// name either.
    fn pane_location(&self, id: &str) -> String {
        match self.panes.get(id) {
            Some(pane) => format!("{} in {} · {}", pane.title, pane.session, pane.workspace),
            None => id.to_string(),
        }
    }
}

/// The last non-empty `/`-separated segment of a workspace's absolute path —
/// what a workspace prints when nobody has given it a custom label. The
/// daemon has no access to the brain's project-label cache from a settings
/// row alone, so a folder name is the honest answer here rather than a
/// guess dressed up as one.
fn last_path_segment(path: &str) -> String {
    let trimmed = path.trim_end_matches('/');
    trimmed
        .rsplit('/')
        .find(|segment| !segment.is_empty())
        .unwrap_or(path)
        .to_string()
}

/// `CreateSession` carries the literal command to run, not an engine name.
/// The daemon derives a readable one from the program's own basename —
/// `claude`, `codex`, `copilot`, `antigravity` — and calls everything else
/// (a bare shell, an unrecognised binary) "shell", the same placeholder the
/// native app's own `Engine` enum reserves for it.
fn engine_from_command(command: &[String]) -> String {
    let program = command
        .first()
        .and_then(|first| std::path::Path::new(first).file_name())
        .and_then(|name| name.to_str())
        .unwrap_or_default();
    match program {
        "claude" | "codex" | "copilot" | "antigravity" => program.to_string(),
        _ => "shell".to_string(),
    }
}

/// The 5 s of quiet after which [`ActivityLog::tick`] flushes a pane's
/// half-typed input even without a `\r` (spec §8).
const INPUT_QUIET: Duration = Duration::from_secs(5);

/// Buffers `Input` per session and turns admitted frames into rows.
///
/// See the module doc for exactly which [`MessageKind`]s produce a row and
/// why the rest correctly produce none.
#[derive(Debug, Default)]
pub struct ActivityLog {
    /// Half-typed input per session id, flushed on CR, Interrupt, or quiet.
    pending: HashMap<String, (String, Instant)>,
}

impl ActivityLog {
    /// Maps one admitted frame to a row, or `None` when the frame does not
    /// belong in the log (a read, a malformed payload, or a kind this table
    /// deliberately leaves silent — see the module doc).
    pub fn record(&mut self, frame: &Frame, ctx: &ActivityContext) -> Option<ActivityEntry> {
        match frame.header.message_kind {
            MessageKind::Attach => {
                let attach: AttachPayload = serde_json::from_slice(&frame.payload).ok()?;
                Some(ActivityEntry {
                    ts: SystemTime::now(),
                    kind: "attach",
                    summary: format!("Opened {}", ctx.pane_location(&attach.id)),
                    detail: None,
                })
            }
            MessageKind::CreateSession => {
                let create: CreateSession = serde_json::from_slice(&frame.payload).ok()?;
                let engine = engine_from_command(&create.command);
                let workspace = create
                    .cwd
                    .as_deref()
                    .map(last_path_segment)
                    .filter(|name| !name.is_empty())
                    .unwrap_or_else(|| "this Mac".to_string());
                let detail = format!(
                    "cwd: {}\ncommand: {}",
                    create.cwd.as_deref().map(redact).unwrap_or_default(),
                    redact(&create.command.join(" ")),
                );
                Some(ActivityEntry {
                    ts: SystemTime::now(),
                    kind: "create_session",
                    summary: format!("Started a {engine} terminal in {workspace}"),
                    detail: Some(detail),
                })
            }
            MessageKind::Input => {
                let (session, bytes) = decode_raw_payload(&frame.payload).ok()?;
                self.push_input(session, bytes, ctx)
            }
            MessageKind::Interrupt => {
                let target: SessionIdPayload = serde_json::from_slice(&frame.payload).ok()?;
                let pane = ctx.pane_title(&target.id);
                // Interrupt is also a flush trigger (spec §8): whatever was
                // half-typed when the driver hit Ctrl-C belongs on this same
                // row, not silently discarded.
                let pending = self
                    .pending
                    .remove(&target.id)
                    .map(|(text, _)| text)
                    .filter(|text| !text.is_empty());
                Some(ActivityEntry {
                    ts: SystemTime::now(),
                    kind: "interrupt",
                    summary: format!("Interrupted {pane}"),
                    detail: pending.map(|text| redact(&text)),
                })
            }
            MessageKind::Kill => {
                let target: SessionIdPayload = serde_json::from_slice(&frame.payload).ok()?;
                Some(ActivityEntry {
                    ts: SystemTime::now(),
                    kind: "kill",
                    summary: format!("Closed {}", ctx.pane_title(&target.id)),
                    detail: None,
                })
            }
            MessageKind::SetSetting => {
                let setting: SettingValue = serde_json::from_slice(&frame.payload).ok()?;
                let summary = if setting.key == "layout" {
                    "Changed the workspace layout".to_string()
                } else {
                    // Every other reachable key (`editor_panes_native`,
                    // `roots`, `persona`, and whatever joins them later) is
                    // just as remote-writable as `layout` — a frame that
                    // changes one of them and produces no row is the exact
                    // bug this log exists to not have.
                    format!("Changed a setting ({})", setting.key)
                };
                Some(ActivityEntry {
                    ts: SystemTime::now(),
                    kind: "set_setting",
                    summary,
                    detail: None,
                })
            }
            MessageKind::RootsStartIngest => {
                let payload: RootsStartIngestPayload =
                    serde_json::from_slice(&frame.payload).ok()?;
                Some(ActivityEntry {
                    ts: SystemTime::now(),
                    kind: "roots",
                    summary: format!("Started scanning {} for workspaces", redact(&payload.path)),
                    detail: None,
                })
            }
            MessageKind::RootsAddProject => {
                let payload: RootsAddProjectPayload =
                    serde_json::from_slice(&frame.payload).ok()?;
                let path = redact(&payload.path);
                match payload.name.as_deref().map(redact) {
                    Some(name) => Some(ActivityEntry {
                        ts: SystemTime::now(),
                        kind: "roots",
                        summary: format!("Added workspace {name}"),
                        detail: Some(path),
                    }),
                    None => Some(ActivityEntry {
                        ts: SystemTime::now(),
                        kind: "roots",
                        summary: format!("Added workspace {path}"),
                        detail: None,
                    }),
                }
            }
            MessageKind::RootsRenameProject => {
                let payload: RootsRenameProjectPayload =
                    serde_json::from_slice(&frame.payload).ok()?;
                Some(ActivityEntry {
                    ts: SystemTime::now(),
                    kind: "roots",
                    summary: format!("Renamed a workspace to {}", redact(&payload.new_label)),
                    detail: None,
                })
            }
            MessageKind::RootsSetPaused => {
                let payload: RootsSetPausedPayload = serde_json::from_slice(&frame.payload).ok()?;
                let verb = if payload.paused { "Paused" } else { "Resumed" };
                Some(ActivityEntry {
                    ts: SystemTime::now(),
                    kind: "roots",
                    summary: format!("{verb} workspace {}", redact(&payload.project)),
                    detail: None,
                })
            }
            MessageKind::RootsReingestProject => {
                let payload: RootsReingestProjectPayload =
                    serde_json::from_slice(&frame.payload).ok()?;
                Some(ActivityEntry {
                    ts: SystemTime::now(),
                    kind: "roots",
                    summary: format!("Re-ingested workspace {}", redact(&payload.project)),
                    detail: None,
                })
            }
            MessageKind::RootsRebuild => Some(ActivityEntry {
                ts: SystemTime::now(),
                kind: "roots",
                summary: "Rebuilt the whole brain".to_string(),
                detail: None,
            }),
            MessageKind::ListDirectory => {
                let payload: ListDirectoryPayload = serde_json::from_slice(&frame.payload).ok()?;
                Some(ActivityEntry {
                    ts: SystemTime::now(),
                    kind: "list_directory",
                    summary: format!("Browsed {}", redact(&payload.path)),
                    detail: None,
                })
            }
            MessageKind::BrainSearch => {
                let payload: BrainSearchPayload = serde_json::from_slice(&frame.payload).ok()?;
                let query = redact(&payload.query);
                // A row that already shows the whole query has nothing left
                // to expand; a truncated one keeps the full text a click
                // away rather than losing it.
                const PREVIEW_CHARS: usize = 60;
                if query.chars().count() > PREVIEW_CHARS {
                    let preview: String = query.chars().take(PREVIEW_CHARS).collect();
                    Some(ActivityEntry {
                        ts: SystemTime::now(),
                        kind: "brain_search",
                        summary: format!("Searched the brain for \"{preview}…\""),
                        detail: Some(query),
                    })
                } else {
                    Some(ActivityEntry {
                        ts: SystemTime::now(),
                        kind: "brain_search",
                        summary: format!("Searched the brain for \"{query}\""),
                        detail: None,
                    })
                }
            }
            // Every other reachable kind is a read (`ListSessions`,
            // `GetSetting`, `BrainListProjects`, `BrainGetContext`, the
            // read-only `Roots*` status queries), or a mutation the table
            // deliberately leaves silent (`Resize`, `Detach` — see the
            // module doc) — nothing happened here worth a row.
            _ => None,
        }
    }

    /// The context-free flush: pops whatever is pending for `session` and
    /// redacts it, naming the pane by its raw session id rather than
    /// resolving it through an [`ActivityContext`] — for a caller with no
    /// context conveniently in hand, such as [`Self::tick`]'s periodic sweep
    /// across every pending session at once, which is not scoped to any one
    /// connection's layout.
    pub fn flush_input(&mut self, session: &str) -> Option<ActivityEntry> {
        let (text, _) = self.pending.remove(session)?;
        Self::finish_input(session.to_string(), text)
    }

    /// Flushes every session that has gone quiet for [`INPUT_QUIET`] or
    /// longer, so a half-typed prompt is not lost just because the driver
    /// never pressed return.
    pub fn tick(&mut self, now: Instant) -> Vec<ActivityEntry> {
        let stale: Vec<String> = self
            .pending
            .iter()
            .filter(|(_, (_, last))| now.saturating_duration_since(*last) >= INPUT_QUIET)
            .map(|(session, _)| session.clone())
            .collect();
        stale
            .into_iter()
            .filter_map(|session| self.flush_input(&session))
            .collect()
    }

    /// Buffers `bytes` for `session`, flushing on the first `\r` in them.
    fn push_input(
        &mut self,
        session: &str,
        bytes: &[u8],
        ctx: &ActivityContext,
    ) -> Option<ActivityEntry> {
        let now = Instant::now();
        let cr_at = bytes.iter().position(|&byte| byte == b'\r');
        let head = cr_at.map_or(bytes, |pos| &bytes[..pos]);
        {
            let buffered = self
                .pending
                .entry(session.to_string())
                .or_insert_with(|| (String::new(), now));
            buffered.0.push_str(&String::from_utf8_lossy(head));
            buffered.1 = now;
        }
        cr_at?;
        let (text, _) = self.pending.remove(session)?;
        Self::finish_input(ctx.pane_with_engine(session), text)
    }

    // ponytail: redaction only; PTY echo-state detection if this ever bites.
    // The daemon cannot tell a password prompt from a shell prompt, so a typed
    // secret can reach this log. Recorded rather than papered over (spec §8).
    fn finish_input(pane: String, text: String) -> Option<ActivityEntry> {
        if text.is_empty() {
            return None;
        }
        Some(ActivityEntry {
            ts: SystemTime::now(),
            kind: "input",
            summary: format!("Sent a prompt to {pane}"),
            detail: Some(redact(&text)),
        })
    }
}

/// The active log file [`append`] writes to, and the one previous file it
/// keeps once that grows past [`ACTIVITY_LOG_ROTATE_AT`].
const ACTIVITY_LOG_FILE_NAME: &str = "remote-activity.jsonl";
const ACTIVITY_LOG_ROTATED_NAME: &str = "remote-activity.1.jsonl";
const ACTIVITY_LOG_ROTATE_AT: u64 = 8 * 1024 * 1024;

/// Appends one JSON object per line to `<data_dir>/remote-activity.jsonl`,
/// rotating to `remote-activity.1.jsonl` (replacing any previous one) once
/// the active file reaches 8 MB — so the log never keeps more than one
/// previous file and never grows without bound. Task 20 reads this file.
///
/// There is deliberately no RPC that reads it back over the wire (spec §12
/// invariant 8): `ListDirectory` returns names and kinds only, never
/// contents — see its own doc in `protocol.rs` — and that boundary is what
/// keeps this file's redacted leftovers safe to write at all.
///
/// A write failure here must never be the reason a remote session drops. It
/// is logged at `warn` on the way out so the fact is on record even if a
/// caller composes this with `?`, but the caller — the daemon's dispatch
/// loop — must still swallow the returned `Err` rather than let it end the
/// connection; a full disk is not a reason to lose someone's terminal.
pub fn append(entry: &ActivityEntry, data_dir: &Path) -> io::Result<()> {
    append_inner(entry, data_dir).inspect_err(|error| {
        tracing::warn!(error = %error, "failed to append to the remote activity log");
    })
}

fn append_inner(entry: &ActivityEntry, data_dir: &Path) -> io::Result<()> {
    let path = data_dir.join(ACTIVITY_LOG_FILE_NAME);
    if let Ok(metadata) = std::fs::metadata(&path) {
        if metadata.len() >= ACTIVITY_LOG_ROTATE_AT {
            std::fs::rename(&path, data_dir.join(ACTIVITY_LOG_ROTATED_NAME))?;
        }
    }
    let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
    let mut line = serde_json::to_string(entry)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    line.push('\n');
    file.write_all(line.as_bytes())
}
