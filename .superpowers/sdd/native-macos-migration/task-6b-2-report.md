# Task 6b-2 report — Native surface: SwiftUI settings, onboarding, usage, inspectors

Branch: `codex/native-macos-migration-progress`. Base commit: `a91836f`. Worked directly in the repo checkout (not an isolated worktree), per the task brief. Diff is entirely under `macos/` (`git diff --name-only` against the base returns nothing outside it) — no Rust, no TypeScript, no `crates/mcp-server`.

**Status: all seven pieces the brief named are built, wired, and tested: `SettingsStore`, the settings screen, usage, the inspector, `AuthGate`, `FirstRun`, and the palette's brain-search row.**

---

## What was built

Dependency order, as the brief specified.

### 1. `SettingsStore` — `SettingsStore.swift`, `BrainClients.swift`, `SettingsKeys.swift`

- **`SettingsClient`** protocol (`getSetting`/`setSetting`, matching `SessionConnection`'s existing Task 6a signatures exactly) + a blank `extension SessionConnection: SettingsClient {}` conformance — the same injectable-seam shape `NotificationDelivering` already gives `SessionNotifier`.
- **`SettingsStore`** — thin facade: `get`/`set` pass through to the client; `getBool`/`setBool` centralize the `"true"`/anything-else convention `review_memory` uses (default supplied per call site, since `auth_gate_resolved`'s "only 'true' counts" and `auth_signed_in`'s "only 'false' counts" are *different* conventions that a single generic bool reader can't both express — those two stay in `AuthGate`'s own pure functions, see below).
- **`BrainClients.swift`** — three more injectable protocols narrowing `SessionConnection`'s Task 6a-2 surface for the remaining screens: `BrainAdminClient` (`listProjects`/`getContext`/`staleness`/`pausedProjects`/`setPaused`/`reingestProject`/`renameProject`/`rebuildBrain` — the inspector + About's rebuild), `IngestionClient` (`startIngest`/`ingestionStatus`/`biggestProject`/`rootsList` — FirstRun), `BrainSearchClient` (`search` — the palette). All three are blank `extension SessionConnection: ...` conformances; `SessionConnection` itself needed zero changes.
- **`SettingsKeys.swift`** — added every remaining key the brief named, copied verbatim from `ui/src/lib/tauri.ts`/`ui/src/onboarding/authGateState.ts`/`ui/src/state/usageAnalytics.ts`: `reviewMemory`, `authGateResolved`/`authSignedIn`/`authPersona`, `closedWorkspaces`, `fileTreeVisible`/`fileTreeWidth`, `codeReviewWidth`, `usageAnalytics`. Two of these (`closedWorkspaces`, `fileTreeVisible`) are declared but not consumed by this build — see Concerns.

### 2. SwiftUI settings screen — `SettingsView.swift`

`NSHostingController`-hosted in a standalone `NSWindow` (not a sheet — Settings is a destination, not a gate), reachable via the OmniAgent application menu's **Settings…** (⌘,), which travels the responder chain like every other command in this app (`Selector(("showSettings:"))`, same convention `toggleSidebar:`/`newSession:` already use — none of these are `#selector`-checkable across files without a shared protocol, which is why the existing code already accepts the resulting warning; not new to this task).

Five sections + the Usage readout, each a thin `TabView` tab over one `SettingsViewModel`:
- **Account** — sign in/out + the captured persona, mirroring `accountBadgeState.ts`'s honest-placeholder convention (`AuthGate.describeAuthSummary`). "Sign in" re-presents the same `AuthGateView` flow (not a second implementation); "Log out" calls `AuthGateCoordinator.reset` directly, matching the web's instant log-out.
- **Notifications** — a snapshot of `SessionNotifier.entries` (mark-all-read, clear-all). Deliberately a snapshot-on-open rather than a live subscription: `SessionNotifier.onEntriesChanged` already has exactly one subscriber (`WorkspaceWindowController`, for persistence), and Settings is a transient window, not the live notification surface AppKit's own toast/badge already own.
- **Review** — the `review_memory` toggle, copy ported from `ReviewPanel.tsx`'s two hint strings.
- **Panels** — `file_tree_width`/`code_review_width`, plain numeric text fields. (No native file tree/code-review panel exists yet to *observe* these widths — the fields exist so a value set on the web side round-trips, and vice versa, against the same `brain.db` row.)
- **About** — bundle version (`CFBundleShortVersionString`, mirroring `aboutVersionLine`'s shape), the tagline, and the now-unblocked **Rebuild brain** (confirm → `SessionConnection.rebuildBrain`).
- **Usage** — embeds `UsageView` (below) as a sixth tab, rather than a separate window/menu entry, to keep the surface count minimal.

### 3. Usage — `UsageAnalytics.swift`, `UsageAnalyticsRecorder.swift`, `UsageView.swift`

- **`UsageAnalytics.swift`** — a faithful, field-for-field port of `ui/src/state/usageAnalytics.ts`: `UsageBucket`/`UsageProjectAnalytics`/`UsageAnalyticsStore` (every field `Double`, matching the oracle's untyped `number` — JSON doesn't distinguish int/float either, and it sidesteps an Int/Double split the TypeScript source never has), every `record*` mutator, `nextHourBoundary`'s hour-splitting (`recordStatusDuration` walks `[fromTs, toTs)` one hour-chunk at a time, exactly as the oracle does), the `__all__` global-project fan-out (`touch`/`GLOBAL_USAGE_PROJECT`), `deriveUsageInsights`, and `parseTokenEstimateMax` (three regex phrasings, ported to `NSRegularExpression`). `UsageAnalyticsCodec` (JSON in/out) follows the same `JSONSerialization`-based, one-malformed-field-costs-only-itself convention as `PersistedLayoutCodec`/`NotificationFeedCodec`.
- **`UsageAnalyticsRecorder.swift`** — the stateful shell. Fed from exactly the callback set the brief named (`SessionConnection`'s status/exit path, via `WorkspaceWindowController`) plus the pane-creation call site: `recordPaneOpened` (terminal + first-time-per-group session), `recordStatus` (flushes the *previous* status's duration on every transition — nothing to flush on a session's first-ever status), `recordExit` (flushes whatever status was last tracked). `recordInput`/`recordOutput`/`recordTokens` are ported in `UsageAnalytics.swift` (faithfully, tested) but **not wired to a live byte stream** — see Concerns.
- **`UsageView.swift`** — `DashboardOverview.tsx`'s numbers (totals, a 14-day active-hours bar chart, a 24-slot hourly histogram with the best hour highlighted), not that component's full dashboard (working-now list, git status, contribution pie, …) — this is client-computed analytics behind a settings-adjacent tab, not the workspace's primary view. A project picker (`UsageViewModel`, backed by `listProjects`) switches between `__all__` and any known project.

### 4. Inspector — `InspectorView.swift`, plus the project-label fix

- **`InspectorViewModel`** — one project's `getContext` briefing (summary/recent decisions/memory notes/related projects) plus `ProjectMenu.tsx`'s pause/re-check/rename controls, now unblocked by Task 6a-2's `roots_*` routing: `togglePause` (optimistic, reverted on failure, same shape as `ReviewPanel.tsx`'s `toggleReviewMode`), `reingest` (re-checks then reloads), `rename` (blank/unchanged guarded, matching `ProjectMenu.tsx`'s `commitRename`).
- **`InspectorWindowController`** — an `NSPanel`, reachable via the Window menu's **Show Inspector** (⌘I), scoped to the focused pane's project; rebuilt fresh every time it's asked to show a project (same "never stale" contract `CommandPaletteController.present` already keeps), and refreshed automatically when focus moves to a pane in a *different* project while the panel is open.
- **The project-label fix (6b-1 concern #3, one of the brief's two named palette/outline exceptions):** `SessionOutline.projectLabel(_:labels:)` now takes an id → label cache and prefers it over the raw id. `WorkspaceWindowController.projectLabels` is that one shared cache (`refreshProjectLabels()`, fed by `listProjects`, refreshed on every connect — read-only, so unlike the `layout` row there's no "read once" guard needed). `SessionOutlineView.reload` and `CommandPaletteModel.build` both now thread it through, so the outline, the palette's "Switch to …" rows, and the inspector's title all read the same label from the same read — not three lookup paths.

### 5. Onboarding — AuthGate — `AuthGateState.swift`, `AuthGateView.swift`

- **`AuthGateState.swift`** (pure) — `AuthGatePhase`/`AuthGateOutcome`/`AuthGateState`/`AuthGateReducer`, a direct port of `authGateReducer`; `AuthGate` enum holds the persona list, `fakeAccountName`, `alreadyResolved`/`resolveSignedIn` (the two *different*, intentionally asymmetric "what counts as X" conventions), and `describeAuthSummary`.
- **`AuthGateView.swift`** — `AuthGateViewModel` (dispatches actions, republishes for SwiftUI, calls `onResolved` once); `AuthGateContentView` (the login step + the one-question persona picker, styled to the workspace's own dark palette via a small shared `OmniAgentPalette` enum); `AuthGateCoordinator` (the I/O half — `needsPresenting`/`resolve`/`reset`/`summary`, entirely testable against a fake `SettingsClient`); `AuthGateWindowController` (presents as a sheet on the workspace window — the native shape of the web's `overlay-backdrop`, which AppKit has no equivalent of).
- Presented automatically once per launch, before FirstRun, from `WorkspaceWindowController.start()`'s `.connected` handler — mirroring `App.tsx`'s boot-effect ordering (`needsAuthGate` resolves before `needsOnboarding` is allowed to render anything).

### 6. Onboarding — FirstRun — `OnboardingState.swift`, `FirstRunView.swift`

- **`OnboardingState.swift`** (pure) — `OnboardingPhase`/`OnboardingState`/`OnboardingReducer`, a direct port of `onboardingReducer` including the `everRunning` guard against a not-yet-started `{running: false}` snapshot reading as "already done."
- **`FirstRunView.swift`** — `FirstRunViewModel` (an injectable `folderChooser` closure — same seam shape as `WorkspaceWindowController.directoryChooser` — drives `startIngest` → dispatches `.rootPicked` → polls `ingestionStatus` on an injectable interval, folding every poll through the reducer, fetching `biggestProject` once `projects_total > 0` and the phase reaches `.done`); `FirstRunContentView` (pick/ingesting/done, matching `FirstRun.tsx`'s three phases and its warp-style progress meter); `FirstRunWindowController` (the `NSOpenPanel`, the sheet, and `needsPresenting` — `rootsList().isEmpty`, mirroring `App.tsx`'s `needsOnboarding`, failing open on a read error).
- Presented once per launch, after the auth gate resolves. "Open terminal in *biggest*" calls the existing `startSession(inDirectory:project:)`. "Skip for now" is session-only (not persisted), matching the web's own in-memory `firstRunDismissed`.
- **Import from other tools** (`ImportProjectsFlow` in `FirstRun.tsx`) was **not** ported — it isn't part of `onboardingState.ts`'s reducer (the web component itself keeps it as a separate local `importOpen` flag with its own Tauri commands `detect_importable_tools`/`list_import_candidates`, none of which Task 6a/6a-2 routed through the daemon), and the brief's reading list scopes this task to the ingest flow. Named explicitly here rather than silently dropped.

### 7. Command palette brain search — `CommandPalette.swift`, `WorkspaceWindowController.swift`

- `PaletteAction` gained three cases: `.searchBrain(query:)`, `.revealProjectContext(project:)`, `.noop`.
- `CommandPaletteModel.matches` now appends a synthetic "Search brain for "…"" row whenever the trimmed query is non-empty — present even when it's the *only* row (a query matching no action still offers something), matching the web palette's own always-offered search row. `CommandPaletteModel.build` also gained an optional `projectLabels` parameter (see item 4).
- `WorkspaceWindowController.run(_:)` runs `.searchBrain` by calling `connection.search`, then re-presents the *same* palette panel with the hits as rows (the native shape of the web palette's `searchResults` view swapping in for the action list) — each hit's row runs `.revealProjectContext`, which opens the inspector on that hit's project (the closest real "go look at this" action available without a map/graph view; a documented, deliberate choice, not a fake one). Zero hits still presents one row: "No matches…", action `.noop`.

---

## TDD evidence

Representative RED → GREEN pairs (every behavioral file was written test-first or test-alongside; the full list is in the test files themselves):

- **`UsageAnalytics.recordStatusDuration`'s hour-splitting** — `testStatusDurationSplitsAtEveryHourBoundaryItCrosses` written against the empty `UsageAnalytics` enum first; failed (`recordStatusDuration` didn't exist), then failed again (10/20-minute split wrong) until the `nextHourBoundary`-driven `while cursor < toTs` loop matched the TS oracle exactly.
- **`AuthGateReducer`** — `testActionsThatDoNotMatchThePhaseAreIgnored` (a resolved gate can't be reopened; a login-phase action can't be answered from personalize) failed against a first-draft reducer that didn't guard `state.phase` per case, exactly mirroring `authGateReducer`'s own per-case guards.
- **`CommandPaletteModel`'s search row** — `testAQueryThatMatchesNoActionStillOffersTheSearchBrainRow` replaced the old (now-incorrect) `testAQueryThatMatchesNothingSelectsNothingRatherThanTheWrongRow`; it failed against the pre-6b-2 `matches` (empty list) until `matches` grew the trailing synthetic row.
- **`InspectorViewModel.togglePause`'s optimistic revert** — `testTogglePauseIsOptimisticAndRevertsOnFailure` failed (state stuck at the optimistic flip) until the completion handler's `if case .failure` branch reverted it.
- **The async-hop bug this task's own review caught**: `SettingsViewModelTests.testInitLoadsAccountReviewAndPanelsFromSettings`/`testSignOutResetsTheAuthGateAndRefreshesTheSummary` failed (`authSummary` stuck at `"Loading…"`) against `AuthGateCoordinator.summary`/`persist` implementations that batched their reads/writes behind `DispatchGroup.notify(queue: .main)` — which always hops a run-loop turn, even against a synchronous fake client with nothing left to wait for. Fixed by chaining two/three single-key calls directly instead of batching; both tests then passed without adding `wait(for:)` anywhere (see Concerns for why this was the right fix, not a workaround).

## Test results

`./macos/build.sh build` — `** BUILD SUCCEEDED **`, zero new warnings (the pre-existing `AppDelegate.swift`/`SessionOutlineView.swift` warnings this task's own new menu items also produce — `Selector(("showSettings:"))`/`Selector(("showInspectorPanel:"))` — are the same deliberate, already-warned-about cross-file selector pattern every other responder-chain command in this file uses, not new noise).

`./macos/build.sh test`:

```
274 unique test cases, 0 failed individually.
```

One suite-level `** TEST FAILED **` designation, caused entirely by a **pre-existing, documented flake**: `WorkspaceWindowControllerTests.testCommandOptionOIsClaimedByMenuBeforeSwiftTermKittyKeyDown` (a real-window/modal-session test) crashes the test host under full-suite load, exactly as task-6a-2's report already recorded ("a real-window/modal-session test, pre-existing, untouched by this task's diff... environment-timing flakiness, not a regression"). Reproduced identically across three consecutive full-suite runs in this session; confirmed passing in isolation every time (`-only-testing:...testCommandOptionOIsClaimedByMenuBeforeSwiftTermKittyKeyDown`, 0.067s). This task's diff never touches that test, `TerminalSurfaceView.swift`, or the Option-as-Meta menu item — nothing in the 6b-2 diff plausibly causes it, and it was already flagged before this task started.

New suites, all green (exact counts from the final run's per-test-case tally): `SettingsStoreTests` (4), `AuthGateStateTests` (9), `AuthGateCoordinatorTests` (5), `AuthGateViewModelTests` (2), `OnboardingStateTests` (7), `FirstRunViewModelTests` (6) + `FirstRunWindowControllerTests` (2), `UsageAnalyticsTests` (16), `UsageAnalyticsRecorderTests` (8), `UsageViewModelTests` (2), `InspectorViewModelTests` (5), `SettingsViewModelTests` (7), `WorkspaceWindowControllerTask6b2Tests` (4). Plus extended coverage in `CommandPaletteTests` (now 15, up from 12: the search row, the project-label cache) and the untouched pre-6b-2 suites (unaffected — `SessionOutlineTests`' `projectLabel("")`/`projectLabel("alpha")` calls still pass against the new default-`[:]` `labels` parameter). `WorkspaceWindowControllerTests.swift` (the pre-existing file) was **not edited** by this task — its own 27 test cases are all pre-existing, exercised here only as part of the full-suite run.

`git diff --check` — clean, no whitespace errors.

## Files changed

New (`macos/OmniAgent/`): `SettingsStore.swift`, `BrainClients.swift`, `SettingsView.swift`, `AuthGateState.swift`, `AuthGateView.swift`, `OnboardingState.swift`, `FirstRunView.swift`, `UsageAnalytics.swift`, `UsageAnalyticsRecorder.swift`, `UsageView.swift`, `InspectorView.swift`.

New (`macos/OmniAgentTests/`): `SettingsStoreTests.swift`, `AuthGateStateTests.swift`, `AuthGateCoordinatorTests.swift`, `OnboardingStateTests.swift`, `FirstRunViewModelTests.swift`, `UsageAnalyticsTests.swift`, `UsageAnalyticsRecorderTests.swift`, `BrainAdminClientTestDouble.swift`, `InspectorViewModelTests.swift`, `UsageViewModelTests.swift`, `SettingsViewModelTests.swift`, `WorkspaceWindowControllerTask6b2Tests.swift`.

Edited: `SettingsKeys.swift` (the remaining key constants), `WorkspaceWindowController.swift` (wiring for all seven pieces: settings/inspector/auth-gate/first-run entry points, usage recording at pane-open/status/exit, project-label refresh, palette-search dispatch), `CommandPalette.swift` (the search row, `projectLabels` threading), `SessionOutline.swift`/`SessionOutlineView.swift` (the label fix), `AppDelegate.swift` (the two new menu items), `CommandPaletteTests.swift` (two tests updated for the new search row, one added).

`macos/OmniAgent.xcodeproj/project.pbxproj` — edited by script (no synchronized file-system group; 23 new files needed explicit `PBXBuildFile`/`PBXFileReference`/group/`Sources`-phase entries), same approach Task 6a/6b-1 used. The script lives in the session scratchpad, not the repo. Verified with `plutil -lint` and `xcodebuild -list` before building.

---

## Self-review findings (fixed before this report)

1. **A real `?? nil`-on-an-already-flattened-optional warning** (`SettingsStore.swift`, plus copies of the same pattern in `AuthGateView.swift`/`SettingsView.swift`): `try? result.get()` on a `Result<String?, Error>` already flattens to `String?` (SE-0230), so `(try? result.get()) ?? nil` is a no-op the compiler correctly flagged. Fixed at every occurrence.
2. **The async-hop bug** described under TDD evidence above — caught by my own tests, not by inspection. Fixed by chaining single-key reads/writes instead of batching behind `DispatchGroup`.
3. **Dead code**: `SettingsStore.get(_ keys: [String], completion:)` (a batched multi-key reader) was built anticipating `AuthGateCoordinator.summary`'s two-key read, then made unnecessary by fix #2 above (chaining turned out to be both simpler *and* correct, where batching was subtly wrong). Once no production call site used it, removed it and its two dedicated tests rather than shipping a facade method nothing calls — the same "a constant nothing reads is a claim this build honours a setting it does not" discipline `SettingsKeys.swift`'s own doc comment already holds this codebase to, applied to a method instead of a constant.
4. **`InspectorViewModel.load()`'s nested-closure `self.project` capture** — the compiler's own "reference to property in closure requires explicit use of self" error (nested closures inside an escaping closure don't inherit the outer `guard let self`'s implicit-member-access permission) — fixed by capturing `project` into a local before the nested `.first { }`.

## Concerns

1. **`closedWorkspaces`/`fileTreeVisible` are declared-but-unconsumed settings keys**, which is exactly the pattern `SettingsKeys.swift`'s pre-6b-2 doc comment argued against. I kept them because the brief's item 1 explicitly lists both by name as constants to add ("plus the remaining `SettingsKey` constants: ... `CLOSED_WORKSPACES_SETTING_KEY`, `FILE_TREE_VISIBLE/WIDTH_SETTING_KEY` ..."), and because `fileTreeVisible` mirrors a key the web app itself has already left dead since the left-pane redesign (its own doc comment says so) — declaring it here is schema parity with an already-inert row, not a new false claim. `closedWorkspaces` is the one genuine judgment call: nothing in this build's session/pane model has a "closed workspace" concept to attach it to (that's the web's closeable per-project tab strip; this build's outline/palette are pane-based, not workspace-based). If a future native project-picker task doesn't end up wanting this key, it should be removed rather than carried forward indefinitely.
2. **`recordInput`/`recordOutput`/`recordTokens` (and `parseTokenEstimateMax`) are ported and tested but not wired to a live terminal byte stream.** The brief scoped the live wiring to "`SessionConnection`'s existing status/attention/exit callbacks" specifically; hooking output bytes for char-counts and token-estimate scanning would mean intercepting every pane's `onTerminalData`/`write` call site, a materially larger and more perf-sensitive seam than status/exit. Recorded here as a deliberate, named gap rather than a silent one — the pure functions are ready for whoever wires that seam next.
3. **The Notifications tab in Settings is a snapshot, not a live view.** Correct given `SessionNotifier.onEntriesChanged` is a single-subscriber callback already claimed by persistence, and Settings is not meant to duplicate the AppKit notification surface — but it does mean an approval that lands *while* Settings is open won't appear there until the window is reopened. Worth a second subscriber slot on `SessionNotifier` if this ever needs to be live.
4. **The Inspector's pause/staleness/paused-projects reads (`load()`) fire three separate daemon round-trips** rather than one combined call — there's no combined "project detail" daemon message, only the four separate ones Task 6a-2 added. Fine at today's scale (one project, opened on demand), but a candidate for a combined message kind if the inspector ever needs to feel snappier.
5. **No UI screenshot/visual pass was possible in this environment** — the same category of concern 6b-1's own report named for the sidebar's vibrancy. The five settings tabs, the inspector panel, and the two onboarding sheets build and their view models are tested, but their pixel-level appearance against the workspace's near-black palette has not been eyeballed on a real screen.
6. **`FirstRunWindowController`/`AuthGateWindowController`/`InspectorWindowController`'s actual `NSWindow`/`NSPanel`/`NSHostingController` presentation code has no automated coverage** — the same accepted boundary `CommandPaletteController`'s own window mechanics already have in this codebase (a sheet/panel that pops open during a unit test is exercised structurally by `WorkspaceWindowControllerTask6b2Tests`, which calls `showSettings`/`showInspectorPanel`/the palette actions against a disconnected socket and asserts no crash, but doesn't assert on-screen appearance).
