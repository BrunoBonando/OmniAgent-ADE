//! Headless enrichment worker (Task 4.1): drains `enrich_queue` jobs by
//! running a short, store-derived prompt through an `EnrichEngine` and
//! writing the answer back onto the target node's `summary` field.
//!
//! Two job kinds are handled today: `project_summary` and
//! `community_summary`, both enqueued by this crate right after
//! `ingest_project`/`community::detect` create their target node (see
//! `lib.rs` and `community.rs`). A third kind, `session_summary`, is named
//! in PLAN.md as Phase 7's job (transcript + git-diff -> a Memory note, not
//! a node summary) — `build_prompt`'s match below has a labelled arm for it
//! that intentionally does nothing yet, so Phase 7 only has to fill that arm
//! in rather than touch `drain_queue`'s dispatch or retry machinery.
//!
//! Privacy/cost discipline (DESIGN.md): prompts are built ONLY from node
//! labels/paths already in the store, plus capped excerpts of `Doc`-kind
//! files (READMEs, notes) read fresh from disk — never `File`/`CodeEntity`
//! source content. The `ClaudeEngine` also runs with `--tools ""`, so even
//! if a prompt were somehow insufficient, the model has no way to go read
//! the real project files itself.

use anyhow::Result;
use brain_core::{now_ts, NodeKind, Origin, QueueJob, Store};
use std::path::Path;
use std::process::Command;

// --- engine abstraction ------------------------------------------------

/// Why an `EnrichEngine::run` call failed, distinguishing two cases
/// `drain_queue` treats very differently.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EngineError {
    /// The engine itself isn't usable right now (CLI missing, offline, spawn
    /// failure, ...). Retrying the same job immediately won't help, and
    /// neither will trying the *next* job — so `drain_queue` stops the whole
    /// pass and leaves every remaining job untouched (`pending`) for a later
    /// drain, rather than marking anything `failed`.
    Unavailable(String),
    /// This specific attempt failed (non-zero exit for this prompt, bad
    /// JSON, the model reported an error, ...) — worth one immediate retry
    /// before giving up on the job.
    Failed(String),
}

impl EngineError {
    fn message(&self) -> &str {
        match self {
            EngineError::Unavailable(m) | EngineError::Failed(m) => m,
        }
    }
}

/// Runs one enrichment prompt and returns the model's plain-text answer.
/// Implemented by `ClaudeEngine` (production) and `FakeEngine` (tests).
pub trait EnrichEngine {
    fn run(&self, prompt: &str) -> Result<String, EngineError>;
}

/// Shells out to the user's own `claude` CLI, headless and zero-config: no
/// flags that read or write `~/.claude/*`, no MCP config, no system-prompt
/// override — just a one-shot prompt/response round trip using whatever
/// auth the user already has set up (OAuth/keychain), same as PLAN.md's
/// "bring your own engine" principle for interactive sessions.
///
/// PLAN.md sketched `claude -p <prompt> --output-format json --max-turns 1`;
/// `claude --help` on this machine (v2.1.218) has no `--max-turns` flag at
/// all. `--tools ""` is the current equivalent for a bounded, single-shot
/// call — it disables tool use entirely, so the run can't loop across turns
/// AND can't go read files outside the prompt we gave it (the real
/// enforcement mechanism behind DESIGN.md's "never dump raw file contents
/// wholesale" rule). Confirmed with a live `claude -p ... --tools ""` call:
/// `num_turns: 1`, plain-text `result` field, no tool_use content.
pub struct ClaudeEngine;

#[derive(serde::Deserialize)]
struct ClaudeJsonResult {
    is_error: bool,
    result: String,
}

impl EnrichEngine for ClaudeEngine {
    fn run(&self, prompt: &str) -> Result<String, EngineError> {
        let output = Command::new("claude")
            .arg("-p")
            .arg(prompt)
            .arg("--output-format")
            .arg("json")
            .arg("--tools")
            .arg("")
            .output();

        let output = match output {
            Ok(o) => o,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(EngineError::Unavailable(format!(
                    "claude CLI not found on PATH: {e}"
                )));
            }
            Err(e) => {
                return Err(EngineError::Unavailable(format!(
                    "failed to launch claude CLI: {e}"
                )));
            }
        };

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
            return Err(EngineError::Failed(format!(
                "claude CLI exited with {}: {stderr}",
                output.status
            )));
        }

        let stdout = String::from_utf8_lossy(&output.stdout);
        let parsed: ClaudeJsonResult = serde_json::from_str(&stdout).map_err(|e| {
            EngineError::Failed(format!(
                "claude CLI returned unparseable JSON ({e}): {stdout}"
            ))
        })?;

        if parsed.is_error {
            return Err(EngineError::Failed(format!(
                "claude CLI reported an error: {}",
                parsed.result
            )));
        }

        Ok(parsed.result)
    }
}

/// Test double for `EnrichEngine`. Returns canned outcomes in order — one
/// per `run()` call — repeating the last outcome once the list is
/// exhausted, so a test only has to spell out as many outcomes as it cares
/// about (e.g. `[Failed, Ok]` proves the retry-then-succeed path without
/// having to predict `drain_queue`'s total call count).
pub struct FakeEngine {
    outcomes: std::cell::RefCell<std::collections::VecDeque<Result<String, EngineError>>>,
}

impl FakeEngine {
    pub fn new(outcomes: Vec<Result<String, EngineError>>) -> Self {
        assert!(
            !outcomes.is_empty(),
            "FakeEngine needs at least one outcome"
        );
        FakeEngine {
            outcomes: std::cell::RefCell::new(outcomes.into()),
        }
    }

    pub fn always_ok(summary: &str) -> Self {
        Self::new(vec![Ok(summary.to_string())])
    }

    pub fn always_unavailable() -> Self {
        Self::new(vec![Err(EngineError::Unavailable("engine offline".into()))])
    }

    pub fn always_failing() -> Self {
        Self::new(vec![Err(EngineError::Failed("boom".into()))])
    }
}

impl EnrichEngine for FakeEngine {
    fn run(&self, _prompt: &str) -> Result<String, EngineError> {
        let mut q = self.outcomes.borrow_mut();
        if q.len() > 1 {
            q.pop_front().unwrap()
        } else {
            q.front().cloned().expect("at least one outcome")
        }
    }
}

// --- prompt building -----------------------------------------------------

const MAX_FILES_IN_PROMPT: usize = 60;
const MAX_ENTITIES_IN_PROMPT: usize = 80;
const MAX_DOCS_IN_PROMPT: usize = 6;
const MAX_MEMBERS_IN_PROMPT: usize = 60;
const DOC_EXCERPT_CHARS: usize = 400;

const PROJECT_SUMMARY_INSTRUCTION: &str = "You are enriching a developer's local knowledge graph. Based ONLY on the file/entity/doc listing below (you have no tools and cannot read any other files), write a concise 2-4 sentence summary of what this project is and does. Do not invent details the listing doesn't support. Reply with the summary text only, no preamble or markdown headers.\n\n";

const COMMUNITY_SUMMARY_INSTRUCTION: &str = "You are enriching a developer's local knowledge graph. The listing below is one cluster (\"community\") of related files/entities inside a larger project, grouped because they reference each other. Based ONLY on this listing, write a 1-2 sentence summary of what this cluster is responsible for. Do not invent details the listing doesn't support. Reply with the summary text only, no preamble.\n\n";

fn truncate_chars(s: &str, max: usize) -> String {
    if s.chars().count() <= max {
        return s.to_string();
    }
    let truncated: String = s.chars().take(max).collect();
    format!("{truncated}\u{2026}")
}

/// Reads a short excerpt of a `Doc` node's file straight from disk (capped
/// at `DOC_EXCERPT_CHARS`). Docs are prose (READMEs, notes) and explicitly
/// the one place PLAN.md allows real file content into an enrichment prompt
/// ("doc excerpts") — `File`/`CodeEntity` nodes never get this treatment,
/// only their labels/paths do.
fn doc_excerpt(project_root: Option<&str>, rel_path: Option<&str>) -> String {
    let (Some(root), Some(rel)) = (project_root, rel_path) else {
        return String::new();
    };
    match std::fs::read_to_string(Path::new(root).join(rel)) {
        Ok(text) => truncate_chars(text.trim(), DOC_EXCERPT_CHARS),
        Err(_) => String::new(),
    }
}

/// Builds the `project_summary` prompt body from everything the store
/// already knows about `project_id`. `Ok(None)` means the project node is
/// gone (re-ingested away since the job was queued) — nothing to summarize.
fn project_summary_context(store: &Store, project_id: &str) -> Result<Option<String>> {
    let Some(project_node) = store.get_node(project_id)? else {
        return Ok(None);
    };
    let root = project_node.path.clone();
    let nodes = store.nodes_for_project(project_id)?;

    let mut files: Vec<&str> = nodes
        .iter()
        .filter(|n| n.kind == NodeKind::File)
        .map(|n| n.label.as_str())
        .collect();
    files.sort_unstable();

    let mut entities: Vec<(&str, &str)> = nodes
        .iter()
        .filter(|n| n.kind == NodeKind::CodeEntity)
        .map(|n| (n.label.as_str(), n.path.as_deref().unwrap_or("")))
        .collect();
    entities.sort_unstable();

    let mut docs: Vec<&brain_core::Node> =
        nodes.iter().filter(|n| n.kind == NodeKind::Doc).collect();
    docs.sort_by(|a, b| a.label.cmp(&b.label));

    let mut out = format!(
        "Project \"{}\" \u{2014} {} files, {} code entities, {} docs.\n\n",
        project_node.label,
        files.len(),
        entities.len(),
        docs.len()
    );

    out.push_str("Files:\n");
    for f in files.iter().take(MAX_FILES_IN_PROMPT) {
        out.push_str("- ");
        out.push_str(f);
        out.push('\n');
    }
    if files.len() > MAX_FILES_IN_PROMPT {
        out.push_str(&format!(
            "- \u{2026} and {} more\n",
            files.len() - MAX_FILES_IN_PROMPT
        ));
    }

    out.push_str("\nCode entities (name in file):\n");
    for (name, path) in entities.iter().take(MAX_ENTITIES_IN_PROMPT) {
        out.push_str(&format!("- {name} in {path}\n"));
    }
    if entities.len() > MAX_ENTITIES_IN_PROMPT {
        out.push_str(&format!(
            "- \u{2026} and {} more\n",
            entities.len() - MAX_ENTITIES_IN_PROMPT
        ));
    }

    if !docs.is_empty() {
        out.push_str("\nDoc excerpts:\n");
        for doc in docs.iter().take(MAX_DOCS_IN_PROMPT) {
            let excerpt = doc_excerpt(root.as_deref(), doc.path.as_deref());
            out.push_str(&format!("### {}\n{}\n\n", doc.label, excerpt));
        }
    }

    Ok(Some(out))
}

/// Builds the `community_summary` prompt body: the labels/paths of every
/// member of the community, nothing else. `Ok(None)` means the community
/// node is gone.
fn community_summary_context(store: &Store, community_id: &str) -> Result<Option<String>> {
    let Some(community_node) = store.get_node(community_id)? else {
        return Ok(None);
    };
    let neighbors = store.neighbors(community_id, 500)?;

    let mut member_lines: Vec<String> = neighbors
        .iter()
        .filter(|(e, _)| e.kind == brain_core::EdgeKind::MemberOf)
        .map(|(_, n)| match n.path.as_deref() {
            Some(path) => format!("- {} ({:?}) in {}", n.label, n.kind, path),
            None => format!("- {} ({:?})", n.label, n.kind),
        })
        .collect();
    member_lines.sort_unstable();
    member_lines.dedup();

    let mut out = format!(
        "A cluster of {} related files/entities from project \"{}\":\n\n",
        member_lines.len(),
        community_node.project
    );
    for line in member_lines.iter().take(MAX_MEMBERS_IN_PROMPT) {
        out.push_str(line);
        out.push('\n');
    }
    if member_lines.len() > MAX_MEMBERS_IN_PROMPT {
        out.push_str(&format!(
            "\u{2026} and {} more\n",
            member_lines.len() - MAX_MEMBERS_IN_PROMPT
        ));
    }

    Ok(Some(out))
}

/// Resolves one queue job into `(target_node_id, full_prompt)`. `Ok(None)`
/// means: leave the job pending, there's nothing to do with it right now —
/// covers an unrecognized/future job kind (`session_summary`, Phase 7) and a
/// target node that vanished since the job was queued.
fn build_prompt(store: &Store, job: &QueueJob) -> Result<Option<(String, String)>> {
    let payload: serde_json::Value =
        serde_json::from_str(&job.payload).unwrap_or(serde_json::Value::Null);
    let node_id = payload.get("node_id").and_then(|v| v.as_str());

    match (job.kind.as_str(), node_id) {
        ("project_summary", Some(node_id)) => {
            let Some(context) = project_summary_context(store, node_id)? else {
                return Ok(None);
            };
            Ok(Some((
                node_id.to_string(),
                format!("{PROJECT_SUMMARY_INSTRUCTION}{context}"),
            )))
        }
        ("community_summary", Some(node_id)) => {
            let Some(context) = community_summary_context(store, node_id)? else {
                return Ok(None);
            };
            Ok(Some((
                node_id.to_string(),
                format!("{COMMUNITY_SUMMARY_INSTRUCTION}{context}"),
            )))
        }
        // Phase 7: transcript + git-diff -> a Memory note (Memory::write_note,
        // origin=MachineSummary), NOT a node summary — a different write-back
        // path than the two arms above. Left as a no-op (job stays pending)
        // rather than guessed at here; adding it later is a new match arm,
        // not a change to drain_queue's dispatch/retry machinery.
        ("session_summary", _) => Ok(None),
        _ => Ok(None), // unknown kind or malformed payload — leave pending
    }
}

/// Writes `summary` onto `node_id`, marking it machine-generated
/// (DESIGN.md's contamination rule: machine summaries are recorded as a
/// distinct origin from user-authored content). Re-upserts the whole node
/// rather than a partial update since `Store` has no partial-update method
/// and every other field is unchanged.
fn write_summary(store: &Store, node_id: &str, summary: &str) -> Result<()> {
    let Some(mut node) = store.get_node(node_id)? else {
        return Ok(()); // target vanished since the job was queued
    };
    node.summary = Some(summary.trim().to_string());
    node.origin = Origin::MachineSummary;
    node.updated = now_ts();
    store.upsert_node(&node)?;
    Ok(())
}

/// Folds an engine-failure message into a job's payload so `enrich_queue`
/// stays a readable audit trail of what went wrong, not just a bare status.
fn record_error(original_payload: &str, err: &str) -> String {
    match serde_json::from_str::<serde_json::Value>(original_payload) {
        Ok(serde_json::Value::Object(mut map)) => {
            map.insert(
                "error".to_string(),
                serde_json::Value::String(err.to_string()),
            );
            serde_json::Value::Object(map).to_string()
        }
        _ => serde_json::json!({ "original_payload": original_payload, "error": err }).to_string(),
    }
}

fn run_with_one_retry(engine: &dyn EnrichEngine, prompt: &str) -> Result<String, EngineError> {
    match engine.run(prompt) {
        Err(EngineError::Failed(_)) => engine.run(prompt), // one retry, per PLAN.md
        other => other,
    }
}

/// ponytail: a per-call cap so one `drain_queue()` invocation can't grind
/// through an arbitrarily large backlog — Phase 5 is expected to tick this
/// on a timer, so the next tick just picks up where this one left off.
const DRAIN_BATCH: usize = 50;

/// Processes pending `enrich_queue` jobs through `engine`, writing results
/// back onto their target node's `summary` field. Returns the count of jobs
/// completed successfully.
///
/// Never propagates engine failures to the caller — only real store/DB
/// errors bubble up via `?`. Behavior split by `EngineError` variant:
/// - `Unavailable` (CLI missing, offline, spawn failure): every pending job
///   is left untouched (`status` unchanged) and the whole pass stops
///   immediately — trying the next job would just fail the same way.
/// - `Failed` (bad output for this one prompt): retried once immediately;
///   if the retry also fails, the job is marked `failed` with the error
///   folded into its payload and is not retried again on a later drain.
pub fn drain_queue(store: &Store, engine: &dyn EnrichEngine) -> Result<usize> {
    let jobs = store.pending_jobs(DRAIN_BATCH)?;
    let mut done = 0usize;

    for job in jobs {
        let Some((node_id, prompt)) = build_prompt(store, &job)? else {
            continue;
        };

        match run_with_one_retry(engine, &prompt) {
            Ok(summary) => {
                write_summary(store, &node_id, &summary)?;
                store.set_job_status(job.id, "done", &job.payload)?;
                done += 1;
            }
            Err(EngineError::Unavailable(_)) => {
                break;
            }
            Err(err @ EngineError::Failed(_)) => {
                let payload = record_error(&job.payload, err.message());
                store.set_job_status(job.id, "failed", &payload)?;
            }
        }
    }
    Ok(done)
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_core::{now_ts, Edge, EdgeKind, Node, Origin, Store};
    use tempfile::tempdir;

    fn project_node(id: &str, root: &Path) -> Node {
        Node {
            id: id.to_string(),
            kind: NodeKind::Project,
            project: id.to_string(),
            label: id.to_string(),
            path: Some(root.to_string_lossy().to_string()),
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        }
    }

    fn file_node(project: &str, rel: &str) -> Node {
        Node {
            id: format!("{project}:{rel}"),
            kind: NodeKind::File,
            project: project.to_string(),
            label: rel.to_string(),
            path: Some(rel.to_string()),
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        }
    }

    #[test]
    fn drain_with_fake_engine_writes_summary_and_marks_job_done() {
        let store = Store::open_in_memory().unwrap();
        store
            .upsert_node(&project_node("p1", Path::new("/tmp/p1")))
            .unwrap();
        store
            .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
            .unwrap();

        let engine = FakeEngine::always_ok("A tidy little project.");
        let done = drain_queue(&store, &engine).unwrap();

        assert_eq!(done, 1);
        let node = store.get_node("p1").unwrap().unwrap();
        assert_eq!(node.summary.as_deref(), Some("A tidy little project."));
        assert_eq!(node.origin, Origin::MachineSummary);
        assert!(store.pending_jobs(10).unwrap().is_empty());
        assert_eq!(store.jobs_with_status("done", 10).unwrap().len(), 1);
    }

    #[test]
    fn unavailable_engine_leaves_job_pending_and_returns_zero() {
        let store = Store::open_in_memory().unwrap();
        store
            .upsert_node(&project_node("p1", Path::new("/tmp/p1")))
            .unwrap();
        store
            .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
            .unwrap();

        let engine = FakeEngine::always_unavailable();
        let done = drain_queue(&store, &engine).unwrap();

        assert_eq!(done, 0);
        assert_eq!(store.pending_jobs(10).unwrap().len(), 1);
        let node = store.get_node("p1").unwrap().unwrap();
        assert_eq!(
            node.origin,
            Origin::Extracted,
            "untouched by an unavailable engine"
        );
        assert!(node.summary.is_none());
    }

    #[test]
    fn engine_failing_twice_marks_job_failed_with_error_recorded() {
        let store = Store::open_in_memory().unwrap();
        store
            .upsert_node(&project_node("p1", Path::new("/tmp/p1")))
            .unwrap();
        store
            .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
            .unwrap();

        let engine = FakeEngine::always_failing();
        let done = drain_queue(&store, &engine).unwrap();

        assert_eq!(done, 0);
        assert!(
            store.pending_jobs(10).unwrap().is_empty(),
            "must not loop forever"
        );
        let failed = store.jobs_with_status("failed", 10).unwrap();
        assert_eq!(failed.len(), 1);
        assert!(failed[0].payload.contains("boom"), "{}", failed[0].payload);
    }

    #[test]
    fn engine_failing_once_then_succeeding_completes_via_the_retry() {
        let store = Store::open_in_memory().unwrap();
        store
            .upsert_node(&project_node("p1", Path::new("/tmp/p1")))
            .unwrap();
        store
            .enqueue_job("project_summary", r#"{"node_id":"p1"}"#)
            .unwrap();

        let engine = FakeEngine::new(vec![
            Err(EngineError::Failed("transient".into())),
            Ok("Recovered on retry.".into()),
        ]);
        let done = drain_queue(&store, &engine).unwrap();

        assert_eq!(done, 1);
        assert!(store.jobs_with_status("failed", 10).unwrap().is_empty());
        let node = store.get_node("p1").unwrap().unwrap();
        assert_eq!(node.summary.as_deref(), Some("Recovered on retry."));
    }

    #[test]
    fn unknown_job_kind_is_left_pending_not_consumed() {
        let store = Store::open_in_memory().unwrap();
        store
            .enqueue_job("some_future_kind", r#"{"node_id":"p1"}"#)
            .unwrap();

        let engine = FakeEngine::always_ok("should never be called");
        let done = drain_queue(&store, &engine).unwrap();

        assert_eq!(done, 0);
        assert_eq!(store.pending_jobs(10).unwrap().len(), 1);
    }

    #[test]
    fn session_summary_kind_is_left_pending_for_phase_7() {
        let store = Store::open_in_memory().unwrap();
        store
            .enqueue_job("session_summary", r#"{"project":"p1"}"#)
            .unwrap();

        let engine = FakeEngine::always_ok("should never be called");
        let done = drain_queue(&store, &engine).unwrap();

        assert_eq!(done, 0);
        assert_eq!(store.pending_jobs(10).unwrap().len(), 1);
    }

    #[test]
    fn community_summary_prompt_lists_members_not_raw_code() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.upsert_node(&project_node("p1", dir.path())).unwrap();
        store.upsert_node(&file_node("p1", "a.ts")).unwrap();
        store.upsert_node(&file_node("p1", "b.ts")).unwrap();
        store
            .upsert_node(&Node {
                id: "p1:community:0".to_string(),
                kind: NodeKind::Community,
                project: "p1".to_string(),
                label: "Community 0".to_string(),
                path: None,
                summary: None,
                origin: Origin::Extracted,
                updated: now_ts(),
            })
            .unwrap();
        for member in ["p1:a.ts", "p1:b.ts"] {
            store
                .upsert_edge(&Edge {
                    src: member.to_string(),
                    dst: "p1:community:0".to_string(),
                    kind: EdgeKind::MemberOf,
                    weight: 1.0,
                })
                .unwrap();
        }

        let context = community_summary_context(&store, "p1:community:0")
            .unwrap()
            .unwrap();
        assert!(context.contains("a.ts"), "{context}");
        assert!(context.contains("b.ts"), "{context}");
    }

    #[test]
    fn project_summary_context_includes_doc_excerpt_not_code_body() {
        let dir = tempdir().unwrap();
        std::fs::write(
            dir.path().join("README.md"),
            "# Hello\nThis is the readme body.",
        )
        .unwrap();
        std::fs::write(
            dir.path().join("secret.ts"),
            "const API_KEY = 'sk-should-not-appear';",
        )
        .unwrap();

        let store = Store::open_in_memory().unwrap();
        store.upsert_node(&project_node("p1", dir.path())).unwrap();
        store
            .upsert_node(&Node {
                id: "p1:README.md".to_string(),
                kind: NodeKind::Doc,
                project: "p1".to_string(),
                label: "README.md".to_string(),
                path: Some("README.md".to_string()),
                summary: None,
                origin: Origin::Extracted,
                updated: now_ts(),
            })
            .unwrap();
        store.upsert_node(&file_node("p1", "secret.ts")).unwrap();

        let context = project_summary_context(&store, "p1").unwrap().unwrap();
        assert!(context.contains("This is the readme body."), "{context}");
        assert!(!context.contains("sk-should-not-appear"), "{context}");
    }

    #[test]
    fn missing_target_node_leaves_job_pending() {
        let store = Store::open_in_memory().unwrap();
        // job queued but the project node it points at was never created
        store
            .enqueue_job("project_summary", r#"{"node_id":"ghost"}"#)
            .unwrap();

        let engine = FakeEngine::always_ok("should never be called");
        let done = drain_queue(&store, &engine).unwrap();

        assert_eq!(done, 0);
        assert_eq!(store.pending_jobs(10).unwrap().len(), 1);
    }
}
