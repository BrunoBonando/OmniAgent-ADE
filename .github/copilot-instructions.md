# GitHub Copilot instructions — OmniAgent-ADE

Purpose: provide Copilot CLI and future AI sessions repository-specific guidance for building, testing, running, and reasoning about this project.

---

## 1) Build, test, and lint (how to run)

Rust workspace (root)
- Install toolchain: `rustup` (ensure `~/.cargo/bin` on PATH).
- Build workspace: `cargo build --workspace`
- Build a single crate: `cd <crate> && cargo build`
- Run all tests: `cargo test --workspace`
- Run tests for a single crate: `cargo test -p <crate-name>` (e.g. `-p brain-ingest`)
- Run a single test by name: `cargo test -p <crate-name> -t "test_name_pattern"`
- Run mcp-server contract tests after protocol changes: `cargo test -p mcp-server`
- Format: `cargo fmt --all`
- Lint: `cargo clippy --all-targets --all-features`

Frontend (ui/)
- Install deps: `npm --prefix ui install`
- Dev server: `npm --prefix ui run dev`  (or `cd ui && npm install && npm run dev`)
- Build: `npm --prefix ui run build`
- Tests (Vitest): `npm --prefix ui run test`
- Run a single Vitest by name: `npm --prefix ui run test -- -t "test name"` or `npx vitest -t "test name" --run` (from repo root)
- Preview: `npm --prefix ui run preview`

Tauri (desktop shell)
- Dev (from repo root):
  `cd src-tauri && ../ui/node_modules/.bin/tauri dev`
- Build packaged app:
  `cd src-tauri && ../ui/node_modules/.bin/tauri build`

Notes:
- Tauri dev/build must be executed from `src-tauri/` because `tauri.conf.json` and `beforeBuildCommand` expect the repo layout.
- The Tauri build expects the `omniagent-mcp` binary to be available and copied into app resources during packaging.
- Many commands assume `cargo` and `node` are on PATH; non-login shells may omit `~/.cargo/bin`.

---

## 2) High-level architecture (big picture)

- Monorepo: Rust/Cargo workspace + TypeScript React UI wrapped by Tauri:
  - `crates/brain-core` — SQLite + FTS5 storage and retrieval
  - `crates/brain-ingest` — repository walker, tree-sitter parsing, ingestion, enrichment
  - `crates/mcp-server` — frozen MCP contract, stdio/local server component and contract tests
  - `src-tauri` — Tauri Rust core (PTY sessions, session manager, app wiring)
  - `ui/` — React + TypeScript + Vite frontend (brain map, terminals, sidebar)
- Runtime: Tauri app (UI + Rust core), a graph daemon/ingest process, and an MCP server process; they share retrieval crates and storage layers.
- Storage: SQLite "brain" DB (rebuildable) + durable Markdown memory under:
  `~/Library/Application Support/OmniAgent-ADE/brain/` — override with `OMNIAGENT_ADE_DATA_DIR`.

See `docs/DESIGN.md` and `docs/PLAN.md` for architecture and product principles.

---

## 3) Key repository conventions and patterns

- Cargo workspace: root `Cargo.toml` lists members; prefer workspace-level builds/tests for cross-crate changes.
- Packaging rule: changes that affect releases should end with a packaged app build (`target/release/bundle/*.app` or `.dmg`).
- MCP contract: the MCP server protocol is frozen for v1. Changing public MCP shapes (tools/requests) requires updating integrations and running `crates/mcp-server` contract tests.
- Commit trailer: When creating commits for repository changes, include this trailer unless explicitly requested not to:
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`
- Memory is authoritative as Markdown. The SQLite brain DB is rebuildable from source + Markdown; prefer writing durable notes under `brain/<project>/` rather than treating DB rows as canonical writable surface.
- Transcripts & redaction: transcripts are persisted; secret-pattern redaction runs before writing memory. Be cautious when modifying transcript or memory-writing code paths.
- Tests & fixtures: `fixtures/sample-project/` is the golden repo for ingestion tests.
- Watcher behavior: file watching uses FSEvents on macOS with debounced incremental re-ingest — large repo changes must be validated for incremental correctness.
- Session IDs: stable, name-based UUIDv5 derivation; sessions map to persistent conversation IDs across restarts.

---

## 4) Useful entry points for Copilot suggestions

- `README.md` — quick start, data dir, high-level commands
- `docs/DESIGN.md` — architecture and product constraints (read before large changes)
- `docs/PLAN.md` — phased implementation notes and rough edges
- `crates/*` and `src-tauri/*` — core APIs: retrieval, MCP, session management
- `ui/` — Vite+React entry points (brain-map, terminal panes)
- `fixtures/sample-project/` — golden repo for ingestion tests

---

Keep changes minimal and prefer explaining intent when suggesting API/contract alterations (MCP, brain storage, ingestion pipeline). When in doubt, reference `docs/DESIGN.md`.

Note on file authority and one-shot edits:
- By default, `.github/copilot-instructions.md` is the authoritative source. The local sync script regenerates agent-specific files from it.
- To promote an agent-specific file as authoritative (for example, after a direct update to `CLAUDE.md`), run:

  `./scripts/sync-instructions.sh CLAUDE.md`

  This will propagate CLAUDE.md's content into the other agent files and update `.github/copilot-instructions.md` so everything stays in sync.


---

Summary of what this file provides:
- Consolidated build/test/lint commands including single-test commands
- High-level architecture overview and runtime processes
- Repository-specific conventions (MCP contract, commit trailer, memory rules)

If you want adjustments (more detail for UI tests, CI hooks, or adding MCP server configs), say which and a branch/PR can be used for review.
