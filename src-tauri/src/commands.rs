//! Thin `#[tauri::command]` wrappers around [`crate::sessions::SessionManager`]
//! and around the shared brain retrieval crates (`brain_core` / `mcp_server`).
//!
//! All the actual PTY logic lives in `sessions.rs` and is independently
//! testable without Tauri; these functions only adapt that API to Tauri's
//! calling convention (`State` extraction, `Result<T, String>` so failures
//! surface as rejected promises on the JS side instead of panics).
//!
//! ## Why this file also calls into `mcp_server::tools`
//!
//! DESIGN.md 3.3 is explicit: "One shared retrieval API (Rust crate) used by
//! all three [app, daemon, MCP server] — never three query implementations."
//! `mcp_server::tools` is already that thin, synchronous, fully-tested
//! dispatch layer over `brain_core::Store` (see `crates/mcp-server/src/
//! tools.rs`) — `search_brain`/`get_context`/`list_projects` here call it
//! directly rather than re-deriving the same `NodeView`/`ProjectView`
//! projections a second time in this crate.

use std::path::PathBuf;
use std::sync::Mutex;

use mcp_server::tools::{self, ToolContext};
use serde_json::{json, Value};
use tauri::State;

use crate::sessions::{CreateSessionRequest, SessionInfo, SessionManager};

/// Shared handle to the local brain DB, managed as Tauri state alongside
/// [`SessionManager`]. `Store` wraps a plain `rusqlite::Connection` (`Send`
/// but not `Sync`), hence the `Mutex` — Tauri commands run on a thread pool,
/// never in parallel against the same connection.
pub struct BrainState {
    pub store: Mutex<brain_core::Store>,
    pub data_dir: PathBuf,
}

impl BrainState {
    pub fn open(data_dir: PathBuf) -> anyhow::Result<Self> {
        let store = brain_core::Store::open(&data_dir)?;
        Ok(Self {
            store: Mutex::new(store),
            data_dir,
        })
    }

    fn tool_ctx<'a>(&'a self, store: &'a brain_core::Store) -> ToolContext<'a> {
        ToolContext {
            store,
            data_dir: &self.data_dir,
        }
    }
}

/// `list_projects` / command-palette "Search brain…" backing command
/// (PLAN.md Task 5.2 names this `brain_query`). `kind` selects which of the
/// shared `mcp_server::tools` dispatchers to call:
/// - `"list_projects"` -> `[{id, label, path}]` (the sidebar's project list)
/// - `"search"` -> `[{id, kind, project, label, path?, summary?}]` (`query`
///   required, `scope` optional) — the command palette's "Search brain…"
///   action.
#[tauri::command]
pub fn brain_query(
    kind: String,
    query: Option<String>,
    scope: Option<String>,
    brain: State<'_, BrainState>,
) -> Result<Value, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    let ctx = brain.tool_ctx(&store);
    match kind.as_str() {
        "list_projects" => tools::list_projects(&ctx, &json!({})),
        "search" => {
            let query = query.ok_or_else(|| "\"query\" is required for kind=search".to_string())?;
            tools::search_brain(&ctx, &json!({ "query": query, "scope": scope }))
        }
        other => return Err(format!("unknown brain_query kind: {other:?}")),
    }
    .map_err(|e| e.to_string())
}

/// The raw `get_context(project)` briefing block (same JSON shape the MCP
/// tool returns) — exposed in case the UI wants the structured data (e.g. a
/// future "project info" panel), separate from [`brain_briefing`] which
/// renders it down to the flat markdown text passed to `session_create`.
#[tauri::command]
pub fn brain_get_context(project: String, brain: State<'_, BrainState>) -> Result<Value, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    let ctx = brain.tool_ctx(&store);
    tools::get_context(&ctx, &json!({ "project": project })).map_err(|e| e.to_string())
}

/// The `claude --append-system-prompt` briefing text for a new tab: fetches
/// `get_context(project)` and renders it to ~40 lines of markdown. Kept as
/// its own command (rather than pushing the rendering into the UI) so it's
/// covered by a plain Rust unit test on [`render_briefing`] below.
#[tauri::command]
pub fn brain_briefing(project: String, brain: State<'_, BrainState>) -> Result<String, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    let ctx = brain.tool_ctx(&store);
    let context = tools::get_context(&ctx, &json!({ "project": project })).map_err(|e| e.to_string())?;
    Ok(render_briefing(&project, &context))
}

/// Reads a `settings` table row (Task 5.2: per-project default engine,
/// persisted tab layout). `None` when unset.
#[tauri::command]
pub fn settings_get(key: String, brain: State<'_, BrainState>) -> Result<Option<String>, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    store.get_setting(&key).map_err(|e| e.to_string())
}

/// Upserts a `settings` table row.
#[tauri::command]
pub fn settings_set(key: String, value: String, brain: State<'_, BrainState>) -> Result<(), String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    store.set_setting(&key, &value).map_err(|e| e.to_string())
}

const BRIEFING_LIST_CAP: usize = 8;

/// Pure rendering of a `get_context` JSON blob into the markdown block
/// forwarded to `claude --append-system-prompt`. Capped to stay skimmable
/// (roughly the ~40-line budget PLAN.md's Task 5.1 names) — long lists are
/// truncated with a "+N more" line rather than dumped in full.
fn render_briefing(project: &str, context: &Value) -> String {
    let mut out = format!("# OmniAgent ADE briefing: {project}\n\n");

    let summary = context.get("summary").and_then(|v| v.as_str()).unwrap_or("");
    if !summary.trim().is_empty() {
        out.push_str("## Project summary\n");
        out.push_str(summary.trim());
        out.push_str("\n\n");
    }

    render_node_list(&mut out, "## Recent decisions\n", context.get("recent_decisions"));
    render_node_list(&mut out, "## Related projects\n", context.get("related_projects"));
    render_node_list(&mut out, "## Memory notes\n", context.get("memory_notes"));

    if out.trim_end() == format!("# OmniAgent ADE briefing: {project}") {
        out.push_str("_No prior context yet — this is the first session in this project._\n");
    }

    out
}

fn render_node_list(out: &mut String, heading: &str, items: Option<&Value>) {
    let Some(items) = items.and_then(|v| v.as_array()) else {
        return;
    };
    if items.is_empty() {
        return;
    }
    out.push_str(heading);
    for item in items.iter().take(BRIEFING_LIST_CAP) {
        let label = item
            .get("label")
            .and_then(|v| v.as_str())
            .unwrap_or("(untitled)");
        out.push_str("- ");
        out.push_str(label);
        out.push('\n');
    }
    if items.len() > BRIEFING_LIST_CAP {
        out.push_str(&format!("- …and {} more\n", items.len() - BRIEFING_LIST_CAP));
    }
    out.push('\n');
}

/// Creates a new PTY session running `engine` ("claude" | "codex" | "shell")
/// in `cwd`. For `engine == "claude"`, `briefing` (if provided) is forwarded
/// verbatim to `claude --append-system-prompt`; ignored for other engines.
/// See `sessions.rs` module docs for the full zero-config MCP wiring.
#[tauri::command]
pub fn session_create(
    project: String,
    engine: String,
    cwd: String,
    briefing: Option<String>,
    manager: State<'_, SessionManager>,
) -> Result<SessionInfo, String> {
    manager
        .create(CreateSessionRequest {
            project,
            engine,
            cwd,
            briefing,
        })
        .map_err(|e| e.to_string())
}

/// Writes raw bytes (keystrokes, pasted text, control sequences) to a
/// session's PTY.
#[tauri::command]
pub fn session_write(
    id: String,
    data: String,
    manager: State<'_, SessionManager>,
) -> Result<(), String> {
    manager.write(&id, &data).map_err(|e| e.to_string())
}

/// Resizes a session's PTY — call whenever the terminal pane's fit-addon
/// recomputes rows/cols.
#[tauri::command]
pub fn session_resize(
    id: String,
    cols: u16,
    rows: u16,
    manager: State<'_, SessionManager>,
) -> Result<(), String> {
    manager.resize(&id, cols, rows).map_err(|e| e.to_string())
}

/// Kills a session's process and synchronously reaps it.
#[tauri::command]
pub fn session_kill(id: String, manager: State<'_, SessionManager>) -> Result<(), String> {
    manager.kill(&id).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_core::{now_ts, Node, NodeKind, Origin, Store};
    use tempfile::tempdir;

    #[test]
    fn brain_state_opens_a_store_and_round_trips_settings() {
        let dir = tempdir().unwrap();
        let state = BrainState::open(dir.path().to_path_buf()).unwrap();
        {
            let store = state.store.lock().unwrap();
            store.set_setting("default_engine:demo", "codex").unwrap();
            assert_eq!(
                store.get_setting("default_engine:demo").unwrap(),
                Some("codex".to_string())
            );
        }
    }

    #[test]
    fn render_briefing_with_no_data_says_so() {
        let out = render_briefing("demo", &json!({}));
        assert!(out.contains("# OmniAgent ADE briefing: demo"));
        assert!(out.contains("No prior context yet"));
    }

    #[test]
    fn render_briefing_includes_summary_and_lists() {
        let context = json!({
            "summary": "A sample project.",
            "recent_decisions": [{"label": "Use SQLite"}],
            "related_projects": [],
            "memory_notes": [{"label": "Session: add auth"}],
        });
        let out = render_briefing("demo", &context);
        assert!(out.contains("## Project summary"));
        assert!(out.contains("A sample project."));
        assert!(out.contains("## Recent decisions"));
        assert!(out.contains("- Use SQLite"));
        assert!(out.contains("## Memory notes"));
        assert!(out.contains("- Session: add auth"));
        // related_projects was empty -> heading omitted entirely.
        assert!(!out.contains("## Related projects"));
    }

    #[test]
    fn render_briefing_truncates_long_lists_with_a_count() {
        let items: Vec<Value> = (0..12).map(|i| json!({"label": format!("note {i}")})).collect();
        let context = json!({ "memory_notes": items });
        let out = render_briefing("demo", &context);
        assert!(out.contains("- note 0"));
        assert!(out.contains(&format!("- note {}", BRIEFING_LIST_CAP - 1)));
        assert!(!out.contains(&format!("- note {BRIEFING_LIST_CAP}")));
        assert!(out.contains("…and 4 more"));
    }

    #[test]
    fn brain_query_list_projects_returns_frozen_project_view_shape() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&Node {
                id: "p1".into(),
                kind: NodeKind::Project,
                project: "p1".into(),
                label: "p1".into(),
                path: Some("/tmp/p1".into()),
                summary: None,
                origin: Origin::Extracted,
                updated: now_ts(),
            })
            .unwrap();
        let brain = BrainState {
            store: Mutex::new(store),
            data_dir: dir.path().to_path_buf(),
        };
        let store = brain.store.lock().unwrap();
        let ctx = brain.tool_ctx(&store);
        let result = tools::list_projects(&ctx, &json!({})).unwrap();
        let items = result.as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "p1");
        assert_eq!(items[0]["path"], "/tmp/p1");
    }
}
