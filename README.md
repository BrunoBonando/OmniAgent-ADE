# OmniAgent

A local-first macOS Agentic Development Environment: parallel agent-CLI terminal sessions grouped per project, all connected to one fully local knowledge graph with a navigable brain map. See [`docs/DESIGN.md`](docs/DESIGN.md) for the full spec and [`docs/PLAN.md`](docs/PLAN.md) for the phased build plan this repo is being built against.

**Status: v0.1.0 — v1 complete, dogfood build.** All eight phases of `docs/PLAN.md` are implemented: local brain store + ingestion, the frozen MCP server, the terminal workspace, the WebGL brain map, the session feedback loop, and first-run onboarding. See that file's own "Self-review notes" and the Phase 8 commit for the known rough edges before wider distribution (packaged-app PATH resolution for `claude`/`codex`, no code signing/notarization yet).

## Layout

```
crates/brain-core/    # SQLite + FTS5 store, Markdown memory, redaction
crates/brain-ingest/  # walker, tree-sitter parsing, git mining, communities, CLI + watcher
crates/mcp-server/    # omniagent-mcp — the frozen MCP tool contract over stdio
src-tauri/            # Tauri 2 desktop shell (Rust core: PTY sessions, commands, onboarding)
ui/                   # React 18 + TypeScript + Vite frontend
fixtures/              # golden test fixture repo used by brain-ingest tests
docs/                 # DESIGN.md, PLAN.md, visual reference (g-brain, logo)
```

## Data

Everything lives under `~/Library/Application Support/OmniAgent-ADE/` by default: `brain.db` (the derived, rebuildable graph — see the sidebar's "About" panel for "Rebuild brain"), `brain/<project>/*.md` (durable Markdown memory — never deleted by a rebuild), and `transcripts/` (per-session PTY logs). Override with `OMNIAGENT_ADE_DATA_DIR` (every crate honors it) — useful for a scratch/test data dir instead of your real one.

## First run

The app has no separate setup step. Launch it with no project roots configured yet and it asks, once, where your projects live (a native folder picker); everything under that folder gets walked, parsed, and linked into your local knowledge graph automatically — the brain map filling in live *is* the onboarding, no tutorial screens. Add more roots later, pause a project's ingestion, or force a from-scratch rebuild from the same panel/sidebar menu.

## Dev setup

```bash
# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Frontend deps
npm --prefix ui install

# Run the whole workspace's tests
cargo test --workspace
npm --prefix ui test

# Launch the desktop app in dev mode (tauri.conf.json lives in src-tauri/,
# so the CLI must run from there — it shells out to `npm --prefix ../ui`)
cd src-tauri && ../ui/node_modules/.bin/tauri dev
```

## Build

```bash
cd src-tauri && ../ui/node_modules/.bin/tauri build
```

**Standing rule (Bruno, 2026-07-26): every code change ends with a fresh build** — "always generate a new app when coding the omniagent-ade". A green test suite he can't launch isn't a shipped change, so the packaged app is the deliverable, not an optional extra step. (`cargo` must be on `PATH` — a non-login shell won't have `~/.cargo/bin` and the CLI fails with `failed to run 'cargo metadata'`.)

Produces an ad-hoc-signed `.app` / `.dmg` under **`target/release/bundle/`** at the repo root — this is a cargo *workspace*, so the shared target dir is not inside `src-tauri/` — fine for local dogfooding; real Developer-ID signing and notarization are explicitly deferred until a wider private beta ships (see `docs/PLAN.md`). The build's `beforeBuildCommand` also builds `omniagent-mcp` in release mode and `tauri.conf.json`'s `bundle.resources` copies it into `OmniAgent.app/Contents/Resources/omniagent-mcp`, so Claude sessions launched from the packaged app (not just `cargo tauri dev`) get the same zero-config MCP wiring (`src-tauri/src/sessions.rs`'s `resolve_mcp_server_binary` checks that exact path).
