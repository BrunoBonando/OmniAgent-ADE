# Task 6b — Native surface: sidebar, palette, toolbar, notifications, restoration, SwiftUI settings/onboarding/usage/inspectors

Sub-task of plan Task 6 (`docs/plans/native-macos-migration.md`), split for implementer-sized review. Plan bullet:

> Add AppKit sidebar/session outline, command palette, toolbar, notifications, restoration, and SwiftUI-hosted settings/onboarding/usage/inspectors.

**Depends on Task 6a** (must be complete first): read `.superpowers/sdd/native-macos-migration/task-6a-report.md` for the exact `SessionConnection` method names/signatures it added for settings get/set and brain queries — use those, do not re-invent a second routing path.

## What exists today (Task 4-5 native code, and the web/Tauri UI you're porting)

- `macos/OmniAgent/WorkspaceWindowController.swift` and `macos/OmniAgent/PaneWorkspaceView.swift` (Task 5) already own N-pane session lifecycle, focus, drag/drop and the responder-chain command pattern (`@objc` selectors wired through `ApplicationMenus.install()` in `macos/OmniAgent/AppDelegate.swift`) — reuse this pattern for command-palette/toolbar actions and the sidebar's session outline (same pane/session identity model, do not duplicate it).
- `macos/OmniAgent/AppDelegate.swift` currently hardcodes one bootstrap session (`sessionID: "native-terminal"`) — replace this with restoration from the `layout` setting (via Task 6a's settings-get) once this task lands, rebuilding whatever panes/sessions the layout describes on launch.
- **Settings today is a flat key/value table in `brain.db`**, no unified screen. You're consolidating these scattered web-UI surfaces into one SwiftUI settings screen, same setting keys (so settings stay shared/compatible with the web app against the same `brain.db`):
  - `LAYOUT_SETTING_KEY="layout"`, `NOTIFICATIONS_SETTING_KEY`, `REVIEW_MEMORY_SETTING_KEY`, `AUTH_GATE_RESOLVED/SIGNED_IN/PERSONA_SETTING_KEY`, `CLOSED_WORKSPACES_SETTING_KEY`, `FILE_TREE_VISIBLE/WIDTH_SETTING_KEY`, `CODE_REVIEW_WIDTH_SETTING_KEY`, `USAGE_ANALYTICS_SETTING_KEY` (all named in `ui/src/lib/tauri.ts` / `ui/src/state/sessions.ts` / `ui/src/state/usageAnalytics.ts`).
  - Reference React surfaces to replicate (not port pixel-for-pixel — reference for *what each control does*): `ui/src/components/AboutPanel.tsx` (branding/version, auth summary, "Rebuild brain"), `ui/src/components/NotificationsPanel.tsx`, `ui/src/components/ReviewPanel.tsx` (review-memory toggle), `ui/src/components/AccountBadge.tsx` (sign-in/out), `ui/src/components/Sidebar.tsx` / `ProjectMenu.tsx` (per-project default engine, pause/staleness controls), `ui/src/components/FileTree.tsx` (tree width/visibility).
- **Onboarding already exists as two composed flows** — reimplement both in SwiftUI/AppKit against the same persisted keys and the same steps:
  - `ui/src/onboarding/AuthGate.tsx` + `authGateState.ts` — sign-in + one-question persona picker, resolved once.
  - `ui/src/onboarding/FirstRun.tsx` + `onboardingState.ts` — project-root picker → start-ingest → poll ingestion status → live progress.
- **Usage is client-computed analytics, not billing/limits** (there is no billing/quota concept anywhere in this codebase — don't invent one). `ui/src/state/usageAnalytics.ts` tracks per-project counters (sessions/terminals opened, commands submitted, input/output chars, token count, time-in-status, hourly activity) stored via the settings table and derives daily/hourly `UsageInsights`, rendered in `ui/src/components/DashboardOverview.tsx`. Port the aggregation faithfully, or compute client-side in Swift from the same raw counters routed through Task 6a's settings methods — your call, document which you chose and why in the report.
- Sessions/status events your notifications should hook: `SessionConnection`'s `onAttention`/`onStatus`/`onExit` callbacks (already wired per-session in `WorkspaceWindowController.swift` after the Task 5 fix round) — surface these through `UNUserNotificationCenter`, not a custom banner.

## Global constraints that bind this task

- macOS 14 target, AppKit for primary workspace behavior, SwiftUI only for low-frequency surfaces (settings/onboarding/usage/inspectors — exactly what this bullet asks for; sidebar/palette/toolbar/notifications/restoration stay AppKit).
- Do not change public MCP shapes. Do not build a custom terminal renderer.
- Preserve `PersistedTab`, the `layout` setting, maximum eight panes, and current pane repair semantics (Task 5's `PaneGrid`/`syncPaneTree`-equivalent) through restoration.
- Follow TDD for behavior changes.

## Verification

- `./macos/build.sh test`
- `./macos/build.sh build`
- `git diff --check`

Commit all Task 6b work and write `.superpowers/sdd/native-macos-migration/task-6b-report.md`.
