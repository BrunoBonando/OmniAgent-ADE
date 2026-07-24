# OmniAgent ADE v1 — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Read [DESIGN.md](DESIGN.md) fully before Task 0.1 — it is the authority; this plan is the sequence.

**Goal:** Build OmniAgent ADE v1 — a local-first macOS Agentic Development Environment: parallel agent-CLI terminal sessions grouped per project, all connected to one fully local knowledge graph with a navigable WebGL brain map.

**Architecture:** Three processes sharing one SQLite brain DB + Markdown memory: (1) Tauri 2 desktop app (React/TS UI + Rust core with PTY sessions), (2) graph daemon (walk → tree-sitter parse → git mine → enrich → communities), (3) MCP server exposing the brain to any MCP client. One shared Rust retrieval crate; never duplicate query logic.

**Tech Stack:** Tauri 2 · Rust (workspace: `rusqlite` bundled, `tree-sitter` + language grammars, `portable-pty`, `notify`, `rmcp` MCP SDK) · React 18 + TypeScript + Vite + Tailwind · `@xterm/xterm` + WebGL addon · `force-graph` (WebGL 2D) for the brain map.

## Global Constraints

- **Repo:** `~/Documents/Bruno.Digital/OmniAgent-ADE/` (new sibling repo; Task 0.1 creates it). Branch `main`, conventional commits (`feat:`, `fix:`, `test:`, `chore:`, `docs:`).
- **Local-first:** all data under `~/Library/Application Support/OmniAgent-ADE/` (`brain.db`, `brain/<project>/*.md` memory, `transcripts/`). Env override `OMNIAGENT_ADE_DATA_DIR` for tests — every crate must honor it.
- **Zero-config, stock engines (DESIGN principle 5):** NEVER modify the user's `~/.claude/*`, project `CLAUDE.md`, or global MCP config. All wiring is per-session flags (`--mcp-config`, `--append-system-prompt`) on processes we spawn.
- **No telemetry. No network calls** except processes the user's own CLIs make and the enrichment calls routed through their CLI.
- **Secret redaction** before anything persists to transcripts/memory: strip matches of `(?i)(api[_-]?key|token|secret|password|bearer)\s*[=:]\s*\S+` and AWS/OpenAI/Anthropic key shapes (`AKIA[0-9A-Z]{16}`, `sk-[A-Za-z0-9-_]{20,}`).
- **TDD throughout:** every non-trivial task = failing test → implement → pass → commit. `cargo test` and `npm test` (vitest) must be green at every commit.
- **macOS only** (Apple Silicon primary). Don't add Windows/Linux cfg work.
- **Frozen MCP schemas:** tool names/shapes in Phase 3 are contracts — never rename after Phase 3 lands.
- **Visual quality is a v1 requirement:** UI phases (5, 6, 8) must load the `frontend-design` skill before building screens. Dark, HUD-inflected aesthetic (reference: g-brain screenshots in `docs/reference/` after Task 0.1); no default-Tailwind genericism.
- **Phase gates:** at the end of every phase: all tests green, the phase's Demo runs, commit, then STOP and report to Bruno before the next phase.

---

## Phase 0 — Repo scaffold (gate: app window opens)

### Task 0.1: Repository + workspace skeleton

**Files:** Create `~/Documents/Bruno.Digital/OmniAgent-ADE/` with:
```
OmniAgent-ADE/
  Cargo.toml                 # [workspace] members = ["crates/*", "src-tauri"]
  crates/brain-core/         # storage + retrieval (lib)
  crates/brain-ingest/       # walker, parsers, git, communities (lib + bin "brain")
  crates/mcp-server/         # MCP stdio server (bin "omniagent-mcp")
  src-tauri/                 # Tauri 2 app (Rust core)
  ui/                        # React 18 + TS + Vite + Tailwind
  fixtures/sample-project/   # golden test fixture (Task 1.2)
  docs/                      # DESIGN.md + PLAN.md copied from My-Brain, reference/ for g-brain pngs
  .gitignore                 # target/, node_modules/, dist/, *.db
```

- [ ] `git init`; copy `DESIGN.md`, `PLAN.md`, and the two g-brain PNGs from `My-Brain/projects/omniagent-ade/` into `docs/` (PNGs → `docs/reference/`)
- [ ] `npm create tauri-app@latest` (React-TS template) merged into the layout above; `cargo new --lib` the three crates; wire the workspace `Cargo.toml`
- [ ] Verify: `cd ui && npm install && cd .. && npm run tauri dev` opens a window titled "OmniAgent ADE" (set `productName`, `identifier: com.omniagent.ade` in `src-tauri/tauri.conf.json`)
- [ ] Verify: `cargo test --workspace` passes (0 tests, compiles)
- [ ] Commit: `chore: scaffold OmniAgent ADE workspace (tauri app + 3 crates)`

**PHASE 0 GATE — Demo:** window opens; workspace compiles. Report to Bruno.

---

## Phase 1 — Brain store (`brain-core`) (gate: graph CRUD + FTS proven)

### Task 1.1: Schema + store API

**Files:** Create `crates/brain-core/src/{lib.rs,store.rs,schema.sql}`, test `crates/brain-core/tests/store_test.rs`.

**Produces (contract for ALL later tasks):**
```rust
pub struct Store { /* rusqlite::Connection */ }
pub struct Node { pub id: String, pub kind: NodeKind, pub project: String,
                  pub label: String, pub path: Option<String>,
                  pub summary: Option<String>, pub origin: Origin, pub updated: i64 }
pub enum NodeKind { Project, File, CodeEntity, Doc, Memory, Decision, Session, Community }
pub enum Origin { Extracted, MachineSummary, UserAuthored }   // contamination rule
pub struct Edge { pub src: String, pub dst: String, pub kind: EdgeKind, pub weight: f32 }
pub enum EdgeKind { Contains, Imports, References, LinksTo, MemberOf, Touched }
impl Store {
    pub fn open(data_dir: &Path) -> Result<Store>;        // creates brain.db + schema
    pub fn upsert_node(&self, n: &Node) -> Result<()>;
    pub fn upsert_edge(&self, e: &Edge) -> Result<()>;
    pub fn delete_project_extracted(&self, project: &str) -> Result<()>; // re-ingest support; keeps Memory/Decision
    pub fn search(&self, query: &str, scope: Option<&str>, limit: usize) -> Result<Vec<Node>>; // FTS5
    pub fn neighbors(&self, id: &str, limit: usize) -> Result<Vec<(Edge, Node)>>;
    pub fn list_projects(&self) -> Result<Vec<Node>>;
}
```

`schema.sql`: tables `nodes(id TEXT PK, kind TEXT, project TEXT, label TEXT, path TEXT, summary TEXT, origin TEXT, updated INTEGER)`, `edges(src TEXT, dst TEXT, kind TEXT, weight REAL, PRIMARY KEY(src,dst,kind))`, FTS5 virtual table `nodes_fts(label, summary, content=nodes)` with sync triggers, and `enrich_queue(id INTEGER PK, kind TEXT, payload TEXT, status TEXT DEFAULT 'pending', created INTEGER)`.

- [ ] Write failing tests: open-creates-db; upsert+search round-trip (`search("parse", None, 10)` finds node labeled `parse_config`); neighbors returns typed edges; `delete_project_extracted` removes `Extracted` but keeps `UserAuthored` nodes; FTS survives reopen
- [ ] Run `cargo test -p brain-core` → FAIL (unimplemented)
- [ ] Implement with `rusqlite` (feature `bundled`); `Store::open` respects `OMNIAGENT_ADE_DATA_DIR`
- [ ] `cargo test -p brain-core` → PASS
- [ ] Commit: `feat(brain-core): sqlite store with nodes/edges/FTS5 + enrich queue`

### Task 1.2: Markdown memory layer

**Files:** Create `crates/brain-core/src/memory.rs`, test in `crates/brain-core/tests/memory_test.rs`. Create fixture `fixtures/sample-project/` (used from Phase 2 on):
```
fixtures/sample-project/
  README.md            # "# Sample. Uses the auth helper." + link [notes](docs/notes.md)
  docs/notes.md
  src/auth.ts          # exports function login(user: string), imports './util'
  src/util.ts          # export function hashPassword(pw: string)
  main.py              # def fetch_data(url): ... ; import helpers
  helpers.py           # def parse_config(path): ...
```

**Produces:** `Memory::write_note(project, title, body, origin) -> Result<PathBuf>` (writes `brain/<project>/YYYY-MM-DD-<slug>.md` with frontmatter `origin: machine|user`, secret-redacted, and upserts a `Memory` node + `LinksTo` edges for any `[[wiki-link]]` / relative md link in body); `Memory::read_all(project)`.

- [ ] Failing tests: note lands on disk + as node; body containing `API_KEY=abc123` is stored redacted (`API_KEY=[redacted]`); machine vs user origin recorded
- [ ] Implement (redaction regexes from Global Constraints, shared `redact()` in `brain-core::redact` — ONE implementation, exported)
- [ ] `cargo test -p brain-core` → PASS · Commit: `feat(brain-core): markdown memory layer with redaction + graph linking`

**PHASE 1 GATE — Demo:** `cargo test -p brain-core` green. Report.

---

## Phase 2 — Ingestion (`brain-ingest`) (gate: fixture + a real repo ingested from CLI)

### Task 2.1: Walker + tree-sitter code parsing

**Files:** Create `crates/brain-ingest/src/{lib.rs,walk.rs,code.rs}`, test `tests/ingest_test.rs`.

**Consumes:** `brain_core::Store`. **Produces:** `ingest_project(store, root: &Path, name: &str) -> Result<IngestStats>` (`IngestStats { files, entities, edges }`).

- Walk with `ignore` crate (respects .gitignore). File nodes for source/docs only (skip binaries >1 MB, `node_modules`, `target`, `.git`).
- tree-sitter grammars v1: `tree-sitter-typescript`, `tree-sitter-javascript`, `tree-sitter-python`, `tree-sitter-rust`. Extract: functions, classes/structs, exported consts → `CodeEntity` nodes (`id = "<project>:<relpath>#<name>"`); `Contains` edges file→entity; `Imports` edges file→file resolved within the project (relative imports only; unresolved imports dropped, not guessed).
- [ ] Failing test against `fixtures/sample-project`: exact assertions — ≥6 file nodes; entities include `login`, `hashPassword`, `fetch_data`, `parse_config`; `Imports` edge `src/auth.ts → src/util.ts`; re-running `ingest_project` twice doesn't duplicate (upsert semantics, `delete_project_extracted` first)
- [ ] Implement · `cargo test -p brain-ingest` → PASS · Commit: `feat(ingest): walker + tree-sitter TS/JS/Py/Rust extraction`
- [ ] Follow-on in same task: add `tree-sitter-go` + `tree-sitter-swift` behind the same extractor trait (DESIGN names all five). If the Swift grammar fights, ship without it and leave `// ponytail: swift grammar deferred, files still indexed as File nodes`

### Task 2.2: Docs, git mining, communities

**Files:** Create `crates/brain-ingest/src/{docs.rs,gitmine.rs,community.rs}`; extend `ingest_project`.

- `docs.rs`: md files → `Doc` nodes; relative md links → `LinksTo` edges (README.md→docs/notes.md in fixture).
- `gitmine.rs`: `git log --numstat --format=...` via `std::process::Command` (no libgit2 dep); co-change counts → bump `References` edge weight between files changed in the same commit (cap weight 10). Non-git roots: skip silently.
- `community.rs`: label propagation over the project subgraph (`ponytail:` label propagation, ~50 lines; upgrade to Leiden if map legibility demands). → `Community` nodes + `MemberOf` edges. Deterministic: seed by sorted node id.
- [ ] Failing tests: fixture yields ≥1 community containing both `auth.ts` and `util.ts`; doc link edge exists; determinism (two runs → identical community assignment)
- [ ] Implement · PASS · Commit: `feat(ingest): docs + git co-change mining + label-propagation communities`

### Task 2.3: CLI + watcher

**Files:** Create `crates/brain-ingest/src/bin/brain.rs`, `src/watch.rs`.

**Produces:** `brain ingest <root>` (walks immediate subdirs of `<root>`; each dir containing `.git` or ≥3 source files = one project), `brain search <query>`, `brain stats`; `watch_roots(store, roots, debounce_ms)` re-ingests only changed projects (`notify` crate, 2 s debounce).

- [ ] Failing test: integration — `brain ingest fixtures` then `brain search parse_config` prints the node (assert via `assert_cmd`)
- [ ] Implement · PASS
- [ ] Manual verify: `OMNIAGENT_ADE_DATA_DIR=/tmp/ade-test cargo run -p brain-ingest --bin brain -- ingest ~/Documents/Bruno.Digital` completes; `brain stats` reports plausible node/edge counts. Record counts in the commit body.
- [ ] Commit: `feat(ingest): brain CLI + fs watcher with incremental re-ingest`

**PHASE 2 GATE — Demo:** Bruno's real folder ingested from the CLI; stats reported. Report.

---

## Phase 3 — MCP server (gate: Claude Code answers from the brain)

### Task 3.1: `omniagent-mcp` stdio server

**Files:** Create `crates/mcp-server/src/main.rs`, `tools.rs`; contract test `tests/contract_test.rs`.

**Produces (FROZEN contract):** MCP tools, all reading through `brain_core`:
- `search_brain {query: string, scope?: string}` → `[{id, kind, project, label, path?, summary?}]`
- `get_context {project: string}` → `{summary, recent_decisions: [...], related_projects: [...], memory_notes: [...]}` — the briefing block, also used by Phase 5
- `related {node_id: string}` → `[{edge_kind, node}]`
- `record_decision {project: string, text: string}` / `record_note {project: string, text: string}` → `{path}` (via `Memory::write_note`, origin=UserAuthored)
- `list_projects {}` → `[{id, label, path}]`

- [ ] Failing contract tests: spawn the binary, speak MCP over stdio (initialize → tools/list → tools/call `search_brain` on fixture db), assert exact tool names + response shapes
- [ ] Implement with `rmcp` (official Rust MCP SDK; check current API via context7 — if SDK friction exceeds a session, hand-roll the JSON-RPC stdio loop: initialize, tools/list, tools/call only)
- [ ] `cargo test -p mcp-server` → PASS
- [ ] Manual verify: `claude mcp add omniagent-test -- <path-to-binary>` in a scratch dir, ask Claude "search my brain for parse_config" → correct answer; then `claude mcp remove omniagent-test`
- [ ] Commit: `feat(mcp): omniagent-mcp stdio server — frozen v1 tool contract`

**PHASE 3 GATE — Demo:** stock Claude Code answering from the brain. Report.

---

## Phase 4 — Enrichment queue (gate: summaries appear without user action)

### Task 4.1: Headless enrichment worker

**Files:** Create `crates/brain-ingest/src/enrich.rs`; extend ingest to enqueue.

**Produces:** `drain_queue(store, engine: &EnrichEngine) -> Result<usize>`; `EnrichEngine::Claude` runs `claude -p <prompt> --output-format json --max-turns 1`; trait-shaped so tests inject `EnrichEngine::Fake(fn)`.

- Jobs (payload JSON): `project_summary`, `community_summary`, `session_summary` (Phase 7 enqueues these). Prompts include only node labels/paths/doc excerpts — never file contents wholesale. Results → `summary` field (origin=MachineSummary) / memory notes.
- Offline/CLI-missing: jobs stay `pending`; `drain_queue` returns 0, never errors the caller. Failures → `status='failed'` with stderr in payload, retried once.
- [ ] Failing tests (Fake engine): ingest fixture → queue has `project_summary` job; drain → project node has summary, origin MachineSummary; missing engine → jobs remain pending, no error
- [ ] Implement · PASS
- [ ] Manual verify: drain against real `claude -p` on the fixture; sanity-check the summary text
- [ ] Commit: `feat(enrich): queued headless enrichment via user's claude CLI`

**PHASE 4 GATE.** Report.

---

## Phase 5 — Shell + terminals (gate: daily-drivable app)

*Load the `frontend-design` skill before any UI work in this phase.*

### Task 5.1: PTY sessions in Tauri

**Files:** Create `src-tauri/src/{sessions.rs,commands.rs}`; UI `ui/src/{components/Terminal.tsx,state/sessions.ts}`; test `src-tauri/tests/session_test.rs` (PTY lifecycle, no UI).

**Produces (Tauri commands):**
```rust
#[tauri::command] fn session_create(project: String, engine: String, cwd: String) -> SessionInfo
// SessionInfo { id: String, project, engine, cwd, created: i64 }
#[tauri::command] fn session_write(id: String, data: String)
#[tauri::command] fn session_resize(id: String, cols: u16, rows: u16)
#[tauri::command] fn session_kill(id: String)
// output streamed as Tauri event "session-output:{id}" (base64 chunks)
```
- `portable-pty`; engines: `claude` | `codex` | `shell` (spawn `$SHELL`). Raw output tee'd (redacted) to `transcripts/<session-id>.log` + lifecycle JSON lines.
- **Claude wiring (zero-config):** spawn as `claude --mcp-config <generated>.json --append-system-prompt <briefing>` where the briefing = `get_context(project)` rendered to ~40 lines of markdown. Other engines: stock spawn, no flags. User's own config untouched.
- [ ] Failing Rust tests: create shell session → write `echo hi\n` → event contains `hi`; kill reaps the child (no zombie); transcript file exists and is redacted
- [ ] Implement · PASS · Commit: `feat(shell): PTY session engine with stock-CLI spawn + auto MCP/briefing wiring for claude`

### Task 5.2: Workspace UI

**Files:** `ui/src/{App.tsx,components/{Sidebar.tsx,TabBar.tsx,EnginePicker.tsx,CommandPalette.tsx}}`; vitest `ui/src/state/sessions.test.ts`.

- Sidebar: projects from `list_projects` (via a `brain_query` Tauri command added to `commands.rs` calling brain-core directly). Tabs grouped per project; new tab (⌘T) → engine picker, Enter = default (Claude, per-project override persisted in a `settings` table); tab opens already running the engine.
- xterm.js + `@xterm/addon-webgl`, fit addon; ⌘K palette: switch session/project, "New tab in <project>", "Search brain…".
- Session restore: layout (projects, tab order, engines) persisted; on relaunch, tabs reopen and restart engines fresh; transcripts persist (DESIGN 3.1 — no PTY resurrection).
- Machine-pressure badge when >6 live sessions (sysinfo crate, polled 5 s).
- [ ] Vitest: session-state reducer (create/close/restore ordering); Rust: settings round-trip
- Drag-and-drop: dropping a file from Finder onto a terminal pastes its quoted path (DESIGN 3.1).
- [ ] Manual verify: two projects × two tabs each; jump via ⌘K; quit/relaunch restores; drag a file onto a terminal → quoted path appears; Claude tab boots pre-briefed (ask it "what project is this?" — it answers from the briefing)
- [ ] Commit: `feat(shell): project-grouped terminal workspace with palette + restore`

**PHASE 5 GATE — Demo:** Bruno vibe-codes a real task in the app. Report. **This is the dogfood threshold — Bruno switches daily driving to the app from here.**

---

## Phase 6 — Brain map (gate: the flagship pane)

*Load the `frontend-design` skill; visual reference `docs/reference/` g-brain PNGs. This pane is the App-Store screenshot — HUD aesthetic, but every pixel functional.*

### Task 6.1: Graph data feed + LOD

**Files:** `src-tauri/src/map_feed.rs`; `ui/src/map/{useGraphData.ts}`; tests both sides.

**Produces:** Tauri command `map_graph {project?: string, expanded: string[] /*community ids*/, filter: string[] /*NodeKind names*/}` → `{nodes: [{id,kind,label,project,size}], links: [{src,dst,kind,weight}]}`. Collapsed communities return as single hub nodes (size = member count); expanding a community id swaps the hub for members. Cap payload at 3 000 visible nodes (`ponytail:` hard cap; virtualize if users outgrow it).

- [ ] Rust test on fixture: collapsed → `Community` hubs, no `CodeEntity` leaves; expanded → members present, hub gone; filter `["Memory"]` excludes code nodes
- [ ] Implement · PASS · Commit: `feat(map): LOD graph feed with community collapse`

### Task 6.2: Interactive map pane

**Files:** `ui/src/map/{BrainMap.tsx,RadialLayout.ts,HierarchyLayout.ts,DetailPanel.tsx,Lens.tsx}`.

- `force-graph` (WebGL). **Radial:** project hubs pinned on a ring (`fx/fy` from polar coords), force sim inside. **Hierarchy:** roots→projects→communities→entities via `dagMode: 'radialout'`. Toggle top-left (g-brain pattern).
- Lens filters (node kinds), legend, search-to-focus (zoom+center on hit), fullscreen, stats widgets (nodes, last ingest, queue depth — from `brain stats` data via command).
- Detail panel on click: summary, path, backlinks + actions **Open file** (`open <path>`), **Reveal in Finder**, **Open terminal here** (creates session in that project), **Jump to transcript** (Session nodes).
- Click-to-expand community hubs; double-click background collapses all.
- [ ] Vitest: radial layout math (N hubs → evenly spaced pinned coords); filter/expand state reducer
- [ ] Manual verify on Bruno's real brain: 60 fps pan/zoom at full collapsed view; expand two projects; every detail-panel action works
- [ ] Commit: `feat(map): two-mode WebGL brain map with lens, search, working detail actions`

**PHASE 6 GATE — Demo:** the money screenshot, on real data. Report.

---

## Phase 7 — Session feedback loop (gate: the brain compounds)

### Task 7.1: Transcript → memory

**Files:** `src-tauri/src/feedback.rs`; extend `sessions.rs` kill/exit path; tests `src-tauri/tests/feedback_test.rs`.

- On session end (or 30-min checkpoint while alive): enqueue `session_summary` job with payload `{project, transcript_tail: last 400 redacted lines, git_diff: --stat vs session start-ref}`. Drain (Phase 4 worker, now spawned as a background thread in the app on a 60 s tick) → memory note (origin=MachineSummary) titled `Session: <first user intent line>`, linked to project + touched files (`Touched` edges from diff paths).
- Auto-commit default; `review_memory` setting=true → note lands with frontmatter `status: pending` and a UI inbox badge; approve/discard in a small review list (Settings pane).
- A `Session` node per session (label = intent line, path = transcript).
- [ ] Failing tests (Fake engine): end session → queue job → drain → note exists, `Touched` edges to diff files, Session node present; review mode → pending status, approve flips it
- [ ] Implement · PASS
- [ ] Manual verify: real session ("add a comment to util.ts"), end it, watch the note + map node appear
- [ ] Commit: `feat(feedback): session transcripts compound into the graph`

**PHASE 7 GATE — Demo:** yesterday's session visible in today's briefing (`get_context` includes it). Report.

---

## Phase 8 — First-run, polish, package (gate: installable beta)

### Task 8.1: Onboarding + degradation

**Files:** `ui/src/onboarding/FirstRun.tsx`; `src-tauri/src/roots.rs`.

- First run: native folder picker ("Where do your projects live?") → roots persisted → ingestion starts → **the map grows live as onboarding** (poll `brain stats` every 2 s, animate new nodes in; no tutorial) → first tab offered on the biggest project.
- Degradation surfaces: offline → map badge "enrichment queued (N)"; daemon dead → "stale" badge + relaunch button; per-project ingest pause in sidebar context menu; Settings → "Rebuild brain" button = delete `brain.db` + full re-ingest (DESIGN 5: DB is rebuildable; Markdown memory survives untouched).
- [ ] Tests: roots persistence; stats-poll reducer
- [ ] Commit: `feat(onboarding): pick roots → watch your brain grow`

### Task 8.2: Package

- [ ] App icon (OmniAgent family mark, dark), DMG via `tauri build`; ad-hoc signing is fine for dogfood (`ponytail:` Developer-ID + notarization when the private beta ships to others)
- [ ] `README.md` in repo: what it is, dev setup, build
- [ ] Full pass: `cargo test --workspace && cd ui && npm test` green; fresh-machine-style run from the DMG on Bruno's Mac
- [ ] Commit: `chore: v0.1.0 — dogfood build` + tag `v0.1.0`

**PHASE 8 GATE — Demo:** installed .app, first-run onboarding on real data, daily-drivable. **v1 complete → Bruno dogfoods → private beta list.**

---

## Deferred (do NOT build in v1 — roadmap after dogfood)

Task board/Kanban · swarms · voice · embeddings · Warp-style command blocks · editor beyond file viewer · licensing/accounts · Windows/Linux · Ollama-local enrichment.

## Self-review notes (for the executor)

- Every phase ends in working, testable software; if a task balloons past ~2 sessions, stop and report rather than expanding scope.
- `brain-core` is the ONLY place that touches SQLite. UI never queries the DB directly — always through Tauri commands → brain-core.
- When docs are needed: Tauri 2 / rmcp / xterm.js / force-graph APIs move fast — use context7 rather than memory.
- Anything ambiguous: DESIGN.md wins; if DESIGN.md is silent, choose the lazier option and leave a `ponytail:` comment naming the ceiling.
