# Task 10a + 10c + 10d — DESK loads the canvas; toolbar and palette reach it

Branch: `worktree-desk-canvas`. Suite after: **973 executed, 0 failures** (`caffeinate -disu ./macos/build.sh test`).

## What was built

### 10a — selecting DESK loads canvas mode

`WorkspaceWindowController.applyDestination(_:)` gained two statements, not one:

```swift
workspace.canvasMode = isTerminals
workspace.deskCanvasLoaded = isTerminals
```

The second is the writer Task 8's report said was missing (`deskCanvasLoaded` had no writer at all, and
`pinchCanvas`/`magnify` are guarded on `isCanvasMode || deskCanvasLoaded` — so pinch-out from *inside* a
session was unreachable code until now). `installSplitView(on:)` is untouched; the workspace is never
remounted.

New test file `macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift`, hand-registered in
`project.pbxproj` (build file `886AD5FC7A3C4837958280C6`, file ref `FB9D2F62F22A4B56B0D9AAF1`), with three
tests: the destination loads/unloads the canvas, it also sets `deskCanvasLoaded`, and the round trip never
remounts the pane workspace. Task 10b and Task 10e append to this file.

### 10c — Zoom to Fit and Enter Session on the toolbar

`ToolbarItem.zoomToFit` / `.enterSession`, a slot each between `.flexibleSpace` and `ToolbarItem.palette`,
and two arms through the existing private `item(_:_:_:_:)` factory (plain bordered buttons, `target == nil`,
SF Symbols `arrow.down.right.and.arrow.up.left` / `arrow.up.left.and.arrow.down.right`). The toolbar's
autosave identity is bumped to `digital.bruno.omniagent.workspace.canvas`, or both buttons would have
shipped invisible on every existing install. Enablement is free: `validateToolbarItem`'s probe menu item
lands in `validateMenuItem`, which now has the two arms below.

### 10d — palette rows

`PaletteAction.enterSession(group:)` and `.zoomDeskToFit`; one `enter:<group>` row per session emitted
**immediately before** `commands += paneRows[.terminal] ?? []` so the Terminals section stays one
consecutive run; a `zoom-to-fit` row immediately before `toggle-sidebar`. Both `run(_:)` arms call the same
methods the toolbar buttons and (later) the Desk menu items call.

### Borrowed from Task 10b (which has not landed)

10c and 10d consume controller methods that Task 10b's section produces. The four they actually need were
added here, **verbatim from Task 10b Step 7**, in a new `// MARK: - Desk canvas commands` section placed
exactly where 10b asks for it (right after `run(_:)`):

- `func enterDeskSession(_ group: String)`
- `func currentDeskSessionGroup() -> String?`
- `@objc func zoomDeskToFit(_ sender: Any?)`
- `@objc func enterFocusedSession(_ sender: Any?)`

plus the two `validateMenuItem` arms for `zoomDeskToFit(_:)` and `enterFocusedSession(_:)`.

**Task 10b still has to do the rest of its own Step 7/8/9**: the `Desk` menu in `AppDelegate.swift`,
`selectSession(_:)` / `nextSession(_:)` / `previousSession(_:)` / `stepTarget(by:)` / `stepSession(by:)` /
`deskSession(at:)`, their three `validateMenuItem` arms, and routing `shellSidebar.onSelectSession` through
`enterDeskSession`. Its Steps 1–6 (the menu tests) are untouched and still fail as written.

`PaneFocusOverlayView.forwardedCommands` was checked and deliberately **not** widened (10b Step 11): every
command added here lives on `WorkspaceWindowController`, which AppKit puts in the responder chain after the
window, so it is reachable with a focus card up already. The set is eleven selectors now (Task 8 added
`zoomCanvasIn:`/`zoomCanvasOut:`), all of them `PaneWorkspaceView`'s.

## Deviations from the plan

1. **`applyDestination`'s doc comment does not claim the camera survives.** The plan's comment says the
   camera "is not touched here… preserved across a trip to Dashboard and back". That was true when the plan
   was written and is false now: Task 5's `canvasMode` setter does `camera = DeskCamera(scale: 1, origin: .zero)`
   on the way *out* ("Normal mode must carry no transform at all"). The comment was rewritten to describe
   what the code does. See "Left undone" for the behaviour this leaves.
2. **`deskCanvasLoaded` is set alongside `canvasMode`** — not in the plan's Task 10a text, but required by
   Task 8's report, and its own doc already names `applyDestination(_:)` as its only writer.
3. **Task 10d's expected session label was wrong in the plan.** The plan's test expects
   `"Enter Session 2 — alpha"` for the second (unnamed) session of a project whose first session is named
   "Build". `SessionOutline.group` hands unnamed sessions the *lowest free* number, and "Session 1" is free
   there — the shipped test asserts `"Enter Session 1 — alpha"`, which is what the numbering rule
   (documented on `lowestFreeSessionNumber`) actually produces.
4. **The plan's row-list arrays in 10d Step 6 were stale** (they predate the `session:` and `destination:`
   rows). Each was re-read and merged rather than replaced.
5. **`testRestoreReturnsToTheLastUsedSession` had to be adapted** — see below.

## The one behaviour change outside my three sections

`WorkspaceWindowControllerTests.testRestoreReturnsToTheLastUsedSession` started failing the moment
`canvasMode` is on at launch. Nothing was weakened; the assertions are unchanged. The reason it failed:

`applyRestoredBrowserPanes` ends with `workspace.focusPane(lastFocusedPaneOnLaunch)`, and Task 7 changed
`focusPane` so that in canvas mode a pane in another session is **flown to** rather than swapped in — so
`activeGroup`/`focusedPaneID` arrive one 0.38s camera flight later, at `landSession`. The test now pumps the
run loop until the landing (polled, 5s ceiling) and then asserts exactly what it asserted before. A fixed
`zoomTransitionDuration + 0.2` wait was tried first and was **flaky** — green run alone, red inside the
full class — because `RunLoop.run(until:)` returns immediately when the run loop has no input source; the
poll loop is what makes it deterministic. Ran the class three times and the whole suite once, all green.

Product consequence, deliberate and I believe correct: **launching on the Desk now flies the camera into the
session you were last in**, rather than swapping it in instantly. Task 10e's camera restore
(`applyRestoredDeskCanvas`) lands on the same connect and will need to decide who wins — see below.

## For the tasks that follow

- **Task 10e**: two collisions to plan for.
  1. `applyRestoredDeskCanvas` sets `workspace.camera` (or calls `exitToCanvas()`), and by then the restore
     chain may already have started an entry flight via `focusPane(lastFocusedPaneOnLaunch)`. That flight's
     token-guarded `landSession` fires 0.38s later and will overwrite whatever camera was restored. Either
     apply the canvas row before the browser-pane step, or have the restore cancel a pending entry.
  2. `applyDestination(.dashboard)` sets `canvasMode = false`, which Task 5's setter turns into
     `camera = DeskCamera(scale: 1, origin: .zero)`. If `camera`'s `didSet` is wired to `onDeskCanvasChanged`,
     **leaving the Desk will persist an identity camera over the real one**. Debounce alone does not save
     it; the write wants a gate on "the Desk is loaded", i.e. `deskCanvasLoaded`.
- **Known gap, nobody's section owns it yet** (flagged rather than fixed, because the plan's Task 10a is
  explicitly one statement and every cheap repair I tried is wrong):
  going Desk → Dashboard → Desk does not come back to what you left.
  - If you were **on the canvas** at some camera C, C is destroyed by the mode-off reset and you come back at
    scale 1, origin 0 — the corner of the canvas, root chip in view. ⌘0 (Task 10b) fixes it in one keystroke.
  - If you were **inside a session**, `canvasMode = true` on the way back puts you on the canvas at that same
    corner instead of back in the session. Task 8's report suggested re-seating with
    `DeskCamera.focus(on: card, in: bounds)` — **do not do that**: `focus` on a card gives a non-zero origin,
    so `camera.isIdentityTransform` is false, so `canvasOwnsInput` is true, and you would be staring at a
    full-size session that swallows every keystroke into the canvas. The honest fix is to *not turn canvas
    mode on* when the Desk was left inside a session (remember which of the two states it was in), or to
    make `landSession`'s state survive the mode toggle some other way.
- `enterDeskSession` calls the private `reloadOutline()`, so it must stay in `WorkspaceWindowController.swift`.
- The `enter:` palette rows cover **every** project's sessions, not just the selected one (same tree the
  pane rows come from). The `⌃N` hint is the index *within its project*, which is what ⌃1…⌃9 will select.

## Files changed

- `macos/OmniAgent/WorkspaceWindowController.swift`
- `macos/OmniAgent/WorkspaceToolbar.swift`
- `macos/OmniAgent/CommandPalette.swift`
- `macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift` (new)
- `macos/OmniAgentTests/WorkspaceWindowControllerTests.swift`
- `macos/OmniAgentTests/CommandPaletteTests.swift`
- `macos/OmniAgent.xcodeproj/project.pbxproj`
