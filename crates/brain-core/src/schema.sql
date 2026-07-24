CREATE TABLE IF NOT EXISTS nodes (
    id       TEXT PRIMARY KEY,
    kind     TEXT NOT NULL,
    project  TEXT NOT NULL,
    label    TEXT NOT NULL,
    path     TEXT,
    summary  TEXT,
    origin   TEXT NOT NULL,
    updated  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS edges (
    src    TEXT NOT NULL,
    dst    TEXT NOT NULL,
    kind   TEXT NOT NULL,
    weight REAL NOT NULL DEFAULT 1.0,
    PRIMARY KEY (src, dst, kind)
);

CREATE INDEX IF NOT EXISTS idx_edges_src ON edges(src);
CREATE INDEX IF NOT EXISTS idx_edges_dst ON edges(dst);
CREATE INDEX IF NOT EXISTS idx_nodes_project ON nodes(project);
CREATE INDEX IF NOT EXISTS idx_nodes_kind ON nodes(kind);

-- Standalone (non-external-content) FTS5 table: Store::upsert_node/delete_*
-- keep this in sync explicitly (delete-then-insert) rather than via SQL
-- triggers, so the sync logic is one visible, testable place in Rust.
CREATE VIRTUAL TABLE IF NOT EXISTS nodes_fts USING fts5(
    id UNINDEXED,
    label,
    summary
);

CREATE TABLE IF NOT EXISTS enrich_queue (
    id      INTEGER PRIMARY KEY AUTOINCREMENT,
    kind    TEXT NOT NULL,
    payload TEXT NOT NULL,
    status  TEXT NOT NULL DEFAULT 'pending',
    created INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT NOT NULL
);
