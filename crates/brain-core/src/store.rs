use rusqlite::{params, Connection, OptionalExtension};
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

pub struct Store {
    pub(crate) conn: Connection,
    /// Where this store was opened from, and which on-disk file it got.
    /// `None` for [`Store::open_in_memory`] — a `:memory:` database has no
    /// file for anyone to replace.
    origin: Option<StoreOrigin>,
}

/// The `data_dir` a [`Store`] was opened from plus the identity of the
/// `brain.db` inode it actually opened — what [`Store::was_replaced`]
/// compares against.
struct StoreOrigin {
    data_dir: PathBuf,
    identity: FileIdentity,
}

/// A POSIX file identity: the `(st_dev, st_ino)` pair, which is what
/// actually distinguishes "the same file" from "a different file that
/// happens to live at the same path". Path equality is not enough here —
/// "Rebuild brain" `unlink`s `brain.db` and creates a *new* file at the
/// identical path, so only the inode changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct FileIdentity {
    dev: u64,
    ino: u64,
}

fn file_identity(path: &Path) -> Option<FileIdentity> {
    std::fs::metadata(path).ok().map(|meta| FileIdentity {
        dev: meta.dev(),
        ino: meta.ino(),
    })
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

/// Bug fix: `enqueue_job`'s original SELECT-then-INSERT dedup check was a
/// check-then-act race across separate connections to the same on-disk
/// `brain.db` — two connections (e.g. a bulk re-ingest and a per-project
/// re-ingest for the same project, both realistic given `open`'s
/// multi-connection-per-`brain.db` architecture) could each see "no
/// pending job" before either commits its INSERT, producing duplicate
/// enrichment jobs (`dedup_race_tests::
/// concurrent_enqueue_job_across_connections_never_duplicates` reproduces
/// this against the pre-fix code).
///
/// A partial `UNIQUE` index — unique on `(kind, payload)` only among rows
/// still `status = 'pending'` — turns the second connection's INSERT into
/// an atomic no-op enforced by SQLite itself (via `INSERT ... ON CONFLICT
/// ... DO NOTHING` in `enqueue_job`), which no read-then-write race in
/// application code can defeat: unlike wrapping the existing
/// SELECT-then-INSERT in `Store::with_transaction` (a plain deferred
/// `BEGIN`), a real UNIQUE constraint doesn't depend on both connections'
/// reads happening to serialize with their writes — the constraint is
/// checked by the same atomic INSERT statement that would create the
/// duplicate, not by a separate, racing SELECT.
///
/// This lives here (in `store.rs`, executed at `open` time) rather than in
/// `schema.sql` only because `enqueue_job`'s dedup is `Store`'s own
/// invariant to own and test end-to-end in one file; the index itself is
/// ordinary schema and behaves identically either way.
///
/// Deletes any pre-existing duplicate pending rows first (keeping the
/// lowest/oldest id per `kind`+`payload`), so opening an existing
/// `brain.db` that already accumulated duplicates from this very bug
/// doesn't fail with a `UNIQUE` constraint violation while building the
/// index.
fn ensure_enrich_queue_pending_dedup_index(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(
        "DELETE FROM enrich_queue
           WHERE status = 'pending'
             AND id NOT IN (
               SELECT MIN(id) FROM enrich_queue
               WHERE status = 'pending'
               GROUP BY kind, payload
             );
         CREATE UNIQUE INDEX IF NOT EXISTS idx_enrich_queue_pending_dedup
           ON enrich_queue(kind, payload) WHERE status = 'pending';",
    )
}

/// Settings-table key for a project's custom display-name override, set via
/// the app's `rename_project` command (`src-tauri/src/roots.rs`) and the
/// daemon's `RootsRenameProject` (both through
/// `brain_ingest::roots::rename_project`), and applied as a read-time
/// overlay by `mcp_server::tools::list_projects` — so every caller sees a
/// renamed project's real label: the app's sidebar via `brain_query`, the
/// native app via the daemon, AND any external MCP client mounting this same
/// store (DESIGN.md 3.4: "one shared retrieval API ... used by all three").
///
/// Lives here in `brain-core`, the crate every one of those sits on, rather
/// than in `mcp-server` where it started: `brain-ingest` is a *lower* layer
/// than the frozen MCP contract and must not depend on it for a string
/// helper (final whole-branch review, Minor #6). `mcp_server::tools`
/// re-exports this name so no existing caller path had to change.
///
/// Lives in the separate `settings` table rather than the node's own
/// `label` column on purpose: `brain_ingest::ingest_project` unconditionally
/// re-upserts a `Project` node's `label` back to its id on every
/// re-ingest/watch-triggered pass (see that function's own doc comment) —
/// a plain node-label edit would silently revert on the next file change,
/// "re-check now", or "Rebuild brain". The settings table isn't touched by
/// ingestion at all (and "Rebuild brain" already explicitly preserves it
/// across a rebuild), so storing the override there and applying it as a
/// read-time overlay is the only way a rename actually sticks.
pub fn project_label_key(project_id: &str) -> String {
    format!("project_label:{project_id}")
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
    ///
    /// Sets three connection-level pragmas *every* open, not just on first
    /// creation, because the app runs several independent connections
    /// against the same on-disk file concurrently (`BrainState`'s
    /// UI-facing connection, the ingestion background thread's own
    /// connection, and the 60s enrichment drain loop's own connection — see
    /// `roots.rs`/`lib.rs`) and `synchronous`/`busy_timeout` are
    /// per-connection, not persisted in the database file:
    ///
    /// - `journal_mode = WAL`: SQLite's default rollback-journal mode takes
    ///   an exclusive lock for the brief moment a writer commits, which
    ///   blocks every other connection's reads *and* writes until it
    ///   releases — with thousands of individual commits during a project
    ///   ingest, that adds up to noticeable UI stalls (empirically
    ///   reproduced in `examples/concurrency_repro.rs`: read latency spikes
    ///   from a ~1.5ms baseline to 300ms-1s+ while a concurrent write loop
    ///   runs against the pre-WAL code). WAL lets readers keep reading a
    ///   consistent snapshot while a writer appends to the WAL file, so
    ///   concurrent reads no longer queue up behind commits. This *is*
    ///   persisted in the db file, so setting it redundantly on reopen is a
    ///   cheap no-op, not a correctness requirement — it's set every time
    ///   for clarity and because a pre-existing non-WAL `brain.db` from
    ///   before this fix needs it set at least once per file to switch over.
    /// - `busy_timeout = 5000`: rusqlite does not set a default (SQLite's
    ///   own default is 0 — instant `SQLITE_BUSY` on any residual lock
    ///   conflict, e.g. WAL's own brief writer-vs-writer exclusion). 5s
    ///   gives a real conflict time to clear instead of surfacing as a
    ///   user-visible error.
    /// - `synchronous = NORMAL`: the standard pairing with WAL (skips an
    ///   fsync on every commit, only fsyncing at WAL checkpoints), safe here
    ///   because `brain.db` is explicitly a rebuildable derived cache, not
    ///   the source of truth — DESIGN.md's "the whole DB is rebuildable [by
    ///   re-ingesting]" (see `roots.rs`'s `rebuild_brain`/`rebuild_store`).
    ///   The only durability this trades away is surviving an OS-level
    ///   power loss / hard crash between commits (an application crash
    ///   alone is still safe: WAL + NORMAL is crash-safe, just not
    ///   power-loss-safe) — for a local dev tool's cache-like graph DB, a
    ///   `brain rebuild`/re-ingest after a rare power-loss event is an
    ///   acceptable tradeoff for the throughput win on every ordinary
    ///   commit.
    pub fn open(data_dir: &Path) -> rusqlite::Result<Store> {
        std::fs::create_dir_all(data_dir).expect("create data dir");
        let path = data_dir.join("brain.db");
        let conn = Connection::open(&path)?;
        conn.execute_batch(
            "PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; PRAGMA busy_timeout=5000;",
        )?;
        conn.execute_batch(include_str!("schema.sql"))?;
        ensure_enrich_queue_pending_dedup_index(&conn)?;
        // Recorded *after* the connection is open and the schema exists, so
        // the identity is the file this handle is actually talking to.
        let origin = file_identity(&path).map(|identity| StoreOrigin {
            data_dir: data_dir.to_path_buf(),
            identity,
        });
        Ok(Store { conn, origin })
    }

    /// True when the `brain.db` this handle opened is no longer the file at
    /// the path it was opened from — i.e. some other process (or an earlier
    /// call in this one) ran "Rebuild brain".
    ///
    /// `brain_ingest::roots::rebuild_store` deletes `brain.db` and creates a
    /// fresh file at the same path. `remove_file` is a POSIX `unlink`: every
    /// already-open connection keeps working perfectly against the old, now
    /// *nameless* inode, silently. Before this branch that was harmless —
    /// only one process held a long-lived `Store` and it swapped its own
    /// handle as part of the rebuild. `omniagent-pty-daemon` is now a second
    /// long-lived holder against the same file, so a rebuild triggered from
    /// either app would leave the *other* one writing `layout`/
    /// `notifications`/`usage_analytics_v1` rows into an orphaned inode that
    /// nothing will ever read again and that disappears when the handle
    /// closes. Hence this check, and [`Self::reopen_if_replaced`].
    ///
    /// A path that has no file at all right now also counts as replaced: the
    /// unlink has happened and this handle is already orphaned, whether or
    /// not the rebuilder has re-created the file yet.
    ///
    /// Always `false` for an in-memory store (nothing on disk to replace).
    pub fn was_replaced(&self) -> bool {
        let Some(origin) = &self.origin else {
            return false;
        };
        match file_identity(&origin.data_dir.join("brain.db")) {
            Some(current) => current != origin.identity,
            None => true,
        }
    }

    /// Re-opens this store against the file currently living at its
    /// `data_dir` when [`Self::was_replaced`] says the old one is gone,
    /// replacing this handle in place. Returns whether a reopen happened.
    ///
    /// Callers hold `Store` behind a mutex (`src-tauri`'s `BrainState`,
    /// `omniagent-pty-daemon`'s `DaemonServer::settings`); calling this while
    /// holding that lock, before each operation, is what makes a cross-process
    /// rebuild transparent instead of silently lossy. Cheap enough to do per
    /// operation: one `stat(2)` of a path that is essentially always in the
    /// kernel's cache, and no reopen at all in the overwhelmingly common case.
    pub fn reopen_if_replaced(&mut self) -> rusqlite::Result<bool> {
        if !self.was_replaced() {
            return Ok(false);
        }
        let Some(data_dir) = self.origin.as_ref().map(|o| o.data_dir.clone()) else {
            return Ok(false);
        };
        *self = Store::open(&data_dir)?;
        Ok(true)
    }

    /// In-memory store, for tests only.
    ///
    /// No WAL pragma here: `:memory:` databases have no shared file to
    /// write a WAL against (SQLite treats the pragma as a silent no-op,
    /// reporting journal_mode "memory" regardless), and each `:memory:`
    /// connection is its own private, unshared database — there is no
    /// concurrent-access scenario for `open_in_memory` to protect against,
    /// unlike `open`.
    pub fn open_in_memory() -> rusqlite::Result<Store> {
        let conn = Connection::open_in_memory()?;
        conn.execute_batch(include_str!("schema.sql"))?;
        ensure_enrich_queue_pending_dedup_index(&conn)?;
        Ok(Store { conn, origin: None })
    }

    /// Runs `f` inside a single explicit `BEGIN`/`COMMIT` transaction
    /// instead of letting each statement `f` issues autocommit on its own —
    /// additive batching support for callers doing many writes in a loop
    /// (`brain-ingest::ingest_project`'s per-file/per-entity/per-edge
    /// upserts), without changing `upsert_node`/`upsert_edge`'s own
    /// signatures or behavior for one-off callers (`mcp-server`,
    /// `feedback.rs`, `memory.rs` all keep calling them individually,
    /// each auto-committing exactly as before). Rolls back and propagates
    /// `f`'s error if it returns `Err`, so a failure partway through a
    /// batch (e.g. mid-project-ingest) can't leave a half-written project
    /// in the graph. Not reentrant — calling this from inside another
    /// `with_transaction` (or any other open transaction on the same
    /// connection) will error on the nested `BEGIN`; every current caller
    /// only ever does one top-level call per `Store`/thread.
    pub fn with_transaction<F, T, E>(&self, f: F) -> Result<T, E>
    where
        F: FnOnce(&Store) -> Result<T, E>,
        E: From<rusqlite::Error>,
    {
        self.conn.execute_batch("BEGIN")?;
        match f(self) {
            Ok(v) => {
                self.conn.execute_batch("COMMIT")?;
                Ok(v)
            }
            Err(e) => {
                // Best-effort rollback: if the connection is in a state
                // where even ROLLBACK fails, propagate f's original error
                // rather than the rollback failure — that's the actionable
                // one.
                let _ = self.conn.execute_batch("ROLLBACK");
                Err(e)
            }
        }
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
    ///
    /// This dedup is enforced atomically by the partial `UNIQUE` index built
    /// in `ensure_enrich_queue_pending_dedup_index` (on `(kind, payload)`
    /// among `status = 'pending'` rows), not by a separate check-then-act
    /// SELECT: `INSERT ... ON CONFLICT ... DO NOTHING` either inserts the
    /// new row or — atomically, as part of the same statement, so no other
    /// connection can observe or race a gap between "check" and "act" — a
    /// no-op when a pending row for this `kind`+`payload` already exists.
    /// That's what makes this safe across the several separate connections
    /// this app opens against the same on-disk `brain.db` (see `open`'s doc
    /// comment), unlike the SELECT-then-INSERT this replaced, which two
    /// connections could both pass before either committed its INSERT.
    pub fn enqueue_job(&self, kind: &str, payload: &str) -> rusqlite::Result<i64> {
        let inserted = self.conn.execute(
            "INSERT INTO enrich_queue (kind, payload, status, created)
             VALUES (?1, ?2, 'pending', ?3)
             ON CONFLICT (kind, payload) WHERE status = 'pending' DO NOTHING",
            params![kind, payload, now_ts()],
        )?;
        if inserted > 0 {
            return Ok(self.conn.last_insert_rowid());
        }
        // The INSERT above was a no-op: a pending job for this kind+payload
        // already exists (ours or a concurrent connection's that won the
        // race). Look its id up instead of returning a phantom rowid.
        self.conn.query_row(
            "SELECT id FROM enrich_queue WHERE kind = ?1 AND payload = ?2 AND status = 'pending'",
            params![kind, payload],
            |r| r.get(0),
        )
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

    /// Count of jobs currently `pending` (Task 8.1's map-pane "enrichment
    /// queued (N)" badge) — a plain `COUNT(*)` rather than `pending_jobs(..)
    /// .len()` so the degradation badge doesn't pull every row's `payload`
    /// text off disk just to size a number.
    pub fn pending_job_count(&self) -> rusqlite::Result<usize> {
        self.conn.query_row(
            "SELECT COUNT(*) FROM enrich_queue WHERE status = 'pending'",
            [],
            |r| r.get(0),
        )
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

    /// Every row in the `settings` table. Task 8.1's "Rebuild brain" reads
    /// this before wiping `brain.db`: project roots, per-project pause
    /// flags, `review_memory`, the persisted tab layout, and per-project
    /// default engines are lightweight user config, not derived graph data
    /// (DESIGN.md's "the whole DB is rebuildable" rule is about the
    /// *extracted* graph, not the user's settings) — capturing them here
    /// lets the caller restore every setting into the freshly recreated
    /// database afterward instead of silently forgetting them.
    pub fn all_settings(&self) -> rusqlite::Result<Vec<(String, String)>> {
        let mut stmt = self.conn.prepare("SELECT key, value FROM settings")?;
        let rows = stmt
            .query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?
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

    /// Every node in the DB, any project. The whole-brain counterpart to
    /// `nodes_for_project` (Task 6.1's `map_graph project: None` view). A
    /// full table scan — whole-brain callers are expected to be rare next
    /// to per-project queries, so this trades a bit of scan cost for not
    /// needing an N-query fan-out over `list_projects()`.
    pub fn all_nodes(&self) -> rusqlite::Result<Vec<Node>> {
        let mut stmt = self
            .conn
            .prepare(&format!("SELECT {NODE_COLS} FROM nodes"))?;
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
        let changed = self.conn.execute(
            "DELETE FROM pending_notes WHERE node_id = ?1",
            params![node_id],
        )?;
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
        self.conn.execute(
            "DELETE FROM pending_notes WHERE node_id = ?1",
            params![node_id],
        )?;
        Ok(node)
    }
}

#[cfg(test)]
mod pragma_tests {
    // In-crate (not `tests/`) so these can reach `Store::conn`, which is
    // `pub(crate)` — an external integration-test crate can't see it.
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn open_sets_wal_journal_mode_and_it_persists_across_reopen() {
        let dir = tempdir().unwrap();
        let mode: String = {
            let store = Store::open(dir.path()).unwrap();
            store
                .conn
                .query_row("PRAGMA journal_mode", [], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(mode.to_lowercase(), "wal");

        // WAL is persisted in the database file itself, so a fresh
        // connection to the same file reports WAL even though `open`
        // re-issues the pragma redundantly on every call.
        let mode_after_reopen: String = {
            let store = Store::open(dir.path()).unwrap();
            store
                .conn
                .query_row("PRAGMA journal_mode", [], |r| r.get(0))
                .unwrap()
        };
        assert_eq!(mode_after_reopen.to_lowercase(), "wal");
    }

    #[test]
    fn open_sets_busy_timeout_and_synchronous_normal() {
        let dir = tempdir().unwrap();
        let store = Store::open(dir.path()).unwrap();

        let busy_timeout: i64 = store
            .conn
            .query_row("PRAGMA busy_timeout", [], |r| r.get(0))
            .unwrap();
        assert_eq!(busy_timeout, 5000);

        // synchronous: 0=OFF, 1=NORMAL, 2=FULL, 3=EXTRA.
        let synchronous: i64 = store
            .conn
            .query_row("PRAGMA synchronous", [], |r| r.get(0))
            .unwrap();
        assert_eq!(synchronous, 1, "expected NORMAL (1)");
    }

    #[test]
    fn open_in_memory_is_unaffected_by_the_wal_pragma() {
        // :memory: databases can't use WAL (no shared file to write it
        // against) and are never accessed by more than one connection, so
        // open_in_memory deliberately does not set journal_mode=WAL. This
        // documents that it still works and reports SQLite's own "memory"
        // mode, not "wal".
        let store = Store::open_in_memory().unwrap();
        let mode: String = store
            .conn
            .query_row("PRAGMA journal_mode", [], |r| r.get(0))
            .unwrap();
        assert_eq!(mode.to_lowercase(), "memory");
    }
}

/// "Rebuild brain" replaces `brain.db` under every *other* long-lived handle
/// in the machine. These pin down that a handle notices and recovers rather
/// than writing into an orphaned inode.
#[cfg(test)]
mod replacement_tests {
    use super::*;
    use tempfile::tempdir;

    /// Byte-for-byte what `brain_ingest::roots::rebuild_store` does to the
    /// directory (unlink `brain.db` + its WAL/SHM/journal siblings, then open
    /// a fresh file at the same path) — reproduced here rather than depended
    /// on, because `brain-core` sits *below* `brain-ingest` and must not
    /// import it.
    fn rebuild_like_the_other_process(data_dir: &Path) -> Store {
        for suffix in ["", "-wal", "-shm", "-journal"] {
            let mut name = data_dir.join("brain.db").into_os_string();
            name.push(suffix);
            let _ = std::fs::remove_file(PathBuf::from(name));
        }
        Store::open(data_dir).unwrap()
    }

    #[test]
    fn a_replaced_brain_db_is_detected_and_reopened_so_later_writes_are_not_lost() {
        let dir = tempdir().unwrap();
        let mut store = Store::open(dir.path()).unwrap();
        store.set_setting("layout", "before").unwrap();
        assert!(!store.was_replaced(), "nothing has touched the file yet");
        assert!(!store.reopen_if_replaced().unwrap());

        // The other process (the native app or the Tauri app) rebuilds.
        let other = rebuild_like_the_other_process(dir.path());
        other.set_setting("notifications", "written-by-the-rebuilder").unwrap();
        drop(other);

        assert!(store.was_replaced(), "the inode at brain.db changed");
        assert!(store.reopen_if_replaced().unwrap(), "and we reopened it");
        assert!(!store.was_replaced(), "the new identity is now recorded");

        store.set_setting("layout", "after").unwrap();

        // Read through a third, independent handle: the point is that the
        // write landed in the file that actually lives at the path, not in a
        // nameless inode only this handle can see.
        let verify = Store::open(dir.path()).unwrap();
        assert_eq!(verify.get_setting("layout").unwrap().as_deref(), Some("after"));
        assert_eq!(
            verify.get_setting("notifications").unwrap().as_deref(),
            Some("written-by-the-rebuilder"),
            "reopening must not clobber what the rebuilder wrote"
        );
    }

    #[test]
    fn without_the_reopen_a_write_after_a_rebuild_is_silently_lost() {
        // The bug this whole mechanism exists for, pinned down so the fix
        // cannot be quietly reverted: a handle that never checks keeps
        // writing to the unlinked inode and the file on disk never sees it.
        let dir = tempdir().unwrap();
        let stale = Store::open(dir.path()).unwrap();
        drop(rebuild_like_the_other_process(dir.path()));

        stale.set_setting("layout", "into-the-void").unwrap();
        assert_eq!(
            stale.get_setting("layout").unwrap().as_deref(),
            Some("into-the-void"),
            "the orphaned handle happily reads back its own write"
        );

        let verify = Store::open(dir.path()).unwrap();
        assert_eq!(
            verify.get_setting("layout").unwrap(),
            None,
            "but the file at the path never got it"
        );
    }

    #[test]
    fn a_brain_db_deleted_and_not_yet_recreated_also_counts_as_replaced() {
        let dir = tempdir().unwrap();
        let mut store = Store::open(dir.path()).unwrap();
        std::fs::remove_file(dir.path().join("brain.db")).unwrap();
        assert!(store.was_replaced());
        assert!(store.reopen_if_replaced().unwrap());
        assert!(dir.path().join("brain.db").exists());
    }

    #[test]
    fn an_in_memory_store_is_never_considered_replaced() {
        let mut store = Store::open_in_memory().unwrap();
        assert!(!store.was_replaced());
        assert!(!store.reopen_if_replaced().unwrap());
    }
}

#[cfg(test)]
mod dedup_race_tests {
    // Bug 2: `enqueue_job`'s SELECT-then-INSERT dedup was a check-then-act
    // race across separate connections to the same on-disk `brain.db`
    // (this app runs several concurrently — see `open`'s doc comment: the
    // UI connection, the ingestion background thread's connection, the
    // enrichment drain loop's connection — and a bulk re-ingest racing a
    // per-project re-ingest for the same project is realistic). This test
    // drives that race for real: two genuine `Store::open` connections
    // (not `:memory:` — an in-memory database is private and unshared per
    // connection, so it can never reproduce a *cross-connection* race) to
    // the same tempdir, synchronized with a `Barrier` so both threads reach
    // `enqueue_job` at (as close to) the same instant as possible, racing
    // to enqueue the identical (kind, payload) job. Repeated over many
    // rounds (each with a fresh payload, so a bad round can't be masked by
    // a later round's cleanup) to make a scheduling fluke that happens to
    // avoid the race exceedingly unlikely to hide a real bug.
    use super::*;
    use std::sync::{Arc, Barrier};
    use std::thread;
    use tempfile::tempdir;

    #[test]
    fn concurrent_enqueue_job_across_connections_never_duplicates() {
        let dir = tempdir().unwrap();

        for round in 0..25 {
            let kind = "summarize";
            let payload = format!("node-{round}");

            // Two genuine, separately-opened connections to the same
            // on-disk brain.db — opened up front (schema creation is not
            // the thing under test and racing two connections' `CREATE
            // TABLE IF NOT EXISTS`/FTS5 DDL against each other is its own,
            // unrelated source of transient `SQLITE_BUSY` contention). The
            // barrier below synchronizes only the `enqueue_job` call
            // itself, which is the actual check-then-act race this test
            // targets.
            let store_a = Store::open(dir.path()).unwrap();
            let store_b = Store::open(dir.path()).unwrap();
            let barrier = Arc::new(Barrier::new(2));

            let handles = [store_a, store_b].into_iter().map(|store| {
                let payload = payload.clone();
                let barrier = Arc::clone(&barrier);
                thread::spawn(move || {
                    barrier.wait();
                    store.enqueue_job(kind, &payload).unwrap()
                })
            });
            for h in handles.collect::<Vec<_>>() {
                h.join().unwrap();
            }

            let verify = Store::open(dir.path()).unwrap();
            let pending = verify.pending_jobs(1000).unwrap();
            let matching = pending
                .iter()
                .filter(|j| j.kind == kind && j.payload == payload)
                .count();
            assert_eq!(
                matching, 1,
                "round {round}: expected exactly 1 pending job for {kind}/{payload}, found {matching}"
            );
        }
    }
}
