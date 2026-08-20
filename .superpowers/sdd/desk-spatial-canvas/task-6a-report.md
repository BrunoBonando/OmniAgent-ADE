# Task 6a — Level of detail, part 1: viewport culling

**Status:** complete. `./macos/build.sh build` succeeds; `caffeinate -disu ./macos/build.sh test` is
**902 / 0 failures** (896 baseline after Task 5, + 6 new). No pre-existing failures were observed.

## What now exists

A card the camera cannot see is hidden outright, and `isHidden` is the lever — `suspendsDrawing` rides
along as the belt-and-braces half only, exactly as the plan and the spec's §3 insist.

| Symbol | File | Notes |
|---|---|---|
| `extension DeskCamera { func canvasViewport(in bounds: CGRect) -> CGRect }` | `macos/OmniAgent/DeskCanvas.swift` | Two mapped corners through `canvasPoint(from:)`, combined with `min`/`abs` so the flipped canvas space needs no orientation assumption. Placed immediately below the `DeskCamera` struct, above `enum DeskCanvas`. |
| `func canvasRect(forGroup group: String) -> CGRect?` | `macos/OmniAgent/PaneWorkspaceView.swift` | `canvasLayout?.frames[group]`, one line. The **only** reader of `canvasLayout` in the LOD path — the whole path re-anchors here if the layout storage ever moves. |
| `var transitionViewport: CGRect?` | `macos/OmniAgent/PaneWorkspaceView.swift` | Public, `didSet` → `updateVisibility()` guarded on `!=`. Task 7's flight sets it to the union of both ends and clears it on arrival. Read only in canvas mode; normal mode returns before it is consulted. |
| `private func onScreenPaneIDs() -> Set<String>` | `macos/OmniAgent/PaneWorkspaceView.swift` | Normal mode: `Set(paneIDs)`, unchanged. Canvas mode: every group whose `canvasRect(forGroup:)` intersects `transitionViewport ?? camera.canvasViewport(in: bounds)`, unioned by `grids[group]?.paneIDs()`. Iterates `groupOrder` (deterministic), touches no dictionary order. |
| `DeskCanvasLODTests` | `macos/OmniAgentTests/DeskCanvasLODTests.swift` (new, registered in `project.pbxproj`) | 6 tests: viewport math, card lookup by group id, off-camera card hidden entirely, camera move re-derives the set, leaving canvas mode restores the one-session rule, and both ends of a flight staying up. |

`updateVisibility()`'s body now reads `let visible = onScreenPaneIDs()` and nothing else changed in it —
it is still the sole writer of `container.isHidden` and `container.surface.suspendsDrawing`. Three call
sites feed it:

- **`camera`'s `didSet`**, after `applyCamera()`. An ancestor transform moves no frame, so no layout pass
  follows a camera move; this is the only thing that re-derives the visible set. Every path that changes
  the camera must go through the setter.
- **`updateCanvasLayout()`'s tail**, after `refreshFocusSubtitles()`. Not `updateLayout()`'s tail — Task 5
  makes `if isCanvasMode { return updateCanvasLayout() }` its first statement, so a tail there is
  unreachable in exactly the mode it would be guarded on, and leaving the normal-mode tail alone keeps a
  divider drag as cheap as it is today.
- **`canvasMode`'s setter**, which already called `updateVisibility()` unconditionally (see deviation 1).

`sessionKiller` is never reached from any of this: it lives on `WorkspaceWindowController`, and
`PaneWorkspaceView` does not reference it at all. Culling hides panes and nothing else — asserted directly
(`allPaneIDs` unchanged after a cull).

## Deviations

1. **`canvasMode`'s setter keeps its existing `updateVisibility()` call *before* `updateLayout()`, rather
   than gaining a second one after it.** The plan asked for an unconditional call as the setter's last
   statement; Task 5 had already shipped an unconditional call one line earlier, so the requirement was
   already met and a second call would be pure duplication. The order is load-bearing in the direction the
   plan did not consider: `updateVisibility()` runs `validateZoom()`, and `updateLayout()` ends in
   `applyZoom()` — moving the visibility call after the layout call would let `applyZoom` act on a zoom the
   mode change has just invalidated. On the way *in*, `updateCanvasLayout()`'s new tail call re-runs it
   once the node rects exist; on the way *out* the pre-layout call is the only one needed. A comment at the
   call site records all of this.

2. **Step 7 predicted three red tests; two were red.**
   `testLeavingCanvasModeRestoresTheOneSessionOnScreenRule` was green before Step 8 — with the pre-6a
   "laid out means on screen" rule, leaving canvas mode already restored the active-group rule, so that
   test is a characterization test of behaviour Task 5 shipped rather than of anything new here. It is kept
   as written: it is the guard that culling never leaks into normal mode.

3. **`onScreenPaneIDs()` reads `isCanvasMode` rather than `canvasMode`.** Same value; the stored property
   avoids bouncing through the computed getter on a path that runs on every camera move.

## What the next tasks need to know

- **`onScreenPaneIDs()` is the single choke point for the visible set.** Task 6b's chip threshold and any
  further narrowing belong there (or in `updateVisibility()` immediately after it), not in a new parallel
  visibility path — `setSuspendsDrawing`'s comment records what happened the one time something else wrote
  `surface.suspendsDrawing` directly.
- **Task 7 (`flyCamera(to:)`) must set `transitionViewport` to the union of the two ends *before*
  assigning the destination camera, and clear it on arrival** (in the `DispatchQueue.main.asyncAfter`
  landing, not an animation group completion). `transitionViewport` is in canvas coordinates — the view's
  flipped space — and its `didSet` is `!=`-guarded, so setting the same rect twice costs nothing.
- **Entering canvas mode with the default identity camera now hides almost everything.** At
  `DeskCamera(scale: 1, origin: .zero)` the viewport is `bounds` at the canvas origin, and the tidy tree
  puts session cards below and to the right of it, so few or no cards intersect. This is correct culling,
  not a bug — but **Task 10a (selecting DESK) must set the camera (`fitAll` over
  `canvasLayout.contentRect`) as part of entering canvas mode**, or the user sees an empty canvas. Task 5's
  own tests already do exactly that.
- **A camera move now costs an `updateVisibility()` pass** (a `containers` walk plus `validateZoom` /
  `updateZoomAvailability`). It still schedules zero PTY resizes — `testMovingTheCameraSchedulesNoPTYResize`
  in `PaneWorkspaceCanvasModeTests` remains green — but a per-frame camera animation should drive
  `layer` values directly rather than reassigning `camera` on every frame.
- `PaneWorkspaceCanvasModeTests.testCanvasModeLaysEverySessionOutAtItsOwnCardRect` already asserted
  "hidden iff off-viewport" in anticipation of this task; it passes unchanged, so that suite's private
  `canvasViewport(of:in:)` helper and `DeskCamera.canvasViewport(in:)` agree.

## Left undone

Nothing from Task 6a's section. Not pushed, not merged (per instructions).
