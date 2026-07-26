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

use crate::sessions::{CreateSessionRequest, SessionInfo, SessionManager, SessionStatusEvent};

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

/// Task 8.1's map-pane "enrichment queued (N)" badge — a thin wrapper over
/// `Store::pending_job_count`, same lock-then-delegate pattern as every
/// other command in this file.
#[tauri::command]
pub fn enrich_queue_pending_count(brain: State<'_, BrainState>) -> Result<usize, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    store.pending_job_count().map_err(|e| e.to_string())
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
///
/// ## `restoreId` — the session-persistence contract (2026-07-26)
///
/// JS signature (Tauri camel-cases command arguments):
///
/// ```js
/// invoke("session_create", {
///   project, engine, cwd,
///   briefing,          // string | undefined, claude only (unchanged)
///   restoreId,         // string | undefined  <-- NEW, optional
/// }) // -> { id, project, engine, cwd, created, restored, persistent }
/// ```
///
/// Omit `restoreId` and behavior is byte-for-byte what it was: a fresh id, a
/// fresh engine. Pass the `id` a previous run returned and the session is
/// *reconnected* — if its tmux session is still alive (the app was closed
/// without that tab being closed), the same live `claude`/`codex`/shell
/// process comes back with its scrollback, and the returned `restored` is
/// `true`.
///
/// **The frontend must persist the id for this to do anything.** Today
/// `ui/src/state/sessions.ts`'s `PersistedTab` deliberately does not store it
/// ("engines are restarted fresh on restore… never the old session id"), and
/// `generate_session_id` mints a new one per call, so ids are *not* stable
/// across app restarts on their own. The frontend dispatch that follows this
/// one needs to: add `id` to `PersistedTab`/`serializeLayout`, and pass it as
/// `restoreId` in `App.tsx`'s boot-time restore loop. Until then this
/// parameter is simply never sent and nothing changes.
///
/// `restored`/`persistent` on the response are additive fields; existing
/// callers that ignore them are unaffected.
#[tauri::command]
pub fn session_create(
    project: String,
    engine: String,
    cwd: String,
    briefing: Option<String>,
    restore_id: Option<String>,
    manager: State<'_, SessionManager>,
) -> Result<SessionInfo, String> {
    manager
        .create(CreateSessionRequest {
            project,
            engine,
            cwd,
            briefing,
            restore_id,
        })
        .map_err(|e| e.to_string())
}

/// The five-state light for one session, computed on demand — `"ready"`
/// (green), `"thinking"` (white/blue), `"tool_execution"` (cyan),
/// `"awaiting_approval"` (amber) or `"error"` (red). `Ok(None)` when there's
/// no such live session.
///
/// Returns the **same [`SessionStatusEvent`] shape** the `session-status:{id}`
/// event carries, `notify` flag included, so a pane rendering on mount and a
/// pane reacting to a transition consume one type. The push counterpart is
/// emitted only when a session's status actually changes; this pull exists so
/// a pane can render the right light the moment it mounts (or is restored)
/// instead of showing a wrong one until the next transition — call it once on
/// mount, then let the event stream drive it.
///
/// `notify` is the backend's answer to "should this raise a notification"
/// (Bruno: only green/amber/red do). Do not re-derive it in the UI — see
/// `sessions::SessionStatus::notifies`.
#[tauri::command]
pub fn session_status(
    id: String,
    manager: State<'_, SessionManager>,
) -> Result<Option<SessionStatusEvent>, String> {
    Ok(manager.status(&id))
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

/// The pane header's git-branch pill (BridgeSpace pane-grid rebuild — see
/// docs/DESIGN.md and docs/reference/bridgespace-pane-grid-reference.png):
/// `git -C <path> rev-parse --abbrev-ref HEAD`, shelled out directly rather
/// than pulling in a git library for one read-only lookup. Returns `Ok(None)`
/// — never `Err` — whenever `path` isn't a git repo, `git` isn't on `PATH`,
/// or the command otherwise fails, so one pane's missing branch can never
/// error out the whole pane (the frontend just doesn't render the pill).
/// Takes a plain `path: String` rather than `State` — no shared state
/// involved, unlike every other command in this file.
#[tauri::command]
pub fn git_branch(path: String) -> Result<Option<String>, String> {
    let output = std::process::Command::new("git")
        .args(["-C", &path, "rev-parse", "--abbrev-ref", "HEAD"])
        .output();

    let Ok(output) = output else {
        return Ok(None); // `git` not installed / failed to spawn
    };
    if !output.status.success() {
        return Ok(None); // not a git repo (or no commits yet, etc.)
    }
    let branch = String::from_utf8_lossy(&output.stdout).trim().to_string();
    if branch.is_empty() {
        return Ok(None);
    }
    Ok(Some(branch))
}

/// The file tree panel's directory listing (founder feedback, 2026-07-25,
/// verbatim: "nice to have a folder/file navigation on the right panel") —
/// one lazy, gitignore-aware directory level per call, expand-on-click
/// rather than a full recursive walk. All the actual logic (the `ignore`
/// crate walker, `SKIP_DIRS`, sort order, error handling for a bad path)
/// lives in `brain_ingest::walk::list_dir`, independently unit-tested there
/// against both synthetic tempdirs and the golden fixture — this is a thin
/// wrapper, same house style as every other command in this file. Takes a
/// plain `path: String` rather than `State`, like `git_branch` — no shared
/// state involved.
#[tauri::command]
pub fn list_dir(path: String) -> Result<Vec<brain_ingest::walk::DirEntry>, String> {
    brain_ingest::walk::list_dir(std::path::Path::new(&path))
}

// ------------------------------------------------------------------------
// File tree write side (Part A — backend only; the Finder-like UI on top of
// these is a follow-up task). Founder feedback, 2026-07-25, verbatim: "make
// sure the file view works correctly, with it's own file visualization. It
// must work exactly like the Finder from Mac OS."
//
// Every command below is a thin wrapper — identical house style to
// `list_dir` above — over `brain_ingest::fileops`, which does the real work
// AND the real safety enforcement (path-traversal/symlink rejection scoped
// to `project_root`, collision handling, routing deletes through the real
// macOS Trash). See that module's doc comment for the full safety model;
// nothing here re-derives or duplicates it. `project_root` is always
// `ProjectInfo.path` on the frontend — the project whose file tree is
// currently showing the entry being acted on.
// ------------------------------------------------------------------------

/// Renames a file/folder in place (same parent directory). `new_name` must
/// be a bare filename (no path separators — that's a move, see
/// [`move_path`]). Returns the new full path.
#[tauri::command]
pub fn rename_path(project_root: String, path: String, new_name: String) -> Result<String, String> {
    brain_ingest::fileops::rename_path(
        std::path::Path::new(&project_root),
        std::path::Path::new(&path),
        &new_name,
    )
    .map(|p| p.to_string_lossy().into_owned())
}

/// Moves a file/folder into a different directory (same basename, new
/// parent) — what drag-and-drop-to-reparent in the frontend calls. Returns
/// the new full path.
#[tauri::command]
pub fn move_path(project_root: String, path: String, new_parent_dir: String) -> Result<String, String> {
    brain_ingest::fileops::move_path(
        std::path::Path::new(&project_root),
        std::path::Path::new(&path),
        std::path::Path::new(&new_parent_dir),
    )
    .map(|p| p.to_string_lossy().into_owned())
}

/// Copies a file, or recursively copies a directory, into the same parent
/// with the next free Finder-style " copy"/" copy N" name. Returns the new
/// full path.
#[tauri::command]
pub fn duplicate_path(project_root: String, path: String) -> Result<String, String> {
    brain_ingest::fileops::duplicate_path(std::path::Path::new(&project_root), std::path::Path::new(&path))
        .map(|p| p.to_string_lossy().into_owned())
}

/// Moves the file/folder to the macOS system Trash — never a permanent
/// delete (see `brain_ingest::fileops`'s module doc).
#[tauri::command]
pub fn delete_to_trash(project_root: String, path: String) -> Result<(), String> {
    brain_ingest::fileops::delete_to_trash(std::path::Path::new(&project_root), std::path::Path::new(&path))
}

/// Creates a new empty file named `name` inside `parent_dir`. Errors on a
/// name collision (the frontend prompts) rather than auto-incrementing an
/// "untitled 2" style name. Returns the new full path.
#[tauri::command]
pub fn create_file(project_root: String, parent_dir: String, name: String) -> Result<String, String> {
    brain_ingest::fileops::create_file(
        std::path::Path::new(&project_root),
        std::path::Path::new(&parent_dir),
        &name,
    )
    .map(|p| p.to_string_lossy().into_owned())
}

/// Creates a new empty folder named `name` inside `parent_dir`. Same
/// collision policy as [`create_file`]. Returns the new full path.
#[tauri::command]
pub fn create_dir(project_root: String, parent_dir: String, name: String) -> Result<String, String> {
    brain_ingest::fileops::create_dir(
        std::path::Path::new(&project_root),
        std::path::Path::new(&parent_dir),
        &name,
    )
    .map(|p| p.to_string_lossy().into_owned())
}

/// Starts watching `path` (one directory level, non-recursive — matches
/// `list_dir`'s own semantics) for external changes, so the file tree can
/// refresh itself when a file/folder is created/deleted/renamed outside the
/// app while that directory is expanded. Idempotent: calling this again for
/// a path that's already watched is a no-op, not a duplicate watcher. Emits
/// `dir-changed:{path}` (via the sink wired in `lib.rs`'s `.setup()`) on any
/// change within that directory. See `brain_ingest::dirwatch`'s module doc
/// for the full lifecycle design.
#[tauri::command]
pub fn watch_dir(path: String, watcher: State<'_, brain_ingest::dirwatch::DirWatchRegistry>) -> Result<(), String> {
    watcher.watch(std::path::Path::new(&path))
}

/// Stops watching `path` — call when the frontend collapses that directory
/// in the tree. A no-op (not an error) if it wasn't being watched.
#[tauri::command]
pub fn unwatch_dir(path: String, watcher: State<'_, brain_ingest::dirwatch::DirWatchRegistry>) -> Result<(), String> {
    watcher.unwatch(std::path::Path::new(&path))
}

// ------------------------------------------------------------------------
// Import detection (Part A — backend only). Founder ask, 2026-07-25,
// verbatim: "detect other dev tools already installed on the user's
// machine and offer to import their known project lists, so a new
// OmniAgent user doesn't have to manually '+ Add Project' one folder at a
// time." Read-only: neither command below writes anything or calls
// `add_project` — that's the next (frontend) task, built on top of
// `list_import_candidates`. Thin wrappers, same house style as `list_dir`
// above — the real logic (per-tool detection, path decoding, SQLite
// parsing, every degrade-gracefully edge case) lives in
// `brain_ingest::import_detect`, independently unit-tested there. Take no
// `State` — no shared app state involved, same as `list_dir`/`git_branch`.
// ------------------------------------------------------------------------

/// Every dev tool this build knows how to detect (Claude Code / VS Code /
/// Cursor), with whether it was found on this machine and how many real,
/// filesystem-verified candidate projects it has. Always `Ok` — detection
/// itself never fails; a given tool simply reports `detected: false`.
#[tauri::command]
pub fn detect_importable_tools() -> Result<Vec<brain_ingest::import_detect::DetectedTool>, String> {
    Ok(brain_ingest::import_detect::detect_tools())
}

/// Every real, filesystem-verified import candidate for one tool
/// (`tool` = `"claude-code"` | `"vscode"` | `"cursor"`, matching
/// [`brain_ingest::import_detect::DetectedTool::id`]). `Err` only for an
/// unrecognized `tool` id; a known tool that simply isn't installed/found
/// returns `Ok(vec![])`.
#[tauri::command]
pub fn list_import_candidates(tool: String) -> Result<Vec<brain_ingest::import_detect::ImportCandidate>, String> {
    brain_ingest::import_detect::list_candidates(&tool)
}

// ------------------------------------------------------------------------
// Per-session code review panel. Founder ask, 2026-07-26, verbatim: "For
// each session, have a top right menu with three things: Code Review Panel
// info (number of changes within files that are uncommited) and if clicked,
// it should show a code review panel for that session ... as a new column,
// dedicated on the right", plus "Make sure that the code panel is for
// session, okay?".
//
// That last sentence is why every command below takes a `repo_path` and
// holds no state: the panel is scoped to the cwd of the pane it was opened
// from. Thin wrappers, same house style as the `fileops` block above — all
// the real logic, safety rules and edge-case handling live in
// `brain_ingest::gitreview`, independently unit-tested there against real
// temporary git repos. Take no `State`, like `list_dir`/`git_branch`.
// ------------------------------------------------------------------------

/// Everything uncommitted in the repo `repo_path` sits inside — the branch,
/// each changed file with its own added/removed counts, and the aggregate.
/// Backs both the pane menu's change-count badge and the panel header.
/// `Err` for a path that isn't a git repo or doesn't exist.
#[tauri::command]
pub fn review_status(repo_path: String) -> Result<brain_ingest::gitreview::ReviewStatus, String> {
    brain_ingest::gitreview::status(&repo_path)
}

/// One file's diff, parsed into hunks with both line-number gutters already
/// resolved (see `gitreview::parse_unified_diff`) so the panel renders line
/// numbers without re-deriving them. Binary files come back `binary: true`
/// with no hunks rather than an empty diff that would read as "no changes".
#[tauri::command]
pub fn review_file_diff(repo_path: String, path: String) -> Result<brain_ingest::gitreview::FileDiff, String> {
    brain_ingest::gitreview::file_diff(&repo_path, &path)
}

/// Stages every uncommitted change in the repo and commits it with
/// `message` — all of it, matching the single "Commit" button in the
/// reference panel and the exact set of files the panel lists. No `--amend`,
/// no force, no `--no-verify`, and no push (see `gitreview`'s module doc).
#[tauri::command]
pub fn review_commit(repo_path: String, message: String) -> Result<brain_ingest::gitreview::CommitResult, String> {
    brain_ingest::gitreview::commit(&repo_path, &message)
}

/// Throws away one file's uncommitted changes. **Destructive** — the
/// frontend confirms this in-row before calling it and never wires it to a
/// bare one-click. A file with no committed version goes to the macOS Trash
/// (recoverable) instead of being `git clean`ed; anything else is restored
/// from HEAD. Renames are refused rather than half-undone.
#[tauri::command]
pub fn review_revert_file(repo_path: String, path: String) -> Result<brain_ingest::gitreview::RevertOutcome, String> {
    brain_ingest::gitreview::revert_file(&repo_path, &path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_core::{now_ts, Node, NodeKind, Origin, Store};
    use std::path::PathBuf;
    use tempfile::tempdir;

    /// Same fixture-path convention as `roots.rs`/`map_feed.rs`'s own tests:
    /// `fixtures/sample-project` is a real git repo (seeded by Phase 2's
    /// ingestion work) checked out on `main` with real commit history.
    fn sample_project_path() -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("fixtures/sample-project")
    }

    #[test]
    fn git_branch_returns_the_checked_out_branch_for_a_real_repo() {
        let path = sample_project_path();
        let branch = git_branch(path.to_string_lossy().to_string()).unwrap();
        assert_eq!(branch, Some("main".to_string()));
    }

    #[test]
    fn git_branch_returns_none_gracefully_for_a_non_git_directory() {
        let dir = tempdir().unwrap();
        let branch = git_branch(dir.path().to_string_lossy().to_string()).unwrap();
        assert_eq!(branch, None);
    }

    #[test]
    fn git_branch_returns_none_gracefully_for_a_path_that_does_not_exist() {
        let branch = git_branch("/no/such/path/omniagent-ade-test".to_string()).unwrap();
        assert_eq!(branch, None);
    }

    #[test]
    fn list_dir_returns_the_fixture_s_top_level_dirs_first_then_files() {
        let path = sample_project_path();
        let entries = list_dir(path.to_string_lossy().to_string()).unwrap();
        let names: Vec<&str> = entries.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["docs", "src", "helpers.py", "main.py", "README.md"], "{names:?}");
        assert!(!names.contains(&".git"), "{names:?}");
    }

    #[test]
    fn list_dir_returns_an_error_for_a_path_that_does_not_exist() {
        let err = list_dir("/no/such/path/omniagent-ade-list-dir-command-test".to_string());
        assert!(err.is_err());
    }

    // -------------------------------------------------- fileops command wrappers
    //
    // The real safety enforcement and every edge case is already covered
    // exhaustively in `brain_ingest::fileops`'s own test suite (including
    // symlink-escape traversal). These are smoke tests proving the
    // `String` <-> `Path` plumbing and error propagation work end to end
    // through the actual `#[tauri::command]` functions the frontend calls —
    // same "thin wrapper, real logic tested elsewhere" split `list_dir`
    // above already has (`walk::list_dir`'s tests vs. these).

    #[test]
    fn rename_path_command_renames_and_returns_the_new_path() {
        let root = tempdir().unwrap();
        std::fs::write(root.path().join("a.txt"), "hi").unwrap();

        let new_path = rename_path(
            root.path().to_string_lossy().into_owned(),
            root.path().join("a.txt").to_string_lossy().into_owned(),
            "b.txt".to_string(),
        )
        .unwrap();

        assert!(new_path.ends_with("b.txt"), "{new_path}");
        assert!(std::path::Path::new(&new_path).exists());
    }

    #[test]
    fn move_path_command_moves_and_returns_the_new_path() {
        let root = tempdir().unwrap();
        std::fs::write(root.path().join("a.txt"), "hi").unwrap();
        std::fs::create_dir(root.path().join("sub")).unwrap();

        let new_path = move_path(
            root.path().to_string_lossy().into_owned(),
            root.path().join("a.txt").to_string_lossy().into_owned(),
            root.path().join("sub").to_string_lossy().into_owned(),
        )
        .unwrap();

        assert!(new_path.ends_with("sub/a.txt"), "{new_path}");
    }

    #[test]
    fn duplicate_path_command_returns_the_finder_copy_name() {
        let root = tempdir().unwrap();
        std::fs::write(root.path().join("a.txt"), "hi").unwrap();

        let dup = duplicate_path(
            root.path().to_string_lossy().into_owned(),
            root.path().join("a.txt").to_string_lossy().into_owned(),
        )
        .unwrap();

        assert!(dup.ends_with("a copy.txt"), "{dup}");
    }

    #[test]
    fn create_file_and_create_dir_commands_work() {
        let root = tempdir().unwrap();
        let root_str = root.path().to_string_lossy().into_owned();

        let file = create_file(root_str.clone(), root_str.clone(), "new.txt".to_string()).unwrap();
        assert!(std::path::Path::new(&file).is_file());

        let dir = create_dir(root_str.clone(), root_str, "newdir".to_string()).unwrap();
        assert!(std::path::Path::new(&dir).is_dir());
    }

    #[test]
    fn delete_to_trash_command_removes_the_file_from_its_original_location() {
        let root = tempdir().unwrap();
        let file = root.path().join("omniagent-ade-commands-test-trash-me.txt");
        std::fs::write(&file, "bye").unwrap();

        delete_to_trash(
            root.path().to_string_lossy().into_owned(),
            file.to_string_lossy().into_owned(),
        )
        .unwrap();

        assert!(!file.exists());
    }

    #[test]
    fn fileops_commands_reject_a_dotdot_traversal_attempt_outside_the_root() {
        let root = tempdir().unwrap();
        let outside = tempdir().unwrap();
        std::fs::write(outside.path().join("secret.txt"), "top secret").unwrap();

        let traversal = format!(
            "{}/../{}/secret.txt",
            root.path().display(),
            outside.path().file_name().unwrap().to_string_lossy()
        );

        let err = delete_to_trash(root.path().to_string_lossy().into_owned(), traversal.clone());
        assert!(err.is_err(), "traversal delete must be rejected");

        let err = rename_path(root.path().to_string_lossy().into_owned(), traversal, "pwned.txt".to_string());
        assert!(err.is_err(), "traversal rename must be rejected");

        assert_eq!(std::fs::read_to_string(outside.path().join("secret.txt")).unwrap(), "top secret");
    }

    // ------------------------------------------------------------- dirwatch

    #[test]
    fn dir_watch_registry_watch_and_unwatch_are_directly_usable_outside_tauri_state() {
        // `watch_dir`/`unwatch_dir` themselves are one-line `State<'_, T>`
        // delegations (same as every other stateful command in this file,
        // e.g. `session_create`/`brain_query` above) — untestable without a
        // full Tauri app harness, and, per this codebase's own convention,
        // not unit-tested at that thin a layer (see e.g. `BrainState`'s
        // tests, which exercise the state type directly rather than the
        // `#[tauri::command]` wrapper). `DirWatchRegistry` itself has its
        // own full lifecycle test suite in `brain_ingest::dirwatch`; this
        // just proves the type this file's commands delegate to is the same
        // one, wired the same way.
        let dir = tempdir().unwrap();
        let calls = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let calls_clone = calls.clone();
        let sink: brain_ingest::dirwatch::ChangeSink =
            std::sync::Arc::new(move |p: &std::path::Path| calls_clone.lock().unwrap().push(p.to_path_buf()));
        let registry = brain_ingest::dirwatch::DirWatchRegistry::new(sink);

        registry.watch(dir.path()).unwrap();
        assert_eq!(registry.watched_count(), 1);
        registry.unwatch(dir.path()).unwrap();
        assert_eq!(registry.watched_count(), 0);
    }

    // -------------------------------------------------- import-detect commands
    //
    // The real per-tool detection logic (path decoding, worktree dedup,
    // SQLite parsing, every degrade-gracefully edge case) is already
    // exhaustively covered by `brain_ingest::import_detect`'s own test
    // suite against constructed fixtures. These are smoke tests proving
    // the thin `#[tauri::command]` wrappers plumb through correctly — same
    // split as `list_dir`'s own command tests above. Deliberately don't
    // assert on this dev machine's actual detected tool/candidate data
    // (that would be flaky across machines/CI); see this task's manual
    // verification notes for the real numbers on this machine.

    #[test]
    fn detect_importable_tools_command_returns_one_entry_per_known_tool() {
        let tools = detect_importable_tools().unwrap();
        let ids: Vec<&str> = tools.iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids, vec!["claude-code", "vscode", "cursor"], "{ids:?}");
    }

    #[test]
    fn list_import_candidates_command_accepts_every_known_tool_id_without_erroring() {
        for id in ["claude-code", "vscode", "cursor"] {
            let result = list_import_candidates(id.to_string());
            assert!(result.is_ok(), "{id}: {result:?}");
        }
    }

    #[test]
    fn list_import_candidates_command_rejects_an_unknown_tool_id() {
        let err = list_import_candidates("not-a-real-tool".to_string()).unwrap_err();
        assert!(err.contains("not-a-real-tool"), "{err}");
    }

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

    // ---------------------------------------------- review panel wrappers
    //
    // Every real edge case (not-a-repo, no commits, binary, unicode names,
    // huge diffs, the destructive-revert rules) is covered exhaustively in
    // `brain_ingest::gitreview`'s own 38-test suite against real temporary
    // git repos. These are smoke tests proving the `String` plumbing and
    // error propagation work end to end through the actual
    // `#[tauri::command]` functions the frontend calls — same split as the
    // fileops wrappers above.

    /// Builds a real throwaway git repo with one real uncommitted change.
    /// Never run against this repository itself.
    fn scratch_repo() -> tempfile::TempDir {
        let dir = tempdir().unwrap();
        let git = |args: &[&str]| {
            let out = std::process::Command::new("git")
                .arg("-C")
                .arg(dir.path())
                .args(args)
                .output()
                .unwrap();
            assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
        };
        git(&["init", "-q", "-b", "main"]);
        git(&["config", "user.email", "test@example.com"]);
        git(&["config", "user.name", "Test"]);
        std::fs::write(dir.path().join("a.txt"), "one\n").unwrap();
        git(&["add", "-A"]);
        git(&["commit", "-q", "-m", "baseline"]);
        std::fs::write(dir.path().join("a.txt"), "one\ntwo\n").unwrap();
        dir
    }

    #[test]
    fn review_status_command_reports_the_branch_and_the_changed_file() {
        let dir = scratch_repo();
        let status = review_status(dir.path().to_string_lossy().to_string()).unwrap();
        assert_eq!(status.branch.as_deref(), Some("main"));
        assert_eq!(status.file_count, 1);
        assert_eq!(status.files[0].path, "a.txt");
        assert_eq!(status.added, 1);
    }

    #[test]
    fn review_status_command_propagates_the_not_a_repo_error() {
        let dir = tempdir().unwrap();
        let err = review_status(dir.path().to_string_lossy().to_string()).unwrap_err();
        assert!(err.contains("isn't inside a git repository"), "{err}");
    }

    #[test]
    fn review_file_diff_command_returns_structured_hunks() {
        let dir = scratch_repo();
        let diff = review_file_diff(dir.path().to_string_lossy().to_string(), "a.txt".to_string()).unwrap();
        assert!(!diff.binary);
        assert_eq!(diff.hunks.len(), 1);
        assert!(diff.line_count >= 1);
    }

    #[test]
    fn review_commit_command_creates_a_real_commit_in_a_scratch_repo() {
        let dir = scratch_repo();
        let result = review_commit(
            dir.path().to_string_lossy().to_string(),
            "test: wrapper smoke commit".to_string(),
        )
        .unwrap();
        assert_eq!(result.short_sha.len(), 7);
        let after = review_status(dir.path().to_string_lossy().to_string()).unwrap();
        assert_eq!(after.file_count, 0, "the tree should be clean after committing");
    }

    #[test]
    fn review_revert_file_command_restores_a_modified_file() {
        let dir = scratch_repo();
        let outcome = review_revert_file(dir.path().to_string_lossy().to_string(), "a.txt".to_string()).unwrap();
        assert_eq!(outcome, brain_ingest::gitreview::RevertOutcome::RestoredFromHead);
        assert_eq!(std::fs::read_to_string(dir.path().join("a.txt")).unwrap(), "one\n");
    }
}
