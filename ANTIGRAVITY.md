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
- `./macos/dist.sh preflight <path-to-OmniAgent.app> [--mas]` is the store-readiness gate: it checks the signed bundle for what App Review and notarization actually look at — app/daemon Team ID match, daemon hardened runtime, no `get-task-allow` debug entitlement, `PrivacyInfo.xcprivacy`, the required `Info.plist` keys (`LSApplicationCategoryType`, `NSHumanReadableCopyright`, `ITSAppUsesNonExemptEncryption`, the three folder-usage descriptions), a bundle-relative LaunchAgent `Program`, and the bundled Legal pages. Developer-ID facts fail the run (non-zero exit); the MAS-only gaps (app sandbox entitlement, the unsandboxed `~/.omniagent-ade` socket path, no MAS build lane) only print as `MAS-GATE` by default since the sandbox is absent by decision (`docs/appstore-rejection-risks.html`) — pass `--mas` to fail on those too.
- `dist.sh sign` falls back to the keychain's sole "Developer ID Application" identity when `OMNIAGENT_CODESIGN_IDENTITY` is unset (and still fails clearly when there is none, or more than one). This is not cosmetic: macOS keys TCC folder-access grants to the code-signing identity, and an ad-hoc/linker-signed bundle's identity is effectively its cdhash — which changes every build, so an unsigned rebuild re-prompts for Documents access every single time.
- A **disk image must be signed as well as notarized**, and nothing warns you otherwise: `stapler staple` reports success on an unsigned `.dmg` and notarization accepts it, because both judge the app inside. Only `spctl -a -t open --context context:primary-signature` catches it, as `source=no usable signature`. `dist.sh notarize` therefore signs a `.dmg` before submitting, and asks Gatekeeper afterwards rather than trusting `stapler`'s exit code.
- `scripts/rebuild-app.sh` runs the whole pipeline in the order that matters — build → sign app → notarize+staple app → DMG → sign+notarize+staple DMG → install — because a DMG built before the app is stapled ships an app with no ticket. It notarizes when `OMNIAGENT_NOTARY_PROFILE` is set, says so plainly when it is not, and takes `--no-notarize` to skip the two Apple round-trips for the fast local loop (notarization buys nothing for a `ditto` install, which carries no quarantine flag). It quits a running `/Applications/OmniAgent.app` before replacing it, **and stops the PTY daemon with it** (standing decision, 2026-08-17). The daemon outlives the app by design, and this script used to leave it up for that reason — but it is a binary *inside the bundle being replaced*, so leaving it running meant every install silently kept the old daemon: daemon-side changes (agent status detection, `MAX_SESSIONS`) looked shipped and were not, with the surviving process running from an unlinked inode. This ends live terminal sessions; `--keep-daemon` opts out for a rebuild that changes nothing daemon-side. The app respawns the daemon on launch whenever nothing is listening on the socket (`DaemonPersistence.shouldSpawn`).
- `scripts/bump-build-version.sh` bumps the sequential `MAJOR.MINOR.PATCH` version in the Xcode project — the only place the version lives now. No flag bumps the patch (a deploy: `1.6.234` → `1.6.235`); `--minor` bumps minor and resets patch to 1 (`1.6.234` → `1.7.1`); `--major` bumps major and resets minor+patch. `rebuild-app.sh` runs it (patch bump) by itself; never bump by hand first — for a minor/major release, run `./scripts/bump-build-version.sh --minor` (or `--major`) before `rebuild-app.sh`.
- `scripts/publish-release.sh` publishes a built DMG to `dl.omni-agent.ai` as a **Sparkle release**: it EdDSA-signs the image, regenerates `appcast.xml`, uploads both (DMG first -- a feed pointing at a file still uploading is a broken update for anyone who checks in between), and then asks the *public* URL what it is actually serving. That last check exists because Cloudflare caches `appcast.xml`: an overwritten feed can keep serving the old copy from the edge, during which the release exists, is downloadable, and is invisible to every app checking for it. Sparkle's own no-cache policy defeats only the client's URL cache, not the edge -- the permanent fix is a Cloudflare Cache Rule bypassing `/releases/appcast.xml`. Needs `OMNIAGENT_DL_AUTH` (`user:password`) and the LAN; the upload host is internal-only. Sparkle's `generate_appcast`/`generate_keys` are expected at `~/.local/share/sparkle/bin`.
- The DMG background assets `make-dmg.sh` uses live in `macos/dmg/`.

---

## 2) High-level architecture (big picture)

- Monorepo: Rust/Cargo workspace + a native macOS app:
  - `crates/brain-core` — SQLite + FTS5 storage and retrieval
  - `crates/brain-ingest` — repository walker, tree-sitter parsing, ingestion, enrichment
  - `crates/mcp-server` — frozen MCP contract, stdio/local server component and contract tests. Its lib is a dependency of the daemon; the `omniagent-mcp` binary is not yet bundled with the native app (`EngineLauncher.swift` launches agents stock until it is)
  - `crates/omniagent-pty-daemon` — the persistent PTY daemon: sole owner of real PTYs/child processes, versioned socket protocol the native app speaks (`SessionConnection.swift`)
    - **Remote session control** (`docs/superpowers/specs/2026-08-30-remote-session-control-design.md`): `src/relay.rs` holds one outbound control WebSocket to `relay.omni-agent.ai` (staging `relay.omni-agent.dev`) while the `remote_control` settings row lists ≥ 1 workspace — idle enabled workspaces, whose `sessions` array is empty, keep the machine reachable (`remote_control_active`, `src/server.rs`) — **and** a `relay_device_token` row exists. The relay opens one data WebSocket per viewer, over which the ordinary per-connection handler runs as `serve_client(…, ClientTrust::Remote)` — the relay never parses frames, so `PROTOCOL_VERSION` and the daemon protocol are unchanged. Remote clients are confined to an allowlist in `authorize_remote` (`src/server.rs`): `Hello`, `ListSessions` (filtered to the projection), `Attach`, `Input`, `Interrupt`, `Detach`, `GetSetting("remote_control")` — each session-bound frame’s id re-checked against the projection, everything else answered with `Error`. `Resize` is **not** on it: the host owns the grid and a viewer scales the host's size to fit its own window (phase 2 §1, `docs/superpowers/specs/2026-08-31-remote-session-control-phase-2-design.md`), so the daemon tells viewers the size with `SessionResized` rather than letting them set it. The relay service itself lives in `OmniAgent-Core/omniagent/relay/` (a dumb byte pipe; device registry in the `relay_devices` table), fronted by the BDN edge nginx. The four settings rows `remote_control`, `remote_control_workspaces`, `relay_device_token` and `remote_control_blocked` (the kicked viewer ids — the daemon appends on a kick so it holds with the app closed, the app clears the row when sharing is switched back on) are a JSON contract between Swift (writer) and Rust (reader) — snake_case keys, exact shapes in the spec and `SettingsKeys.swift`; never rename on one side alone.
  - `macos/` — native macOS app (`OmniAgent.xcodeproj`): AppKit primary workspace, SwiftUI for low-frequency surfaces (settings/onboarding/usage/inspectors), SwiftTerm for terminals; see "Native macOS app (macos/)" above
    - **Self-update** (`docs/superpowers/specs/2026-09-01-self-update-design.md`): Sparkle 2.x drives the cycle against `https://dl.omni-agent.ai/releases/appcast.xml` (`SUFeedURL`/`SUPublicEDKey` in `Info.plist`), but none of Sparkle's own windows ever appear — `UpdateController.swift` is the app's own `SPUUserDriver`, and it **holds** Sparkle's reply blocks rather than answering them, which is what turns a sequence of modal dialogs into one strip the user advances at their own pace. One `UpdateState` feeds every surface: the sidebar card at the foot of the column, directly above the session/week limits card and in the same liquid glass (`SidebarUpdateWidget.swift`), Settings › General, the OmniAgent menu, Home's pill and three spotlight rows. **The daemon is the part that breaks silently:** the bundle being replaced holds the running PTY daemon, so an update that leaves it up keeps talking to the old one from an unlinked inode — exactly what `rebuild-app.sh` exists to prevent for installs. `shouldPostponeRelaunchForUpdate` stops it; consent is taken *earlier*, in `confirmRestart` (the house ask when sessions are live), because once Sparkle is ready to relaunch the swap has already happened and there is no longer a "no" to offer. `Sparkle.framework` embeds four independently loadable helpers (`Autoupdate`, `Updater.app`, two XPC services) that `dist.sh sign` signs inner-out — never with `codesign --deep` — and `dist.sh preflight` checks for Team ID and hardened runtime.
    - Editor panes: `PaneKind.editor` is a tabbed code editor whose internals are Monaco running in a `WKWebView` (vendored under `macos/OmniAgent/Resources/monaco/`) — the one scoped exception to the native-only rule, permitted for the editor pane's internals and nowhere else — with its open/pinned tabs persisted to the native-only `editor_panes_native` settings row rather than the shared `layout` row.
- Runtime: the native macOS app (UI), a persistent `omniagent-pty-daemon` process, a graph ingest process, and an MCP server process; they share retrieval crates and storage layers.
- Storage: SQLite "brain" DB (rebuildable) + durable Markdown memory under a **data root**, `~/Library/Application Support/OmniAgent-ADE/` — override the root with `OMNIAGENT_ADE_DATA_DIR`. The root is per-account (`docs/superpowers/specs/2026-08-30-account-scoped-workspace-design.md`): it holds a pointer file `current-account` naming the signed-in account (`<id>` = first 16 hex of SHA-256 of the lower-cased, trimmed email — `Store::account_dir_id` / `AccountDirectory.accountID(forEmail:)`), and while the pointer exists every crate and the app resolve the data dir to `<root>/accounts/<id>/` (`brain_core::Store::default_data_dir()`, `macos/OmniAgent/AccountDirectory.swift`); absent or blank, the root itself (signed out). The daemon reads the pointer **once at startup**, so switching accounts is a daemon restart (`WorkspaceWindowController.switchAccount`); on the first start into an account dir it moves a pre-account install's `brain.db`/`brain/`/`transcripts/` there (`Store::adopt_legacy_data`). The app writes and removes the pointer and never moves files or creates `accounts/`.
- **Never kill a busy daemon on your own** (standing rule, 2026-08-30): the app ends the daemon only after the user confirms in the house modal when it has running sessions (`switchAccount` / `logOutOfAccount`, via `DaemonPersistenceController.terminateDaemon` with the pid off the socket's `LOCAL_PEERPID`), and a developer never terminates the running production daemon to test this — use `scripts/rebuild-app.sh --keep-daemon`, targeted `xcodebuild test … -only-testing:` runs with fake terminators, and the Preview configuration (bundle id `digital.bruno.omniagent.preview`, own socket + data dir) for end-to-end checks.
- **Native macOS migration** (`docs/plans/native-macos-migration.md`) is complete. The native app is the only artifact Bruno builds and runs (standing decision, 2026-08-03; reconfirmed 2026-08-10, "it all must be native macOS"). The Task 7 "cutover" gate (`scripts/cutover.sh`) that guarded the deletion of the web terminal hot path was retired along with the web app itself on 2026-08-30 by Bruno's explicit decision — there is no rollback Tauri build.
- Settings rows written by the old web build (the shared `layout` row, etc.) may still exist on users' disks; `fixtures/native-macos-compat/` and `NativeMacosCompatibilityFixtureTests.swift`/`PaneGridTests.swift` pin the formats the native app must keep reading.

See `docs/DESIGN.md` and `docs/PLAN.md` for architecture and product principles.

---

## 3) Key repository conventions and patterns

- Cargo workspace: root `Cargo.toml` lists members; prefer workspace-level builds/tests for cross-crate changes.
- **Spotlight finds everything** (standing rule, 2026-08-28): every navigable thing in the native app — destinations (Home, To Do List, Desk, Settings), workspaces, sessions, panes, editor files, Settings sections and, as they are built, the items *inside* them — must be a row in the spotlight (`macos/OmniAgent/CommandPalette.swift`, `CommandPaletteModel.build`) the day it lands, with its own symbol, a subtitle naming where it lives, `keywords` for what a user would type, an action `WorkspaceWindowController.run(_:)` dispatches, and a `CommandPaletteTests` test that the rows exist. Build rows off `allCases`/live lists so later additions appear without anyone remembering this.
- **Remote access is deny-by-default**: any new protocol message kind or settings key that a *remote* client should be able to reach must be added to `authorize_remote` in `crates/omniagent-pty-daemon/src/server.rs` deliberately, with a `tests/remote_authz.rs` case — nothing becomes remote-reachable merely by being added to the dispatch. The app-side viewer surfaces (the per-machine sidebar sections, the `remote:` palette rows) are navigable things, so they follow the “Spotlight finds everything” rule above.
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
  - Implementation touchpoints: `docs/DESIGN.md`, `docs/PLAN.md`, `docs/superpowers/specs`, `docs/superpowers/plans`, `crates/mcp-server/`, `macos/OmniAgent/EngineLauncher.swift`, `macos/OmniAgent.xcodeproj`. For remote session control (daemon relay, `ClientTrust::Remote` allowlist, the relay service in `OmniAgent-Core`, viewer UI and predictive echo) the reference is `docs/superpowers/specs/2026-08-30-remote-session-control-design.md`.

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
