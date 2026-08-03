//! The six frozen v1 MCP tools (PLAN.md Task 3.1). Each tool is a pure
//! function of `(ToolContext, arguments: &Value) -> Result<Value, ToolError>`
//! — `protocol::serve` owns the JSON-RPC/MCP envelope (`content`,
//! `structuredContent`, `isError`) and just calls `call()` to dispatch.
//!
//! ## `Decision` vs `Memory` nodes (a deliberate deviation, documented)
//!
//! PLAN.md's frozen contract says `record_decision`/`record_note` both go
//! "via `Memory::write_note`" — and `Memory::write_note` (Phase 1, already
//! committed) always upserts a `NodeKind::Memory` node; there is no code
//! path that produces a `NodeKind::Decision` node even though that enum
//! variant exists in `brain_core::store`. Rather than reach back into
//! already-shipped Phase 1 code for this task, both tools write `Memory`
//! nodes and distinguish themselves purely by a title prefix:
//! `record_decision` -> `"Decision: <first line of text, <=60 chars>"`,
//! `record_note` -> `"Note: <...>"`. `get_context`'s `recent_decisions`
//! is therefore `Memory` nodes whose label starts with `"Decision:"`;
//! `memory_notes` is *all* `Memory` nodes for the project (decisions
//! included) so nothing is hidden from the general briefing list.
//!
//! ## `related_projects` (currently usually empty, by design)
//! `get_context`'s `related_projects` is the `Project`-kind neighbors of
//! the project's own node. As of Phase 2, ingestion never creates
//! cross-project edges (imports/co-change are resolved within one project
//! only — see `brain-ingest`'s `code.rs`/`gitmine.rs`), so this is
//! legitimately `[]` today. It's wired against real graph adjacency (not
//! stubbed) so it lights up automatically once something creates
//! cross-project edges (DESIGN.md 3.3 names "cross-project link
//! candidates" as a later enrichment job).

use brain_core::{Edge, Memory, Node, NodeKind, Origin, Store};
use serde::Serialize;
use serde_json::{json, Value};
use std::path::Path;

/// Default result caps for tools whose frozen input contract has no limit
/// parameter (`search_brain`, `related`) or whose output is a briefing
/// block that should stay skimmable (`get_context`'s lists).
const SEARCH_LIMIT: usize = 20;
const RELATED_LIMIT: usize = 25;
const RECENT_DECISIONS_LIMIT: usize = 10;
const MEMORY_NOTES_LIMIT: usize = 20;
const TITLE_TRUNCATE_CHARS: usize = 60;

pub struct ToolContext<'a> {
    pub store: &'a Store,
    pub data_dir: &'a Path,
}

#[derive(Debug)]
pub enum ToolError {
    /// A required argument was absent from `arguments` — a malformed
    /// `tools/call`, surfaced by `protocol::serve` as a JSON-RPC
    /// "invalid params" error rather than a tool-level failure.
    MissingField(&'static str),
    /// The tool ran but failed doing its job (DB error, disk write
    /// failure, ...) — surfaced as a `CallToolResult` with `isError: true`.
    Internal(String),
}

impl std::fmt::Display for ToolError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ToolError::MissingField(field) => write!(f, "missing required field: {field}"),
            ToolError::Internal(msg) => write!(f, "{msg}"),
        }
    }
}

fn internal<E: std::fmt::Display>(e: E) -> ToolError {
    ToolError::Internal(e.to_string())
}

fn require_str<'a>(args: &'a Value, field: &'static str) -> Result<&'a str, ToolError> {
    args.get(field)
        .and_then(|v| v.as_str())
        .ok_or(ToolError::MissingField(field))
}

fn kind_str(kind: NodeKind) -> &'static str {
    match kind {
        NodeKind::Project => "project",
        NodeKind::File => "file",
        NodeKind::CodeEntity => "code_entity",
        NodeKind::Doc => "doc",
        NodeKind::Memory => "memory",
        NodeKind::Decision => "decision",
        NodeKind::Session => "session",
        NodeKind::Community => "community",
    }
}

fn edge_kind_str(kind: brain_core::EdgeKind) -> &'static str {
    use brain_core::EdgeKind::*;
    match kind {
        Contains => "contains",
        Imports => "imports",
        References => "references",
        LinksTo => "links_to",
        MemberOf => "member_of",
        Touched => "touched",
    }
}

/// The shared node projection used by `search_brain`, `related`, and
/// `get_context`'s `recent_decisions`/`memory_notes`:
/// `{id, kind, project, label, path?, summary?}` — exactly the
/// `search_brain` frozen shape, reused everywhere a node needs to appear
/// in a tool result so there's one serialization, not several.
#[derive(Serialize)]
struct NodeView {
    id: String,
    kind: &'static str,
    project: String,
    label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    path: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    summary: Option<String>,
}

impl From<&Node> for NodeView {
    fn from(n: &Node) -> Self {
        NodeView {
            id: n.id.clone(),
            kind: kind_str(n.kind),
            project: n.project.clone(),
            label: n.label.clone(),
            path: n.path.clone(),
            summary: n.summary.clone(),
        }
    }
}

/// The `list_projects` / `get_context.related_projects` shape: `{id, label, path}`.
#[derive(Serialize)]
struct ProjectView {
    id: String,
    label: String,
    path: Option<String>,
}

impl From<&Node> for ProjectView {
    fn from(n: &Node) -> Self {
        ProjectView {
            id: n.id.clone(),
            label: n.label.clone(),
            path: n.path.clone(),
        }
    }
}

/// `"Decision"`/`"Note"` + the first line of `text`, truncated to
/// `TITLE_TRUNCATE_CHARS`. Falls back to the bare prefix if `text` is
/// empty/whitespace-only, so `Memory::write_note`'s slugified filename is
/// never empty.
fn derive_title(prefix: &str, text: &str) -> String {
    let first_line: String = text
        .lines()
        .next()
        .unwrap_or("")
        .trim()
        .chars()
        .take(TITLE_TRUNCATE_CHARS)
        .collect();
    if first_line.is_empty() {
        prefix.to_string()
    } else {
        format!("{prefix}: {first_line}")
    }
}

/// `search_brain {query, scope?}` -> `[{id, kind, project, label, path?, summary?}]`
pub fn search_brain(ctx: &ToolContext, args: &Value) -> Result<Value, ToolError> {
    let query = require_str(args, "query")?;
    let scope = args.get("scope").and_then(|v| v.as_str());
    let hits = ctx
        .store
        .search(query, scope, SEARCH_LIMIT)
        .map_err(internal)?;
    let items: Vec<NodeView> = hits.iter().map(NodeView::from).collect();
    Ok(serde_json::to_value(items).expect("NodeView always serializes"))
}

/// `get_context {project}` -> `{summary, recent_decisions, related_projects, memory_notes}`
pub fn get_context(ctx: &ToolContext, args: &Value) -> Result<Value, ToolError> {
    let project = require_str(args, "project")?;

    let summary = ctx
        .store
        .get_node(project)
        .map_err(internal)?
        .and_then(|n| n.summary)
        .unwrap_or_default();

    let nodes = ctx.store.nodes_for_project(project).map_err(internal)?;

    // Task 7.1: a session-summary Memory note awaiting review (`pending_notes`)
    // must not show up in the briefing until approved — "not auto-committed
    // live into ... briefings" per PLAN.md's review-mode bullet. Same gate
    // `Store::search` applies, applied here since `nodes_for_project` itself
    // stays ungated (the brain map still renders pending nodes informationally).
    let pending_ids: std::collections::HashSet<String> = ctx
        .store
        .pending_notes(Some(project))
        .map_err(internal)?
        .into_iter()
        .map(|p| p.node_id)
        .collect();

    let mut memory_nodes: Vec<&Node> = nodes
        .iter()
        .filter(|n| n.kind == NodeKind::Memory && !pending_ids.contains(&n.id))
        .collect();
    memory_nodes.sort_by_key(|n| std::cmp::Reverse(n.updated));

    let recent_decisions: Vec<NodeView> = memory_nodes
        .iter()
        .filter(|n| n.label.starts_with("Decision:"))
        .take(RECENT_DECISIONS_LIMIT)
        .map(|n| NodeView::from(*n))
        .collect();

    let memory_notes: Vec<NodeView> = memory_nodes
        .iter()
        .take(MEMORY_NOTES_LIMIT)
        .map(|n| NodeView::from(*n))
        .collect();

    let neighbors = ctx
        .store
        .neighbors(project, RELATED_LIMIT)
        .map_err(internal)?;
    let mut seen = std::collections::HashSet::new();
    let related_projects: Vec<ProjectView> = neighbors
        .iter()
        .filter(|(_, n)| n.kind == NodeKind::Project && seen.insert(n.id.clone()))
        .map(|(_, n)| ProjectView::from(n))
        .collect();

    Ok(json!({
        "summary": summary,
        "recent_decisions": recent_decisions,
        "related_projects": related_projects,
        "memory_notes": memory_notes,
    }))
}

/// `related {node_id}` -> `[{edge_kind, node}]`
pub fn related(ctx: &ToolContext, args: &Value) -> Result<Value, ToolError> {
    let node_id = require_str(args, "node_id")?;
    let neighbors = ctx
        .store
        .neighbors(node_id, RELATED_LIMIT)
        .map_err(internal)?;
    let items: Vec<Value> = neighbors
        .iter()
        .map(|(edge, node): &(Edge, Node)| {
            json!({
                "edge_kind": edge_kind_str(edge.kind),
                "node": NodeView::from(node),
            })
        })
        .collect();
    Ok(Value::Array(items))
}

fn write_memory(ctx: &ToolContext, prefix: &str, args: &Value) -> Result<Value, ToolError> {
    let project = require_str(args, "project")?;
    let text = require_str(args, "text")?;
    let title = derive_title(prefix, text);

    let memory = Memory::new(ctx.store, ctx.data_dir);
    let path = memory
        .write_note(project, &title, text, Origin::UserAuthored)
        .map_err(internal)?;

    Ok(json!({ "path": path.to_string_lossy() }))
}

/// `record_decision {project, text}` -> `{path}`. Writes via
/// `Memory::write_note(..., Origin::UserAuthored)` with a `"Decision: "`-
/// prefixed title (see module docs for why this is a `Memory` node, not a
/// `Decision` node).
pub fn record_decision(ctx: &ToolContext, args: &Value) -> Result<Value, ToolError> {
    write_memory(ctx, "Decision", args)
}

/// `record_note {project, text}` -> `{path}`. Same as `record_decision`
/// but with a `"Note: "`-prefixed title, so `get_context` doesn't surface
/// it as a decision.
pub fn record_note(ctx: &ToolContext, args: &Value) -> Result<Value, ToolError> {
    write_memory(ctx, "Note", args)
}

/// Re-export of [`brain_core::project_label_key`], kept at this path because
/// it is where the helper was first defined and where `src-tauri` and
/// `brain-ingest` already reference it from.
///
/// It moved down into `brain-core` (final whole-branch review, Minor #6):
/// `brain-ingest` needed it too, and depending on this crate for one string
/// helper inverted the intended layering — `mcp-server` is the frozen public
/// contract *above* ingestion, not below it. `brain-core` is the crate both
/// already sit on, and the key names a `settings` row, which is `Store`'s own
/// table. See the definition for why the override lives in `settings` rather
/// than on the node's `label` column.
pub use brain_core::project_label_key;

/// `list_projects {}` -> `[{id, label, path}]`. `label` reflects a
/// `rename_project` override (see [`project_label_key`]) when one exists,
/// in preference to the node's own (ingestion-owned) label.
pub fn list_projects(ctx: &ToolContext, _args: &Value) -> Result<Value, ToolError> {
    let projects = ctx.store.list_projects().map_err(internal)?;
    let items: Vec<ProjectView> = projects
        .iter()
        .map(|n| {
            let mut view = ProjectView::from(n);
            if let Ok(Some(label)) = ctx.store.get_setting(&project_label_key(&n.id)) {
                let trimmed = label.trim();
                if !trimmed.is_empty() {
                    view.label = trimmed.to_string();
                }
            }
            view
        })
        .collect();
    Ok(serde_json::to_value(items).expect("ProjectView always serializes"))
}

/// Dispatches a `tools/call` by name. `None` means the name isn't one of
/// the six frozen tools (the caller turns that into a JSON-RPC error).
pub fn call(ctx: &ToolContext, name: &str, args: &Value) -> Option<Result<Value, ToolError>> {
    match name {
        "search_brain" => Some(search_brain(ctx, args)),
        "get_context" => Some(get_context(ctx, args)),
        "related" => Some(related(ctx, args)),
        "record_decision" => Some(record_decision(ctx, args)),
        "record_note" => Some(record_note(ctx, args)),
        "list_projects" => Some(list_projects(ctx, args)),
        _ => None,
    }
}

/// The `tools/list` payload: JSON Schema `inputSchema` for each of the six
/// frozen tools, in the order the contract lists them in PLAN.md.
pub fn tool_defs() -> Vec<Value> {
    vec![
        json!({
            "name": "search_brain",
            "description": "Full-text search over the local knowledge graph (files, code entities, docs, memory notes, decisions, projects).",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Free-text search query."},
                    "scope": {"type": "string", "description": "Optional project id to restrict the search to."}
                },
                "required": ["query"]
            }
        }),
        json!({
            "name": "get_context",
            "description": "Per-project briefing block: summary, recent decisions, related projects, and memory notes.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": {"type": "string", "description": "Project id."}
                },
                "required": ["project"]
            }
        }),
        json!({
            "name": "related",
            "description": "Graph neighbors of a node: typed edge plus the neighboring node.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "node_id": {"type": "string", "description": "Node id to look up neighbors for."}
                },
                "required": ["node_id"]
            }
        }),
        json!({
            "name": "record_decision",
            "description": "Record a user-authored decision as a Markdown memory note, linked into the graph.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": {"type": "string"},
                    "text": {"type": "string"}
                },
                "required": ["project", "text"]
            }
        }),
        json!({
            "name": "record_note",
            "description": "Record a user-authored general note as a Markdown memory note, linked into the graph.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "project": {"type": "string"},
                    "text": {"type": "string"}
                },
                "required": ["project", "text"]
            }
        }),
        json!({
            "name": "list_projects",
            "description": "List every ingested project.",
            "inputSchema": {
                "type": "object",
                "properties": {},
                "required": []
            }
        }),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use brain_core::{now_ts, EdgeKind, NodeKind, Origin};
    use tempfile::tempdir;

    fn node(id: &str, kind: NodeKind, project: &str, label: &str) -> Node {
        Node {
            id: id.to_string(),
            kind,
            project: project.to_string(),
            label: label.to_string(),
            path: None,
            summary: None,
            origin: Origin::Extracted,
            updated: now_ts(),
        }
    }

    #[test]
    fn derive_title_prefixes_and_truncates() {
        assert_eq!(
            derive_title("Decision", "Use SQLite"),
            "Decision: Use SQLite"
        );
        assert_eq!(derive_title("Note", ""), "Note");
        assert_eq!(derive_title("Note", "   \n  "), "Note");
        let long = "x".repeat(200);
        let title = derive_title("Note", &long);
        assert_eq!(title, format!("Note: {}", "x".repeat(TITLE_TRUNCATE_CHARS)));
    }

    #[test]
    fn derive_title_uses_first_line_only() {
        assert_eq!(
            derive_title("Decision", "line one\nline two"),
            "Decision: line one"
        );
    }

    #[test]
    fn search_brain_requires_query() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };
        let err = search_brain(&ctx, &json!({})).unwrap_err();
        assert!(matches!(err, ToolError::MissingField("query")));
    }

    #[test]
    fn search_brain_returns_frozen_shape() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&node(
                "p1:helpers.py#parse_config",
                NodeKind::CodeEntity,
                "p1",
                "parse_config",
            ))
            .unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };

        let result = search_brain(&ctx, &json!({"query": "parse_config"})).unwrap();
        let items = result.as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "p1:helpers.py#parse_config");
        assert_eq!(items[0]["kind"], "code_entity");
        assert_eq!(items[0]["project"], "p1");
        assert_eq!(items[0]["label"], "parse_config");
        // path/summary are None on this node -> omitted, not null.
        assert!(items[0].get("path").is_none());
        assert!(items[0].get("summary").is_none());
    }

    #[test]
    fn list_projects_returns_frozen_shape() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&Node {
                path: Some("/tmp/p1".to_string()),
                ..node("p1", NodeKind::Project, "p1", "p1")
            })
            .unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };

        let result = list_projects(&ctx, &json!({})).unwrap();
        let items = result.as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "p1");
        assert_eq!(items[0]["label"], "p1");
        assert_eq!(items[0]["path"], "/tmp/p1");
    }

    #[test]
    fn list_projects_prefers_a_rename_override_over_the_nodes_own_label() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&Node {
                path: Some("/tmp/p1".to_string()),
                ..node("p1", NodeKind::Project, "p1", "p1")
            })
            .unwrap();
        // Simulates `rename_project` having written the override, plus a
        // re-ingest pass afterward re-upserting the node's own label back
        // to "p1" (exactly what `ingest_project` does on every re-ingest) —
        // the override must still win.
        store
            .set_setting(&project_label_key("p1"), "OmniAgent")
            .unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };

        let result = list_projects(&ctx, &json!({})).unwrap();
        let items = result.as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["id"], "p1"); // id/project key never changes
        assert_eq!(items[0]["label"], "OmniAgent");
    }

    #[test]
    fn list_projects_ignores_a_blank_override() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&node("p1", NodeKind::Project, "p1", "p1"))
            .unwrap();
        store.set_setting(&project_label_key("p1"), "   ").unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };

        let result = list_projects(&ctx, &json!({})).unwrap();
        assert_eq!(result.as_array().unwrap()[0]["label"], "p1");
    }

    #[test]
    fn related_returns_edge_kind_and_node() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&node("p1:a.ts", NodeKind::File, "p1", "a.ts"))
            .unwrap();
        store
            .upsert_node(&node("p1:b.ts", NodeKind::File, "p1", "b.ts"))
            .unwrap();
        store
            .upsert_edge(&Edge {
                src: "p1:a.ts".into(),
                dst: "p1:b.ts".into(),
                kind: EdgeKind::Imports,
                weight: 1.0,
            })
            .unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };

        let result = related(&ctx, &json!({"node_id": "p1:a.ts"})).unwrap();
        let items = result.as_array().unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0]["edge_kind"], "imports");
        assert_eq!(items[0]["node"]["id"], "p1:b.ts");
    }

    #[test]
    fn record_decision_writes_note_and_returns_path() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };

        let result =
            record_decision(&ctx, &json!({"project": "p1", "text": "Use SQLite"})).unwrap();
        let path = result["path"].as_str().unwrap();
        assert!(std::path::Path::new(path).exists());
        let contents = std::fs::read_to_string(path).unwrap();
        assert!(contents.contains("# Decision: Use SQLite"));
        assert!(contents.contains("Use SQLite"));
    }

    #[test]
    fn record_note_uses_note_prefix_not_decision() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };

        let result = record_note(&ctx, &json!({"project": "p1", "text": "Remember this"})).unwrap();
        let path = result["path"].as_str().unwrap();
        let contents = std::fs::read_to_string(path).unwrap();
        assert!(contents.contains("# Note: Remember this"));
    }

    #[test]
    fn get_context_splits_decisions_from_general_notes() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        store
            .upsert_node(&Node {
                summary: Some("A project.".into()),
                ..node("p1", NodeKind::Project, "p1", "p1")
            })
            .unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };

        record_decision(&ctx, &json!({"project": "p1", "text": "Decision text"})).unwrap();
        record_note(&ctx, &json!({"project": "p1", "text": "Note text"})).unwrap();

        let result = get_context(&ctx, &json!({"project": "p1"})).unwrap();
        assert_eq!(result["summary"], "A project.");
        assert_eq!(result["recent_decisions"].as_array().unwrap().len(), 1);
        assert_eq!(result["memory_notes"].as_array().unwrap().len(), 2);
        assert!(result["related_projects"].as_array().unwrap().is_empty());
    }

    #[test]
    fn get_context_hides_pending_memory_notes_until_approved() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };
        store
            .upsert_node(&Node {
                summary: Some("A project.".into()),
                ..node("p1", NodeKind::Project, "p1", "p1")
            })
            .unwrap();

        let memory = Memory::new(&store, dir.path());
        let (_path, note_id) = memory
            .write_note_with_status(
                "p1",
                "Session: add auth",
                "did some work",
                Origin::MachineSummary,
                true,
            )
            .unwrap();

        let result = get_context(&ctx, &json!({"project": "p1"})).unwrap();
        assert!(
            result["memory_notes"].as_array().unwrap().is_empty(),
            "{result:?}"
        );

        store.approve_pending(&note_id).unwrap();

        let result = get_context(&ctx, &json!({"project": "p1"})).unwrap();
        assert_eq!(result["memory_notes"].as_array().unwrap().len(), 1);
    }

    #[test]
    fn call_dispatches_by_name_and_returns_none_for_unknown() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();
        let ctx = ToolContext {
            store: &store,
            data_dir: dir.path(),
        };

        assert!(call(&ctx, "list_projects", &json!({})).is_some());
        assert!(call(&ctx, "not_a_real_tool", &json!({})).is_none());
    }

    #[test]
    fn tool_defs_names_match_frozen_contract_exactly() {
        let defs = tool_defs();
        let names: Vec<&str> = defs.iter().map(|t| t["name"].as_str().unwrap()).collect();
        assert_eq!(
            names,
            vec![
                "search_brain",
                "get_context",
                "related",
                "record_decision",
                "record_note",
                "list_projects",
            ]
        );
    }
}
