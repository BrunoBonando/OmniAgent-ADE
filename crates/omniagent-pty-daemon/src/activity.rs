//! Frames become rows, then rows survive the connection — spec §8
//! (`docs/superpowers/specs/2026-09-01-remote-environment-sharing-design.md`).
//!
//! **The whole argument for this file is who witnesses what.** Nothing here
//! is reported by the viewer about itself: [`ActivityLog::record`] maps a
//! [`Frame`] the daemon actually received into zero or more [`ActivityEntry`]
//! values, and [`append`] persists them. A self-reported audit trail on a
//! security surface is worse than none, because it looks like evidence — so
//! a row exists only when the wire carried the frame that caused it.
//!
//! [`ActivityLog::record`] is one `match` on [`MessageKind`], producing a row
//! for exactly the mutating frames a remote client can reach
//! (`crate::authorize_remote`'s allowlist): every kind that only *reads* the
//! machine without disclosing anything about it (`ListSessions`,
//! `GetSetting`, the read-only `Roots*` status queries) produces no row,
//! because nothing happened worth logging. `BrainListProjects`,
//! `BrainGetContext` and `BrainSearch` are reads too, but ones that hand
//! brain content — a project list, a brief, search results — to the remote
//! client, the same reasoning `ListDirectory` gets, so all four are logged
//! for disclosure, not mutation. `Detach` is silent: it drops a
//! subscription, not the session underneath it. `Resize` is a real mutation
//! (it ioctls the host pty, `session.resize`), so it is **not** silent
//! either — but a raw `Resize` frame arrives once per pixel of a window drag,
//! so it is coalesced exactly like `Input`: the buffered size settles into
//! one row after the driver stops resizing, rather than one row per frame.
//! Every other reachable kind — `Attach`, `CreateSession`, `Input`
//! (coalesced), `Interrupt`, `Kill`, `SetSetting`, every mutating `Roots*`
//! kind — produces one immediately.
//!
//! Connection-opened/closed rows (spec §8's other two table rows) are not
//! built here: by the time a frame reaches [`ActivityLog::record`], `Hello`
//! has already been consumed by the handshake and a close is not a frame at
//! all. Both are events the dispatch loop itself observes directly, with the
//! connection's own [`crate::AssertedIdentity`]/timing in hand — Task 19
//! builds those two rows at the point it already has that context, rather
//! than this module inventing a second, frame-shaped API for events that are
//! not frames. That same dispatch loop must call [`ActivityLog::flush_all`]
//! when a connection ends, so a viewer that drops mid-line does not simply
//! erase whatever it had half-typed.

use std::collections::HashMap;
use std::fs::OpenOptions;
use std::io::{self, Write};
use std::path::Path;
use std::time::{Duration, Instant, SystemTime};

use brain_core::redact::redact;
use serde::{Deserialize, Serialize};

use crate::protocol::{
    decode_raw_payload, AttachPayload, BrainGetContextPayload, BrainSearchPayload, Frame,
    ListDirectoryPayload, MessageKind, ResizePayload, RootsAddProjectPayload,
    RootsReingestProjectPayload, RootsRenameProjectPayload, RootsSetPausedPayload,
    RootsStartIngestPayload, SessionIdPayload, SettingValue,
};
use crate::CreateSession;

/// `ActivityEntry.ts`'s wire format: RFC 3339, not serde's default
/// `SystemTime` encoding (`{"secs_since_epoch":…,"nanos_since_epoch":…}`).
/// Task 20 reads `remote-activity.jsonl` back to render history, so the
/// timestamp on the wire has to be something a reader can use directly —
/// the same reasoning `connections.rs`'s own `rfc3339` helper exists for the
/// presence roster's `since` field.
mod rfc3339_ts {
    use serde::{Deserialize, Deserializer, Serialize, Serializer};
    use std::time::SystemTime;

    pub fn serialize<S: Serializer>(value: &SystemTime, serializer: S) -> Result<S::Ok, S::Error> {
        chrono::DateTime::<chrono::Utc>::from(*value)
            .to_rfc3339()
            .serialize(serializer)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<SystemTime, D::Error> {
        let text = String::deserialize(deserializer)?;
        chrono::DateTime::parse_from_rfc3339(&text)
            .map(|parsed| SystemTime::from(parsed.with_timezone(&chrono::Utc)))
            .map_err(serde::de::Error::custom)
    }
}

/// One row of the daemon-witnessed remote activity log.
///
/// `detail` is `None` exactly when `summary` already says everything there
/// is to say — a row with nothing more does not expand (spec §8: "clicking a
/// session is one line and no detail"). Task 19 pushes these as
/// `RemoteActivity` (`0x8f`) and Task 20 renders them (reading them back from
/// `remote-activity.jsonl`, hence `Deserialize`), so the shape is a contract
/// those two consume: keep it small and stable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivityEntry {
    #[serde(with = "rfc3339_ts")]
    pub ts: SystemTime,
    /// A short, stable machine tag — `"attach"`, `"create_session"`,
    /// `"input"`, `"interrupt"`, `"kill"`, `"set_setting"`, `"roots"`,
    /// `"list_directory"`, `"brain_search"`, `"brain_get_context"`,
    /// `"resize"` — for Task 20 to group or icon rows by, never itself shown
    /// as the row's text. A `String`, not `&'static str`: the latter cannot
    /// implement `Deserialize`, and Task 20 has to read this back.
    pub kind: String,
    /// One line, human, no ids.
    pub summary: String,
    /// Shown when the row is expanded.
    pub detail: Option<String>,
}

impl ActivityEntry {
    /// Stamps `ts` with now and owns `kind`, so every arm of
    /// [`ActivityLog::record`] states only what makes it different.
    /// `pub(crate)` rather than private: Task 19 builds the
    /// connection-opened/closed rows the same way, right where it already
    /// has the context this module cannot reach through a `Frame` (see the
    /// module doc).
    pub(crate) fn new(kind: &'static str, summary: String, detail: Option<String>) -> Self {
        Self {
            ts: SystemTime::now(),
            kind: kind.to_string(),
            summary,
            detail,
        }
    }
}

/// The `RemoteActivity` (`0x8f`) push payload (Task 19, spec §8) — one batch
/// of everything a single frame, or a single quiet-tick flush, produced.
/// Never persisted as-is: each entry inside it is what actually lands, one
/// per line, in `remote-activity.jsonl` (see [`append`]); this wrapper exists
/// only on the wire, exactly as [`crate::protocol::RemoteViewersPayload`]
/// wraps [`crate::protocol::ViewerSummaryPayload`] for its own push.
///
/// `dropped` (fix round 1, IMPORTANT 2) is how many rows this particular
/// push is *not* delivering because a slow local feed fell behind the
/// registry's capped in-memory history and they were trimmed before it ever
/// saw them. Zero the overwhelming majority of the time. A feed that fell
/// behind used to jump straight to whatever was still retained with nothing
/// on the wire to say so — invisible on an audit surface whose whole job is
/// to be trusted, which is worse than an honest gap. `#[serde(default)]` so
/// a value built before this field existed still deserializes.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RemoteActivityPayload {
    pub entries: Vec<ActivityEntry>,
    #[serde(default)]
    pub dropped: usize,
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
    ///
    /// Gated behind `test-support` rather than `#[cfg(test)]`: an integration
    /// test in `tests/` is a separate crate that links this library built
    /// *without* `cfg(test)`, so a `cfg(test)`-only `pub fn` would compile out
    /// of the very binary that needs it. The crate's own `[dev-dependencies]`
    /// turns the feature on for every test target; the real daemon binary
    /// never enables it.
    #[cfg(any(test, feature = "test-support"))]
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

/// The 5 s of quiet after which [`ActivityLog::tick`] settles a pane's
/// half-typed input, or its half-finished resize, into a row (spec §8 for
/// input; the same shape is reused for `Resize` — see the module doc).
const SETTLE_QUIET: Duration = Duration::from_secs(5);

/// Half-typed input for one session: the pane name resolved *once*, at the
/// moment typing started, and reused at every flush — a CR-triggered row and
/// a 5 s-quiet row for the same keystrokes must read identically, not one
/// dressed up and the other naming the raw session id because it happened to
/// end a different way.
#[derive(Debug, Clone)]
struct PendingInput {
    pane: String,
    text: String,
    last_activity: Instant,
}

/// A pane's settling resize: the latest size the driver has asked for, and
/// when it last changed. Named once, same reasoning as [`PendingInput`].
#[derive(Debug, Clone)]
struct PendingResize {
    pane: String,
    cols: u16,
    rows: u16,
    last_activity: Instant,
}

/// Buffers `Input` and `Resize` per session and turns admitted frames into
/// rows.
///
/// See the module doc for exactly which [`MessageKind`]s produce a row and
/// why the rest correctly produce none.
#[derive(Debug, Default)]
pub struct ActivityLog {
    /// Half-typed input per session id, flushed on CR, Interrupt, or quiet.
    pending: HashMap<String, PendingInput>,
    /// A settling resize per session id, flushed on quiet or on
    /// [`ActivityLog::flush_all`].
    pending_resize: HashMap<String, PendingResize>,
}

impl ActivityLog {
    /// Maps one admitted frame to zero or more rows — zero when the frame
    /// does not belong in the log (a read, a malformed payload, or a kind
    /// this table deliberately leaves silent — see the module doc), more
    /// than one when a single `Input` frame carries more than one line (a
    /// multi-line paste arrives as one frame; each embedded `\r` completes a
    /// row, and whatever follows the last one stays pending).
    pub fn record(&mut self, frame: &Frame, ctx: &ActivityContext) -> Vec<ActivityEntry> {
        match frame.header.message_kind {
            MessageKind::Attach => {
                let Ok(attach) = serde_json::from_slice::<AttachPayload>(&frame.payload) else {
                    return Vec::new();
                };
                vec![ActivityEntry::new(
                    "attach",
                    format!("Opened {}", ctx.pane_location(&attach.id)),
                    None,
                )]
            }
            MessageKind::CreateSession => {
                let Ok(create) = serde_json::from_slice::<CreateSession>(&frame.payload) else {
                    return Vec::new();
                };
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
                vec![ActivityEntry::new(
                    "create_session",
                    format!("Started a {engine} terminal in {workspace}"),
                    Some(detail),
                )]
            }
            MessageKind::Input => {
                let Ok((session, bytes)) = decode_raw_payload(&frame.payload) else {
                    return Vec::new();
                };
                self.push_input(session, bytes, ctx)
            }
            MessageKind::Resize => {
                let Ok(resize) = serde_json::from_slice::<ResizePayload>(&frame.payload) else {
                    return Vec::new();
                };
                self.push_resize(&resize, ctx);
                Vec::new()
            }
            MessageKind::Interrupt => {
                let Ok(target) = serde_json::from_slice::<SessionIdPayload>(&frame.payload) else {
                    return Vec::new();
                };
                let pane = ctx.pane_title(&target.id);
                // Interrupt is also a flush trigger (spec §8): whatever was
                // half-typed when the driver hit Ctrl-C belongs on this same
                // row, not silently discarded.
                let pending = self
                    .pending
                    .remove(&target.id)
                    .map(|pending| pending.text)
                    .filter(|text| !text.is_empty());
                vec![ActivityEntry::new(
                    "interrupt",
                    format!("Interrupted {pane}"),
                    pending.map(|text| redact(&text)),
                )]
            }
            MessageKind::Kill => {
                let Ok(target) = serde_json::from_slice::<SessionIdPayload>(&frame.payload) else {
                    return Vec::new();
                };
                vec![ActivityEntry::new(
                    "kill",
                    format!("Closed {}", ctx.pane_title(&target.id)),
                    None,
                )]
            }
            MessageKind::SetSetting => {
                let Ok(setting) = serde_json::from_slice::<SettingValue>(&frame.payload) else {
                    return Vec::new();
                };
                // Every reachable key (`editor_panes_native`, `roots`,
                // `remote_control`, `remote_control_workspaces`, `persona`,
                // and whatever joins them later — `protected_setting_key`
                // is the only list that matters) is just as remote-writable
                // as `layout`. A frame that changes one and produces no row
                // is the exact bug this log exists to not have.
                let (summary, detail) = if setting.key == "layout" {
                    // The one exception worth omitting: `layout` is a large
                    // JSON blob whose shape is not human-readable, so a
                    // detail here would be noise, not evidence.
                    ("Changed the workspace layout".to_string(), None)
                } else {
                    // For everything else the redacted value *is* the
                    // auditable fact — "changed the persona" with no detail
                    // does not say what it was changed to.
                    (
                        format!("Changed a setting ({})", setting.key),
                        Some(redact(&setting.value)),
                    )
                };
                vec![ActivityEntry::new("set_setting", summary, detail)]
            }
            MessageKind::RootsStartIngest => {
                let Ok(payload) = serde_json::from_slice::<RootsStartIngestPayload>(&frame.payload)
                else {
                    return Vec::new();
                };
                vec![ActivityEntry::new(
                    "roots",
                    format!("Started scanning {} for workspaces", redact(&payload.path)),
                    None,
                )]
            }
            MessageKind::RootsAddProject => {
                let Ok(payload) = serde_json::from_slice::<RootsAddProjectPayload>(&frame.payload)
                else {
                    return Vec::new();
                };
                let path = redact(&payload.path);
                match payload.name.as_deref().map(redact) {
                    Some(name) => vec![ActivityEntry::new(
                        "roots",
                        format!("Added workspace {name}"),
                        Some(path),
                    )],
                    None => vec![ActivityEntry::new(
                        "roots",
                        format!("Added workspace {path}"),
                        None,
                    )],
                }
            }
            MessageKind::RootsRenameProject => {
                let Ok(payload) =
                    serde_json::from_slice::<RootsRenameProjectPayload>(&frame.payload)
                else {
                    return Vec::new();
                };
                vec![ActivityEntry::new(
                    "roots",
                    format!("Renamed a workspace to {}", redact(&payload.new_label)),
                    None,
                )]
            }
            MessageKind::RootsSetPaused => {
                let Ok(payload) = serde_json::from_slice::<RootsSetPausedPayload>(&frame.payload)
                else {
                    return Vec::new();
                };
                let verb = if payload.paused { "Paused" } else { "Resumed" };
                vec![ActivityEntry::new(
                    "roots",
                    format!("{verb} workspace {}", redact(&payload.project)),
                    None,
                )]
            }
            MessageKind::RootsReingestProject => {
                let Ok(payload) =
                    serde_json::from_slice::<RootsReingestProjectPayload>(&frame.payload)
                else {
                    return Vec::new();
                };
                vec![ActivityEntry::new(
                    "roots",
                    format!("Re-ingested workspace {}", redact(&payload.project)),
                    None,
                )]
            }
            MessageKind::RootsRebuild => vec![ActivityEntry::new(
                "roots",
                "Rebuilt the whole brain".to_string(),
                None,
            )],
            MessageKind::ListDirectory => {
                let Ok(payload) = serde_json::from_slice::<ListDirectoryPayload>(&frame.payload)
                else {
                    return Vec::new();
                };
                vec![ActivityEntry::new(
                    "list_directory",
                    format!("Browsed {}", redact(&payload.path)),
                    None,
                )]
            }
            MessageKind::BrainListProjects => {
                // No argument to name in the summary (the request payload is
                // `{}`), but a read that hands back every project's name and
                // path is exactly the disclosure `ListDirectory` is logged
                // for — leaving it silent while `BrainGetContext`/
                // `BrainSearch` are logged is the inconsistent read policy
                // this arm exists to close (carried-over item, Task 19).
                vec![ActivityEntry::new(
                    "brain_list_projects",
                    "Listed the brain's projects".to_string(),
                    None,
                )]
            }
            MessageKind::BrainGetContext => {
                let Ok(payload) = serde_json::from_slice::<BrainGetContextPayload>(&frame.payload)
                else {
                    return Vec::new();
                };
                // A read, but one that hands brain content — the project's
                // summary, decisions, notes — to the remote client, the same
                // disclosure `ListDirectory`/`BrainSearch` are logged for.
                vec![ActivityEntry::new(
                    "brain_get_context",
                    format!("Read the brief for {}", redact(&payload.project)),
                    None,
                )]
            }
            MessageKind::BrainSearch => {
                let Ok(payload) = serde_json::from_slice::<BrainSearchPayload>(&frame.payload)
                else {
                    return Vec::new();
                };
                let query = redact(&payload.query);
                // A row that already shows the whole query has nothing left
                // to expand; a truncated one keeps the full text a click
                // away rather than losing it.
                const PREVIEW_CHARS: usize = 60;
                if query.chars().count() > PREVIEW_CHARS {
                    let preview: String = query.chars().take(PREVIEW_CHARS).collect();
                    vec![ActivityEntry::new(
                        "brain_search",
                        format!("Searched the brain for \"{preview}…\""),
                        Some(query),
                    )]
                } else {
                    vec![ActivityEntry::new(
                        "brain_search",
                        format!("Searched the brain for \"{query}\""),
                        None,
                    )]
                }
            }
            // Every other reachable kind is a read that discloses nothing
            // beyond its own success (`ListSessions`, `GetSetting`, the
            // read-only `Roots*` status queries), or a mutation the table
            // deliberately leaves silent (`Detach` — see the module doc) —
            // nothing happened here worth a row.
            _ => Vec::new(),
        }
    }

    /// The pane-name-resolved flush: pops whatever is pending for `session`
    /// and redacts it. Used identically by the CR path inside
    /// [`Self::push_input`], by [`Self::tick`]'s quiet sweep, and by
    /// [`Self::flush_all`] — the same pane name every time, because it was
    /// resolved once, at push time, and stored on the [`PendingInput`]
    /// itself rather than re-resolved (or not) depending on how the line
    /// happened to end.
    pub fn flush_input(&mut self, session: &str) -> Option<ActivityEntry> {
        let pending = self.pending.remove(session)?;
        Self::finish_input(pending.pane, pending.text)
    }

    /// The `Resize` counterpart of [`Self::flush_input`]: pops the settled
    /// size for `session` and builds its row, naming the pane the same way
    /// it was named when the resize started.
    fn flush_resize(&mut self, session: &str) -> Option<ActivityEntry> {
        let pending = self.pending_resize.remove(session)?;
        Some(ActivityEntry::new(
            "resize",
            format!(
                "Resized {} to {}x{}",
                pending.pane, pending.cols, pending.rows
            ),
            None,
        ))
    }

    /// Flushes every session — input or resize — that has gone quiet for
    /// [`SETTLE_QUIET`] or longer, so a half-typed prompt or a half-finished
    /// drag is not lost just because nothing else ever triggers it.
    pub fn tick(&mut self, now: Instant) -> Vec<ActivityEntry> {
        let stale_input: Vec<String> = self
            .pending
            .iter()
            .filter(|(_, pending)| {
                now.saturating_duration_since(pending.last_activity) >= SETTLE_QUIET
            })
            .map(|(session, _)| session.clone())
            .collect();
        let stale_resize: Vec<String> = self
            .pending_resize
            .iter()
            .filter(|(_, pending)| {
                now.saturating_duration_since(pending.last_activity) >= SETTLE_QUIET
            })
            .map(|(session, _)| session.clone())
            .collect();
        let mut entries: Vec<ActivityEntry> = stale_input
            .into_iter()
            .filter_map(|session| self.flush_input(&session))
            .collect();
        entries.extend(
            stale_resize
                .into_iter()
                .filter_map(|session| self.flush_resize(&session)),
        );
        entries
    }

    /// Flushes **everything** pending, regardless of how recently it moved —
    /// for a connection that is ending. CR, `Interrupt`, and the 5 s tick are
    /// not the only ways a typed line or a resize ends: a dropped connection
    /// ends it too, and the daemon must not let that text or that size
    /// simply vanish, because a viewer disconnecting mid-line is exactly the
    /// moment the record matters most. Task 19 calls this once per
    /// connection, on close.
    pub fn flush_all(&mut self) -> Vec<ActivityEntry> {
        let sessions: Vec<String> = self.pending.keys().cloned().collect();
        let resizing: Vec<String> = self.pending_resize.keys().cloned().collect();
        let mut entries: Vec<ActivityEntry> = sessions
            .into_iter()
            .filter_map(|session| self.flush_input(&session))
            .collect();
        entries.extend(
            resizing
                .into_iter()
                .filter_map(|session| self.flush_resize(&session)),
        );
        entries
    }

    /// Buffers `bytes` for `session`, flushing one row per line terminator
    /// found in them — a frame is not always one keystroke: a pasted
    /// multi-line prompt arrives as a single `Input` frame carrying every
    /// embedded terminator at once, and each one completes a line exactly as
    /// if it had arrived on its own. Whatever follows the last terminator (or
    /// all of `bytes`, if there is none) stays buffered for the next frame,
    /// `Interrupt`, or the quiet tick.
    ///
    /// A terminator is `\r`, and `\r\n` counts as **one** — the `\n`
    /// immediately following a `\r` is consumed with it rather than becoming
    /// the next line's leading character. Without this, `"line1\r\nline2\r\n"`
    /// produced "line1", then "\nline2" with a stray leading newline, then a
    /// lone "\n" left pending that later flushed as its own whitespace-only
    /// row — no text was ever lost, but on a log whose evidence *is* the
    /// typed text that stray newline is noise in the wrong place. `\n` on its
    /// own, not preceded by a `\r`, is still not a terminator: only `\r` (bare
    /// or CRLF) ends a line here.
    ///
    /// The pairing only looks inside `bytes`: a `\r` that happens to be the
    /// very last byte of one `Input` frame, with its `\n` arriving as the
    /// first byte of the next, is treated as two frames' worth of ordinary
    /// terminators rather than one split pair — a PTY write is not expected
    /// to split a two-byte sequence at exactly that byte, and no text is
    /// lost either way, only (in that one pathological split) an extra blank
    /// line.
    fn push_input(
        &mut self,
        session: &str,
        bytes: &[u8],
        ctx: &ActivityContext,
    ) -> Vec<ActivityEntry> {
        let mut entries = Vec::new();
        let mut remaining = bytes;
        loop {
            match remaining.iter().position(|&byte| byte == b'\r') {
                Some(cr_at) => {
                    self.append_pending(session, &remaining[..cr_at], ctx);
                    if let Some(entry) = self.flush_input(session) {
                        entries.push(entry);
                    }
                    let after_cr = cr_at + 1;
                    let crlf = remaining.get(after_cr) == Some(&b'\n');
                    remaining = &remaining[after_cr + usize::from(crlf)..];
                }
                None => {
                    self.append_pending(session, remaining, ctx);
                    break;
                }
            }
        }
        entries
    }

    /// Appends `bytes` to `session`'s buffer, resolving and storing the pane
    /// name once, on the insert that creates the buffer.
    fn append_pending(&mut self, session: &str, bytes: &[u8], ctx: &ActivityContext) {
        let now = Instant::now();
        let buffered = self
            .pending
            .entry(session.to_string())
            .or_insert_with(|| PendingInput {
                pane: ctx.pane_with_engine(session),
                text: String::new(),
                last_activity: now,
            });
        buffered.text.push_str(&String::from_utf8_lossy(bytes));
        buffered.last_activity = now;
    }

    /// Records or extends `session`'s settling resize, keeping the pane name
    /// resolved on the first frame of the drag and updating only the size
    /// and the quiet timer on every one after.
    fn push_resize(&mut self, resize: &ResizePayload, ctx: &ActivityContext) {
        let now = Instant::now();
        self.pending_resize
            .entry(resize.id.clone())
            .and_modify(|pending| {
                pending.cols = resize.cols;
                pending.rows = resize.rows;
                pending.last_activity = now;
            })
            .or_insert_with(|| PendingResize {
                pane: ctx.pane_title(&resize.id),
                cols: resize.cols,
                rows: resize.rows,
                last_activity: now,
            });
    }

    // ponytail: redaction only; PTY echo-state detection if this ever bites.
    // The daemon cannot tell a password prompt from a shell prompt, so a typed
    // secret can reach this log. Recorded rather than papered over (spec §8).
    fn finish_input(pane: String, text: String) -> Option<ActivityEntry> {
        if text.is_empty() {
            return None;
        }
        Some(ActivityEntry::new(
            "input",
            format!("Sent a prompt to {pane}"),
            Some(redact(&text)),
        ))
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
