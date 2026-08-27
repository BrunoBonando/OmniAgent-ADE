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

Native macOS app (macos/)
- As of the native macOS migration (`docs/plans/native-macos-migration.md`), `macos/OmniAgent.xcodeproj` is a first-class, independently buildable/testable part of this repo alongside the Tauri app — not a separate project.
- Build/test (Debug configuration, Xcode-only, no Rust toolchain required): `./macos/build.sh test`, `./macos/build.sh build`.
- Post-upgrade sanity check after macOS/Xcode updates: `./scripts/macos-post-upgrade-check.sh` (add `--full` to include `cargo build/test --workspace`).
- Universal (arm64+x86_64) Release build — embeds the signed daemon binary + LaunchAgent plists, so it *does* require the Rust workspace built first: `./macos/build.sh universal`.
- Xcode 27+ requires the Metal component for SwiftTerm shader compilation; install once with `xcodebuild -downloadComponent MetalToolchain` if `build.sh test` fails with `cannot execute tool 'metal'`.
- Sign / verify a built `.app`: `./macos/dist.sh sign|verify <path-to-OmniAgent.app>`. Notarize takes a bundle **or a disk image**: `./macos/dist.sh notarize <path-to-OmniAgent.app|path-to.dmg>`. Each subcommand fails clearly with actionable instructions when required credentials (`OMNIAGENT_CODESIGN_IDENTITY`, `OMNIAGENT_NOTARY_PROFILE`) are absent from the keychain.
- `dist.sh sign` falls back to the keychain's sole "Developer ID Application" identity when `OMNIAGENT_CODESIGN_IDENTITY` is unset (and still fails clearly when there is none, or more than one). This is not cosmetic: macOS keys TCC folder-access grants to the code-signing identity, and an ad-hoc/linker-signed bundle's identity is effectively its cdhash — which changes every build, so an unsigned rebuild re-prompts for Documents access every single time.
- A **disk image must be signed as well as notarized**, and nothing warns you otherwise: `stapler staple` reports success on an unsigned `.dmg` and notarization accepts it, because both judge the app inside. Only `spctl -a -t open --context context:primary-signature` catches it, as `source=no usable signature`. `dist.sh notarize` therefore signs a `.dmg` before submitting, and asks Gatekeeper afterwards rather than trusting `stapler`'s exit code.
- `scripts/rebuild-app.sh` runs the whole pipeline in the order that matters — build → sign app → notarize+staple app → DMG → sign+notarize+staple DMG → install — because a DMG built before the app is stapled ships an app with no ticket. It notarizes when `OMNIAGENT_NOTARY_PROFILE` is set, says so plainly when it is not, and takes `--no-notarize` to skip the two Apple round-trips for the fast local loop (notarization buys nothing for a `ditto` install, which carries no quarantine flag). It quits a running `/Applications/OmniAgent.app` before replacing it, **and stops the PTY daemon with it** (standing decision, 2026-08-17). The daemon outlives the app by design, and this script used to leave it up for that reason — but it is a binary *inside the bundle being replaced*, so leaving it running meant every install silently kept the old daemon: daemon-side changes (agent status detection, `MAX_SESSIONS`) looked shipped and were not, with the surviving process running from an unlinked inode. This ends live terminal sessions; `--keep-daemon` opts out for a rebuild that changes nothing daemon-side. The app respawns the daemon on launch whenever nothing is listening on the socket (`DaemonPersistence.shouldSpawn`).
- `dist.sh verify`'s packaged-PTY-smoke check currently fails against every build: `scripts/native-macos-pty-harness.py` (Task 1) still speaks the original per-request JSON-over-a-newline protocol, not the persistent 16-byte-envelope framing the daemon has used since Task 2. Known, pre-existing, and out of scope to fix opportunistically — see the Task 6d and Task 7 reports under `.superpowers/sdd/native-macos-migration/`.

Release cutover (retiring the web terminal hot path)
- `scripts/cutover.sh` is the release-gated mechanism for eventually removing the web/Tauri terminal hot path (xterm.js, React Mosaic, the Tauri-side terminal events/commands, and its duplicate daemon-protocol client) once the native app has proven itself across real releases. See `docs/plans/native-macos-migration.md` Task 7.
- `scripts/cutover.sh record --version V [--note TEXT]` records one completed, real-world release-candidate cycle (a build actually shipped to real users, not a local build) — always a deliberate, manual step; deliberately **not** wired into `scripts/bump-build-version.sh`/`scripts/rebuild-app.sh`, since either of those can run many times a day and auto-recording would make the gate trivially satisfiable.
- `scripts/cutover.sh status` reports how many cycles are recorded and whether the gate is open (≥ 2) or closed, plus the full removal/retention checklist.
- `scripts/cutover.sh cutover [--yes]` performs the removal once the gate is open; refuses clearly (non-zero exit, explicit count) and does nothing destructive while closed. As of this writing: 0/2 recorded, gate **CLOSED** — do not hand-delete the web terminal hot path outside this script, and do not hand-record cycles to force it open.

---

## 2) High-level architecture (big picture)

- Monorepo: Rust/Cargo workspace + TypeScript React UI wrapped by Tauri, plus a native macOS app:
  - `crates/brain-core` — SQLite + FTS5 storage and retrieval
  - `crates/brain-ingest` — repository walker, tree-sitter parsing, ingestion, enrichment
  - `crates/mcp-server` — frozen MCP contract, stdio/local server component and contract tests
  - `crates/omniagent-pty-daemon` — the persistent PTY daemon: sole owner of real PTYs/child processes, versioned socket protocol both the Tauri app's compatibility client and the native macOS app speak
  - `src-tauri` — Tauri Rust core (session manager, app wiring; a client of `omniagent-pty-daemon`, not a PTY owner itself)
  - `ui/` — React + TypeScript + Vite frontend (brain map, terminals, sidebar)
  - `macos/` — native macOS app (`OmniAgent.xcodeproj`): AppKit primary workspace, SwiftUI for low-frequency surfaces (settings/onboarding/usage/inspectors), SwiftTerm for terminals; see "Native macOS app (macos/)" above
    - Editor panes: `PaneKind.editor` is a tabbed code editor whose internals are Monaco running in a `WKWebView` (vendored under `macos/OmniAgent/Resources/monaco/`) — the one scoped exception to the native-only rule, permitted for the editor pane's internals and nowhere else — with its open/pinned tabs persisted to the native-only `editor_panes_native` settings row rather than the shared `layout` row.
- Runtime: Tauri app (UI + Rust core) and/or the native macOS app (UI), a persistent `omniagent-pty-daemon` process, a graph ingest process, and an MCP server process; they share retrieval crates and storage layers.
- Storage: SQLite "brain" DB (rebuildable) + durable Markdown memory under:
  `~/Library/Application Support/OmniAgent-ADE/brain/` — override with `OMNIAGENT_ADE_DATA_DIR`.
- **Native macOS migration status** (`docs/plans/native-macos-migration.md`): the native app is built and passes its own test suite (Tasks 1–6 complete — persistent daemon protocol, Tauri compatibility client, AppKit pane workspace, daemon-routed settings/brain/roots, SMAppService persistence, universal build/signing/notarization).
- **`macos/` is where UI work goes.** Standing decision (2026-08-03, recorded in `scripts/rebuild-app.sh`): the native app is the only artifact Bruno builds and runs day-to-day, and `scripts/rebuild-app.sh` deliberately does not build the Tauri app at all. New product/design work targets `macos/`; `ui/` is legacy. Reconfirmed 2026-08-10 ("it all must be native macOS") after design step 1 was mistakenly built in `ui/` first and reverted.
  - This is **not** the same thing as the Task 7 cutover. That gate (`scripts/cutover.sh status`, 0/2, CLOSED) governs *deleting* the web terminal hot path, which still may not be hand-removed — it says nothing about where new work lands. The two used to be conflated here; they are separate.

See `docs/DESIGN.md` and `docs/PLAN.md` for architecture and product principles.

---

## 3) Key repository conventions and patterns

- Cargo workspace: root `Cargo.toml` lists members; prefer workspace-level builds/tests for cross-crate changes.
- **Spotlight finds everything** (standing rule, 2026-08-28): every navigable thing in the native app — destinations (Home, To Do List, Desk, Settings), workspaces, sessions, panes, editor files, Settings sections and, as they are built, the items *inside* them — must be a row in the spotlight (`macos/OmniAgent/CommandPalette.swift`, `CommandPaletteModel.build`) the day it lands, with its own symbol, a subtitle naming where it lives, `keywords` for what a user would type, an action `WorkspaceWindowController.run(_:)` dispatches, and a `CommandPaletteTests` test that the rows exist. Build rows off `allCases`/live lists so later additions appear without anyone remembering this.
- Packaging rule: changes that affect releases should end with a packaged app build (`target/release/bundle/*.app` or `.dmg`).
- MCP contract: the MCP server protocol is frozen for v1. Changing public MCP shapes (tools/requests) requires updating integrations and running `crates/mcp-server` contract tests.
- Commit trailer: When creating commits for repository changes, include this trailer unless explicitly requested not to:
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`
- Memory is authoritative as Markdown. The SQLite brain DB is rebuildable from source + Markdown; prefer writing durable notes under `brain/<project>/` rather than treating DB rows as canonical writable surface.
- Transcripts & redaction: transcripts are persisted; secret-pattern redaction runs before writing memory. Be cautious when modifying transcript or memory-writing code paths.
- Tests & fixtures: `fixtures/sample-project/` is the golden repo for ingestion tests.
- Watcher behavior: file watching uses FSEvents on macOS with debounced incremental re-ingest — large repo changes must be validated for incremental correctness.
- Session IDs: stable, name-based UUIDv5 derivation; sessions map to persistent conversation IDs across restarts.
- Native macOS migration: `macos/` is a first-class build surface alongside the Tauri app. The web terminal hot path (xterm.js, React Mosaic, Tauri terminal events/commands, the Tauri-side daemon-protocol client) is retired only via the gated `scripts/cutover.sh` once two real release-candidate cycles are recorded — never by hand-deleting that code or hand-recording cycles to force the gate.

---

## 4) Agent-specific notes (Claude / Codex / AntiGravity)

- **Claude**
  - Default pre-briefed engine for workspaces: receives curated brain context and MCP wiring when started as a workspace engine, to improve relevance.
  - MCP-wired: receives structured prompts and tool wiring. Changing MCP shapes/tool contracts requires updating `crates/mcp-server` and running its contract tests.
  - When debugging agent behavior, check whether the engine was started "pre-briefed" vs. a "stock" spawn (Codex is typically stock).
  - For UI/UX changes affecting engine selection or pre-briefing, check `docs/superpowers` and `ui/src` components/tests.
  - Implementation touchpoints: `docs/DESIGN.md`, `docs/PLAN.md`, `docs/superpowers/specs`, `docs/superpowers/plans`, `src-tauri/src/sessions.rs`, `crates/mcp-server/`, `ui/src/components/*`, and — as of the native macOS migration — `macos/OmniAgent.xcodeproj`.

- **Codex**
  - "Stock" engine: spawns without ADE wiring by default (no pre-brief). Useful for an unmodified engine experience; the agent-selection UI exposes Codex as an option.
  - Codex-related UI/design references: `docs/ANALYSIS.md` and `design/` assets.

- **AntiGravity**
  - Special-purpose agent (schema/migration oriented in product designs). Treat as a domain specialist — follow repository conventions and run the same tests/build steps as any other agent.

- Agent selection & UI: engine badges (Claude, Codex, AntiGravity, Shell) live in `docs/superpowers` specs and `ui/` components.
- MCP contract is frozen for v1 — do not change public MCP shapes without running/updating `crates/mcp-server` contract tests and coordinating integrations.
- Keep agent docs synchronized: this file is authoritative; `./scripts/sync-instructions.sh` regenerates `AGENTS.md`, `CLAUDE.md`, `CODEX.md`, `ANTIGRAVITY.md` from it verbatim. Edit this file, then run the sync script — do not hand-edit the generated files (see "Note on file authority" below).

---

## 5) Useful entry points for Copilot suggestions

- `README.md` — quick start, data dir, high-level commands
- `docs/DESIGN.md` — architecture and product constraints (read before large changes)
- `docs/PLAN.md` — phased implementation notes and rough edges
- `crates/*` and `src-tauri/*` — core APIs: retrieval, MCP, session management
- `ui/` — Vite+React entry points (brain-map, terminal panes)
- `fixtures/sample-project/` — golden repo for ingestion tests
- `macos/` — native macOS app sources (AppKit/SwiftUI/SwiftTerm), `build.sh` (Xcode test/build/universal), `dist.sh` (sign/notarize/verify)
- `scripts/cutover.sh` — release-gated web-terminal-hot-path cutover (`record`/`status`/`cutover`); see `docs/plans/native-macos-migration.md` Task 7

---

Keep changes minimal and prefer explaining intent when suggesting API/contract alterations (MCP, brain storage, ingestion pipeline). When in doubt, reference `docs/DESIGN.md`.

Note on file authority and one-shot edits:
- By default, `.github/copilot-instructions.md` is the authoritative source. The local sync script regenerates agent-specific files from it.
- To promote an agent-specific file as authoritative (for example, after a direct update to `CLAUDE.md`), run:

  `./scripts/sync-instructions.sh CLAUDE.md`

  This will propagate CLAUDE.md's content into the other agent files and update `.github/copilot-instructions.md` so everything stays in sync.


---

Summary of what this file provides:
- Consolidated build/test/lint commands including single-test commands, the native macOS app (`macos/build.sh`/`dist.sh`), and the release cutover script (`scripts/cutover.sh`)
- High-level architecture overview, runtime processes, and native macOS migration status
- Repository-specific conventions (MCP contract, commit trailer, memory rules)
- Agent-specific notes (Claude / Codex / AntiGravity)

If you want adjustments (more detail for UI tests, CI hooks, or adding MCP server configs), say which and a branch/PR can be used for review.
