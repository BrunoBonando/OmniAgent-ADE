# Task 9b — Install the chips and connectors on the canvas

**Status:** done. Suite: `Executed 969 tests, with 0 failures` (was 964 at the end of Task 9; +5 here).

## What now exists

Task 9 built `DeskCanvasChipView` and `DeskCanvasEdgeLayer` and unit-tested them in isolation;
nothing instantiated either one. The canvas layout pass now installs both.

`PaneWorkspaceView` gains:

- `private var canvasChips: [String: DeskCanvasChipView]` — pooled **by node id**, the way
  `syncHolePlaceholders(_:holeIDs:)` pools hole tiles, so a chip is never rebuilt out from under
  its own selection ring during an arrow-walk.
- `private let canvasEdges = DeskCanvasEdgeLayer()` — one layer, one path, inserted as sublayer 0
  of this view's own layer, so the camera's `sublayerTransform` carries it for free.
- `private func syncCanvasChrome(_ layout: DeskCanvasLayout, root: DeskNode)` — walks the tree,
  makes/moves/retires one chip per **non-session** node (a session's card *is* its grid), stacks
  them below every pane container (`addSubview(_:positioned: .below, relativeTo: nil)`) so a card
  always composites over the tree, then hands the edge layer the layout and the camera scale.
  Called from `updateCanvasLayout()`'s tail, immediately before its closing `updateVisibility()`.
- `private func updateCanvasChipSelection()` — the ring's only hook between layout passes.
- `private var accountDisplayName` — `NSFullUserName()`, with `"You"` as the fallback.
- Testing seams: `canvasChipIDsForTesting`, `canvasChipForTesting(_:)`, `canvasEdgePathForTesting`,
  `canvasEdgeLineWidthForTesting`.
- Teardown in `canvasMode`'s `else` arm: every chip out of the view tree, the edge layer off the
  layer tree. Normal mode knows nothing about the organigram, and `landSession` turns canvas mode
  off on **every** entry into a session, so this runs constantly rather than rarely.

Two hooks the plan did not name, both of which the shipped code needs and neither of which any
layout pass would have caught:

1. **`applyCamera()` re-applies the edge layer** (`if let canvasLayout { canvasEdges.apply(...) }`).
   `lineWidth` is in canvas units and a camera move runs **no layout pass** — the camera's `didSet`
   calls `applyCamera()` and `updateVisibility()` and nothing else. Without this the stroke
   compensation would only ever be recomputed by a *resize*, i.e. never during a pinch, which is
   the one gesture it exists for. The plan's own `testTheEdgeLineWidthIsCompensatedForTheCamera`
   cannot pass without it (`layoutSubtreeIfNeeded()` after a camera assignment is a no-op — the
   camera dirties no layout).
2. **`selectedNodeID`'s `didSet` calls `updateCanvasChipSelection()`.** Task 8 ships arrow-walking
   of `selectedNodeID`, and a keypress runs no layout pass either, so the ring drawn by
   `syncCanvasChrome` would only have appeared the next time something else happened to re-lay the
   canvas out — on a still canvas, never. Done inside the view rather than through
   `onCanvasSelectionChanged`, which belongs to whoever owns the view.

## Tests added (5, in `DeskCanvasNodeViewsTests`)

- `testACanvasLayoutPassInstallsAChipPerNonSessionNodeAndOneEdgePath`
- `testLeavingCanvasModeTakesTheChipsAndTheConnectorsWithIt`
- `testTheEdgeLineWidthIsCompensatedForTheCamera`
- `testWalkingTheSelectionMovesTheRingWithoutALayoutPass`
- `testTheAssembledCanvasRendersAtFitAllAndAtIdentity` (spec §6's two offscreen renders)

Verified as real by disabling the `syncCanvasChrome(_:root:)` call and re-running the class: 4 of
the 5 fail (the line-width one survives, because `applyCamera` still applies the stroke — the
*insertion* of the layer is covered by the teardown test's precondition instead).

## Deviations from the plan, and why

- **The workspace chip's title is the project name, not its initials.** The plan wrote
  `chip.apply(title: ShellPalette.initials(project), detail: project, …)`. Task 9's shipped
  `DeskCanvasChipView.drawLeading` computes `ShellPalette.initials(title)` *itself*, and its own
  `testAWorkspaceNameFitsTheColumnTheLayoutActuallyGivesIt` sizes the title column against the
  workspace **name** and the detail row against `ShellPalette.sessionCountLabel(_:)`. The plan's
  literal call would have drawn "OA" in the name row and the initials of "OA" in the tile. What
  ships: `title: SessionOutline.projectLabel(project)` (which also answers "No project" for the
  empty project id `derivedCanvasRoot()` produces), `detail: ShellPalette.sessionCountLabel(children.count)`,
  `tint: ShellPalette.avatarGradient(forID: project)`.
- **`accountDisplayName` is `NSFullUserName()`.** The plan said to confirm by grep and use whatever
  it showed; `WorkspaceAccountRowView` uses `NSFullUserName()`, so the canvas says the same thing
  the sidebar does. `"You"` only when that is empty.
- **The plan's teardown comment ("The camera is deliberately NOT reset here") was not added** — it
  contradicts the shipped code, whose `else` arm *does* reset the camera, with its own recorded
  reason ("Normal mode must carry no transform at all"). Writing the plan's comment would have put
  a false statement in the file.
- **The render test waits out the flight** (`RunLoop.current.run(until: … zoomTransitionDuration + 0.2)`)
  before the identity shot. The plan rendered mid-flight. Two reasons: the render is meant to be of
  a session the camera has *arrived* in, and an un-awaited landing is a `DispatchQueue.main.asyncAfter`
  that would otherwise fire into a closed window during some later, unrelated test.
- **`distinctColours(in:)` gained a `samples:` parameter, defaulting to the existing 20.** At
  identity the picture is one session — ~95% flat terminal — and a 20×20 grid steps straight over
  the 26pt header strip that is the only proof anything drew (measured: 3 distinct colours). The
  identity assertion uses `samples: 120`. The fit-all shot passes at the default.
- **Five tests, not the plan's four**, because of the selection-ring hook above.
- **A fifth test seam was not added**; the plan's step-8 snippet referenced `groupOrderForTesting`,
  which does not exist — the accessor is `groupIDs`.

## For the next task

- The PNGs are worth looking at: `TEST_RUNNER_PANE_RENDER_DIR=/tmp/desk-canvas ./macos/build.sh test`
  writes `desk-canvas-fit-all.png` and `desk-canvas-identity.png`. **They come out vertically
  mirrored** — the harness's documented blind spot (`CALayer.render(in:)` skips the compositor's
  geometry flips), so the account chip appears at the bottom and every label is upside down. That
  is the harness, not the layout: on screen the account is at the top. Do not "fix" it.
- The fit-all render confirms the tree reads as an organigram: account chip → workspace chip →
  three session cards, elbowed connectors between them, cards compositing over the tree.
- Design observation carried over from Task 9 and now visible on the real canvas: a chip is
  `DeskCanvas.chipSize(forCard:)`, so it shares the card's ~1.6:1 aspect and reads as a wide button
  in a tall box. It is legible and the connectors attach at `frame.midX/maxY`, so if it ever looks
  wrong the honest fix is `DeskCanvas.chipSize(forCard:)`, not the chip's drawing.
- Nothing here writes `canvasRoot`; the canvas is still the derived tree. A future task that hands
  in a `canvasRoot` with a node kind whose id collides with another node's will collapse two chips
  onto one frame — `DeskCanvas`'s own doc comment already records the same constraint for `frames`.

## Left undone

Nothing in this task's scope.
