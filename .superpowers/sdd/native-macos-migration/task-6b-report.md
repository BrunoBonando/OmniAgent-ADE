# Task 6b report — Native surface: AppKit chrome (sidebar, palette, toolbar, notifications, restoration)

Branch: `codex/native-macos-migration-progress`. Base commit: `cda3ac2`. Six commits, no squash, not pushed.

```
4d25947 feat(macos): plan pane restoration from the persisted layout row
3acca96 feat(macos): restore and persist the pane workspace across launches
a8192c5 feat(macos): notify through Notification Center from the shared feed
70df062 feat(macos): add the AppKit sidebar session outline
ac42533 feat(macos): add the command palette and the workspace toolbar
c823e20 fix(macos): stop rewriting unchanged settings rows and land the rename gesture
```

**Status: `DONE_WITH_CONCERNS` — this pass delivers the AppKit half of the brief in full. The SwiftUI half (settings / onboarding / usage / inspectors) is not started, deliberately, and a concrete re-scope proposal for it is in "Proposed Task 6b-2" below. That split uses exactly the seam the task message named, and one of its pieces (onboarding's FirstRun) turns out to have a hard dependency Task 6a explicitly deferred — see "The blocking dependency I found".**

Diff: 3,403 insertions / 34 deletions, entirely under `macos/`. No Rust, no TypeScript, no `crates/mcp-server` (`git diff --name-only cda3ac2..HEAD | grep -v '^macos/'` returns nothing).

---

## What was built

### 1. Window restoration — `WorkspaceRestoration.swift`, `SettingsKeys.swift` (new)

The plan's explicit Task 6 bullet ("restoration ... preserving data/model compatibility and per-field layout repair").

- **`SettingsKey`** — the shared `settings`-table keys, each doc-commented with the exact TypeScript twin it mirrors. Only the two rows this build reads/writes are declared (`layout`, `notifications`); the rest of the brief's key list is deliberately *absent* rather than declared-and-unused, since a constant nothing reads is a claim the build honours a setting it does not. Task 6b-2 adds the rest as it consumes them.
- **`RestoredPane`** — one pane a launch should rebuild: session id, whether it reattaches, plus every field `PersistedTab` stores.
- **`WorkspaceRestoration.plan(fromLayout:limit:makeSessionID:)`** — layered *on top of* Task 6a's `PersistedLayoutCodec.deserialize` (which already does the per-field repair) rather than re-implementing any of it. What becoming a *pane* adds:
  - the **eight-pane cap** (a layout claiming more restores its first `PaneGrid.maxPanes` rather than being rejected wholesale — the same cap `PaneWorkspaceView.addPane` enforces at the other end);
  - a **freshly minted id for every tab that lost its own**, which is the entire point of `deserialize` keeping an id-less tab; minted ids are checked against the backend's `[A-Za-z0-9_-]{1,96}` gate *and* against the plan's own ids, because a duplicate would make `addPane` silently refuse the second pane;
  - the **`__ungrouped__` sentinel** a group-less tab reads as (`ui/src/state/sessions.ts`'s `UNGROUPED_SESSION_ID`), which is itself a valid `SessionIdentifier` so it travels through the same descriptor field a real group id does.
- **`WorkspaceRestoration.persistedTabs(from:)`** — the inverse, so closing/reordering/renaming survives the next launch. It **drops a pane with no project**: `PersistedTab.project` names a project in the brain, this build has no project picker (the `roots_*` surface is not routed through the daemon), and writing `project: ""` into a row the web build reads would hand it a nameless workspace in a shared database. Documented in the function's own doc comment.
- **`PaneDescriptor`** (Task 5's struct) grew `project`/`engine`/`cwd`/`label`/`themeId` — exactly the fields `PersistedTab` stores — so a live pane writes back without a second bookkeeping collection to keep in sync. It keeps a memberwise init with defaults, so Task 5's call sites are untouched. `title` stays separate and is deliberately **not** persisted: it is the terminal's own live OSC title, not something the user named.

**Wiring** (`WorkspaceWindowController`, `AppDelegate`):

- The window now opens **with no panes** and fills itself from the `layout` row on the first `.connected`. It must not wait on the socket — a daemon that is slow or absent has to produce a visible window saying so, not no window. A missing/empty/unreadable row falls back to one bootstrap pane, never to an empty window.
- Restoration runs **exactly once**; a later reconnect re-attaches the panes that already exist rather than reading the row again and rebuilding on top.
- `AppDelegate`'s hardcoded `sessionID: "native-terminal"` bootstrap is gone (replaced by `panes: []`). `init(connection:sessionID:)` survives as a convenience for callers that want a known pane without going through the row.
- **Writes are refused until restoration has run** — a window that has not yet read the row cannot overwrite it — and are suppressed when the serialized value is unchanged (see "Review fixes" below).
- `createSession` now honours the restored pane's `cwd`, and **refuses to start a non-shell engine**. `build_command`'s PATH resolution, MCP wiring and pre-briefing live in `src-tauri/src/sessions.rs` behind no protocol message (the daemon takes an already-built argv), so a restored `claude` pane whose daemon session is still alive reattaches normally — the common case, since the daemon outlives the app — and one whose session is gone reports `"claude session ended — start it from the web app"` instead of quietly launching a login shell under another engine's name.
- ⌘T now inherits the focused pane's group, group label, project and cwd (the web's "a new pane joins the session on screen") instead of the old hardcoded `"sess-grp-1"` / `"Session 1"` / home directory.

### 2. Notifications — `NotificationFeed.swift`, `SessionNotifier.swift` (new)

A faithful port of `ui/src/state/notifications.ts`, split pure-rules / stateful-shell in the same house style as `PaneGrid` / `PaneWorkspaceView`.

- **`NotificationFeed`** (pure, imports no `UserNotifications`): the four-clause on-screen suppression rule, the approvals-only feed (pending + the immediate approved/rejected outcome), `subtitle(for:)`, the immediate-repeat collapse, the 40-entry cap, `unreadCount`, `relativeTime`, and `notifiable` as a restore-time validation guard only (a live event's `event.notify` is always what decides — the rule is never re-derived).
- **The on-screen rule, natively.** Two of the web's four clauses describe a shell this build does not have: there is no project filter and no second view — every pane in the window is on screen at once — so *"the focused pane, in the project on screen, in the workspace view"* collapses into *"the focused pane"*. The two that carry the actual requirement survive verbatim: a hidden/occluded window or a backgrounded app means the user is, definitionally, somewhere else. This reasoning is in the function's own doc comment, not just here.
- **`NotificationFeedCodec`** — `JSONSerialization`-based (same reason `PersistedLayoutCodec` is: one malformed entry must cost only itself), writing the exact camelCase shape `serializeNotifications` writes, including `status` as its Rust wire value and omitting an absent `sessionLabel` rather than writing `null`. A test asserts the raw JSON shape, not just a Swift round-trip.
- **`NotificationDelivering`** protocol + **`UserNotificationDelivery`** (`UNUserNotificationCenter`, `UNUserNotificationCenterDelegate`, per-session `threadIdentifier` grouping, `.default` sound only for a pending approval, tap → `revealPane`). The protocol exists so the feed's behaviour is testable without an authorization prompt and so a test run never posts a banner on the developer's screen.
- **`SessionNotifier`** — the stateful shell: derive → deliver → publish → persist. Restoring the row deliberately does **not** re-deliver anything (a banner for last week's prompt is noise; the row is a log, not a queue). Answering a prompt anywhere withdraws the banner it produced.
- **Which callback does what**, and why: `onStatus` is the only thing that becomes a persisted entry and a banner. `onAttention` stays a dock bounce (`NSApp.requestUserAttention`) rather than a second banner — it fires *alongside* the `awaiting_approval` status event that already becomes one, so notifying from both would double every prompt. `onExit` delivers a **transient** notification that never joins the shared row, because that row's validator only accepts the three notifiable statuses and "ended" is not one of them; it also clears the session's pending approval, since a dead session is not waiting on anything.
- **Bug found and fixed while testing:** the web's `${sessionId}:${Date.now()}` id collides for two events in the same millisecond. Harmless in a list, but the id is also the Notification Center *request identifier*, where a duplicate silently **replaces** the banner it collided with. `NotificationFeed.uniqueID` suffixes the second one. (Persisted-row compatibility is unaffected — the id is an opaque string on both sides.)

### 3. Sidebar / session outline — `SessionOutline.swift`, `SessionOutlineView.swift` (new)

- **`SessionOutline`** (pure) — the port of `ui/src/state/sessionGroups.ts`: the workspace → session → pane tree, first-seen ordering at both levels, the stored-name-else-derived-`Session N` rule with its two-pass "a derived default must never collide with a name someone actually typed" guarantee, `lowestFreeSessionNumber` (closing #2 and opening another gives Session 2 back), `nextSessionName`, the "current session" marker, the session's cwd = its first pane's, and `paneLabel` (`tabDisplayLabel`'s equivalent). Derived from the pane descriptors alone — no second collection, which is exactly what lets restoration bring the grouping back for free.
- **`SessionOutlineView`** — a real `NSOutlineView` inside an `NSSplitViewController` sidebar item, so disclosure, keyboard navigation, type-select, VoiceOver, the collapse animation, the remembered width and the standard sidebar chrome all come from AppKit rather than being re-implemented. Items are a `Hashable` id enum rather than the model structs, so outline identity survives a reload that changed a label. A project row groups but never navigates (`shouldSelectItem` → false); a session row navigates to its first pane; a pane row navigates to itself. Reload is guarded so the outline reflecting focus does not echo back as a request to change it.
- Renaming a session writes the name onto **every pane in the group**, exactly as `session/renamed` does in the web build — one array, one restore.
- The window's content view is now the split view, so the controller exposes `workspaceView` for the pane rectangle; the six existing Task 4/5 tests were updated to use it.

### 4. Command palette — `CommandPalette.swift`, `CommandPaletteController.swift` (new)

- **`CommandPaletteModel`** (pure) — the list, the filter, the highlight. Rows are a **closed `PaletteAction` set** rather than closures, so the list is comparable in a test and `WorkspaceWindowController.run(_:)` is the single place a row becomes a workspace command; every arm calls the same method the menu item calls, so the three surfaces cannot drift.
- Filtering is the same case-insensitive, order-preserving substring the web palette does — deliberately not a fuzzy score: the list is short and stable ordering is what makes muscle memory work. Typing returns the highlight to the top; arrow keys clamp rather than wrap.
- Contents: every live pane ("Switch to *project* — *session* — *pane*"), New terminal pane, and — only when something is focused — Close / Interrupt / Reattach that pane, plus Toggle sidebar and (only when there is something to clear) Clear notifications. Interrupt/reattach call the focused `TerminalSurfaceView`'s own responder actions rather than re-implementing them.
- **No brain search.** The web palette's third section calls `search_brain`, which Task 6a deliberately did not route through the daemon. A row that opened an empty result list is exactly the dead UI this codebase refuses; the row comes back when the query does. Stated in the type's doc comment.
- **`CommandPaletteController`** — an `NSPanel` (not a sheet, so Escape dismisses without unwinding a modal session and the workspace stays visible behind it), rebuilt from the live workspace on every open so it can never offer a pane that closed while it was shut. It closes *before* running, so the action lands with focus already back in the workspace.
- ⌘K on the File menu, targeting `nil` so it travels the responder chain like every other command.

### 5. Toolbar — `WorkspaceToolbar.swift` (new)

`NSToolbar` in `.unified` style with `Sidebar · [sidebarTrackingSeparator] · New Pane · Close Pane · [flexibleSpace] · Commands`. Every item targets `nil` (responder chain, same as the menus) and carries only commands that already exist elsewhere — a toolbar button that were the *only* way to reach something would be a fifth place for the same behaviour to drift. `validateToolbarItem` delegates to the menu's own `validateMenuItem` rather than adding a second enablement rule, and a test asserts that.

Also added: **⌃⌘S Toggle Sidebar** on the Window menu, wired to the controller's own `toggleSidebar:` (not `NSSplitViewController`'s), so the menu item and the palette row run the same method.

### 6. Review fixes (commit `c823e20`)

Two problems I found reviewing my own diff before reporting:

1. **Chatty settings writes.** Both rows are re-derived from live state on every pane mutation, and most mutations do not change what is stored. A shell that repaints its OSC title on every prompt would have written an identical `layout` row several times a second, against the database the web app is also reading. `write(_:to:)` now compares against the last value first. A `settingsWriter` test seam (nil in production) lets the rule be asserted without a socket and without touching the developer's real `brain.db`.
2. **The rename gesture never fired.** Rename was a `mouseDown` override on the outline cell, which `NSOutlineView` consumes before it reaches the cell. Moved to the outline's own `doubleAction`, with the commit path split (`commitRename(named:)`) so the gesture and a test drive the same code.

---

## How I scoped the settings/onboarding/usage consolidation

I did **not** build it this pass. The reasoning, in full, because the brief asked specifically about the scoping:

**What I read before deciding** (all of it, not just the brief's pointers): `ui/src/components/AboutPanel.tsx`, `NotificationsPanel.tsx`+`state/notifications.ts`, `ReviewPanel.tsx`, `AccountBadge.tsx`+`state/accountBadgeState.ts`, `Sidebar.tsx`, `ProjectMenu.tsx`, `CommandPalette.tsx`, `state/usageAnalytics.ts`, `state/sessionGroups.ts`, `state/keyboardShortcuts.ts`, `onboarding/AuthGate.tsx`+`authGateState.ts`, `onboarding/FirstRun.tsx`+`onboardingState.ts`, `lib/tauri.ts`, `state/sessions.ts`, and `src-tauri/src/roots.rs`.

**The seam.** The task message named it: *"AppKit chrome" vs. "SwiftUI panels"*. It is a real seam, not a convenience — the AppKit half depends only on Tasks 4/5 plus Task 6a's `getSetting`/`setSetting`, and it is now complete and coherent at ~3.4k lines. The SwiftUI half is a comparable second body of work (a settings screen over ~10 more setting keys, a full `usageAnalytics.ts` port with its own daily/hourly derivation, an inspector over `listProjects`/`getContext`, and two onboarding flows) with no code overlap with what I built. Delivering both in one pass would have produced roughly a 6k-line diff across two unrelated UI paradigms, which is the sprawling diff the task message asked me to avoid.

**The blocking dependency I found** (this is the part worth acting on before 6b-2 is scoped):

`ui/src/onboarding/FirstRun.tsx`'s flow is *project-root picker → `rootsStartIngest` → poll `ingestionStatus` → live progress → `rootsBiggestProject`*. **None of those four are routed through the daemon.** Task 6a deferred them explicitly, with the reason: they depend on Tauri's `IngestionState` (`src-tauri/src/roots.rs:173` — an `Arc<Mutex<IngestionStatus>>` with background-thread worker accounting) and on `ingest_roots_in_background`, both of which live in `src-tauri` rather than in a shared crate. Routing them means porting a background-thread state machine into the daemon plus new message kinds — genuinely a separate unit of work, not a follow-on. The same gap blocks:

- `AboutPanel`'s **"Rebuild brain"** (`roots_rebuild`),
- `ProjectMenu`'s **pause / re-check / rename** (`roots_set_paused`, `roots_reingest_project`, `roots_staleness`, `rename_project`),
- the palette's **brain search** (`search_brain`) — cheap by comparison, one dispatch arm,
- and any **project *label*** anywhere (the native build shows project ids; `list_projects` is routed but the outline does not call it — see concern 3).

So Task 6b-2 as briefed can deliver AuthGate, the settings screen, usage and the inspector honestly, but **not** FirstRun, "Rebuild brain", or the per-project controls, unless a routing task lands first.

**What I would have built, and would still build, for the settings screen** (recorded so the next pass does not re-derive it): one SwiftUI `Form` in an `NSHostingController`, sections *Account* (`describeAuthSummary` over `auth_signed_in`/`auth_persona`, sign in/out writing the same three keys, the honest-placeholder convention `accountBadgeState.ts` documents), *Notifications* (the feed built here, plus clear/mark-read), *Review* (`review_memory`), *Panels* (`file_tree_width`, `code_review_width`), *About* (bundle version via `aboutVersionLine`'s shape, tagline, and — blocked — Rebuild brain). Every control reading/writing the **same key strings** the web app uses, through Task 6a's `getSetting`/`setSetting`, with a typed `SettingsStore` facade over an injectable protocol so the screen is testable without a socket.

**On usage, the brief's explicit question** ("port the aggregation faithfully, or compute client-side in Swift from the same raw counters — your call, document which"): I did not build it, so this is a recommendation rather than a decision I executed. **Port the aggregation faithfully.** `usageAnalytics.ts`'s store *is* the persisted shape (`usage_analytics_v1` holds `{version, projects: {totals, days, hourActivityMs, updatedAt}}` — raw counters, already aggregated at write time), and `deriveUsageInsights` is a pure read over it. Re-deriving in Swift would mean re-implementing `recordStatusDuration`'s hour-boundary splitting (`nextHourBoundary`) and the `__all__` global-project fan-out anyway, and any drift between the two implementations corrupts a row both apps write. One port, one shape.

---

## Test results

### `./macos/build.sh test`

```
Test Suite 'CommandPaletteTests'            passed — 12 tests, 0 failures   (new)
Test Suite 'FrameCodecTests'                passed —  4 tests, 0 failures
Test Suite 'NotificationFeedTests'          passed — 18 tests, 0 failures   (new)
Test Suite 'PaneGridTests'                  passed — 37 tests, 0 failures
Test Suite 'PaneWorkspaceViewTests'         passed — 21 tests, 0 failures
Test Suite 'PersistedLayoutTests'           passed — 18 tests, 0 failures
Test Suite 'SessionConnectionTests'         passed —  6 tests, 0 failures
Test Suite 'SessionNotifierTests'           passed —  8 tests, 0 failures   (new)
Test Suite 'SessionOutlineTests'            passed — 10 tests, 0 failures   (new)
Test Suite 'SessionOutlineViewTests'        passed —  7 tests, 0 failures   (new)
Test Suite 'WorkspaceRestorationTests'      passed — 11 tests, 0 failures   (new)
Test Suite 'WorkspaceWindowControllerTests' passed — 22 tests, 0 failures   (was 10; +12 new)
Test Suite 'All tests'                      passed — 174 tests, 0 failures
** TEST SUCCEEDED **
```

96 tests before this task → 174 after. 78 new, 0 failures, no test disabled or deleted.

### `./macos/build.sh build`

```
** BUILD SUCCEEDED **
```

### `git diff --check`

Clean — no whitespace errors.

### Rust

Not re-run: this task's diff is Swift-only (`git diff --name-only cda3ac2..HEAD` is entirely under `macos/`), and Task 6a's report already records the workspace state, including the two **pre-existing** `src-tauri --lib` failures (`the_titles_version_is_the_one_tauri_conf_json_declares`, a version drift that predates the whole branch, and `codex_gets_omniagent_mcp_wiring`, a test-isolation flake) which this task neither introduced nor fixed.

### TDD

Every behavioural module was written test-first or test-alongside: `WorkspaceRestorationTests` before the wiring commit, `NotificationFeedTests`/`SessionNotifierTests` before the controller hook-up, `SessionOutlineTests` before the view, `CommandPaletteTests` before the panel. Two of the fixes in `c823e20` came out of that discipline — the notification-id collision was caught by a failing test, not by inspection.

---

## Proposed Task 6b-2 (the SwiftUI panels)

Recommended scope for the follow-on pass, in dependency order:

1. **`SettingsStore`** — a typed facade over Task 6a's `getSetting`/`setSetting` behind an injectable protocol, plus the remaining `SettingsKey` constants. Everything below builds on it.
2. **SwiftUI settings screen** — as scoped above. Ships complete *except* "Rebuild brain" and the per-project controls.
3. **Usage** — port `usageAnalytics.ts` (store + parse + `record*` + `deriveUsageInsights` + `parseTokenEstimateMax`) and a SwiftUI readout of `DashboardOverview`'s numbers. Fully implementable today; the counters would need feeding from `SessionConnection`'s existing callbacks.
4. **Inspector** — a per-pane brain-context panel over Task 6a's `listProjects`/`getContext`. Fully implementable today.
5. **Onboarding — AuthGate only** (`authGateReducer`, the persona picker, the three auth keys). Fully implementable today.
6. **Onboarding — FirstRun: blocked.** Needs a preceding routing task (see below).

**Suggested prerequisite task, if FirstRun and the project controls are wanted:** route `roots_start_ingest` / `ingestion_status` / `roots_rebuild` / `roots_biggest_project` / `roots_set_paused` / `roots_staleness` / `rename_project` / `search_brain` through the daemon. The first four require lifting `IngestionState` + `ingest_roots_in_background` out of `src-tauri/src/roots.rs` into shared, daemon-ownable code; `search_brain` alone is one dispatch arm and could be folded into 6b-2 cheaply if the palette's search row is wanted back.

---

## Concerns

1. **Half the brief's surface is not built.** Stated plainly: the SwiftUI settings/onboarding/usage/inspectors bullet is untouched. This is the split the task message sanctioned, with the seam it named, but the controller should re-scope rather than assume Task 6 is done.
2. **FirstRun cannot be built as briefed** without a preceding daemon-routing task (details above). This is a finding, not a preference — Task 6a's own concern #1 anticipated exactly this decision landing here.
3. **Project rows show ids, not labels.** `SessionOutline.projectLabel` returns the project id (and names the empty case "No project"). Task 6a routed `listProjects`, which returns `{id, label, path}`, so the fix is a read the outline does not yet make — I left it out rather than adding an async load path to a synchronous render for a cosmetic gain, but it is the first thing 6b-2's settings/inspector work will want, since both need the project list anyway.
4. **A restored non-shell pane whose session is gone cannot be restarted natively.** It reports `"claude session ended — start it from the web app"`. This is the honest behaviour, but it does mean the native build is not yet standalone for anything but `shell` panes — the engine-launch surface (`build_command`) is a separate migration item that no plan task currently names.
5. **A pane with no project is not persisted.** Correct for data compatibility (see above), but it means an ad-hoc native ⌘T pane opened in a window with no restored project does not survive relaunch. It resolves itself once a native project picker exists.
6. **`UserNotificationDelivery` is exercised only through its protocol.** The `UNUserNotificationCenter` calls themselves (authorization, `add`, `removeDelivered`, the tap handler) have no automated coverage — deliberate, since a test that posts real banners and prompts for authorization is worse than none. `UNUserNotificationCenter.current()` was verified to construct successfully in the unsigned test host; delivery in a *signed* build is unverified until Task 6d's signing work lands, and is worth a manual check then.
7. **`NSSplitViewItem(sidebarWithViewController:)` brings system vibrancy** into a window that otherwise sets its own near-black palette. It builds and behaves, but the sidebar's exact appearance against the dark workspace has not been eyeballed on a real screen (no UI run was possible in this environment).
8. **`macos/OmniAgent.xcodeproj/project.pbxproj` was edited by script** (the project has no synchronized file-system group, so 13 new files needed explicit `PBXBuildFile`/`PBXFileReference`/group/`Sources` entries). The script lives in the session scratchpad, not the repo. If more files are coming in 6b-2, a synchronized group would be worth the one-time conversion.

---

# Fix report — review round 1: one missing requirement, four Important bugs

Commit range for this round: `c823e20..HEAD` (one commit on top of the original six; two controller-authored docs commits sit in between). Full range now `cda3ac2..HEAD`.

```
478930d feat(macos): start a second session group, and fix four restoration/outline bugs
```

All five findings confirmed and fixed. Every one is now pinned by a test that fails against the previous commit's behaviour.

## Missing requirement — no way to create a new session group

**Confirmed.** The tell the reviewer named was exact: `SessionOutline.nextSessionName` had test coverage and zero non-test callers. Every creation path (⌘T, the outline's "+", the palette's `new-pane`) seeded the new pane's group from the focused pane, so the workspace could only ever hold the groups a restored `layout` row happened to contain.

**Added: ⌘N "New Session"** — a menu item (File), a palette row, and `validateMenuItem` coverage for the eight-pane cap.

- `SessionOutline.newSessionGroupID()` — the port of `newSessionGroupId` (wall clock + a process-local counter), in the `[A-Za-z0-9_-]{1,96}` shape `SessionIdentifier` accepts, because a group id that could not survive a relaunch would silently un-group its panes on the next launch.
- `WorkspaceWindowController.startSession(inDirectory:project:)` — mints the group, names it with **`nextSessionName`** (now wired), and opens one shell pane in it. Returns the group id, so callers and tests address the session by identity.
- `newSession(_:)` — asks for the session's own directory before starting it. This is the native shape of the one real decision the web's `NewSessionModal` makes ("the project folder or a subfolder of it"): an `NSOpenPanel` sheet seeded with the *current* session's own root. Everything else that modal asks (project, engines, layout preset) has no native equivalent yet — no project picker, no engine launcher — so it is not faked.
- The chooser is behind an injectable `directoryChooser`, so `newSession(_:)` is testable without blocking on a modal sheet.
- The palette row names what it would create ("New session — Session 2"), and degrades to a plain "New session" with no dangling dash when there is no name to offer.

Tests: `testStartingASessionPutsItsPaneInABrandNewGroupWithTheLowestFreeName` (new group ≠ focused pane's, valid id, `Session 2` then `Session 3`, the session's own cwd), `testNewSessionAsksForItsDirectoryAndRespectsTheEightPaneCap` (chooser seeded from the current session's root, cancel starts nothing, cap holds and the menu item disables), `testAFreshSessionGroupIDSurvivesARelaunchAndNeverRepeats` (50 ids in a tight loop, all distinct, all valid), plus the menu and palette assertions.

## Important 1 — a failed `layout` read destroyed the shared row

**Confirmed, and the worst of the five.** `let raw = (try? result.get()) ?? nil` collapsed `.failure` into `.success(nil)`. The failure path then bootstrapped a pane and `persistLayout()` wrote `{"tabs":[]}` — so a single transient daemon or SQLite error at launch permanently destroyed the user's saved tabs, in a row the web app also reads.

**Fixed** by switching on the `Result` and adding `layoutReadFailed(_:)`, which:

- invents **no** panes (an unreadable row is not a row saying there are no tabs);
- leaves the write gate **shut**, so ⌘T still works but nothing it does can overwrite the row;
- surfaces the error the way `ensureSession`'s own `.failure` arm does, via `applyConnectionStatus` ("Couldn't read the saved layout — …");
- **re-arms** the read (`layoutReadDispatched = false`) so the next reconnect retries instead of leaving the window degraded for the rest of the session.

The notifications read got the same contract.

Test: `testAFailedLayoutReadNeverWritesAnEmptyLayoutOverTheSavedOne` — asserts no panes, the error in the title, and **zero writes** even after a ⌘T and a descriptor mutation that would otherwise trigger one.

## Important 2 — the write gate opened before the read completed

**Confirmed.** `hasRestored` was set at dispatch time and read as the write gate, so the report's claim ("a window that has not yet read the row cannot overwrite it") was not what the code enforced.

**Fixed** by splitting each row's single flag into two, exactly as the reviewer specified:

| | dispatched (one-shot read guard) | completed (the write gate) |
|---|---|---|
| layout | `layoutReadDispatched` | `layoutReadCompleted`, set only inside `applyRestoredPanes` |
| notifications | `notificationsReadDispatched` | `notificationsReadCompleted`, set only on `.success` |

`applyRestoredPanes`' trailing `persistLayout()` now also serves the in-flight case: a pane opened while the read was outstanding is written once the row lands, merged with what was restored rather than lost.

The notifier half had a second bug behind the same window: `SessionNotifier.restore` **assigned** `entries`, so an `awaiting_approval` recorded mid-read was delivered as a banner and then silently dropped. `restore` now **merges** — live entries are newer, so they keep their place at the front, and restored entries are de-duplicated by id.

Tests: `testAPaneOpenedWhileTheReadIsInFlightIsNotWrittenUntilTheRowLands` (no write before the row lands; both the saved pane and the in-flight one in the write that follows) and `testANotificationRecordedWhileTheFeedIsBeingReadSurvivesTheRestore`.

## Important 3 — the "+" button could add to the wrong session

**Confirmed.** `row.onAdd` discarded the clicked row and the controller re-derived the group from `workspace.focusedPaneID`.

**Fixed**: `SessionOutlineView.onRequestNewPane` is now `((SessionGroupNode) -> Void)?` and carries the row's own session. The controller's `newPane(in:)` takes an optional session — explicit for the outline's "+", `nil` for ⌘T and the hole placeholder, which keep the focus-derived behaviour they should have. `newTerminalPane(_:)` is now a one-line delegation, so both paths share one seeding rule.

Test: `testTheOutlinePlusButtonAddsToItsOwnRowNotToWhateverHasFocus` — focus parked in session 1, "+" clicked on session 2, asserts the new pane's group, group label and cwd all come from session 2.

## Important 4 — reloads destroyed an in-progress rename

**Confirmed**, including the reviewer's diagnosis that `c823e20` fixed the database churn from this event and left the view churn.

**Fixed on three levels:**

1. **Deferral** (the primary fix). `SessionOutlineView.reload` parks the request when a name field is open and applies the newest one the moment editing ends. Deferred, never dropped. `isRenaming` is tracked explicitly rather than read from `outlineView.currentEditor()`, which is always `nil` in a view-based table — the editing control is the `NSTextField` inside the cell, not the table.
2. **Editing genuinely ends, every way it can.** `SessionOutlineRowView` now conforms to `NSTextFieldDelegate` and reports `onEditingEnded` on commit, blur and cancel, guarded against the double commit of the field's action *and* `controlTextDidEndEditing`. A rejected blank name still ends editing, so a deferred reload cannot be parked forever.
3. **Row reuse.** Rows are dequeued via `makeView(withIdentifier:owner:)` with one identifier per kind (a session row carries a "+" the others do not), and `apply(title:detail:kind:)` re-labels in place — and deliberately skips the text while editing, so any reload that slipped through still cannot overwrite what is being typed.

Tests: `testAReloadWhileRenamingIsDeferredNotDroppedSoAnOpenFieldSurvives` (three OSC-title reloads during a rename change nothing; the cell is not rebuilt; the newest lands on commit), `testAnAbandonedRenameStillReleasesTheDeferredReload`, and `testARowIsReLabelledInPlaceAndNeverOverwritesAnOpenNameField`.

On the reuse assertion specifically: I first wrote a test asserting cell **object identity** across a reload and it failed — AppKit does not guarantee a view is in the reuse queue synchronously after `reloadData` for a small table. Asserting that would have pinned an implementation detail of AppKit rather than a contract of this code, so the test asserts the two things that are genuinely guaranteed and genuinely matter: the three kinds have distinct reuse identifiers (and `isCurrent` does *not* split one), and `apply` never clobbers an open field.

## A test bug found while doing this

`testStartingASession…` passed in isolation and failed in the full suite. The cause was mine, not the code's: I asserted on `paneIDs.last`, and `paneIDs` is the grid's **fill order** — a three-pane shape has a hole, and the newest pane is not necessarily last. Both new session tests now address panes by group id through a `pane(inGroup:)` helper, with the reason written down. Worth noting because the same positional assumption is easy to reintroduce.

## Test results after the fixes

`./macos/build.sh test`:

```
Test Suite 'CommandPaletteTests'            passed — 13 tests, 0 failures
Test Suite 'FrameCodecTests'                passed —  4 tests, 0 failures
Test Suite 'NotificationFeedTests'          passed — 18 tests, 0 failures
Test Suite 'PaneGridTests'                  passed — 37 tests, 0 failures
Test Suite 'PaneWorkspaceViewTests'         passed — 21 tests, 0 failures
Test Suite 'PersistedLayoutTests'           passed — 18 tests, 0 failures
Test Suite 'SessionConnectionTests'         passed —  6 tests, 0 failures
Test Suite 'SessionNotifierTests'           passed —  8 tests, 0 failures
Test Suite 'SessionOutlineTests'            passed — 11 tests, 0 failures
Test Suite 'SessionOutlineViewTests'        passed — 11 tests, 0 failures
Test Suite 'WorkspaceWindowControllerTests' passed — 28 tests, 0 failures
Test Suite 'All tests'                      passed — 185 tests, 0 failures
** TEST SUCCEEDED **
```

174 → 185 (+11 this round; one test rewritten, none disabled or deleted).

`./macos/build.sh build` — `** BUILD SUCCEEDED **`. `git diff --check` — clean. Still Swift-only: nothing outside `macos/` was touched this round either.

## Concerns after this round

1. **`newSession` is a directory chooser, not the web's `NewSessionModal`.** It asks the one question that has a native answer today. Session-level engine choice and project selection arrive with the engine-launcher and `roots_*` routing work — noted here so 6b-2 does not assume the flow is finished.
2. **The `NSOpenPanel` sheet path is untested** (only the injected chooser is). A modal sheet in a unit test is worse than no test; worth a manual pass when the app is next run for real.
3. **A restored pane opened while the layout read is in flight is written only after the row lands.** Correct, but it means a very fast ⌘T on a very slow daemon is briefly unpersisted — visible only as "the write happens a moment later", never as data loss.
4. The eight-pane cap now gates `newSession` as well as `newTerminalPane`; a user at the cap wanting a new session must close a pane first. That matches the web build's own cap semantics, but it is a real dead end worth revisiting if sessions ever get their own windows.
5. Unchanged from the original report: the SwiftUI half is still deferred (Task 6b-2), FirstRun still needs the ingestion/roots routing task, project rows still show ids rather than labels, and the accepted deviations (`onAttention` as a dock bounce, no palette brain search) stand as documented.
