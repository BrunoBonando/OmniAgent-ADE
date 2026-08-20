# Task 9 — The organigram visuals: chips and connectors

**Status:** done. Suite 964 executed, 0 failures. `./macos/build.sh build` clean.

## What now exists

`macos/OmniAgent/DeskCanvasNodeViews.swift` (new, registered in `project.pbxproj`):

- **`final class DeskCanvasEdgeLayer: CAShapeLayer`** — every connector as one elbow in one path on
  one layer.
  - `static let strokeWidth: CGFloat = 1` (view points, before the camera multiplies it)
  - `static func path(for layout: DeskCanvasLayout) -> CGPath` — pure, windowless. Flipped space:
    out of the parent's `maxY`, across at the waist, into the child's `minY`. An edge naming a node
    the layout does not hold is skipped.
  - `func apply(_ layout: DeskCanvasLayout, scale: CGFloat)` — sets the path and divides `lineWidth`
    back out of the camera scale (`scale <= 0` falls back to `strokeWidth`, no divide by zero).
  - `override func action(forKey:) -> CAAction?` returns `NSNull()` for every key; `init(layer:)` is
    implemented so the presentation copy keeps its behaviour.

- **`final class DeskCanvasChipView: NSView`** — the organigram's non-session nodes.
  - `enum Role { case account, workspace }`. **No `.pane` role**, per the plan's own note: the
    level-of-detail pane chip is Task 6b's `PaneChipView`.
  - `init(role:)`, `var isSelected: Bool` (redraw only, never a relayout),
    `func apply(title:detail:tint:status:)`, `override var isFlipped: Bool { true }`,
    `override func draw(_:)`. Not an accessibility element.
  - **`struct Metrics` + `static func metrics(in bounds: NSRect, hasDetail: Bool) -> Metrics`** —
    added beyond the plan; see the deviation below. Pure and windowless, the way
    `DeskCanvasEdgeLayer.path(for:)` is. Carries `unit`, `cornerRadius`, `body`, `tile`, `title`,
    `detail`, `titleFont`, `detailFont`. `draw(_:)` is now a thin renderer over it.

`macos/OmniAgentTests/DeskCanvasNodeViewsTests.swift` (new, registered): 14 tests — 6 connector,
4 chip contract, 1 geometry-fit, 3 offscreen renders (workspace, account, selected-vs-unselected).
Renders land in `$PANE_RENDER_DIR` when
`TEST_RUNNER_PANE_RENDER_DIR=/tmp/desk-chips ./macos/build.sh test` is used; unset is a no-op.

## Deviations from the plan, and why

1. **The chip's sizes are derived from a width-capped `unit`, not from `bounds.height`.**
   The plan's `draw(_:)` scaled everything by `height` (title `0.24h`, tile `0.46h`, insets `0.18h`).
   That is tuned for a wide, short chip. A real chip is `DeskCanvas.chipSize(forCard:)` — the card at
   `chipWidthFraction` 0.25 — so it carries the **Desk viewport's** aspect, around 1.6:1. At a
   realistic 360×225 the plan's constants gave a 54pt title a 135pt column and the offscreen render
   showed `Om…` / `3 ses…`. The eyeball step the plan itself asks for (Step 17) is what caught it.
   Fix: `unit = min(bounds.height, bounds.width * 0.34)`, every one of the plan's ratios kept but
   taken against `unit`, and the title/detail block centred vertically as a block rather than pinned
   at `0.22h`/`0.52h`. `testAWorkspaceNameFitsTheColumnTheLayoutActuallyGivesIt` measures
   "OmniAgent ADE" and "3 sessions" against the columns the metrics hand out at three real card
   sizes, so the regression cannot come back silently. (A variant with a bigger, height-driven tile
   was tried and reverted: it re-truncated the name by ~1%, and that test caught it too.)

2. **`testSelectingAChipRedrawsItWithoutRelayingItOut` was split.** The plan asserted
   `chip.needsDisplay == true` and `chip.needsLayout == false` after setting `isSelected`. Measured
   in this test host: `NSView.needsDisplay`'s **getter** answers `false` on a layer-backed view
   regardless of what `setNeedsDisplay(_:)` was told, and the backing layer's own `needsDisplay()` is
   already `true` and never clears without a real compositor commit — so neither flag can witness a
   redraw. `needsLayout` is only clearable once the view is in a window. The test is therefore
   `testSelectingAChipDoesNotLayItOutAgain` (in a window, asserting the layout half), and the redraw
   half is asserted on pixels by
   `testSelectingTheWorkspaceChipDrawsTheAccentRingRatherThanTheCardStroke`. That one forces the
   redraw with `display()` rather than `displayIfNeeded()` **on purpose**: I checked, and
   `displayIfNeeded()` redraws an offscreen layer-backed view whether or not it was invalidated, so
   it passes with the `isSelected` invalidation deleted and would claim to prove something it does
   not. Both facts are recorded in the doc comments.

3. **Test counts differ from the plan's numbers** (it says 3 → 6 → 10 → 12). The plan's Step 13/17
   still expected a `desk-canvas-chip-pane-awaiting` render and a status-dot sample from the removed
   `.pane` role. I replaced that second render with an **account** render (the only other role, and
   otherwise untested — every other chip test uses `.workspace`), and added the geometry-fit test:
   14 in the class.

4. **`ShellDotsView.color(for:)` is not called.** It was listed as consumed for the `.pane` role's
   status dot, which the plan then removed from this class. `status` is still a stored field and
   still in `apply(...)`'s signature — commented as to why — so a future session role does not force
   a rebuild of pooled chips.

## What Task 9b needs to know

- The API is exactly what 9b's interface section expects: `DeskCanvasChipView(role:)`,
  `apply(title:detail:tint:status:)`, `isSelected`, and `DeskCanvasEdgeLayer.apply(_:scale:)`.
  `Role` has **two** cases (`.account`, `.workspace`) — a session node gets no chip, its card is its
  grid.
- Nothing instantiates either class yet: no chip is a subview, `apply(_:scale:)` has no production
  caller. That is 9b's job, as the plan says.
- The chip fills the whole node frame it is given (body inset is `unit * 0.03`), which is what keeps
  the connectors — drawn to `frame.midX/maxY` — attached to what the eye sees. Do not shrink the
  drawn body to hug the text.
- The edge layer must be a sublayer of `PaneWorkspaceView.layer` so the camera's `sublayerTransform`
  carries it, and `apply(_:scale:)` must be called with the **current camera scale** on every camera
  change, not only on relayout — the whole point of the `lineWidth` division.
- Chips are pooled by node id in 9b. `isSelected` survives `apply(...)`, so a chip rebuilt per pass
  would drop the ring mid-arrow-walk; pooling is what prevents that.

## Left undone

- Nothing from this task's scope. One observation for 9b/design: at the card's aspect a chip is
  noticeably taller than its content row, so it reads as a wide button centred in a tall card. It is
  legible and the connectors need the full frame, but if that whitespace looks wrong on the real
  canvas, the honest fix is in `DeskCanvas.chipSize(forCard:)` (a chip need not share the card's
  aspect), not in the chip's own drawing.
