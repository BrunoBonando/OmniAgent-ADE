# OmniAgent

A local-first macOS Agentic Development Environment: parallel agent-CLI terminal sessions grouped per project, all connected to one fully local knowledge graph with a navigable brain map. See [`docs/DESIGN.md`](docs/DESIGN.md) for the full spec and [`docs/PLAN.md`](docs/PLAN.md) for the phased build plan this repo is being built against.

**Status: v0.1.0 — v1 complete, dogfood build.** All eight phases of `docs/PLAN.md` are implemented: local brain store + ingestion, the frozen MCP server, the terminal workspace, the WebGL brain map, the session feedback loop, and first-run onboarding. See that file's own "Self-review notes" and the Phase 8 commit for the known rough edges before wider distribution (packaged-app PATH resolution for `claude`/`codex`, no code signing/notarization yet).

## Layout

```
crates/brain-core/    # SQLite + FTS5 store, Markdown memory, redaction
crates/brain-ingest/  # walker, tree-sitter parsing, git mining, communities, CLI + watcher
crates/mcp-server/    # omniagent-mcp — the frozen MCP tool contract over stdio
crates/omniagent-pty-daemon/  # persistent PTY daemon the app talks to over a local socket
macos/                # the native macOS app (OmniAgent.xcodeproj: AppKit/SwiftUI/SwiftTerm)
fixtures/             # golden test fixture repo used by brain-ingest tests
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

# Rust workspace tests (brain, ingest, MCP server, PTY daemon)
cargo test --workspace

# Native app tests / Debug build (Xcode only)
./macos/build.sh test
./macos/build.sh build
```

## Build

```bash
./scripts/rebuild-app.sh              # build → sign → notarize → DMG → install to /Applications
./scripts/rebuild-app.sh --no-notarize
```

**Standing rule (Bruno, 2026-07-26): every code change ends with a fresh build** — "always generate a new app when coding the omniagent-ade". A green test suite he can't launch isn't a shipped change, so the packaged app is the deliverable, not an optional extra step. (`cargo` must be on `PATH` — the universal build embeds the daemon binary, so it needs the Rust workspace.)

The legacy Tauri/React app that preceded the native app was removed from the tree on 2026-08-30; see `docs/plans/native-macos-migration.md` for the history.

## macOS / Xcode major-upgrade sanity check

After upgrading macOS or Xcode, run:

```bash
./scripts/macos-post-upgrade-check.sh
```

On Xcode 27+, this script also verifies the Metal component SwiftTerm needs. If missing, install it once with:

```bash
xcodebuild -downloadComponent MetalToolchain
```
