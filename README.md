# OmniAgent

A local-first macOS Agentic Development Environment: parallel agent-CLI terminal sessions grouped per project, all connected to one fully local knowledge graph with a navigable brain map. See [`docs/DESIGN.md`](docs/DESIGN.md) for the full spec and [`docs/PLAN.md`](docs/PLAN.md) for the phased build plan this repo is being built against.

## Layout

```
crates/brain-core/    # SQLite + FTS5 store, Markdown memory, redaction
crates/brain-ingest/  # walker, tree-sitter parsing, git mining, communities, CLI + watcher
crates/mcp-server/    # omniagent-mcp — the frozen MCP tool contract over stdio
src-tauri/            # Tauri 2 desktop shell (Rust core: PTY sessions, commands)
ui/                   # React 18 + TypeScript + Vite frontend
fixtures/              # golden test fixture repo used by brain-ingest tests
docs/                 # DESIGN.md, PLAN.md, visual reference (g-brain, logo)
```

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

Produces a signed-for-local-dev `.app` / `.dmg` under `src-tauri/target/release/bundle/`.
