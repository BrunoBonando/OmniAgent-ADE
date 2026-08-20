# Task 6b — Level of detail, part 2: the chip threshold

**Branch:** `worktree-desk-canvas` · **Suite:** 907 tests, 0 failures (902 → 907, +5)

## What now exists

Below `DeskCanvas.lodThreshold` (0.2) an **on-screen** session stops drawing its pane
surfaces and draws chips instead. A chip is a fourth sibling inside
`PaneContainerView`, never a replacement surface — `surface` is
`let surface: any PaneContentView`, and a live terminal swapped out of the view tree
is one that has to be rebuilt, with its scrollback, to come back.

- **`macos/OmniAgent/PaneChipView.swift`** (new, hand-registered in `project.pbxproj`):
  `final class PaneChipView: NSView` with `var title: String`, `var engine: Engine?`,
  `var status: RemoteSessionStatus?`. Drawn, not composed, the way
  `PaneHolePlaceholderView` is. Every dimension is a **fraction of the chip's own box**
  (icon 0.30, title 0.17, dot 0.11, gap 0.07) — a fixed 12pt label would be 1.8pt on
  screen at the scale this view exists for, which is the very trap the surface it
  replaces falls into. Flipped, so the icon draw is literally the call `PaneBadgeView`
  makes. The status dot goes through `PaneStatusMarkView.color(for:)`, so a session
  that reads amber in the sidebar reads amber on its chip.
- **`PaneContainerView.chip`** and **`PaneContainerView.isChipped`**. `isChipped`'s
  `didSet` hides/shows the trio (chip up, surface *and header* down — the header
  carries the same three facts and is 3pt tall at this scale), calls `applyLayout()`
  **directly** rather than setting `needsLayout` (the windowless test host never turns
  a run loop to deliver that pass), and on the way back up kicks
  `(surface as? TerminalSurfaceView)?.requestRendererDraw()`.
- **`applyLayout()`** frames the chip on every pass, hidden or not, at
  `bounds.insetBy(dx: borderWidth, dy: borderWidth)` — the box the header and surface
  shared. **`roundChildren(inside:)`** gained `chip.wantsLayer = true` and a fourth
  loop entry taking `screenTop(of:).union(screenBottom(of:))`, i.e. all four corners:
  the chip is the only child on both edges at once, so the flip that the offscreen
  render harness cannot see cannot apply to it.
- **`descriptorChanged(_:)`** sets `chip.title`/`chip.engine` from `header.title` /
  `header.engine` — the same two expressions, so the two can never disagree, and a
  browser/editor (which carries `.shell` as a placeholder) gets `nil` for free.
  `status`'s `didSet` forwards to `chip.status`.
- **`PaneWorkspaceView.showsChips`** — `canvasMode && camera.scale < DeskCanvas.lodThreshold`
  — beside `canvasRect(forGroup:)`, and one hoisted flag in `updateVisibility()`:
  `container.isChipped = onScreen && chips`. `updateVisibility()` remains the sole
  owner of per-pane visibility; anything that assigns `isChipped` from elsewhere is
  overwritten by its next call.

## Tests

Five new tests in `macos/OmniAgentTests/DeskCanvasLODTests.swift` (`// MARK: - The chip
threshold`), 11 in the class, all green:

- below-threshold on-screen session: `isChipped`, surface **hidden** (not merely
  suspended), header hidden, chip visible and framed inside the 1pt ring;
- the chip carries engine + name + status;
- a `.browser` pane's chip shows no engine and takes the URL as its title;
- the chip's `maskedCorners` is all four and its radius is
  `cornerRadius - borderWidth` — pinned in a test precisely because a PNG cannot
  show it (`CALayer.render(in:)` skips the compositor's geometry flips);
- coming back above the threshold bumps `drawRequestCount` (the one place that
  counter is the right assertion: it counts a *requested* draw).

Step 2 and Step 8 both failed exactly as the plan predicted (`no member 'showsChips'`
…; then `XCTAssertGreaterThan failed: ("0") is not greater than ("0")` — the plan wrote
`("1")`, an irrelevant difference in the starting count).

## Deviations

None of substance. The plan's code was used verbatim.

Extra verification not asked for by the plan: I rendered a 300×200 chip to PNG from a
throwaway test (`bitmapImageRepForCachingDisplay` + `cacheDisplay`) to confirm
`draw(_:)` is not blank and not upside down — Claude's mark upright, the title centred,
the amber `awaitingApproval` dot below it. The throwaway test was removed and the whole
suite re-run afterwards (907/0 both times).

## For later tasks

- `showsChips` is `canvasMode && camera.scale < lodThreshold` and nothing else. It is
  read once per `updateVisibility()`; every camera change already funnels through
  `camera`'s `didSet` → `updateVisibility()`, so nothing extra is needed to keep chips
  in sync with a flight. **Task 6c** (blink suppression) and **Task 7** (the camera
  flight) get chip transitions for free from that path.
- `isChipped` is written **only** by `updateVisibility()`. If a later task needs a pane
  chipped for another reason, it has to go through that method or add its own term to
  the `onScreen && chips` expression — a direct assignment is silently reverted.
- The chip sits **below** `dropHighlight` in the view tree (the drop tint stays
  top-most) and **above** header/surface/approvalBar, and it is opaque and fills the
  pane, so nothing under it needs its own hiding rule.
- `PaneChipView` is the per-*pane* chip. **Task 9**'s organigram chips (the `You` /
  `Workspace` nodes at `DeskCanvas.chipWidthFraction`) are a different thing and want
  their own view; reusing this one would tie a node's look to a pane's.

## Blockers

None.
