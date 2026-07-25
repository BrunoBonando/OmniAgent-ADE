//! Headless enrichment worker (Task 4.1): drains `enrich_queue` jobs by
//! running a short, store-derived prompt through an `EnrichEngine` and
//! writing the answer back either onto the target node's `summary` field
//! (`project_summary`/`community_summary`) or, for `session_summary` (Task
//! 7.1, Phase 7's job), into a new Memory note + `Session` node + `Touched`
//! edges — DESIGN.md's memory model draws that line explicitly: node
//! summaries are machine annotations on an existing entity, session
//! summaries are actual Markdown notes in their own right.
//!
//! Privacy/cost discipline (DESIGN.md): prompts are built ONLY from node
//! labels/paths already in the store, plus capped excerpts of `Doc`-kind
//! files (READMEs, notes) read fresh from disk, or — for `session_summary`
//! only — the session's own (already redacted, re-redacted here as defense
//! in depth) transcript tail and `git diff --stat` output; never
//! `File`/`CodeEntity` source content wholesale. The `ClaudeEngine` also
//! runs with `--tools ""`, so even if a prompt were somehow insufficient,
//! the model has no way to go read the real project files itself.

use anyhow::Result;
use brain_core::redact::redact;
use brain_core::{now_ts, Edge, EdgeKind, Memory, Node, NodeKind, Origin, QueueJob, Store};
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

/// Task 7.1: instructs the model to reply in a parseable two-part shape
/// (`TITLE: ...` line, blank line, then prose) rather than free text. Why
/// the title comes from the model's own answer instead of being mined out
/// of the raw transcript tail: transcript tails are raw PTY bytes —
/// terminal-redraw escape codes, shell prompts, and (for a fullscreen-TUI
/// engine like Claude Code itself) heavy `\r`/cursor-movement repainting,
/// none of which reliably contains one clean "first user intent" line to
/// grep for. Asking the model — which already has to read and understand
/// the whole tail to write the summary — to also name the intent in a fixed
/// format is both more reliable and directly testable via `FakeEngine`
/// (`parse_title_and_body`'s tests below cover the well-formed and
/// malformed-response cases).
const SESSION_SUMMARY_INSTRUCTION: &str = "You are enriching a developer's local knowledge graph after one of their terminal sessions ended. Based ONLY on the transcript excerpt and git diff below (you have no tools and cannot read any other files), reply in EXACTLY this shape:\n\nTITLE: <a short imperative phrase, 60 characters or fewer, naming the main thing the user was trying to do this session>\n\n<a 2-5 sentence plain-prose summary of what was actually done, any decisions made, and files touched>\n\nDo not invent details the transcript/diff don't support. No markdown headers, no preamble beyond the TITLE line.\n\n";

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

/// Task 7.1's `session_summary` job payload, as enqueued by
/// `src-tauri`'s `feedback::on_session_end` on session end. `cwd` is
/// deliberately NOT part of this shape — the git diff is computed once, at
/// enqueue time, against the session's cwd; nothing at drain time needs the
/// cwd itself again.
#[derive(serde::Deserialize)]
struct SessionSummaryPayload {
    project: String,
    session_id: String,
    transcript_path: String,
    transcript_tail: String,
    git_diff: String,
}

/// What to do with a successful `EnrichEngine::run` answer — the two
/// existing job kinds overwrite a node's `summary` field; `session_summary`
/// writes a brand-new Memory note + Session node + Touched edges instead
/// (see module docs: this is DESIGN.md's deliberate node-summary vs.
/// memory-note distinction, not an oversight).
enum PromptTarget {
    NodeSummary(String),
    SessionSummary(SessionSummaryPayload),
}

/// Resolves one queue job into `(target, full_prompt)`. `Ok(None)` means:
/// leave the job pending, there's nothing to do with it right now — covers
/// an unrecognized job kind, a target node that vanished since the job was
/// queued, and a `session_summary` payload that fails to deserialize
/// (shouldn't happen from our own enqueue path, but malformed input must
/// never panic the drain loop).
fn build_prompt(store: &Store, job: &QueueJob) -> Result<Option<(PromptTarget, String)>> {
    let payload: serde_json::Value =
        serde_json::from_str(&job.payload).unwrap_or(serde_json::Value::Null);
    let node_id = payload.get("node_id").and_then(|v| v.as_str());

    match (job.kind.as_str(), node_id) {
        ("project_summary", Some(node_id)) => {
            let Some(context) = project_summary_context(store, node_id)? else {
                return Ok(None);
            };
            Ok(Some((
                PromptTarget::NodeSummary(node_id.to_string()),
                format!("{PROJECT_SUMMARY_INSTRUCTION}{context}"),
            )))
        }
        ("community_summary", Some(node_id)) => {
            let Some(context) = community_summary_context(store, node_id)? else {
                return Ok(None);
            };
            Ok(Some((
                PromptTarget::NodeSummary(node_id.to_string()),
                format!("{COMMUNITY_SUMMARY_INSTRUCTION}{context}"),
            )))
        }
        ("session_summary", _) => {
            let Ok(session_payload) = serde_json::from_str::<SessionSummaryPayload>(&job.payload)
            else {
                return Ok(None);
            };
            let context = session_summary_context(store, &session_payload);
            let prompt = format!("{SESSION_SUMMARY_INSTRUCTION}{context}");
            Ok(Some((PromptTarget::SessionSummary(session_payload), prompt)))
        }
        _ => Ok(None), // unknown kind or malformed payload — leave pending
    }
}

/// Builds the `session_summary` prompt body: the project's existing summary
/// (if any, for a little context), the diff stat, and the redacted
/// transcript tail — nothing else (Task 7.1's exact payload fields).
///
/// `git_diff`/`transcript_tail` are already expected to have been redacted
/// once upstream (at session-end capture time), but both are re-redacted
/// here via [`redact`] as defense in depth before they're folded into the
/// prompt sent to the external `claude` CLI — this is the actual
/// enforcement of that policy, not just a comment claiming it happens.
fn session_summary_context(store: &Store, payload: &SessionSummaryPayload) -> String {
    let project_summary = store
        .get_node(&payload.project)
        .ok()
        .flatten()
        .and_then(|n| n.summary)
        .unwrap_or_default();

    let mut out = format!("Project: {}\n", payload.project);
    if !project_summary.trim().is_empty() {
        out.push_str(&format!("Project summary: {}\n", project_summary.trim()));
    }

    let git_diff = redact(&payload.git_diff);
    out.push_str("\nGit diff --stat (uncommitted changes at session end):\n");
    if git_diff.trim().is_empty() {
        out.push_str("(no uncommitted changes)\n");
    } else {
        out.push_str(git_diff.trim());
        out.push('\n');
    }

    let transcript_tail = redact(&payload.transcript_tail);
    out.push_str("\nTranscript excerpt (tail of the session, redacted):\n");
    if transcript_tail.trim().is_empty() {
        out.push_str("(empty transcript)\n");
    } else {
        out.push_str(transcript_tail.trim());
        out.push('\n');
    }

    out
}

/// Splits a `session_summary` engine answer into `(intent_title, body)`.
/// Well-formed answers start with `TITLE: <line>` followed by a blank line
/// and the summary prose (per `SESSION_SUMMARY_INSTRUCTION`). Never panics
/// or produces an empty title on a malformed answer (a model that ignores
/// the format instruction, an empty string, ...) — falls back to the first
/// non-empty line of the answer, and finally to a generic
/// `"Session in <project>"` if the whole answer is blank.
fn parse_title_and_body(answer: &str, project: &str) -> (String, String) {
    let trimmed = answer.trim();
    let fallback_title = || format!("Session in {project}");

    if let Some(rest) = trimmed.strip_prefix("TITLE:") {
        let mut parts = rest.splitn(2, '\n');
        let title_line = parts.next().unwrap_or("").trim();
        let body = parts.next().unwrap_or("").trim();
        let title = if title_line.is_empty() {
            fallback_title()
        } else {
            title_line.to_string()
        };
        let body = if body.is_empty() { trimmed.to_string() } else { body.to_string() };
        return (title, body);
    }

    let title = trimmed
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .map(|l| l.chars().take(60).collect::<String>())
        .unwrap_or_else(fallback_title);
    (title, trimmed.to_string())
}

/// Parses changed file paths out of `git diff --stat` output. Each content
/// line looks like ` path/to/file.ts | 12 +++++++-----`; the trailing
/// summary line (` 3 files changed, ...`) has no `|` and is skipped
/// naturally. Handles the two rename shapes git emits: brace form
/// (`dir/{old => new}/file.ts`) and whole-path form (`old.ts => new.ts`) —
/// both resolve to the file's *current* path, which is what a `Touched`
/// edge should point at.
fn parse_diff_stat_paths(diff_stat: &str) -> Vec<String> {
    diff_stat
        .lines()
        .filter_map(|line| line.split_once('|').map(|(left, _)| left.trim()))
        .filter(|raw| !raw.is_empty())
        .map(resolve_rename_path)
        .collect()
}

fn resolve_rename_path(raw: &str) -> String {
    if let (Some(start), Some(end)) = (raw.find('{'), raw.find('}')) {
        if end > start {
            if let Some(arrow) = raw[start..end].find("=>") {
                let prefix = &raw[..start];
                let new_part = raw[start..end][arrow + 2..].trim();
                let suffix = &raw[end + 1..];
                return format!("{prefix}{new_part}{suffix}");
            }
        }
    }
    if let Some(arrow) = raw.find("=>") {
        return raw[arrow + 2..].trim().to_string();
    }
    raw.to_string()
}

/// Writes the `session_summary` write-back: a Memory note (gated by the
/// `review_memory` setting), `Touched` edges to every file the diff
/// touched, and a `Session` node for the "jump to transcript" map action.
///
/// ## `Touched` edges to files that may not have a `File` node yet
/// A diff can touch a brand-new untracked file that hasn't been ingested
/// yet, so its `File` node might not exist when this runs. Rather than
/// checking existence and skipping (which would silently lose that edge
/// forever), the edge is created unconditionally: `edges` has no foreign-key
/// constraint, `Store::neighbors`'s inner join makes a dangling edge simply
/// invisible until its target exists, and a future re-ingest that creates
/// that `File` node makes the edge "pick up" with zero special-case code —
/// exactly the same fire-and-forget pattern `Memory::write_note`'s own
/// `LinksTo` edges already use for markdown links to docs that may not
/// exist yet.
///
/// ## Timing of the `Session` node
/// Created here, at drain/summary-generation time (not at session-end
/// enqueue time), so its `label` can reuse the exact same intent line as
/// the Memory note's title, computed once from the one LLM answer both
/// need.
fn write_session_summary(
    store: &Store,
    data_dir: &Path,
    payload: &SessionSummaryPayload,
    answer: &str,
) -> Result<()> {
    let (intent, body) = parse_title_and_body(answer, &payload.project);
    let title = format!("Session: {intent}");

    let memory = Memory::new(store, data_dir);
    let review_mode = store.get_setting("review_memory")?.as_deref() == Some("true");
    let (_path, note_id) =
        memory.write_note_with_status(&payload.project, &title, &body, Origin::MachineSummary, review_mode)?;

    for rel in parse_diff_stat_paths(&payload.git_diff) {
        let file_id = format!("{}:{}", payload.project, rel);
        store.upsert_edge(&Edge {
            src: note_id.clone(),
            dst: file_id,
            kind: EdgeKind::Touched,
            weight: 1.0,
        })?;
    }

    store.upsert_node(&Node {
        id: format!("{}:session:{}", payload.project, payload.session_id),
        kind: NodeKind::Session,
        project: payload.project.clone(),
        label: intent,
        path: Some(payload.transcript_path.clone()),
        summary: Some(body.chars().take(280).collect()),
        origin: Origin::MachineSummary,
        updated: now_ts(),
    })?;

    Ok(())
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
/// back either onto their target node's `summary` field
/// (`project_summary`/`community_summary`) or, for `session_summary`, into a
/// new Memory note (see [`write_session_summary`]). `data_dir` is only
/// needed for that second path (`Memory::new` writes notes under
/// `data_dir/brain/`) — `project_summary`/`community_summary` never touch
/// the filesystem. Returns the count of jobs completed successfully.
///
/// Never propagates engine failures to the caller — only real store/DB
/// errors bubble up via `?`. Behavior split by `EngineError` variant:
/// - `Unavailable` (CLI missing, offline, spawn failure): every pending job
///   is left untouched (`status` unchanged) and the whole pass stops
///   immediately — trying the next job would just fail the same way.
/// - `Failed` (bad output for this one prompt): retried once immediately;
///   if the retry also fails, the job is marked `failed` with the error
///   folded into its payload and is not retried again on a later drain.
pub fn drain_queue(store: &Store, data_dir: &Path, engine: &dyn EnrichEngine) -> Result<usize> {
    let jobs = store.pending_jobs(DRAIN_BATCH)?;
    let mut done = 0usize;

    for job in jobs {
        let Some((target, prompt)) = build_prompt(store, &job)? else {
            continue;
        };

        match run_with_one_retry(engine, &prompt) {
            Ok(answer) => {
                match target {
                    PromptTarget::NodeSummary(node_id) => write_summary(store, &node_id, &answer)?,
                    PromptTarget::SessionSummary(session_payload) => {
                        write_session_summary(store, data_dir, &session_payload, &answer)?
                    }
                }
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
        let done = drain_queue(&store, Path::new("/tmp"), &engine).unwrap();

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
        let done = drain_queue(&store, Path::new("/tmp"), &engine).unwrap();

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
        let done = drain_queue(&store, Path::new("/tmp"), &engine).unwrap();

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
        let done = drain_queue(&store, Path::new("/tmp"), &engine).unwrap();

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
        let done = drain_queue(&store, Path::new("/tmp"), &engine).unwrap();

        assert_eq!(done, 0);
        assert_eq!(store.pending_jobs(10).unwrap().len(), 1);
    }

    // --- Task 7.1: session_summary ------------------------------------------

    fn session_summary_payload(project: &str) -> String {
        serde_json::json!({
            "project": project,
            "session_id": "sess-test-1",
            "transcript_path": "/tmp/transcripts/sess-test-1.log",
            "transcript_tail": "$ echo hello\nhello\n",
            "git_diff": " src/auth.ts | 4 ++--\n 1 file changed, 2 insertions(+), 2 deletions(-)",
        })
        .to_string()
    }

    const WELL_FORMED_ANSWER: &str = "TITLE: Fix auth token refresh\n\nUpdated src/auth.ts to refresh the token before it expires and added a regression test.";

    /// Test-only `EnrichEngine` that records every prompt it's given (Bug 3
    /// needs to inspect the actual prompt TEXT sent to the engine — the
    /// existing `FakeEngine` only returns canned answers, it doesn't expose
    /// what it was called with).
    struct CapturingEngine {
        answer: String,
        prompts: std::cell::RefCell<Vec<String>>,
    }

    impl CapturingEngine {
        fn new(answer: &str) -> Self {
            CapturingEngine {
                answer: answer.to_string(),
                prompts: std::cell::RefCell::new(Vec::new()),
            }
        }
    }

    impl EnrichEngine for CapturingEngine {
        fn run(&self, prompt: &str) -> Result<String, EngineError> {
            self.prompts.borrow_mut().push(prompt.to_string());
            Ok(self.answer.clone())
        }
    }

    /// Bug 3: the module doc comment claims session_summary prompts are
    /// "re-redacted here as defense in depth", but `session_summary_context`
    /// never actually called `brain_core::redact::redact` on `git_diff`/
    /// `transcript_tail` — a secret-shaped string in either field would go
    /// straight into the prompt sent to the real `claude` CLI. Proves the
    /// fix by inspecting the ACTUAL prompt text via `CapturingEngine`,
    /// not just the DB/note output (which wouldn't show what was sent).
    #[test]
    fn session_summary_prompt_redacts_secrets_in_git_diff_and_transcript_tail() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.upsert_node(&project_node("p1", dir.path())).unwrap();

        let payload = serde_json::json!({
            "project": "p1",
            "session_id": "sess-secret-1",
            "transcript_path": "/tmp/transcripts/sess-secret-1.log",
            "transcript_tail": "$ export API_KEY=sk-ant-api03-abcdefghijklmnopqrstuvwx\nok\n",
            "git_diff": " src/auth.ts | 4 ++--\n+  const password = \"hunter2hunter2\";\n 1 file changed",
        })
        .to_string();
        store.enqueue_job("session_summary", &payload).unwrap();

        let engine = CapturingEngine::new(WELL_FORMED_ANSWER);
        let done = drain_queue(&store, dir.path(), &engine).unwrap();
        assert_eq!(done, 1);

        let prompts = engine.prompts.borrow();
        assert_eq!(prompts.len(), 1, "{prompts:?}");
        let prompt = &prompts[0];

        assert!(
            !prompt.contains("sk-ant-api03-abcdefghijklmnopqrstuvwx"),
            "transcript_tail secret leaked into the prompt: {prompt}"
        );
        assert!(
            !prompt.contains("hunter2hunter2"),
            "git_diff secret leaked into the prompt: {prompt}"
        );
        assert!(prompt.contains("[redacted]"), "{prompt}");
    }

    #[test]
    fn session_summary_with_malformed_payload_is_left_pending_not_consumed() {
        let store = Store::open_in_memory().unwrap();
        store
            .enqueue_job("session_summary", r#"{"project":"p1"}"#) // missing required fields
            .unwrap();

        let engine = FakeEngine::always_ok("should never be called");
        let done = drain_queue(&store, Path::new("/tmp"), &engine).unwrap();

        assert_eq!(done, 0);
        assert_eq!(store.pending_jobs(10).unwrap().len(), 1);
    }

    #[test]
    fn drain_session_summary_writes_memory_note_touched_edges_and_session_node() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.upsert_node(&project_node("p1", dir.path())).unwrap();
        store.upsert_node(&file_node("p1", "src/auth.ts")).unwrap();
        store
            .enqueue_job("session_summary", &session_summary_payload("p1"))
            .unwrap();

        let engine = FakeEngine::always_ok(WELL_FORMED_ANSWER);
        let done = drain_queue(&store, dir.path(), &engine).unwrap();
        assert_eq!(done, 1);
        assert!(store.pending_jobs(10).unwrap().is_empty());

        // Memory note: titled "Session: <intent>", origin=MachineSummary,
        // auto-committed (no review_memory setting -> visible immediately).
        // Note: the search term also matches the Session node created below
        // (same intent/summary text by design), so filter to the Memory kind.
        let hits = store.search("token refresh", Some("p1"), 10).unwrap();
        let note = hits
            .iter()
            .find(|n| n.kind == NodeKind::Memory)
            .unwrap_or_else(|| panic!("no memory-kind hit in {hits:?}"));
        assert_eq!(note.label, "Session: Fix auth token refresh");
        assert_eq!(note.origin, Origin::MachineSummary);

        // Touched edge from the note to the file the diff --stat named.
        let neighbors = store.neighbors(&note.id, 10).unwrap();
        assert!(
            neighbors
                .iter()
                .any(|(e, n)| e.kind == EdgeKind::Touched && n.id == "p1:src/auth.ts"),
            "{neighbors:?}"
        );

        // Session node: label = the bare intent line, path = transcript log.
        let session_node = store.get_node("p1:session:sess-test-1").unwrap().unwrap();
        assert_eq!(session_node.kind, NodeKind::Session);
        assert_eq!(session_node.label, "Fix auth token refresh");
        assert_eq!(
            session_node.path.as_deref(),
            Some("/tmp/transcripts/sess-test-1.log")
        );
    }

    #[test]
    fn drain_session_summary_creates_touched_edge_even_when_file_node_does_not_exist_yet() {
        // A diff can touch a brand-new untracked file that hasn't been
        // ingested yet — the edge must still be created (dangling until a
        // future ingest creates the File node), not dropped.
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.upsert_node(&project_node("p1", dir.path())).unwrap();
        // Note: no File node for src/auth.ts this time.
        store
            .enqueue_job("session_summary", &session_summary_payload("p1"))
            .unwrap();

        let engine = FakeEngine::always_ok(WELL_FORMED_ANSWER);
        drain_queue(&store, dir.path(), &engine).unwrap();

        let hits = store.search("token refresh", Some("p1"), 10).unwrap();
        let note_id = &hits
            .iter()
            .find(|n| n.kind == NodeKind::Memory)
            .unwrap_or_else(|| panic!("no memory-kind hit in {hits:?}"))
            .id;
        // neighbors() inner-joins nodes, so a dangling edge to a
        // not-yet-existing node is invisible here — assert the edge row
        // exists via a fresh ingest of that file, which should "pick it up".
        store
            .upsert_node(&file_node("p1", "src/auth.ts"))
            .unwrap();
        let neighbors = store.neighbors(note_id, 10).unwrap();
        assert!(
            neighbors
                .iter()
                .any(|(e, n)| e.kind == EdgeKind::Touched && n.id == "p1:src/auth.ts"),
            "{neighbors:?}"
        );
    }

    #[test]
    fn drain_session_summary_in_review_mode_lands_pending_and_approve_makes_it_visible() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.upsert_node(&project_node("p1", dir.path())).unwrap();
        store.set_setting("review_memory", "true").unwrap();
        store
            .enqueue_job("session_summary", &session_summary_payload("p1"))
            .unwrap();

        let engine = FakeEngine::always_ok(WELL_FORMED_ANSWER);
        let done = drain_queue(&store, dir.path(), &engine).unwrap();
        assert_eq!(done, 1, "the job itself still completes in review mode");

        // Hidden from search while pending (the Session node — never gated
        // — still matches the same term, so assert on the Memory kind
        // specifically rather than the whole result set being empty).
        let hidden_hits = store.search("token refresh", Some("p1"), 10).unwrap();
        assert!(
            !hidden_hits.iter().any(|n| n.kind == NodeKind::Memory),
            "{hidden_hits:?}"
        );

        let pending = store.pending_notes(Some("p1")).unwrap();
        assert_eq!(pending.len(), 1);
        assert_eq!(pending[0].title, "Session: Fix auth token refresh");
        let note_id = pending[0].node_id.clone();

        // Frontmatter carries the pending marker on disk too.
        let note_path = store.get_node(&note_id).unwrap().unwrap().path.unwrap();
        let contents = std::fs::read_to_string(&note_path).unwrap();
        assert!(contents.contains("status: pending"), "{contents}");

        store.approve_pending(&note_id).unwrap();
        let visible_hits = store.search("token refresh", Some("p1"), 10).unwrap();
        assert!(
            visible_hits.iter().any(|n| n.kind == NodeKind::Memory),
            "{visible_hits:?}"
        );
    }

    #[test]
    fn drain_session_summary_review_mode_off_by_default_auto_commits() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store.upsert_node(&project_node("p1", dir.path())).unwrap();
        // No `review_memory` setting written at all.
        store
            .enqueue_job("session_summary", &session_summary_payload("p1"))
            .unwrap();

        let engine = FakeEngine::always_ok(WELL_FORMED_ANSWER);
        drain_queue(&store, dir.path(), &engine).unwrap();

        assert!(store.pending_notes(Some("p1")).unwrap().is_empty());
        let hits = store.search("token refresh", Some("p1"), 10).unwrap();
        assert!(hits.iter().any(|n| n.kind == NodeKind::Memory), "{hits:?}");
    }

    #[test]
    fn parse_title_and_body_handles_well_formed_answer() {
        let (title, body) = parse_title_and_body(WELL_FORMED_ANSWER, "p1");
        assert_eq!(title, "Fix auth token refresh");
        assert!(body.contains("regression test"), "{body}");
    }

    #[test]
    fn parse_title_and_body_falls_back_when_title_prefix_missing() {
        let (title, body) = parse_title_and_body("Just some prose the model wrote.", "p1");
        assert_eq!(title, "Just some prose the model wrote.");
        assert_eq!(body, "Just some prose the model wrote.");
    }

    #[test]
    fn parse_title_and_body_falls_back_to_project_name_on_blank_answer() {
        let (title, _body) = parse_title_and_body("   ", "p1");
        assert_eq!(title, "Session in p1");
    }

    #[test]
    fn parse_diff_stat_paths_extracts_plain_paths() {
        let stat = " src/auth.ts | 4 ++--\n src/util.ts  | 2 +-\n 2 files changed, 4 insertions(+), 2 deletions(-)";
        let paths = parse_diff_stat_paths(stat);
        assert_eq!(paths, vec!["src/auth.ts".to_string(), "src/util.ts".to_string()]);
    }

    #[test]
    fn parse_diff_stat_paths_resolves_brace_rename_to_new_path() {
        let stat = " src/{old.ts => new.ts} | 0";
        let paths = parse_diff_stat_paths(stat);
        assert_eq!(paths, vec!["src/new.ts".to_string()]);
    }

    #[test]
    fn parse_diff_stat_paths_resolves_whole_path_rename_to_new_path() {
        let stat = " old-name.ts => new-name.ts | 0";
        let paths = parse_diff_stat_paths(stat);
        assert_eq!(paths, vec!["new-name.ts".to_string()]);
    }

    #[test]
    fn parse_diff_stat_paths_on_empty_diff_is_empty() {
        assert!(parse_diff_stat_paths("").is_empty());
        assert!(parse_diff_stat_paths("(no uncommitted changes)").is_empty());
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
        let done = drain_queue(&store, Path::new("/tmp"), &engine).unwrap();

        assert_eq!(done, 0);
        assert_eq!(store.pending_jobs(10).unwrap().len(), 1);
    }
}
