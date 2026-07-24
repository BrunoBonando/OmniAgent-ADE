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

-- Phase 7 review-mode gate: a node id present here is a machine-generated
-- Memory note awaiting approval (`review_memory` setting = "true"). Its
-- presence — not a column on `nodes` — is the single source of truth for
-- "pending": Store::search() and get_context()'s memory-notes projection
-- both hide any node listed here until the row is removed (approve) or the
-- node itself is deleted alongside it (discard). A brand-new table rather
-- than an ALTER TABLE on `nodes` so opening an existing brain.db (Bruno's
-- real dogfood data dir, already past Phase 6) never needs a migration step
-- beyond the already-idempotent `CREATE TABLE IF NOT EXISTS`.
CREATE TABLE IF NOT EXISTS pending_notes (
    node_id TEXT PRIMARY KEY,
    project TEXT NOT NULL,
    created INTEGER NOT NULL
);
