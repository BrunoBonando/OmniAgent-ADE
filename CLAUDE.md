<!-- GENERATED from .github/copilot-instructions.md — do not edit directly. Update .github/copilot-instructions.md instead. -->

CLAUDE — OmniAgent-ADE

Purpose: Claude-specific notes for maintainers and agent integrations.

Key behavior
- Claude is the repo's default pre-briefed engine: when started as a workspace engine it receives curated brain context and MCP wiring to improve relevance.
- MCP integration: Claude is expected to be "MCP-wired" (receives structured prompts and tool wiring). Any changes to MCP shapes or tool contracts require updating `crates/mcp-server` and running its contract tests.

Operational reminders
- When debugging agent behavior, verify whether the engine was started as "pre-briefed" vs a "stock" spawn (Codex is typically stock).
- For UI/UX changes that affect engine selection or pre-briefing, check `docs/superpowers` and `ui/src` components/tests.

Where to look
- High-level architecture and product constraints: `docs/DESIGN.md`, `docs/PLAN.md`.
- Agent installation & selection redesign notes: `docs/superpowers/specs` and `docs/superpowers/plans`.
- Implementation touchpoints: `src-tauri/src/sessions.rs`, `crates/mcp-server/`, `ui/src/components/*`.

Sync guidance
- Keep this file aligned with `.github/copilot-instructions.md` and `AGENTS.md`. Update all three when changing test/build commands or MCP contract notes.