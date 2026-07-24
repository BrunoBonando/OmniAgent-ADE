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
        let fts_query = format!("{}*", query.replace('"', ""));
        let mut stmt = self.conn.prepare(&format!(
            "SELECT {cols} FROM nodes_fts f
             JOIN nodes n ON n.id = f.id
             WHERE nodes_fts MATCH ?1
               AND (?2 IS NULL OR n.project = ?2)
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
}
