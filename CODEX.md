<!-- GENERATED from .github/copilot-instructions.md — do not edit directly. To change this content, edit .github/copilot-instructions.md or run: scripts/sync-instructions.sh .github/copilot-instructions.md -->

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

Notes:
- Many commands assume `cargo` and `node` are on PATH; non-login shells may omit `~/.cargo/bin`.

Native macOS app (macos/)
- `macos/OmniAgent.xcodeproj` is the app. It is the only UI in this repo: the legacy Tauri/React app that preceded it (`src-tauri/`, `ui/`) was deleted on 2026-08-30 after the native migration (`docs/plans/native-macos-migration.md`) completed.
- Build/test (Debug configuration, Xcode-only, no Rust toolchain required): `./macos/build.sh test`, `./macos/build.sh build`.
- Post-upgrade sanity check after macOS/Xcode updates: `./scripts/macos-post-upgrade-check.sh` (add `--full` to include `cargo build/test --workspace`).
- Universal (arm64+x86_64) Release build — embeds the signed daemon binary + LaunchAgent plists, so it *does* require the Rust workspace built first: `./macos/build.sh universal`.
- Xcode 27+ requires the Metal component for SwiftTerm shader compilation; install once with `xcodebuild -downloadComponent MetalToolchain` if `build.sh test` fails with `cannot execute tool 'metal'`.
- Sign / verify a built `.app`: `./macos/dist.sh sign|verify <path-to-OmniAgent.app>`. Notarize takes a bundle **or a disk image**: `./macos/dist.sh notarize <path-to-OmniAgent.app|path-to.dmg>`. Each subcommand fails clearly with actionable instructions when required credentials (`OMNIAGENT_CODESIGN_IDENTITY`, `OMNIAGENT_NOTARY_PROFILE`) are absent from the keychain.
- `dist.sh sign` falls back to the keychain's sole "Developer ID Application" identity when `OMNIAGENT_CODESIGN_IDENTITY` is unset (and still fails clearly when there is none, or more than one). This is not cosmetic: macOS keys TCC folder-access grants to the code-signing identity, and an ad-hoc/linker-signed bundle's identity is effectively its cdhash — which changes every build, so an unsigned rebuild re-prompts for Documents access every single time.
- A **disk image must be signed as well as notarized**, and nothing warns you otherwise: `stapler staple` reports success on an unsigned `.dmg` and notarization accepts it, because both judge the app inside. Only `spctl -a -t open --context context:primary-signature` catches it, as `source=no usable signature`. `dist.sh notarize` therefore signs a `.dmg` before submitting, and asks Gatekeeper afterwards rather than trusting `stapler`'s exit code.
- `scripts/rebuild-app.sh` runs the whole pipeline in the order that matters — build → sign app → notarize+staple app → DMG → sign+notarize+staple DMG → install — because a DMG built before the app is stapled ships an app with no ticket. It notarizes when `OMNIAGENT_NOTARY_PROFILE` is set, says so plainly when it is not, and takes `--no-notarize` to skip the two Apple round-trips for the fast local loop (notarization buys nothing for a `ditto` install, which carries no quarantine flag). It quits a running `/Applications/OmniAgent.app` before replacing it, **and stops the PTY daemon with it** (standing decision, 2026-08-17). The daemon outlives the app by design, and this script used to leave it up for that reason — but it is a binary *inside the bundle being replaced*, so leaving it running meant every install silently kept the old daemon: daemon-side changes (agent status detection, `MAX_SESSIONS`) looked shipped and were not, with the surviving process running from an unlinked inode. This ends live terminal sessions; `--keep-daemon` opts out for a rebuild that changes nothing daemon-side. The app respawns the daemon on launch whenever nothing is listening on the socket (`DaemonPersistence.shouldSpawn`).
- `scripts/bump-build-version.sh` bumps the date-based build version (`YYYY.M.D+NNN`) in the Xcode project — the only place the version lives now. `rebuild-app.sh` runs it by itself; never bump by hand first.
- The DMG background assets `make-dmg.sh` uses live in `macos/dmg/`.

---

## 2) High-level architecture (big picture)

- Monorepo: Rust/Cargo workspace + a native macOS app:
  - `crates/brain-core` — SQLite + FTS5 storage and retrieval
  - `crates/brain-ingest` — repository walker, tree-sitter parsing, ingestion, enrichment
  - `crates/mcp-server` — frozen MCP contract, stdio/local server component and contract tests. Its lib is a dependency of the daemon; the `omniagent-mcp` binary is not yet bundled with the native app (`EngineLauncher.swift` launches agents stock until it is)
  - `crates/omniagent-pty-daemon` — the persistent PTY daemon: sole owner of real PTYs/child processes, versioned socket protocol the native app speaks (`SessionConnection.swift`)
  - `macos/` — native macOS app (`OmniAgent.xcodeproj`): AppKit primary workspace, SwiftUI for low-frequency surfaces (settings/onboarding/usage/inspectors), SwiftTerm for terminals; see "Native macOS app (macos/)" above
    - Editor panes: `PaneKind.editor` is a tabbed code editor whose internals are Monaco running in a `WKWebView` (vendored under `macos/OmniAgent/Resources/monaco/`) — the one scoped exception to the native-only rule, permitted for the editor pane's internals and nowhere else — with its open/pinned tabs persisted to the native-only `editor_panes_native` settings row rather than the shared `layout` row.
- Runtime: the native macOS app (UI), a persistent `omniagent-pty-daemon` process, a graph ingest process, and an MCP server process; they share retrieval crates and storage layers.
- Storage: SQLite "brain" DB (rebuildable) + durable Markdown memory under:
  `~/Library/Application Support/OmniAgent-ADE/brain/` — override with `OMNIAGENT_ADE_DATA_DIR`.
- **Native macOS migration** (`docs/plans/native-macos-migration.md`) is complete. The native app is the only artifact Bruno builds and runs (standing decision, 2026-08-03; reconfirmed 2026-08-10, "it all must be native macOS"). The Task 7 "cutover" gate (`scripts/cutover.sh`) that guarded the deletion of the web terminal hot path was retired along with the web app itself on 2026-08-30 by Bruno's explicit decision — there is no rollback Tauri build.
- Settings rows written by the old web build (the shared `layout` row, etc.) may still exist on users' disks; `fixtures/native-macos-compat/` and `NativeMacosCompatibilityFixtureTests.swift`/`PaneGridTests.swift` pin the formats the native app must keep reading.

See `docs/DESIGN.md` and `docs/PLAN.md` for architecture and product principles.

---

## 3) Key repository conventions and patterns

- Cargo workspace: root `Cargo.toml` lists members; prefer workspace-level builds/tests for cross-crate changes.
- **Spotlight finds everything** (standing rule, 2026-08-28): every navigable thing in the native app — destinations (Home, To Do List, Desk, Settings), workspaces, sessions, panes, editor files, Settings sections and, as they are built, the items *inside* them — must be a row in the spotlight (`macos/OmniAgent/CommandPalette.swift`, `CommandPaletteModel.build`) the day it lands, with its own symbol, a subtitle naming where it lives, `keywords` for what a user would type, an action `WorkspaceWindowController.run(_:)` dispatches, and a `CommandPaletteTests` test that the rows exist. Build rows off `allCases`/live lists so later additions appear without anyone remembering this.
- Packaging rule: changes that affect releases should end with a packaged app build (`scripts/rebuild-app.sh`).
- MCP contract: the MCP server protocol is frozen for v1. Changing public MCP shapes (tools/requests) requires updating integrations and running `crates/mcp-server` contract tests.
- Commit trailer: When creating commits for repository changes, include this trailer unless explicitly requested not to:
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`
- Memory is authoritative as Markdown. The SQLite brain DB is rebuildable from source + Markdown; prefer writing durable notes under `brain/<project>/` rather than treating DB rows as canonical writable surface.
- Transcripts & redaction: transcripts are persisted; secret-pattern redaction runs before writing memory. Be cautious when modifying transcript or memory-writing code paths.
- Tests & fixtures: `fixtures/sample-project/` is the golden repo for ingestion tests.
- Watcher behavior: file watching uses FSEvents on macOS with debounced incremental re-ingest — large repo changes must be validated for incremental correctness.
- Session IDs: stable, name-based UUIDv5 derivation; sessions map to persistent conversation IDs across restarts.

---

## 4) Agent-specific notes (Claude / Codex / AntiGravity)

- **Claude**
  - Intended as the pre-briefed engine for workspaces (curated brain context and MCP wiring on start). In the native app this is currently dormant: `EngineLauncher.swift` launches every engine stock because the `omniagent-mcp` helper is not bundled yet. When it is, changing MCP shapes/tool contracts requires updating `crates/mcp-server` and running its contract tests.
  - Implementation touchpoints: `docs/DESIGN.md`, `docs/PLAN.md`, `docs/superpowers/specs`, `docs/superpowers/plans`, `crates/mcp-server/`, `macos/OmniAgent/EngineLauncher.swift`, `macos/OmniAgent.xcodeproj`.

- **Codex**
  - "Stock" engine: spawns without ADE wiring (no pre-brief). The agent-selection UI exposes Codex as an option.
  - Codex-related UI/design references: `docs/ANALYSIS.md` and `design/` assets.

- **AntiGravity**
  - Special-purpose agent (schema/migration oriented in product designs). Treat as a domain specialist — follow repository conventions and run the same tests/build steps as any other agent.

- Agent selection & UI: engine badges (Claude, Codex, AntiGravity, Shell) live in `docs/superpowers` specs and `macos/OmniAgent/EngineLauncher.swift`.
- MCP contract is frozen for v1 — do not change public MCP shapes without running/updating `crates/mcp-server` contract tests and coordinating integrations.
- Keep agent docs synchronized: this file is authoritative; `./scripts/sync-instructions.sh` regenerates `AGENTS.md`, `CLAUDE.md`, `CODEX.md`, `ANTIGRAVITY.md` from it verbatim. Edit this file, then run the sync script — do not hand-edit the generated files (see "Note on file authority" below).

---

## 5) Useful entry points for Copilot suggestions

- `README.md` — quick start, data dir, high-level commands
- `docs/DESIGN.md` — architecture and product constraints (read before large changes)
- `docs/PLAN.md` — phased implementation notes and rough edges
- `crates/*` — core APIs: retrieval, MCP, the PTY daemon and its protocol
- `fixtures/sample-project/` — golden repo for ingestion tests
- `macos/` — native macOS app sources (AppKit/SwiftUI/SwiftTerm), `build.sh` (Xcode test/build/universal), `dist.sh` (sign/notarize/verify), `make-dmg.sh` + `dmg/`

---

Keep changes minimal and prefer explaining intent when suggesting API/contract alterations (MCP, brain storage, ingestion pipeline). When in doubt, reference `docs/DESIGN.md`.

Note on file authority and one-shot edits:
- By default, `.github/copilot-instructions.md` is the authoritative source. The local sync script regenerates agent-specific files from it.
- To promote an agent-specific file as authoritative (for example, after a direct update to `CLAUDE.md`), run:

  `./scripts/sync-instructions.sh CLAUDE.md`

  This will propagate CLAUDE.md's content into the other agent files and update `.github/copilot-instructions.md` so everything stays in sync.


---

Summary of what this file provides:
- Consolidated build/test/lint commands for the Rust workspace and the native macOS app (`macos/build.sh`/`dist.sh`/`rebuild-app.sh`)
- High-level architecture overview and runtime processes
- Repository-specific conventions (MCP contract, commit trailer, memory rules)
- Agent-specific notes (Claude / Codex / AntiGravity)

If you want adjustments (more detail for UI tests, CI hooks, or adding MCP server configs), say which and a branch/PR can be used for review.
