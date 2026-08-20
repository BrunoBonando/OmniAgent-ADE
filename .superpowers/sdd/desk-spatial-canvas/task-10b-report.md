# Task 10b — The Desk menu: ⌘0, ⌃1…⌃9, and session stepping

## What now exists

A **new top-level `Desk` menu**, built in `ApplicationMenus.install()` (`macos/OmniAgent/AppDelegate.swift`)
immediately after the `Panes` block and before `Window`:

| Item | Selector | Chord |
|---|---|---|
| Zoom In | `zoomCanvasIn:` (`PaneWorkspaceView`, Task 8) | ⌘= |
| Zoom Out | `zoomCanvasOut:` (`PaneWorkspaceView`, Task 8) | ⌘- |
| Zoom to Fit | `zoomDeskToFit:` | ⌘0 |
| Enter Session | `enterFocusedSession:` | — |
| Previous / Next Session | `previousSession:` / `nextSession:` | ⇧⌘[ / ⇧⌘] |
| Session 1…9 | `selectSession:` (digit on `tag`) | ⌃1…⌃9 |

Every item has `target = nil` and travels the responder chain, like the rest of the app's menus. The
pre-existing top-level **`Session`** menu (Interrupt / Kill Session / Reattach — one PTY's verbs) is
untouched, exactly as the global constraints demand; the new test asserts that too.

Five commands on `WorkspaceWindowController` (`// MARK: - Desk canvas commands`). Four of them —
`enterDeskSession(_:)`, `currentDeskSessionGroup()`, `zoomDeskToFit(_:)`, `enterFocusedSession(_:)` —
were already in place, added verbatim by Task 10a because 10c/10d consumed them before this task landed.
**This task added the remaining five:**

- `@objc func selectSession(_:)` — ⌃1…⌃9, the digit read off `NSMenuItem.tag` (the `selectPane:`
  precedent), scoped to the *selected project*'s sessions.
- `@objc func nextSession(_:)` / `@objc func previousSession(_:)` — thin wrappers over `stepSession(by:)`.
- `private func stepTarget(by:)` — `SessionOutline.adjacentSessionTab`, so `validateMenuItem` greys the
  item out on exactly the condition the command refuses on. Both ends stop; nothing wraps.
- `private func stepSession(by:)` and `private func deskSession(at:)` (1-based, nil past the end).

Three new `validateMenuItem(_:)` arms (`nextSession:`, `previousSession:`, `selectSession:`), each
gated on `destination == .terminals` plus the same predicate the command uses. `validateToolbarItem`
synthesizes a probe `NSMenuItem` and calls straight into here, so Task 10c's buttons need nothing extra.

`shellSidebar.onSelectSession` now calls `enterDeskSession(session.id)` instead of
`workspace.focusPane(session.paneIDs.first)` — the sidebar row was the app's only "switch to session"
implementation and it must not become the second one. In canvas mode the old body swapped the grid out
from under a camera pointed elsewhere.

**Step 11 (`forwardedCommands`) — checked, no edit.** The set is eleven selectors: the nine pane commands
plus `zoomCanvasIn:`/`zoomCanvasOut:`, which Task 8 already added because those two *are* implemented on
`PaneWorkspaceView`. All five commands added here live on `WorkspaceWindowController`, which AppKit puts
on the chain after the window, so they are reachable with a focus card up already. The set stays closed.

## Deviations from the plan, and why

1. **`desk.submenu?.item(withTitle: "Zoom In")` in the plan's Step 1 test does not compile.** `desk` is
   already an `NSMenu`, and `NSMenu` has no `submenu` property (it has `supermenu`). Written as
   `desk.item(withTitle: "Zoom In")`, which is what the assertion meant.

2. **The two action tests needed `showWindow(nil)` and a run-loop settle after the setup's `focusPane`.**
   This is the real deviation and it is worth reading. The plan was written before Task 10a, and assumed
   the test controller is in *normal* mode. It is not: `WorkspaceWindowController.init` calls
   `applyDestination(.terminals)`, and Task 10a made that the writer of `workspace.canvasMode`. So in a
   freshly built controller the canvas is loaded, and `focusPane("sess-a")` on a pane in a non-active
   group takes `focusPane`'s canvas arm — `pendingFocusPaneID = sessionID; enterSession(group); return` —
   i.e. a 0.38s camera flight, whose landing is scheduled with `DispatchQueue.main.asyncAfter` and
   therefore arrives only when the run loop turns. The plan's assertions ran before it and read the
   *old* session. (`enterSession` also refuses on zero bounds, hence `showWindow(nil)`.)

   The fix is one `settleCameraFlight()` helper (`RunLoop.current.run(until:)` over
   `PaneWorkspaceView.zoomTransitionDuration + 0.2`, the technique `DeskCameraFlightTests` already uses),
   called once after the setup's `focusPane`, plus an added assertion that the entry flight actually
   landed on `grp-1`. Deliberately **not** called after each step: `landSession` turns `canvasMode` off as
   it lands, so from inside a session `enterDeskSession` takes the `activateGroup` arm and is instant.
   Settling after every command would have hidden that, and would have hidden a future regression that
   made stepping asynchronous.

   Behavioural note this exposes, worth knowing: **stepping's timing depends on where you are.** On the
   canvas ⇧⌘] flies; inside a session it is an instant swap. That is what Task 7's `enterSession` was
   written to do and it is not changed here.

## Tests

`macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift` gains three:

- `testTheDeskMenuBindsZoomToFitAndTheNineSessionDigits` — every chord, every selector, the tag on
  `Session 3`, and that `Session ▸ Interrupt` still exists.
- `testSteppingSessionsStopsAtBothEndsRatherThanWrapping` — ⇧⌘]/⇧⌘[ across two sessions, both ends
  stopping rather than wrapping (JS index semantics, ported).
- `testASessionDigitPastTheEndDoesNothing` — ⌃3 with two sessions moves nothing, and
  `validateMenuItem` greys that item while enabling `Session 1`.

`caffeinate -disu ./macos/build.sh test`: **976 executed, 0 failures** (was 973 before this task).

## For later tasks

- The four methods 10c/10d already consume are unchanged; nothing in this task altered their bodies.
- **⌃1…⌃9 is free in this app but not necessarily on the machine.** System Settings → Keyboard →
  Shortcuts → Mission Control ships "Switch to Desktop N" on the same chords once a second Desktop
  exists, and the system binding wins. Task 10f must verify this on the packaged build; ⌥⌘1…⌥⌘9 is the
  recorded fallback.
- Task 10e still owns the collision its own section names: the restore chain's `focusPane` now starts an
  entry flight whose landing fires 0.38s later, and this task's sidebar routing adds another caller that
  can start one.

## Left undone

Nothing in this task's section. Steps 1–12 are all implemented.
