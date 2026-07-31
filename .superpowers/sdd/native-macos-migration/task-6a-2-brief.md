# Task 6a-2 — Route project ingestion/roots operations through the daemon

Follow-up to Task 6a, surfaced by Task 6b's implementer as a blocking dependency for the SwiftUI onboarding/settings/inspector surface (Task 6b-2). Read `.superpowers/sdd/native-macos-migration/task-6b-report.md`'s concerns section for the exact chain of blocked surfaces: onboarding's `FirstRun` flow, `AboutPanel`'s "Rebuild brain", `ProjectMenu`'s pause/re-check/rename, palette brain search, and project labels anywhere in the native UI.

Task 6a wired `list_projects`/`get_context` through the daemon and deliberately deferred `search`, `record_decision`/`record_note`, and everything in `src-tauri/src/roots.rs` (project ingestion, pause, rename, rebuild, staleness) as out of scope. This task closes that gap for the roots/ingestion surface (not `record_decision`/`record_note` — those stay deferred unless a later task needs them).

## What exists today

- `src-tauri/src/roots.rs` (module doc at `:1-45`) owns the entire onboarding/degradation surface as **Tauri-only, in-process** commands: `roots_start_ingest` (`:373`), `ingestion_status` (`:402`, polled ~2s by the frontend), `roots_list` (`:409`), `roots_biggest_project` (`:427`), `add_project`/`add_project_impl` (`:553`/`:501`), `rename_project`/`rename_project_impl` (`:597`/`:567`), `roots_set_paused` (`:625`), `roots_reingest_project` (`:678`), `roots_rebuild` (`:701`), plus `roots_staleness` (referenced in the module doc, degradation surface).
- `IngestionState` (`:173-232`) is a plain `Arc<Mutex<IngestionStatus>>` (`IngestionStatus` at `:143-166`: `running`, `projects_total`, `projects_done`, `current_project`, `total_nodes`, `error`, plus an internal `active_workers` counter deriving `running`). It is Tauri-managed state (`tauri::State<'_, IngestionState>`), constructed once per app process and shared across all commands via Tauri's DI — nothing here is persisted to `brain.db` itself; ingestion progress is transient, in-memory, per-process.
- The actual ingestion work (`brain_ingest::discover_projects`, `ingest_project`) lives in `crates/brain-ingest` already, with no Tauri dependency — `roots.rs` is an orchestration layer on top of it plus `brain_core::Store` reads/writes for persisted bits (`PROJECT_ROOTS_KEY` setting, `ingest_paused:<project>` / `last_ingested:<project>` settings).
- Task 6a already solved an analogous problem for `list_projects`/`get_context` by reusing `mcp_server::tools::call` from the daemon rather than re-deriving the query (`crates/omniagent-pty-daemon/src/server.rs:352-397`) — follow that precedent's *shape* (shared logic, thin dispatch on each side), but `roots.rs`'s logic is not part of `mcp_server::tools` today, so there's no existing shared module to reuse directly; you're extracting one.
- The daemon already resolves the shared `brain_core::Store` at `brain_core::Store::default_data_dir()` (Task 6a's fix, `crates/omniagent-pty-daemon/src/server.rs:54-56,85-86`) — build on that, don't re-solve data-dir resolution.

## Required behavior

- **Extract `roots.rs`'s orchestration logic (ingestion state machine, add/rename/pause/reingest/rebuild/staleness) into a Tauri-independent module** callable by both `src-tauri` (existing Tauri commands become thin wrappers preserving their exact current signatures and behavior — this must be a non-regressing refactor for the web/Tauri app, verified by its existing test suite in `roots.rs`'s `#[cfg(test)]` module continuing to pass unchanged) and `omniagent-pty-daemon` (new message-kind handlers). Where you put it (a new module in `crates/brain-ingest`, a new small crate, or elsewhere) is your call — it must not depend on `tauri` and must be reachable from both call sites without duplicating logic.
- **Add new daemon `MessageKind` values** (append-only, never renumber existing ones — see Task 6a's brief/report for the established pattern and its envelope-validation requirements: 1 MiB cap, malformed-frame rejection, version check, peer-UID check all apply to new kinds by construction, not a side channel) for: start-ingest, ingestion-status (poll), list-projects-with-metadata-if-needed-for-`roots_biggest_project`, add-project, rename-project, set-paused, reingest-project, rebuild, staleness. Group/name them as you see fit; document the final list in your report.
- **Also wire `search`** (`mcp_server::tools`'s already-defined `search_brain` — confirmed present in the six-tool surface by Task 6a's reviewer at `crates/mcp-server/src/tools.rs:340-349` but left unwired) through the same daemon dispatch pattern Task 6a used for `list_projects`/`get_context` — this unblocks the native command palette's brain search, one of the surfaces Task 6b-2 needs.
- **The daemon owns its own `IngestionState` instance**, constructed once at daemon startup, shared across all client connections (mirroring how Tauri's app process owns one today). It is legitimate and expected that the Tauri app and the daemon can each run ingestion independently against the same `brain.db` if both happen to be running — same as Task 6a's precedent of both processes holding independent `Store` connections to one file (WAL-mode safe). Do not attempt cross-process ingestion-state coordination; that's out of scope.
- **Swift client methods** on `SessionConnection` mirroring Task 6a's `getSetting`/`setSetting`/`listProjects`/`getContext` pattern for every new operation, plus a Swift-side ingestion-status poll helper if that fits the existing client shape better than one-shot request/response (your call — document it).
- Preserve exact JSON shapes for anything the web app already depends on (`IngestionStatus`'s Serde shape, project list shape, etc.) — these are read by both processes now, so no field renames/removals.

## Global constraints that bind this task

- Do not change public MCP shapes (`crates/mcp-server`'s dispatch surface stays what it is — you're adding daemon-side wiring to reach it, and adding a new Tauri-independent module for `roots.rs`'s logic, not touching MCP's own contract).
- Reject payloads over 1 MiB, malformed frames, unsupported versions, wrong-user peers — same envelope validation as every existing kind.
- Follow TDD for behavior changes.
- Do not touch `src-tauri`'s existing command *behavior* — only its internals may change (delegating to the extracted module) for the refactor to be safe; its existing tests are the regression guard.

## Verification

- `cargo test -p omniagent-pty-daemon`
- `cargo test -p omniagent-ade --lib` and its integration tests (must show zero regressions in `roots.rs`'s existing test module)
- Whatever new crate/module you extract into gets its own test coverage for the extracted logic, independent of both Tauri and the daemon
- `./macos/build.sh test`
- `./macos/build.sh build`
- `git diff --check`

Commit all Task 6a-2 work and write `.superpowers/sdd/native-macos-migration/task-6a-2-report.md`, including the final list of new message kinds and exactly which `roots.rs` Tauri commands now delegate to the extracted module.
