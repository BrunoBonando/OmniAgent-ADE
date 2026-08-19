# Task 3 — DeskCamera math

**Status:** complete. Whole suite green (874 tests, 0 failures).

## What was built

`struct DeskCamera: Equatable` appended to `macos/OmniAgent/DeskCanvas.swift`, between
`struct DeskCanvasLayout` and `enum DeskCanvas`, plus `import QuartzCore` beneath the
existing `import Foundation`. The file stays free of AppKit and of any window.

Exactly the surface the plan's **Interfaces** block names, and nothing else:

- `var scale: CGFloat`, `var origin: CGPoint`, synthesized memberwise `init(scale:origin:)`
- `static let maxScale: CGFloat = 1.0`
- `var transform: CATransform3D` — `CATransform3DConcat(scale, translate)`: **scale then
  translate**, so `m41`/`m42` carry `origin` *unscaled*
- `func canvasPoint(from viewPoint: CGPoint) -> CGPoint` — the exact inverse of that;
  returns `viewPoint` unchanged when `scale` is not `> 0` and finite, rather than an
  infinity that would poison a hit test
- `static func fitAll(content:in:) -> DeskCamera` — content inset by
  `-DeskCanvas.fitMargin / 2` on each axis, then `focus`ed
- `static func focus(on:in:) -> DeskCamera` — tighter axis, centred, capped at `maxScale`;
  a degenerate rect or an unsized viewport answers `DeskCamera(scale: 1, origin: .zero)`
  rather than a NaN
- `func clamped(minScale:in:) -> DeskCamera` — scale into `[min(minScale, maxScale), maxScale]`
  holding the viewport centre still; returns `self` untouched when already in range
- `var isIdentity: Bool` — `scale == 1` exactly, finite origin, whole-point origin

The contract, unchanged from the plan and load-bearing for every later task:
`viewPoint = canvasPoint * scale + origin`, in `PaneWorkspaceView`'s **flipped** space.
Nothing here inverts an axis.

## Tests

7 new cases in a `// MARK: - camera` section of `macos/OmniAgentTests/DeskCanvasTests.swift`,
placed after the layout sections and above `// MARK: - Helpers`, with `import QuartzCore`
added at the top (for `CATransform3DGetAffineTransform` / `CATransform3DIsAffine`); the
suite still imports no AppKit and needs no window:

- `testFocusingOnARectTheSizeOfTheViewportIsExactlyIdentityScale`
- `testFitAllShowsTheWholeContentPlusItsMarginCentred`
- `testFitAllOnContentSmallerThanTheViewportNeverZoomsPastOne`
- `testAnEmptyCanvasOrAZeroSizedViewportFitsAsIdentityRatherThanNaN`
- `testTheTransformScalesThenTranslatesAndTheInverseUndoesIt`
- `testClampingHoldsTheViewportCentreStillBetweenTheFloorAndOne`
- `testACameraIsIdentityOnlyAtExactlyOneWithAWholePixelOrigin`

`DeskCanvasTests` is now 18 tests (Task 2's 11 + these 7), all green.

Step 4's red state was observed exactly as the plan predicted: a *build* failure,
`cannot find 'DeskCamera' in scope` repeated across the new cases, `** TEST BUILD FAILED **`.
No pre-existing `DeskCamera` anywhere in the tree.

## Deviations

Three, all small:

1. **`CGPoint(x: .infinity, y: 0)` does not compile.** The plan's last assertion in
   `testACameraIsIdentityOnlyAtExactlyOneWithAWholePixelOrigin` fails with
   `error: ambiguous use of 'infinity'` — `CGPoint.init` has `Double`/`CGFloat`/`Int`
   overloads and the bare `.infinity` next to an integer literal `0` cannot be resolved.
   Written as `CGPoint(x: CGFloat.infinity, y: 0)`. Same assertion, spelled so it builds.
2. **Step 1 found nothing to do.** `DeskCanvas.swift` and `DeskCanvasTests.swift` were both
   already registered with 4 `project.pbxproj` entries each (Task 2 did it). No pbxproj
   change was made and it is *not* in this commit — it is dirty in the shared tree from
   other work.
3. **The `DeskCanvasTests` class doc said "no camera".** It now reads "…plus the camera that
   looks at it. Pure — no window and no layer, the way `PaneGridTests` is pure." — the claim
   about purity is what mattered and it is still true; the claim about the camera no longer was.

Also: the plan's Step 9 ends with `git push`. Not run — this worktree's brief forbids pushing.

## What the next task needs to know

- **`transform` assumes a corner anchor.** `m41`/`m42` are the origin unscaled, which is only
  the right thing to assign to `layer.sublayerTransform` when the layer anchors at its corner.
  AppKit's default is `(0.5, 0.5)`. Task 5's `applyCamera()` must assert
  `workspace.layer!.anchorPoint` (the plan already says to) and compose the recentring itself
  if it is centred — the doc comment on `DeskCamera` records this.
- **`clamped` returns `self` unchanged when the scale is already in range**, origin included,
  so an `Equatable` "camera did not change" guard upstream stays true and does not thrash.
- **`clamped` with an unusable current scale** (0, NaN, negative) keeps the origin and only
  fixes the scale — there is no centre to hold in that state. That is deliberate, not an
  oversight; it exists so a stalled camera can be recovered rather than propagating a NaN.
- **`isIdentity` is exact**, not epsilon: `flyCamera(to:)` must *assign* the landing camera
  (`DeskCamera(scale: 1, origin: <integral>)`), never accumulate toward it, or the identity
  snap will never fire.
- **`fitAll` on a zero content rect answers identity, not a fit.** A canvas laid out before
  the view has a size therefore parks at `scale == 1, origin == .zero`; whatever computes the
  clamp floor from `fitAll(content:in:)` will get `1.0` in that state, which collapses the
  clamp range onto the ceiling rather than inverting it. Recompute the floor after the first
  real `layout()`.

## Left undone

Nothing in this task's section. `DeskCamera` has no callers yet by design — Task 5 installs it.
