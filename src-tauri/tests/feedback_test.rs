//! Task 7.1 integration tests: the whole session feedback loop, end to end
//! — real `SessionManager` + real `SessionEndHook` wiring (mirroring what
//! `lib.rs`'s `setup()` actually does) through to `brain-ingest::enrich`'s
//! `FakeEngine` drain (no real `claude` calls here; that's the separate
//! manual-verification step). PLAN.md's exact asks for this task:
//!   1. End a session -> a `session_summary` job appears in the queue with
//!      the right payload shape.
//!   2. Drain that job (Fake engine) -> the Memory note exists, has
//!      `Touched` edges to the diff's changed files, and a `Session` node
//!      is present.
//!   3. Review mode on -> the note lands with `status: pending`; approving
//!      it flips that status (and get_context stops hiding it).

use std::process::Command;
use std::sync::Arc;
use std::time::{Duration, Instant};

use brain_core::Store;
use brain_ingest::enrich::{drain_queue, FakeEngine};
use mcp_server::tools::{self, ToolContext};
use omniagent_ade_lib::feedback;
use omniagent_ade_lib::sessions::{CreateSessionRequest, OutputSink, SessionManager};
use tempfile::tempdir;

const WELL_FORMED_ANSWER: &str = "TITLE: Add a comment to util.ts\n\nAppended an explanatory comment to util.ts via the session's shell.";

fn silent_sink() -> OutputSink {
    Arc::new(|_id: &str, _chunk: &[u8]| {})
}

/// A `SessionManager` wired exactly like `lib.rs`'s real `setup()`: the end
/// hook opens its own short-lived `Store` connection per call and enqueues
/// through `feedback::on_session_end`.
fn manager_with_feedback_hook(data_dir: &std::path::Path, sink: OutputSink) -> SessionManager {
    let hook_data_dir = data_dir.to_path_buf();
    let end_hook: omniagent_ade_lib::sessions::SessionEndHook = Arc::new(move |event| {
        let store = Store::open(&hook_data_dir).expect("open store in feedback hook");
        feedback::on_session_end(&store, event).expect("on_session_end");
    });
    SessionManager::new(data_dir.to_path_buf(), sink).with_end_hook(end_hook)
}

fn init_git_repo_with_file(dir: &std::path::Path) {
    let run = |args: &[&str]| {
        assert!(Command::new("git")
            .arg("-C")
            .arg(dir)
            .args(args)
            .status()
            .unwrap()
            .success());
    };
    run(&["init", "-q"]);
    run(&["config", "user.email", "test@example.com"]);
    run(&["config", "user.name", "Test"]);
    std::fs::write(dir.join("util.ts"), "export function hashPassword() {}\n").unwrap();
    run(&["add", "util.ts"]);
    run(&["commit", "-q", "-m", "init"]);
}

/// Runs a trivial shell session in `project_dir` (echoing something so the
/// transcript has content, and — via `init_git_repo_with_file` having
/// already run — leaving a real uncommitted diff behind) and kills it,
/// returning once `SessionManager::kill` has returned (which itself blocks
/// until the reader thread's final flush, so the feedback hook has already
/// fired by the time this returns).
fn run_and_end_a_session(manager: &SessionManager, project: &str, project_dir: &std::path::Path) {
    let info = manager
        .create(CreateSessionRequest {
            project: project.to_string(),
            engine: "shell".to_string(),
            cwd: project_dir.to_string_lossy().into_owned(),
            briefing: None,
        restore_id: None,
        })
        .unwrap();

    manager
        .write(&info.id, "echo 'session did some work'\n")
        .unwrap();
    // Give the reader thread a moment to observe + line-flush the echoed
    // output before kill (kill's own join guarantees the FINAL flush, but
    // we want this line specifically captured, not just whatever's left in
    // the buffer at kill time).
    std::thread::sleep(Duration::from_millis(500));

    manager.kill(&info.id).unwrap();
}

#[test]
fn ending_a_session_enqueues_a_session_summary_job_with_the_right_payload_shape() {
    let data_dir = tempdir().unwrap();
    let project_dir = tempdir().unwrap();
    init_git_repo_with_file(project_dir.path());
    std::fs::write(
        project_dir.path().join("util.ts"),
        "export function hashPassword() { /* changed */ }\n",
    )
    .unwrap();

    let manager = manager_with_feedback_hook(data_dir.path(), silent_sink());
    run_and_end_a_session(&manager, "demo", project_dir.path());

    let store = Store::open(data_dir.path()).unwrap();
    let pending = store.pending_jobs(10).unwrap();
    let job = pending
        .iter()
        .find(|j| j.kind == "session_summary")
        .unwrap_or_else(|| panic!("no session_summary job in {pending:?}"));

    let payload: serde_json::Value = serde_json::from_str(&job.payload).unwrap();
    assert_eq!(payload["project"], "demo");
    assert!(payload["session_id"].as_str().unwrap().starts_with("sess-"));
    assert!(
        payload["transcript_tail"]
            .as_str()
            .unwrap()
            .contains("session did some work"),
        "{payload}"
    );
    assert!(
        payload["git_diff"].as_str().unwrap().contains("util.ts"),
        "{payload}"
    );
    assert!(payload["transcript_path"].as_str().unwrap().ends_with(".log"));
}

#[test]
fn draining_the_job_writes_a_memory_note_touched_edges_and_a_session_node() {
    let data_dir = tempdir().unwrap();
    let project_dir = tempdir().unwrap();
    init_git_repo_with_file(project_dir.path());
    std::fs::write(
        project_dir.path().join("util.ts"),
        "export function hashPassword() { /* changed */ }\n",
    )
    .unwrap();

    let manager = manager_with_feedback_hook(data_dir.path(), silent_sink());
    run_and_end_a_session(&manager, "demo", project_dir.path());

    let store = Store::open(data_dir.path()).unwrap();
    // The File node the diff touches needs to exist for the Touched edge to
    // be *visible* via neighbors() (an inner join) — a real ingest would
    // have created it already; seed it directly here since this test isn't
    // exercising ingestion.
    store
        .upsert_node(&brain_core::Node {
            id: "demo:util.ts".to_string(),
            kind: brain_core::NodeKind::File,
            project: "demo".to_string(),
            label: "util.ts".to_string(),
            path: Some("util.ts".to_string()),
            summary: None,
            origin: brain_core::Origin::Extracted,
            updated: brain_core::now_ts(),
        })
        .unwrap();

    let engine = FakeEngine::always_ok(WELL_FORMED_ANSWER);
    let done = drain_queue(&store, data_dir.path(), &engine).unwrap();
    assert_eq!(done, 1);

    let hits = store.search("comment to util", Some("demo"), 10).unwrap();
    let note = hits
        .iter()
        .find(|n| n.kind == brain_core::NodeKind::Memory)
        .unwrap_or_else(|| panic!("no memory note in {hits:?}"));
    assert_eq!(note.label, "Session: Add a comment to util.ts");
    assert_eq!(note.origin, brain_core::Origin::MachineSummary);

    let neighbors = store.neighbors(&note.id, 10).unwrap();
    assert!(
        neighbors.iter().any(|(e, n)| e.kind == brain_core::EdgeKind::Touched
            && n.id == "demo:util.ts"),
        "{neighbors:?}"
    );

    let session_nodes: Vec<_> = store
        .nodes_for_project("demo")
        .unwrap()
        .into_iter()
        .filter(|n| n.kind == brain_core::NodeKind::Session)
        .collect();
    assert_eq!(session_nodes.len(), 1, "{session_nodes:?}");
    assert_eq!(session_nodes[0].label, "Add a comment to util.ts");
    assert!(session_nodes[0].path.as_deref().unwrap().ends_with(".log"));

    // PLAN.md's phase-gate framing: "yesterday's session visible in today's
    // briefing" — get_context must include it once drained.
    let ctx = ToolContext {
        store: &store,
        data_dir: data_dir.path(),
    };
    let briefing = tools::get_context(&ctx, &serde_json::json!({"project": "demo"})).unwrap();
    assert!(
        briefing["memory_notes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["label"] == "Session: Add a comment to util.ts"),
        "{briefing}"
    );
}

#[test]
fn review_mode_on_lands_the_note_pending_and_approving_makes_it_visible() {
    let data_dir = tempdir().unwrap();
    let project_dir = tempdir().unwrap();
    init_git_repo_with_file(project_dir.path());

    {
        let store = Store::open(data_dir.path()).unwrap();
        store.set_setting("review_memory", "true").unwrap();
    }

    let manager = manager_with_feedback_hook(data_dir.path(), silent_sink());
    run_and_end_a_session(&manager, "demo", project_dir.path());

    let store = Store::open(data_dir.path()).unwrap();
    let engine = FakeEngine::always_ok(WELL_FORMED_ANSWER);
    drain_queue(&store, data_dir.path(), &engine).unwrap();

    let pending = store.pending_notes(Some("demo")).unwrap();
    assert_eq!(pending.len(), 1, "{pending:?}");
    assert_eq!(pending[0].title, "Session: Add a comment to util.ts");

    let ctx = ToolContext {
        store: &store,
        data_dir: data_dir.path(),
    };
    let briefing_before =
        tools::get_context(&ctx, &serde_json::json!({"project": "demo"})).unwrap();
    assert!(
        briefing_before["memory_notes"].as_array().unwrap().is_empty(),
        "pending note must not show up in the briefing yet: {briefing_before}"
    );

    let note_path = store
        .get_node(&pending[0].node_id)
        .unwrap()
        .unwrap()
        .path
        .unwrap();
    let contents = std::fs::read_to_string(&note_path).unwrap();
    assert!(contents.contains("status: pending"), "{contents}");

    store.approve_pending(&pending[0].node_id).unwrap();

    let briefing_after =
        tools::get_context(&ctx, &serde_json::json!({"project": "demo"})).unwrap();
    assert!(
        briefing_after["memory_notes"]
            .as_array()
            .unwrap()
            .iter()
            .any(|n| n["label"] == "Session: Add a comment to util.ts"),
        "{briefing_after}"
    );
    assert!(store.pending_notes(Some("demo")).unwrap().is_empty());
}

#[test]
fn an_idle_session_with_no_transcript_content_and_no_diff_does_not_enqueue_a_job() {
    let data_dir = tempdir().unwrap();
    let project_dir = tempdir().unwrap();
    // Not a git repo, no commands ever run in the shell before killing it
    // almost immediately.

    let manager = manager_with_feedback_hook(data_dir.path(), silent_sink());
    let info = manager
        .create(CreateSessionRequest {
            project: "demo".to_string(),
            engine: "shell".to_string(),
            cwd: project_dir.path().to_string_lossy().into_owned(),
            briefing: None,
        restore_id: None,
        })
        .unwrap();
    manager.kill(&info.id).unwrap();

    let store = Store::open(data_dir.path()).unwrap();
    let pending = store.pending_jobs(10).unwrap();
    assert!(
        pending.iter().all(|j| j.kind != "session_summary"),
        "{pending:?}"
    );
}

// Bound the flaky PTY-timing surface: fail fast instead of hanging forever
// if `manager.kill` somehow never returns (mirrors session_test.rs's own
// deadline pattern for its output-observing test).
#[test]
fn kill_returns_promptly_even_when_the_feedback_hook_runs() {
    let data_dir = tempdir().unwrap();
    let project_dir = tempdir().unwrap();
    init_git_repo_with_file(project_dir.path());

    let manager = manager_with_feedback_hook(data_dir.path(), silent_sink());
    let info = manager
        .create(CreateSessionRequest {
            project: "demo".to_string(),
            engine: "shell".to_string(),
            cwd: project_dir.path().to_string_lossy().into_owned(),
            briefing: None,
        restore_id: None,
        })
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    manager.kill(&info.id).unwrap();
    assert!(Instant::now() < deadline, "kill() took too long");
}
