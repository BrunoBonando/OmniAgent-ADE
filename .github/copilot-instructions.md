# GitHub Copilot instructions — OmniAgent-ADE

Purpose: give Copilot CLI and future AI sessions immediate, repository-specific guidance for building, testing, running, and reasoning about this project.

---

## 1) Build, test, and lint (how to run)

Rust workspace (root):
- Install toolchain: `rustup` (ensure `~/.cargo/bin` on PATH).
- Build workspace: `cargo build --workspace` (or `cargo build` in a crate dir).
- Run all tests: `cargo test --workspace`.
- Run tests for a single crate: `cargo test -p <crate-name>` (e.g. `-p brain-ingest`).
- Run a single test by name: `cargo test -p <crate-name> -t "test_name_pattern"` (use the test's substring).
- Format: `cargo fmt --all`.
- Lint: `cargo clippy --all-targets --all-features`.

Frontend (ui/):
- Install deps: `npm --prefix ui install`.
- Dev server: `npm --prefix ui run dev` (or `cd ui && npm install && npm run dev`).
- Build: `npm --prefix ui run build`.
- Tests (Vitest): `npm --prefix ui run test`.
- Run a single Vitest by name: `npm --prefix ui run test -- -t "test name"` or `npx vitest -t "test name" --run` from repo root.
- Preview: `npm --prefix ui run preview`.

Tauri (desktop shell):
- Dev (from repo root):
  `cd src-tauri && ../ui/node_modules/.bin/tauri dev`
- Build packaged app:
  `cd src-tauri && ../ui/node_modules/.bin/tauri build`

Notes:
- Many dev commands assume `cargo` and `node` are on PATH; non-login shells may omit `~/.cargo/bin`.
- UI tests use `vitest`; TypeScript typechecks are run during `npm run build`.

---

## 2) High-level architecture (big picture)

- Mono-repo Rust/Cargo workspace + a TypeScript React UI (Tauri wrapper):
  - crates/brain-core — SQLite + FTS5 storage and retrieval.
  - crates/brain-ingest — repository walker, tree-sitter parsing, ingestion, enrichment.
  - crates/mcp-server — the frozen MCP contract and stdio/local server component.
  - src-tauri — Tauri Rust core (PTY sessions, session manager, app wiring).
  - ui/ — React + TypeScript + Vite frontend (brain map, terminals, sidebar).
- Runtime processes: Tauri app (UI + Rust core), graph daemon/ingest (separate process), and an MCP server process. All share the same retrieval crate and storage.
- Storage: SQLite brain DB (rebuildable) + durable Markdown memory under
  `~/Library/Application Support/OmniAgent-ADE/brain/`. Override with `OMNIAGENT_ADE_DATA_DIR`.

Refer to docs/DESIGN.md and docs/PLAN.md for detailed architecture and product principles.

---

## 3) Key repository conventions and patterns (what Copilot should know)

- Cargo workspace: root Cargo.toml lists members; builds/tests should target the workspace when making cross-crate changes.
- Packaging rule: every code change is expected to end with a fresh build of the app (the packaged `.app`/`.dmg` under `target/release/bundle/`). CI and local checks should reproduce that build when validating release-affecting changes.
- MCP server contract is intentionally "frozen" for v1. Do not change public MCP shapes (tools/requests) without updating integrations and contract tests in crates/mcp-server.
- Memory is authoritative as Markdown. The SQLite DB is rebuildable from source + Markdown; prefer writing/reading durable notes in `brain/<project>/…` rather than treating DB rows as the canonical writable surface.
- Ingestion tests use `fixtures/sample-project/` as a golden repository. Use it for deterministic graph/ingest tests.
- Tauri dev/build must be executed from `src-tauri/` because `tauri.conf.json` and the `beforeBuildCommand` expect the repo layout; the Tauri build also relies on the bundled `omniagent-mcp` binary being copied into the app resources.
- Session IDs: stable, name-based UUIDv5 derivation — sessions map to persistent conversation IDs across restarts.
- Transcripts & redaction: transcripts are persisted; secret-pattern redaction runs before writing memory. Be cautious when changing transcript or memory-writing code paths.
- Watcher behavior: file watching is FSEvents (macOS) with debounced incremental re-ingest; large repo changes should be tested for incremental correctness.

---

## 4) Useful entry points for Copilot suggestions

- README.md (root) — quick start, data dir, high-level commands.
- docs/DESIGN.md — architecture and principles (must-read before large changes).
- docs/PLAN.md — phased implementation notes and known rough edges.
- crates/* and src-tauri/ — code-level APIs for retrieval, MCP, session management.
- ui/ — Vite+React entry points (brain-map, terminal panes).

---

Keep changes minimal and prefer explaining intent when suggesting API/contract alterations (MCP, brain storage, ingestion pipeline). When in doubt, reference docs/DESIGN.md for product-level constraints.
