//! Task 7.1 — Session feedback loop: the hook point that turns a finished
//! terminal session into a `session_summary` enrichment job, plus the
//! review-mode Tauri commands (list/approve/discard pending Memory notes).
//!
//! ## The two halves of this task, and why they live in different crates
//! - **Enqueue** (this file, `on_session_end`): runs synchronously inside
//!   `SessionManager::kill`/the natural-exit path (see `sessions.rs`'s
//!   `SessionEndHook`) — cheap (one redacted-tail read, one `git diff`
//!   subprocess, one `INSERT` into `enrich_queue`), so doing it inline at
//!   session-end time is fine, no separate worker needed for this half.
//! - **Drain** (`crates/brain-ingest::enrich::write_session_summary`): the
//!   actual LLM call + Memory note + `Touched` edges + `Session` node. That
//!   half lives in `brain-ingest` (not here) because DESIGN.md 3.3's rule —
//!   "one shared retrieval/enrichment API used by all three [app, daemon,
//!   MCP]" — already put `enrich::drain_queue` there for
//!   `project_summary`/`community_summary`; `session_summary` is a third job
//!   kind on the exact same worker, not a second one. `lib.rs` ticks that
//!   drain on a 60s background thread (PLAN.md's own phrasing: "Phase 4
//!   worker, now spawned as a background thread in the app").
//!
//! ## Payload shape (PLAN.md Task 7.1's exact ask, plus what the drain side
//! needs)
//! `{project, session_id, transcript_path, transcript_tail, git_diff}` —
//! `transcript_tail`/`git_diff` are PLAN.md's named fields; `session_id`/
//! `transcript_path` are what `write_session_summary` needs to create the
//! `Session` node (label + path) without a second lookup. `cwd` is
//! deliberately NOT included: the diff is computed once, here, against the
//! session's cwd — nothing downstream needs the cwd itself again.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::Result;
use brain_core::{redact::redact, Memory, Store};
use serde::Serialize;
use tauri::State;

use crate::commands::BrainState;
use crate::sessions::SessionEndEvent;

/// PLAN.md Task 7.1: "last ~400 redacted lines" of the transcript feed the
/// summary prompt.
const TRANSCRIPT_TAIL_LINES: usize = 400;

/// Reads the last [`TRANSCRIPT_TAIL_LINES`] lines of a session's transcript
/// file. The file is already redacted line-by-line as it's written
/// (`sessions.rs`'s `write_redacted`); this re-redacts the slice anyway as
/// defense in depth — the Global Constraints are explicit that secret
/// redaction applies "before being used in any prompt or persisted anywhere
/// further", and a cheap second pass costs nothing if the on-write pass
/// already caught everything, but isn't a no-op if some future transcript
/// source ever bypasses it.
fn read_transcript_tail(transcript_path: &Path) -> String {
    let Ok(contents) = std::fs::read_to_string(transcript_path) else {
        return String::new();
    };
    let lines: Vec<&str> = contents.lines().collect();
    let start = lines.len().saturating_sub(TRANSCRIPT_TAIL_LINES);
    redact(&lines[start..].join("\n"))
}

/// `git diff --stat HEAD` in `cwd` — Task 7.1's v1 answer to "diff against
/// whatever ref made sense at session start": there's no session-start-ref
/// concept in this codebase yet (a session doesn't snapshot the repo's HEAD
/// when it opens), so this diffs the working tree (staged + unstaged)
/// against the current `HEAD` at session-END time instead. That's an
/// imperfect proxy — it misses anything the session itself committed mid-
/// session — but it's the "reasonable v1" PLAN.md explicitly invites, and
/// it's exactly what a developer would eyeball with `git status`/`git diff`
/// right after a session ends. Non-git `cwd` (or `git` missing) -> empty
/// string, matching `brain-ingest::gitmine`'s "skip silently" precedent for
/// the identical situation.
fn git_diff_stat(cwd: &str) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(cwd)
        .arg("diff")
        .arg("--stat")
        .arg("HEAD")
        .output();
    match output {
        Ok(o) if o.status.success() => String::from_utf8_lossy(&o.stdout).trim().to_string(),
        _ => String::new(),
    }
}

/// The [`crate::sessions::SessionEndHook`] `lib.rs` registers at boot.
/// Builds the `session_summary` payload and enqueues it — never touches the
/// LLM itself (see module docs: that's `brain-ingest::enrich::drain_queue`'s
/// job on its own timer). A session with nothing to report (no transcript
/// content, no uncommitted diff — e.g. a tab opened and closed without any
/// work happening) is skipped rather than queued, so idle terminal churn
/// doesn't spam the enrichment queue with empty-content LLM calls.
pub fn on_session_end(store: &Store, event: &SessionEndEvent) -> Result<()> {
    let transcript_tail = read_transcript_tail(&event.transcript_path);
    let git_diff = git_diff_stat(&event.cwd);

    if transcript_tail.trim().is_empty() && git_diff.trim().is_empty() {
        return Ok(());
    }

    let payload = serde_json::json!({
        "project": event.project,
        "session_id": event.id,
        "transcript_path": event.transcript_path.to_string_lossy(),
        "transcript_tail": transcript_tail,
        "git_diff": git_diff,
    });

    store.enqueue_job("session_summary", &payload.to_string())?;
    Ok(())
}

// --------------------------------------------------------------------------
// Review-mode Tauri commands: the small UI surface Task 7.1 asks for
// ("a simple pending-notes panel with approve/discard buttons"). The
// `review_memory` boolean toggle itself needs no dedicated command — the UI
// reads/writes it through the existing generic `settings_get`/`settings_set`
// (see `commands.rs`), same as every other settings-table entry.
// --------------------------------------------------------------------------

/// One row for the review panel's list — mirrors `brain_core::PendingNote`
/// but as an explicit wire type (same precedent as `map_feed.rs`'s
/// `MapNode`/`MapNodeDetail`: this crate's Tauri-facing shapes are kept
/// separate from storage-internal ones even when they'd currently serialize
/// identically, so a future `PendingNote` change doesn't silently ripple
/// into the frozen-in-spirit IPC contract).
#[derive(Debug, Clone, Serialize)]
pub struct PendingNoteView {
    pub node_id: String,
    pub project: String,
    pub title: String,
    pub path: Option<String>,
    pub created: i64,
}

impl From<brain_core::PendingNote> for PendingNoteView {
    fn from(p: brain_core::PendingNote) -> Self {
        PendingNoteView {
            node_id: p.node_id,
            project: p.project,
            title: p.title,
            path: p.path,
            created: p.created,
        }
    }
}

/// Pure, `Store`-only core of `pending_notes_list` — same split as
/// `map_feed.rs`'s `build_map_graph`/`build_map_node_detail`, so it's
/// directly unit-testable without constructing a Tauri `State`.
fn list_pending_notes(store: &Store, project: Option<&str>) -> anyhow::Result<Vec<PendingNoteView>> {
    let notes = store.pending_notes(project)?;
    Ok(notes.into_iter().map(PendingNoteView::from).collect())
}

/// Pure core of `pending_notes_approve`: lifts the DB-level hold
/// (immediately visible in search/briefings) and rewrites the note's
/// on-disk frontmatter for consistency (`Memory::mark_note_approved_on_disk`
/// — best-effort, see its own docs).
fn approve_note(store: &Store, node_id: &str) -> anyhow::Result<()> {
    let node = store.get_node(node_id)?;
    store.approve_pending(node_id)?;
    if let Some(path) = node.and_then(|n| n.path) {
        Memory::mark_note_approved_on_disk(Path::new(&path));
    }
    Ok(())
}

/// Pure core of `pending_notes_discard`: deletes the node/edges/pending-row
/// (via `Store::discard_pending`) and, if it existed, its `.md` file on
/// disk.
fn discard_note(store: &Store, node_id: &str) -> anyhow::Result<()> {
    let deleted = store.discard_pending(node_id)?;
    if let Some(path) = deleted.and_then(|n| n.path) {
        let _ = std::fs::remove_file(PathBuf::from(path));
    }
    Ok(())
}

/// Lists notes awaiting review, optionally scoped to one project, newest
/// first.
#[tauri::command]
pub fn pending_notes_list(
    project: Option<String>,
    brain: State<'_, BrainState>,
) -> Result<Vec<PendingNoteView>, String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    list_pending_notes(&store, project.as_deref()).map_err(|e| e.to_string())
}

/// Approves a pending note: lifts the DB-level hold (immediately visible in
/// search/briefings) and rewrites its on-disk frontmatter for consistency.
#[tauri::command]
pub fn pending_notes_approve(node_id: String, brain: State<'_, BrainState>) -> Result<(), String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    approve_note(&store, &node_id).map_err(|e| e.to_string())
}

/// Discards a pending note: deletes the node/edges/pending-row and, if it
/// existed, its `.md` file on disk.
#[tauri::command]
pub fn pending_notes_discard(node_id: String, brain: State<'_, BrainState>) -> Result<(), String> {
    let store = brain.store.lock().map_err(|e| e.to_string())?;
    discard_note(&store, &node_id).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_core::{now_ts, EdgeKind, Node, NodeKind, Origin};
    use tempfile::tempdir;

    fn end_event(id: &str, project: &str, cwd: &Path, transcript_path: &Path) -> SessionEndEvent {
        SessionEndEvent {
            id: id.to_string(),
            project: project.to_string(),
            cwd: cwd.to_string_lossy().into_owned(),
            engine: "shell".to_string(),
            transcript_path: transcript_path.to_path_buf(),
        }
    }

    #[test]
    fn read_transcript_tail_caps_at_400_lines_and_redacts() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("t.log");
        let mut lines: Vec<String> = (0..500).map(|i| format!("line {i}")).collect();
        lines.push("API_KEY=abc123".to_string());
        std::fs::write(&path, lines.join("\n")).unwrap();

        let tail = read_transcript_tail(&path);
        assert!(!tail.contains("line 0"), "must be capped to the tail");
        assert!(tail.contains("line 499"));
        assert!(tail.contains("[redacted]"));
        assert!(!tail.contains("abc123"));
    }

    #[test]
    fn read_transcript_tail_on_missing_file_is_empty_not_an_error() {
        assert_eq!(read_transcript_tail(Path::new("/no/such/file.log")), "");
    }

    #[test]
    fn git_diff_stat_on_non_git_dir_is_empty() {
        let dir = tempdir().unwrap();
        assert_eq!(git_diff_stat(&dir.path().to_string_lossy()), "");
    }

    #[test]
    fn git_diff_stat_reports_uncommitted_changes() {
        let dir = tempdir().unwrap();
        let run = |args: &[&str]| {
            assert!(Command::new("git")
                .arg("-C")
                .arg(dir.path())
                .args(args)
                .status()
                .unwrap()
                .success());
        };
        run(&["init", "-q"]);
        run(&["config", "user.email", "test@example.com"]);
        run(&["config", "user.name", "Test"]);
        std::fs::write(dir.path().join("a.ts"), "export const a = 1;\n").unwrap();
        run(&["add", "a.ts"]);
        run(&["commit", "-q", "-m", "init"]);

        std::fs::write(dir.path().join("a.ts"), "export const a = 2;\n").unwrap();

        let stat = git_diff_stat(&dir.path().to_string_lossy());
        assert!(stat.contains("a.ts"), "{stat}");
    }

    // --- on_session_end: enqueues session_summary with the right payload ---

    #[test]
    fn on_session_end_enqueues_session_summary_with_expected_payload_shape() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let transcript_path = dir.path().join("sess-1.log");
        std::fs::write(&transcript_path, "$ echo hi\nhi\n").unwrap();

        let event = end_event("sess-1", "p1", dir.path(), &transcript_path);
        on_session_end(&store, &event).unwrap();

        let pending = store.pending_jobs(10).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].kind, "session_summary");

        let payload: serde_json::Value = serde_json::from_str(&pending[0].payload).unwrap();
        assert_eq!(payload["project"], "p1");
        assert_eq!(payload["session_id"], "sess-1");
        assert_eq!(payload["transcript_path"], transcript_path.to_string_lossy().as_ref());
        assert!(payload["transcript_tail"].as_str().unwrap().contains("echo hi"));
        // Non-git cwd -> empty diff, but the key is always present.
        assert_eq!(payload["git_diff"], "");
    }

    #[test]
    fn on_session_end_skips_enqueue_for_a_totally_empty_session() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        // No transcript file at all, non-git cwd -> nothing happened.
        let event = end_event("sess-1", "p1", dir.path(), &dir.path().join("nope.log"));
        on_session_end(&store, &event).unwrap();

        assert!(store.pending_jobs(10).unwrap().is_empty());
    }

    #[test]
    fn on_session_end_dedupes_like_any_other_enqueue_job_call() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let transcript_path = dir.path().join("sess-1.log");
        std::fs::write(&transcript_path, "content\n").unwrap();
        let event = end_event("sess-1", "p1", dir.path(), &transcript_path);

        on_session_end(&store, &event).unwrap();
        on_session_end(&store, &event).unwrap();

        assert_eq!(store.pending_jobs(10).unwrap().len(), 1);
    }

    // --- review-mode note management (pure functions — same split as
    // map_feed.rs: the #[tauri::command] wrappers just lock + delegate, so
    // constructing a Tauri `State` isn't needed to test the real logic) ----

    #[test]
    fn approve_note_lifts_the_hold_and_rewrites_frontmatter() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let (path, id) = {
            let memory = Memory::new(&store, dir.path());
            memory
                .write_note_with_status("p1", "Session: add auth", "did work", Origin::MachineSummary, true)
                .unwrap()
        };
        assert!(store.is_pending(&id).unwrap());

        approve_note(&store, &id).unwrap();

        assert!(!store.is_pending(&id).unwrap());
        let contents = std::fs::read_to_string(&path).unwrap();
        assert!(contents.contains("status: approved"), "{contents}");
    }

    #[test]
    fn discard_note_removes_node_and_file() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let (path, id) = {
            let memory = Memory::new(&store, dir.path());
            memory
                .write_note_with_status("p1", "Session: throwaway", "did work", Origin::MachineSummary, true)
                .unwrap()
        };
        assert!(path.exists());

        discard_note(&store, &id).unwrap();

        assert!(store.get_node(&id).unwrap().is_none());
        assert!(!path.exists());
    }

    #[test]
    fn list_pending_notes_scopes_by_project_and_orders_newest_first() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        {
            let memory = Memory::new(&store, dir.path());
            memory
                .write_note_with_status("p1", "First", "a", Origin::MachineSummary, true)
                .unwrap();
            memory
                .write_note_with_status("p2", "Other project", "b", Origin::MachineSummary, true)
                .unwrap();
        }

        let list = list_pending_notes(&store, Some("p1")).unwrap();
        assert_eq!(list.len(), 1);
        assert_eq!(list[0].title, "First");
    }

    // A minimal smoke test proving `Node`/`EdgeKind`/`NodeKind`/`now_ts` are
    // reachable the same way `enrich.rs`'s Touched-edge write-back expects,
    // so a future refactor there can't silently drift the id scheme this
    // module's `on_session_end` payload feeds into.
    #[test]
    fn session_node_and_touched_edge_id_scheme_matches_enrich_expectations() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&Node {
                id: "p1:session:sess-1".to_string(),
                kind: NodeKind::Session,
                project: "p1".to_string(),
                label: "did work".to_string(),
                path: Some("/tmp/sess-1.log".to_string()),
                summary: None,
                origin: Origin::MachineSummary,
                updated: now_ts(),
            })
            .unwrap();
        store
            .upsert_edge(&brain_core::Edge {
                src: "p1:memory:note.md".to_string(),
                dst: "p1:session:sess-1".to_string(),
                kind: EdgeKind::Touched,
                weight: 1.0,
            })
            .unwrap();
        assert!(store.get_node("p1:session:sess-1").unwrap().is_some());
    }
}
