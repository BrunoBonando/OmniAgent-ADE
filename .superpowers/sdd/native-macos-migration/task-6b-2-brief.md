# Task 6b-2 — Native surface: SwiftUI settings, onboarding, usage, inspectors

Sub-task of plan Task 6 (`docs/plans/native-macos-migration.md`), the SwiftUI half Task 6b-1 deliberately deferred. Plan bullet (the remaining half of it):

> ...and SwiftUI-hosted settings/onboarding/usage/inspectors.

**Read first, in this order:**
1. `.superpowers/sdd/native-macos-migration/task-6b-report.md` — Task 6b-1's report. Its "Proposed Task 6b-2" section (near the end) and "How I scoped the settings/onboarding/usage consolidation" section are this brief's primary source; this brief operationalizes that proposal. It also names the exact setting keys, the web-UI surfaces each screen replicates, and `SettingsKey`/`RestoredPane`/`PaneDescriptor` types already in `macos/OmniAgent/WorkspaceRestoration.swift` you will extend, not duplicate.
2. `.superpowers/sdd/native-macos-migration/task-6a-report.md` — the exact `SessionConnection` method names/signatures for settings and brain-read (`getSetting`, `setSetting`, `listProjects`, `getContext`) and their response types (`BrainProjectSummary`, `BrainContext`, `BrainNodeView`).
3. `.superpowers/sdd/native-macos-migration/task-6a-2-report.md` — the routing table and Swift client methods this task adds: `startIngest`, `ingestionStatus`, `rootsList`, `biggestProject`, `addProject`, `renameProject`, `pausedProjects`, `setPaused`, `staleness`, `reingestProject`, `rebuildBrain`, `search`, plus their response types (`IngestionStatus`, `ProjectStaleness`, `BrainProjectSummary`, `BrainNodeView`).

## What changed since Task 6b-1 scoped this

Task 6b-1's report identified a **blocking dependency**: `FirstRun`'s onboarding flow, `AboutPanel`'s "Rebuild brain", `ProjectMenu`'s pause/re-check/rename, and the palette's brain search all needed `roots_*`/`search_brain` routed through the daemon, which Task 6a had deliberately deferred. **Task 6a-2 closed that gap** — all of the above are now routed and have Swift client methods (see source #3 above). This means Task 6b-2 is **not** limited to 6b-1's reduced scope ("AuthGate only, FirstRun blocked") — build the full surface below, including FirstRun and the project controls.

## What exists today (do not duplicate)

- `macos/OmniAgent/WorkspaceRestoration.swift`'s `SettingsKey` enum has only `layout`/`notifications` declared so far — add the rest of the keys this task reads/writes (see list below), following its existing doc-comment convention (name the exact TypeScript twin each mirrors).
- `macos/OmniAgent/WorkspaceWindowController.swift` / `SessionOutline.swift` (Task 6b-1) own the live pane/session model. The inspector and project controls read from this plus `listProjects`/`getContext` — do not build a second session/project registry.
- `macos/OmniAgent/CommandPalette.swift`'s `CommandPaletteModel` deliberately has no brain-search row (Task 6b-1's doc comment: "the row comes back when the query does"). The query exists now — add the search row back, calling `SessionConnection.search`.
- `macos/OmniAgent/SessionOutline.swift`'s `projectLabel` returns the project **id**, not the label (Task 6b-1 concern #3) — fix this using `listProjects` now that this screen needs the project list anyway; don't leave two different "get project info" paths.
- Reference React surfaces (for *what each control does*, not pixel-for-pixel porting): `ui/src/components/AboutPanel.tsx`, `NotificationsPanel.tsx`, `ReviewPanel.tsx`, `AccountBadge.tsx`+`state/accountBadgeState.ts`, `Sidebar.tsx`/`ProjectMenu.tsx`, `FileTree.tsx`, `state/usageAnalytics.ts`, `components/DashboardOverview.tsx`, `onboarding/AuthGate.tsx`+`authGateState.ts`, `onboarding/FirstRun.tsx`+`onboardingState.ts`.

## Required behavior

Build all of the following (Task 6b-1's proposed dependency order — follow it, each layer builds on the previous):

1. **`SettingsStore`** — a typed facade over `SessionConnection.getSetting`/`setSetting` behind an injectable protocol (so screens are testable without a socket), plus the remaining `SettingsKey` constants: `NOTIFICATIONS_SETTING_KEY` (already declared), `REVIEW_MEMORY_SETTING_KEY`, `AUTH_GATE_RESOLVED/SIGNED_IN/PERSONA_SETTING_KEY`, `CLOSED_WORKSPACES_SETTING_KEY`, `FILE_TREE_VISIBLE/WIDTH_SETTING_KEY`, `CODE_REVIEW_WIDTH_SETTING_KEY`, `USAGE_ANALYTICS_SETTING_KEY` (exact key strings are in `ui/src/lib/tauri.ts` / `ui/src/state/sessions.ts` / `ui/src/state/usageAnalytics.ts` — copy them verbatim, settings must stay shared/compatible with the web app against the same `brain.db`).
2. **SwiftUI settings screen** (`NSHostingController`-hosted, reachable from the toolbar/menu — your call where, document it): sections *Account* (sign in/out + persona, mirroring `accountBadgeState.ts`'s honest-placeholder convention), *Notifications* (surface Task 6b-1's `NotificationFeed`, clear/mark-read), *Review* (`review_memory` toggle), *Panels* (`file_tree_width`, `code_review_width`), *About* (bundle version, tagline, **and now-unblocked "Rebuild brain"** via `SessionConnection.rebuildBrain`).
3. **Usage** — port `ui/src/state/usageAnalytics.ts` faithfully (per 6b-1's own recommendation): the store shape (`usage_analytics_v1`: `{version, projects: {totals, days, hourActivityMs, updatedAt}}`), `record*` functions fed from `SessionConnection`'s existing status/attention/exit callbacks, `nextHourBoundary`'s hour-splitting, the `__all__` global-project fan-out, `deriveUsageInsights`, `parseTokenEstimateMax`. A SwiftUI readout of `DashboardOverview.tsx`'s numbers (daily/hourly activity, totals). This is client-computed analytics, not billing/limits — there is no quota concept anywhere in this codebase; don't invent one.
4. **Inspector** — a per-pane/per-project brain-context panel over `listProjects`/`getContext`, and (now unblocked) `staleness`/`reingestProject`/`setPaused` for `ProjectMenu`'s per-project pause/re-check controls. Fix `SessionOutline.projectLabel` to use `listProjects`' returned label instead of the raw id here (this is the natural place, per 6b-1 concern #3).
5. **Onboarding — AuthGate**: port `authGateReducer`, the sign-in step, and the one-question persona picker, resolved once via the three auth keys.
6. **Onboarding — FirstRun** (now unblocked): project-root picker (`NSOpenPanel`) → `SessionConnection.startIngest` → poll `SessionConnection.ingestionStatus` → live progress UI → `SessionConnection.biggestProject`, mirroring `onboarding/FirstRun.tsx` + `onboardingState.ts`'s steps.
7. **Command palette brain search**: add the search row back to `CommandPaletteModel` using `SessionConnection.search`, per Task 6b-1's own note that it should return once the query exists.

## Global constraints that bind this task

- macOS 14 target, AppKit for primary workspace behavior — this task's surfaces are exactly the SwiftUI-appropriate ones (settings/onboarding/usage/inspectors); do not build sidebar/palette/toolbar/notifications/restoration changes beyond the two named above (palette search row, project label fix) — those are Task 6b-1's domain and are done.
- Do not change public MCP shapes. Do not build a custom terminal renderer.
- Every setting read/written must use the **exact key strings** the web app uses (see list above) — no renames, this data is shared with the web/Tauri build against the same `brain.db`.
- Follow TDD for behavior changes.
- Reuse `SessionConnection`'s existing completion-handler pattern (`(Result<T, Error>) -> Void`) for every new call site — do not invent a second async style (e.g. don't introduce Combine/async-await wrappers unless `SessionConnection` itself already exposes one).

## Verification

- `./macos/build.sh test`
- `./macos/build.sh build`
- `git diff --check`

Commit all Task 6b-2 work and write `.superpowers/sdd/native-macos-migration/task-6b-2-report.md`.
