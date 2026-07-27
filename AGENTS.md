<!-- GENERATED from .github/copilot-instructions.md — do not edit directly. Update .github/copilot-instructions.md instead. -->

AGENTS — OmniAgent-ADE

Purpose: brief, agent-focused operational notes so other coding agents (Codex, Claude, AntiGravity) see the same repo-level build/test/lint/runtime guidance and agent-specific behavior.

Keep these notes in sync with .github/copilot-instructions.md. When updating build/test/lint commands or repository conventions, update that file and this one.

Common build, test, lint (summary; authoritative copy in .github/copilot-instructions.md)
- Rust workspace: `cargo build --workspace`, `cargo test --workspace`, `cargo test -p <crate>`, `cargo test -p <crate> -t "pattern"`
- Format: `cargo fmt --all`
- Lint: `cargo clippy --all-targets --all-features`
- UI: `npm --prefix ui install`, `npm --prefix ui run dev`, `npm --prefix ui run build`, `npm --prefix ui run test` (Vitest)
- Tauri: run dev/build from `src-tauri/` (see .github/copilot-instructions.md)

Per-agent notes
- Claude
  - Default pre-briefed engine for workspaces (preloads brain context + MCP wiring).
  - MCP-wired: receives structured pre-brief and integrations; changing MCP shapes requires contract tests and integration updates.
  - Read `CLAUDE.md` for Claude-specific guidance.

- Codex
  - "Stock" engine: spawns without ADE wiring by default (no pre-brief).
  - Useful when you want an unmodified engine experience; agent selection UI exposes Codex as an option.
  - Codex-related UI/design references: `docs/ANALYSIS.md` and `design/` assets.

- AntiGravity
  - Special-purpose agent (schema/migration oriented in product designs).
  - Treat as a domain-specialist — follow repository conventions and run the same tests/build steps.

Agent selection & UI
- UI has engine badges (Claude, Codex, AntiGravity, Shell). See `docs/superpowers` specs and `ui/` components.

Notes for maintainers and agents
- MCP contract is frozen for v1 — do not change public MCP shapes without running/updating `crates/mcp-server` contract tests and coordinating integrations.
- Keep agent docs synchronized: when making repository-level documentation changes, mirror relevant bits to `.github/copilot-instructions.md`, `AGENTS.md`, and `CLAUDE.md` (if applicable).