# OmniAgent ADE — Design Spec

> Status: draft for Bruno's review — 2026-07-24. Approach A ("graph-first ADE") as approved in conversation; supersedes nothing.

**One-liner:** a local-first macOS Agentic Development Environment where the knowledge graph is the operating system, not a feature — parallel agent-CLI terminal sessions grouped per project, all feeding and fed by one fully local second brain with a navigable map.

## 1. Positioning

- **Against BridgeMind:** they meter cloud credits; we are local-first with bring-your-own-engine. "Your brain never leaves your machine."
- **Against Warp/Conductor/Claude-Squad-class tools:** they manage sessions; none of them *remember*. The cross-project graph is the moat — it compounds with use and doesn't retrofit easily.
- **In the OmniAgent family:** the developer-facing local product beside the OmniAgent SaaS workforce platform. Shared brand; positioning/site/pricing split TBD (not v1-blocking).
- **v1 monetization:** none. Free beta, BYO model subscriptions. A paid license later must be offline-validatable to keep the local-first promise.

## 2. Product principles

1. **Local-first, always.** Graph DB, memory, transcripts, settings — all on-device. App fully functional offline except model calls. Honest language rule: "fully local" = *data at rest never leaves your machine*; agent sessions and enrichment call the provider the user already trusts with their code (their own subscription). 100%-local model mode (Ollama-class) is a later option, not v1.
2. **The graph is invisible infrastructure.** Point at your projects once; ingestion, briefing, and memory are automatic. No configuration surface in v1 beyond the projects root and an auto-commit toggle.
3. **Bring your own engine.** We orchestrate CLIs the user already pays for (Claude Code default; Codex, Gemini, plain shell selectable). No credits, no metering.
4. **Agents are visible workers.** Everything runs in real terminals the user can watch, take over, or kill. No hidden daemon jobs doing code changes.
5. **Zero-config, stock engines** (Bruno, 2026-07-24: *"allow the user to fully use Claude as normal — no user can set it up correctly"*). Claude Code (and any engine) runs completely unmodified inside the app: the user's own auth, settings, and project CLAUDE.md all work exactly as in a plain terminal. All ADE wiring — MCP registration, context briefing, transcript capture — happens automatically around the engine, never by asking the user to configure anything.
6. **Perfect foundation, first-class visual layer.** V1 optimizes for foundation quality (the storage/ingestion/PTY/MCP kernel others build on for years) and app-wide visual polish — not just the brain map; the whole shell is a design object (frontend-design skill at build time). macOS-only now; Windows/Linux are the Tauri runway, explicitly later.

## 3. Architecture

Three processes, five components:

```
┌─ Tauri App (process 1) ─────────────────────────────┐
│  React/TS UI: sidebar · terminal tabs · brain map    │
│  Rust core: PTY engine · session manager · settings  │
└──────────────┬──────────────────────────────────────┘
               │ shared storage: SQLite brain DB + Markdown memory
┌──────────────┴─────────────┐  ┌─────────────────────┐
│  Graph daemon (process 2)   │  │  MCP server (proc 3) │
│  ingest · watch · enrich    │  │  stdio + localhost   │
└─────────────────────────────┘  └─────────────────────┘
```

Separate processes because they fail differently (the BridgeMind doc's risk-isolation point): a hung ingestion or a crashed MCP client must never take down live terminals. One shared retrieval API (Rust crate) used by all three — never three query implementations.

### 3.1 Shell — Tauri 2 + React/TypeScript

- Project sidebar (projects = folders under the user-chosen roots), terminal tabs grouped per project, brain-map pane, command palette (⌘K: switch project/session, search brain, new tab).
- New tab → engine picker (single keystroke), default engine per project, global default Claude Code. The tab opens *already running* the engine.
- Session restore on relaunch: reopen project groups and tab layout; terminals restart their engine fresh (no fake PTY resurrection), transcripts persist.
- Native macOS menu bar, standard shortcuts, drag-and-drop of files/paths into terminals.

### 3.2 Terminal engine — Rust, in-process

- Real PTYs via `portable-pty`; xterm.js (WebGL addon) rendering; zsh/bash clean.
- Session = `{id, project, engine, cwd, created, transcript_path, status}`.
- Transcripts: raw output ring-buffer on disk per session, plus lifecycle events (start/end/engine/cwd). No Warp-style command-block parsing in v1 — agent CLIs own the inner loop; we capture the stream. (`ponytail:` block parsing = prompt-detection quicksand; revisit only if transcript summaries prove too noisy.)
- Concurrency: no hard cap in v1; surface machine pressure (CPU/RAM badge) when >6 live sessions.

### 3.3 Graph daemon — Rust, separate process

Ingestion pipeline, per project root:
1. **Walk** (gitignore-aware) → file nodes.
2. **Parse code** with tree-sitter (top languages first: TS/JS, Python, Rust, Go, Swift) → entity nodes (functions, classes, modules) + edges (imports, calls-at-file-granularity, containment).
3. **Read docs** (README/*.md) → doc nodes + link edges.
4. **Mine git** → commit timeline, recency, authorship signals (edge weights, not nodes).
5. **Enrich via LLM** (queued, background): per-project summary, per-community summaries, cross-project link candidates, god-node labeling — the graphify playbook. Runs through the user's configured engine headless (`claude -p`); queue drains when online. Graph works lexically without it.
6. **Communities** computed locally (Leiden/Louvain) → the zoom levels of the map and the retrieval granularity.

- FSEvents watcher, debounced, incremental re-ingest of changed files only.
- **Session feedback loop:** on session end (or 30-min checkpoint), transcript + `git diff` → enrichment queue → a memory note (what was done, decisions, files touched) written as Markdown, linked into the graph. Auto-commit by default; "review before commit" toggle.

### 3.4 MCP server — separate process, stdio + localhost

The distribution hook: any MCP client (Cursor, Claude Code outside our app, etc.) can mount the user's brain.

- Tools: `search_brain(query, scope?)`, `get_context(project)` (the briefing block), `related(node)`, `record_decision(project, text)`, `record_note(project, text)`, `list_projects()`.
- Same retrieval crate as the app; schemas frozen from v1 (the doc's warning: MCP integrations rot when shapes drift).
- In-app sessions get the MCP server auto-configured into the engine (e.g. written into the Claude Code MCP config for that session) plus a generated context block at boot: project summary, recent decisions, related projects.

### 3.5 Storage

- One SQLite DB: `nodes(id, type, project, label, path, summary, updated)`, `edges(src, dst, type, weight)`, FTS5 over labels/summaries/memory. No embeddings in v1; lexical + graph adjacency first (the doc's own advice), embeddings only if retrieval quality demands.
- Durable memory as human-readable Markdown: `~/Library/Application Support/OmniAgent-ADE/brain/<project>/…` — decisions, conventions, session summaries. Markdown is ground truth for memory; SQLite for extracted entities; **the whole DB is rebuildable** from repos + Markdown (recovery = re-ingest).
- Machine-generated summaries marked distinct from user-authored notes (contamination rule from the doc).

### 3.6 Brain map — the flagship pane

Visual reference: the two g-brain screenshots in [`sources/assets/`](sources/assets/). Same class, our data, and it must stay a *working surface*.

- **Two layouts, one graph:** *Radial* (category/project hubs pinned on a ring, force-directed core inside) and *Hierarchy* (roots → projects → communities → entities cascade).
- **Scale strategy (the real engineering):** WebGL force-graph rendering (d3-force layout + GPU renderer, cosmos.gl-class); level-of-detail via communities — collapsed to hub nodes zoomed out, expanding on dive. Tens of thousands of nodes stay legible and 60fps; no hairballs.
- **Chrome:** lens filters by node type (project / code entity / doc / memory / decision / session), legend, search-to-focus, focus tabs, fullscreen, ingestion-stats widgets (projects, nodes, last run, queue depth).
- **Node actions (non-negotiable):** click → detail panel (summary, sources, backlinks) with *open file*, *reveal in Finder*, *open terminal in this project*, *jump to session transcript*. Navigation that does things.
- Read-mostly in v1 (no graph editing). HUD aesthetic developed with the frontend-design skill at build time.

## 4. Data flows

- **First run:** pick projects folder(s) → ingestion starts → the map visibly grows while the user watches (this *is* onboarding; no tutorial) → first terminal tab offered on the biggest project.
- **Daily loop:** open project → new tab boots Claude Code pre-briefed → user vibe-codes → session end → memory note into graph → tomorrow's sessions and the map are smarter.
- **Outside the app:** user's Cursor/Claude Code mounts the MCP server → same brain everywhere. This is how the product spreads beyond its own window.

## 5. Trust & failure modes

- Scoped folder access (user-picked roots only; macOS file-picker grants). Per-workspace trust before any auto-launch of engines.
- Secret-pattern redaction (key/token/password regex class) before transcripts or notes are persisted.
- No telemetry in beta. Ever-present "what leaves this machine" explainer: model calls only.
- Offline → terminals + lexical brain queries work; enrichment queues. Huge monorepo → bounded incremental background ingest, visible progress, per-project pause. Corrupt DB → rebuild from sources. Crashed daemon → app stays up, map shows "stale" badge.

## 6. v1 cut list (explicit non-goals)

No Kanban/task board · no swarms/orchestrated multi-agent roles (the user *is* the orchestrator via tabs) · no voice · no code editor (file viewer + open-in-external only) · no accounts, billing, credits · no team/sync · no Windows/Linux (Tauri keeps the runway) · no embeddings · no command-block terminal parsing.

## 7. Testing

- Graph store + ingestion: unit tests against a golden fixture repo (expected nodes/edges/communities).
- PTY lifecycle: spawn/kill/restore under load.
- MCP: schema-frozen contract tests.
- E2E smoke: ingest fixture → query via MCP → assert correct answer; launch tab → engine boots with briefing.

## 8. Decisions (Bruno, 2026-07-24)

1. **Blessed:** enrichment via the user's own CLI, headless — no bundled/local model in v1.
2. **Blessed:** memory notes auto-commit by default — review-first is a settings toggle, not a gate.
3. Both subject to principle 5: the engine stays fully stock for the user; all enrichment/briefing wiring is automatic and invisible.
4. **V1 stays lean** — no parity features pulled forward (task board, swarms, voice remain roadmap); v1 = perfect foundation + first-class visual layer.
5. **Cadence:** full push, vibe-coded together (Bruno + Claude Code sessions) — plan phased in session-sized increments, working software every few days.
6. **Distribution:** Bruno dogfoods first, then a hand-picked private beta; public only with substance.

## 9. Next steps

Implementation plan (phased, via writing-plans) after spec approval → scaffold sibling repo `~/Documents/Bruno.Digital/OmniAgent-ADE/` → build order: storage+ingestion core → MCP → shell+terminals → brain map → session feedback loop.

## Sources

- [BridgeMind capability map + macOS-first strategy](sources/2026-07-24-bridgemind-macos-strategy.md)
- [g-brain radial view](sources/assets/2026-07-24-gbrain-radial-view.png) · [hierarchy view](sources/assets/2026-07-24-gbrain-hierarchy-view.png)
- [wiki/graphify.md](../../wiki/graphify.md) · [wiki/llm-wiki-pattern.md](../../wiki/llm-wiki-pattern.md)
- [README](README.md) — idea, scoping decisions, log
