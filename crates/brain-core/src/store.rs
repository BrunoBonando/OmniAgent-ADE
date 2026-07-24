use rusqlite::{params, Connection, OptionalExtension};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub struct Store {
    pub(crate) conn: Connection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NodeKind {
    Project,
    File,
    CodeEntity,
    Doc,
    Memory,
    Decision,
    Session,
    Community,
}

impl NodeKind {
    fn as_str(&self) -> &'static str {
        match self {
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

    fn from_str(s: &str) -> NodeKind {
        match s {
            "project" => NodeKind::Project,
            "file" => NodeKind::File,
            "code_entity" => NodeKind::CodeEntity,
            "doc" => NodeKind::Doc,
            "memory" => NodeKind::Memory,
            "decision" => NodeKind::Decision,
            "session" => NodeKind::Session,
            "community" => NodeKind::Community,
            other => panic!("unknown NodeKind in db: {other}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Origin {
    Extracted,
    MachineSummary,
    UserAuthored,
}

impl Origin {
    fn as_str(&self) -> &'static str {
        match self {
            Origin::Extracted => "extracted",
            Origin::MachineSummary => "machine_summary",
            Origin::UserAuthored => "user_authored",
        }
    }

    fn from_str(s: &str) -> Origin {
        match s {
            "extracted" => Origin::Extracted,
            "machine_summary" => Origin::MachineSummary,
            "user_authored" => Origin::UserAuthored,
            other => panic!("unknown Origin in db: {other}"),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EdgeKind {
    Contains,
    Imports,
    References,
    LinksTo,
    MemberOf,
    Touched,
}

impl EdgeKind {
    fn as_str(&self) -> &'static str {
        match self {
            EdgeKind::Contains => "contains",
            EdgeKind::Imports => "imports",
            EdgeKind::References => "references",
            EdgeKind::LinksTo => "links_to",
            EdgeKind::MemberOf => "member_of",
            EdgeKind::Touched => "touched",
        }
    }

    fn from_str(s: &str) -> EdgeKind {
        match s {
            "contains" => EdgeKind::Contains,
            "imports" => EdgeKind::Imports,
            "references" => EdgeKind::References,
            "links_to" => EdgeKind::LinksTo,
            "member_of" => EdgeKind::MemberOf,
            "touched" => EdgeKind::Touched,
            other => panic!("unknown EdgeKind in db: {other}"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct Node {
    pub id: String,
    pub kind: NodeKind,
    pub project: String,
    pub label: String,
    pub path: Option<String>,
    pub summary: Option<String>,
    pub origin: Origin,
    pub updated: i64,
}

#[derive(Debug, Clone)]
pub struct Edge {
    pub src: String,
    pub dst: String,
    pub kind: EdgeKind,
    pub weight: f32,
}

/// A row from `enrich_queue` (Phase 4): one unit of headless-LLM enrichment
/// work. `payload` is caller-defined JSON — kept minimal (typically just the
/// target node id) since enrichment reads fresh context from the store at
/// drain time rather than snapshotting it into the queue.
#[derive(Debug, Clone)]
pub struct QueueJob {
    pub id: i64,
    pub kind: String,
    pub payload: String,
    pub status: String,
    pub created: i64,
}

fn row_to_job(row: &rusqlite::Row) -> rusqlite::Result<QueueJob> {
    Ok(QueueJob {
        id: row.get(0)?,
        kind: row.get(1)?,
        payload: row.get(2)?,
        status: row.get(3)?,
        created: row.get(4)?,
    })
}

/// A row from `pending_notes` (Task 7.1's review-mode gate), joined with its
/// node for display purposes — `title`/`path` mirror the node's
/// `label`/`path` at query time rather than being duplicated into
/// `pending_notes` itself, so they can never drift out of sync with the
/// node they describe.
#[derive(Debug, Clone)]
pub struct PendingNote {
    pub node_id: String,
    pub project: String,
    pub title: String,
    pub path: Option<String>,
    pub created: i64,
}

fn row_to_pending_note(row: &rusqlite::Row) -> rusqlite::Result<PendingNote> {
    Ok(PendingNote {
        node_id: row.get(0)?,
        project: row.get(1)?,
        title: row.get(2)?,
        path: row.get(3)?,
        created: row.get(4)?,
    })
}

pub fn now_ts() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_secs() as i64
}

fn row_to_node(row: &rusqlite::Row) -> rusqlite::Result<Node> {
    Ok(Node {
        id: row.get(0)?,
        kind: NodeKind::from_str(&row.get::<_, String>(1)?),
        project: row.get(2)?,
        label: row.get(3)?,
        path: row.get(4)?,
        summary: row.get(5)?,
        origin: Origin::from_str(&row.get::<_, String>(6)?),
        updated: row.get(7)?,
    })
}

const NODE_COLS: &str = "id, kind, project, label, path, summary, origin, updated";

/// Turns free-text user input into a safe FTS5 MATCH expression: splits on
/// anything that isn't alphanumeric/underscore and wraps each token as a
/// quoted prefix term (`"foo"*`), ANDed by FTS5's default juxtaposition.
/// Quoting matters because FTS5's *query* grammar treats bare `-`, `:`, `(`,
/// `"`, etc. as operators (NOT, column filter, grouping, ...) independent of
/// how the content tokenizer split those same characters at insert time —
/// an unquoted search for e.g. "co-change" or "foo:bar" otherwise fails with
/// a raw SQL parse error ("no such column: ...") instead of just finding
/// nothing. Empty input (or input that's all punctuation) yields "".
fn sanitize_fts_query(query: &str) -> String {
    query
        .split(|c: char| !c.is_alphanumeric() && c != '_')
        .filter(|tok| !tok.is_empty())
        .map(|tok| format!("\"{tok}\"*"))
        .collect::<Vec<_>>()
        .join(" ")
}

impl Store {
    /// Resolves the local-first data directory: honors the `OMNIAGENT_ADE_DATA_DIR`
    /// env var override (used by tests and by `OMNIAGENT_ADE_DATA_DIR=... brain ingest`
    /// manual runs) and otherwise falls back to
    /// `~/Library/Application Support/OmniAgent-ADE` per the Global Constraints.
    pub fn default_data_dir() -> PathBuf {
        if let Ok(dir) = std::env::var("OMNIAGENT_ADE_DATA_DIR") {
            if !dir.trim().is_empty() {
                return PathBuf::from(dir);
            }
        }
        let home = std::env::var("HOME").unwrap_or_else(|_| "/tmp".to_string());
        PathBuf::from(home).join("Library/Application Support/OmniAgent-ADE")
    }

    /// Opens (creating if absent) the brain database under `data_dir/brain.db`.
    pub fn open(data_dir: &Path) -> rusqlite::Result<Store> {
        std::fs::create_dir_all(data_dir).expect("create data dir");
        let conn = Connection::open(data_dir.join("brain.db"))?;
        conn.execute_batch(include_str!("schema.sql"))?;
        Ok(Store { conn })
    }

    /// In-memory store, for tests only.
    pub fn open_in_memory() -> rusqlite::Result<Store> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(include_str!("schema.sql"))?;
        Ok(Store { conn })
    }

    pub fn upsert_node(&self, n: &Node) -> rusqlite::Result<()> {
        self.conn.execute(
            "INSERT INTO nodes (id, kind, project, label, path, summary, origin, updated)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
             ON CONFLICT(id) DO UPDATE SET
                kind=excluded.kind, project=excluded.project, label=excluded.label,
                path=excluded.path, summary=excluded.summary, origin=excluded.origin,
                updated=excluded.updated",
            params![
                n.id,
                n.kind.as_str(),
                n.project,
                n.label,
                n.path,
                n.summary,
                n.origin.as_str(),
                n.updated
            ],
        )?;
        self.conn
            .execute("DELETE FROM nodes_fts WHERE id = ?1", params![n.id])?;
        self.conn.execute(
            "INSERT INTO nodes_fts (id, label, summary) VALUES (?1, ?2, ?3)",
            params![n.id, n.label, n.summary.clone().unwrap_or_default()],
        )?;
        Ok(())
    }

    pub fn upsert_edge(&self, e: &Edge) -> rusqlite::Result<()> {
        self.conn.execute(
            "INSERT INTO edges (src, dst, kind, weight) VALUES (?1, ?2, ?3, ?4)
             ON CONFLICT(src, dst, kind) DO UPDATE SET weight=excluded.weight",
            params![e.src, e.dst, e.kind.as_str(), e.weight],
        )?;
        Ok(())
    }

    /// Removes all `Extracted`-origin nodes for a project (and their edges),
    /// so ingestion can be re-run idempotently while preserving Memory/Decision
    /// notes, which are always UserAuthored or MachineSummary.
    pub fn delete_project_extracted(&self, project: &str) -> rusqlite::Result<()> {
        let ids: Vec<String> = self
            .conn
            .prepare("SELECT id FROM nodes WHERE project = ?1 AND origin = 'extracted'")?
            .query_map(params![project], |r| r.get(0))?
            .collect::<Result<_, _>>()?;
        for id in &ids {
            self.conn
                .execute("DELETE FROM edges WHERE src = ?1 OR dst = ?1", params![id])?;
            self.conn
                .execute("DELETE FROM nodes_fts WHERE id = ?1", params![id])?;
            self.conn
                .execute("DELETE FROM nodes WHERE id = ?1", params![id])?;
        }
        Ok(())
    }

    pub fn get_node(&self, id: &str) -> rusqlite::Result<Option<Node>> {
        self.conn
            .query_row(
                &format!("SELECT {NODE_COLS} FROM nodes WHERE id = ?1"),
                params![id],
                row_to_node,
            )
            .optional()
    }

    pub fn search(
        &self,
        query: &str,
        scope: Option<&str>,
        limit: usize,
    ) -> rusqlite::Result<Vec<Node>> {
        let fts_query = sanitize_fts_query(query);
        if fts_query.is_empty() {
            return Ok(vec![]);
        }
        // LEFT JOIN + `p.node_id IS NULL`: exclude anything awaiting review
        // (Task 7.1's `pending_notes` gate) from search results, same as
        // `get_context`'s memory-notes projection — "not auto-committed live
        // into search/briefings" per PLAN.md's review-mode bullet.
        let mut stmt = self.conn.prepare(&format!(
            "SELECT {cols} FROM nodes_fts f
             JOIN nodes n ON n.id = f.id
             LEFT JOIN pending_notes p ON p.node_id = n.id
             WHERE nodes_fts MATCH ?1
               AND (?2 IS NULL OR n.project = ?2)
               AND p.node_id IS NULL
             ORDER BY rank
             LIMIT ?3",
            cols = NODE_COLS
                .split(", ")
                .map(|c| format!("n.{c}"))
                .collect::<Vec<_>>()
                .join(", ")
        ))?;
        let rows = stmt
            .query_map(params![fts_query, scope, limit as i64], row_to_node)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    pub fn neighbors(&self, id: &str, limit: usize) -> rusqlite::Result<Vec<(Edge, Node)>> {
        let mut stmt = self.conn.prepare(&format!(
            "SELECT e.src, e.dst, e.kind, e.weight, {cols}
             FROM edges e JOIN nodes n ON n.id = (CASE WHEN e.src = ?1 THEN e.dst ELSE e.src END)
             WHERE e.src = ?1 OR e.dst = ?1
             LIMIT ?2",
            cols = NODE_COLS
                .split(", ")
                .map(|c| format!("n.{c}"))
                .collect::<Vec<_>>()
                .join(", ")
        ))?;
        let out = stmt
            .query_map(params![id, limit as i64], |row| {
                let edge = Edge {
                    src: row.get(0)?,
                    dst: row.get(1)?,
                    kind: EdgeKind::from_str(&row.get::<_, String>(2)?),
                    weight: row.get(3)?,
                };
                Ok((
                    edge,
                    Node {
                        id: row.get(4)?,
                        kind: NodeKind::from_str(&row.get::<_, String>(5)?),
                        project: row.get(6)?,
                        label: row.get(7)?,
                        path: row.get(8)?,
                        summary: row.get(9)?,
                        origin: Origin::from_str(&row.get::<_, String>(10)?),
                        updated: row.get(11)?,
                    },
                ))
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(out)
    }

    pub fn list_projects(&self) -> rusqlite::Result<Vec<Node>> {
        let mut stmt = self.conn.prepare(&format!(
            "SELECT {NODE_COLS} FROM nodes WHERE kind = 'project' ORDER BY label"
        ))?;
        let rows = stmt
            .query_map([], row_to_node)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// All nodes belonging to `project`, any kind. Used by ingestion (community
    /// detection needs the whole project subgraph) and by callers that want to
    /// inspect ingest results (stats, tests) without a text query.
    pub fn nodes_for_project(&self, project: &str) -> rusqlite::Result<Vec<Node>> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {NODE_COLS} FROM nodes WHERE project = ?1"))?;
        let rows = stmt
            .query_map(params![project], row_to_node)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Adds a pending enrichment job (Phase 4). Dedupes against an existing
    /// *pending* job of the same `kind` + `payload` and returns that job's id
    /// instead of inserting a duplicate — re-ingesting a project you just
    /// ingested a moment ago, or the fs watcher firing twice, shouldn't pile
    /// up repeat LLM calls for jobs no drain has touched yet.
    pub fn enqueue_job(&self, kind: &str, payload: &str) -> rusqlite::Result<i64> {
        let existing: Option<i64> = self
            .conn
            .query_row(
                "SELECT id FROM enrich_queue WHERE kind = ?1 AND payload = ?2 AND status = 'pending'",
                params![kind, payload],
                |r| r.get(0),
            )
            .optional()?;
        if let Some(id) = existing {
            return Ok(id);
        }
        self.conn.execute(
            "INSERT INTO enrich_queue (kind, payload, status, created) VALUES (?1, ?2, 'pending', ?3)",
            params![kind, payload, now_ts()],
        )?;
        Ok(self.conn.last_insert_rowid())
    }

    /// Pending enrichment jobs, oldest first (FIFO drain order).
    pub fn pending_jobs(&self, limit: usize) -> rusqlite::Result<Vec<QueueJob>> {
        self.jobs_with_status("pending", limit)
    }

    /// Enrichment jobs in a given `status` ("pending" | "done" | "failed"),
    /// oldest first. Exposed generically (not just `pending_jobs`) so callers
    /// and tests can inspect drain outcomes.
    pub fn jobs_with_status(&self, status: &str, limit: usize) -> rusqlite::Result<Vec<QueueJob>> {
        let mut stmt = self.conn.prepare(
            "SELECT id, kind, payload, status, created FROM enrich_queue
             WHERE status = ?1 ORDER BY id LIMIT ?2",
        )?;
        let rows = stmt
            .query_map(params![status, limit as i64], row_to_job)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Updates a job's status (and payload — e.g. to record a failure
    /// reason) after `drain_queue` processes it.
    pub fn set_job_status(&self, id: i64, status: &str, payload: &str) -> rusqlite::Result<()> {
        self.conn.execute(
            "UPDATE enrich_queue SET status = ?1, payload = ?2 WHERE id = ?3",
            params![status, payload, id],
        )?;
        Ok(())
    }

    /// Reads a value from the `settings` key/value table (Task 5.2: per-project
    /// default engine, restorable tab layout, etc.). `None` when the key has
    /// never been set.
    pub fn get_setting(&self, key: &str) -> rusqlite::Result<Option<String>> {
        self.conn
            .query_row(
                "SELECT value FROM settings WHERE key = ?1",
                params![key],
                |r| r.get(0),
            )
            .optional()
    }

    /// Upserts a value in the `settings` table.
    pub fn set_setting(&self, key: &str, value: &str) -> rusqlite::Result<()> {
        self.conn.execute(
            "INSERT INTO settings (key, value) VALUES (?1, ?2)
             ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            params![key, value],
        )?;
        Ok(())
    }

    /// All edges whose endpoints are both nodes of `project`. Used by community
    /// detection to build the project's adjacency without an N+1 neighbors() scan.
    pub fn edges_for_project(&self, project: &str) -> rusqlite::Result<Vec<Edge>> {
        let mut stmt = self.conn.prepare(
            "SELECT e.src, e.dst, e.kind, e.weight
             FROM edges e
             JOIN nodes s ON s.id = e.src
             JOIN nodes d ON d.id = e.dst
             WHERE s.project = ?1 AND d.project = ?1",
        )?;
        let rows = stmt
            .query_map(params![project], |row| {
                Ok(Edge {
                    src: row.get(0)?,
                    dst: row.get(1)?,
                    kind: EdgeKind::from_str(&row.get::<_, String>(2)?),
                    weight: row.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Every node in the DB, any project. The whole-brain counterpart to
    /// `nodes_for_project` (Task 6.1's `map_graph project: None` view). A
    /// full table scan — whole-brain callers are expected to be rare next
    /// to per-project queries, so this trades a bit of scan cost for not
    /// needing an N-query fan-out over `list_projects()`.
    pub fn all_nodes(&self) -> rusqlite::Result<Vec<Node>> {
        let mut stmt = self.conn.prepare(&format!("SELECT {NODE_COLS} FROM nodes"))?;
        let rows = stmt
            .query_map([], row_to_node)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Every edge in the DB, any project. The whole-brain counterpart to
    /// `edges_for_project`, used the same way by `map_graph`.
    pub fn all_edges(&self) -> rusqlite::Result<Vec<Edge>> {
        let mut stmt = self
            .conn
            .prepare("SELECT src, dst, kind, weight FROM edges")?;
        let rows = stmt
            .query_map([], |row| {
                Ok(Edge {
                    src: row.get(0)?,
                    dst: row.get(1)?,
                    kind: EdgeKind::from_str(&row.get::<_, String>(2)?),
                    weight: row.get(3)?,
                })
            })?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    // --- Task 7.1: review-mode gate (`pending_notes`) ----------------------

    /// Marks `node_id` as awaiting review — called by `Memory::
    /// write_note_with_status` when the `review_memory` setting is on.
    /// Idempotent (a re-drain of the same session can't produce a duplicate
    /// row).
    pub fn mark_pending(&self, node_id: &str, project: &str) -> rusqlite::Result<()> {
        self.conn.execute(
            "INSERT INTO pending_notes (node_id, project, created) VALUES (?1, ?2, ?3)
             ON CONFLICT(node_id) DO UPDATE SET created=excluded.created",
            params![node_id, project, now_ts()],
        )?;
        Ok(())
    }

    /// Whether `node_id` is currently awaiting review.
    pub fn is_pending(&self, node_id: &str) -> rusqlite::Result<bool> {
        let found: Option<String> = self
            .conn
            .query_row(
                "SELECT node_id FROM pending_notes WHERE node_id = ?1",
                params![node_id],
                |r| r.get(0),
            )
            .optional()?;
        Ok(found.is_some())
    }

    /// Every pending note, optionally scoped to one project, newest first —
    /// the review-panel list. Joins `nodes` for `title`/`path` so the UI
    /// doesn't need a second round trip per row.
    pub fn pending_notes(&self, project: Option<&str>) -> rusqlite::Result<Vec<PendingNote>> {
        let mut stmt = self.conn.prepare(
            "SELECT p.node_id, p.project, n.label, n.path, p.created
             FROM pending_notes p JOIN nodes n ON n.id = p.node_id
             WHERE (?1 IS NULL OR p.project = ?1)
             ORDER BY p.created DESC",
        )?;
        let rows = stmt
            .query_map(params![project], row_to_pending_note)?
            .collect::<Result<Vec<_>, _>>()?;
        Ok(rows)
    }

    /// Approves a pending note: removes it from `pending_notes`, which is
    /// the whole visibility gate (`search`/`get_context` immediately stop
    /// hiding it). The node and its `.md` file are untouched — approving
    /// doesn't rewrite content, only lifts the review hold. Returns `false`
    /// if `node_id` wasn't pending (nothing to do, not an error — e.g. a
    /// stale UI click after someone else already approved it).
    pub fn approve_pending(&self, node_id: &str) -> rusqlite::Result<bool> {
        let changed = self
            .conn
            .execute("DELETE FROM pending_notes WHERE node_id = ?1", params![node_id])?;
        Ok(changed > 0)
    }

    /// Discards a pending note: deletes the node, its FTS row, every edge
    /// touching it (e.g. the `Touched` edges to files it referenced), and
    /// its `pending_notes` row. Returns the deleted `Node` (so the caller —
    /// `feedback.rs`'s Tauri command — can also remove its `.md` file from
    /// disk; `Store` itself never touches the filesystem) or `None` if
    /// `node_id` wasn't pending.
    pub fn discard_pending(&self, node_id: &str) -> rusqlite::Result<Option<Node>> {
        if !self.is_pending(node_id)? {
            return Ok(None);
        }
        let node = self.get_node(node_id)?;
        self.conn.execute(
            "DELETE FROM edges WHERE src = ?1 OR dst = ?1",
            params![node_id],
        )?;
        self.conn
            .execute("DELETE FROM nodes_fts WHERE id = ?1", params![node_id])?;
        self.conn
            .execute("DELETE FROM nodes WHERE id = ?1", params![node_id])?;
        self.conn
            .execute("DELETE FROM pending_notes WHERE node_id = ?1", params![node_id])?;
        Ok(node)
    }
}
