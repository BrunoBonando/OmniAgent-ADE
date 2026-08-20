# Task 5 — Canvas mode in `PaneWorkspaceView`

**Status:** complete. `./macos/build.sh build` succeeds; `caffeinate -disu ./macos/build.sh test` is
**896 / 0 failures** (887 baseline after Task 4, + 9 new).

## What now exists

`PaneWorkspaceView` has a second layout mode. Normal mode is byte-for-byte what it was — `updateLayout()`
gained exactly one line at the top and returns into the canvas pass; everything below it is untouched.

New members, all in a `// MARK: - Canvas mode` section inserted immediately before `// MARK: - Occlusion`:

| Symbol | Notes |
|---|---|
| `var canvasMode: Bool` | Backed by `private var isCanvasMode`. Entering lands any focus card **synchronously** (`setZoomed(nil)` then `finishZoomTransition(zoomTransitionToken)`); leaving resets `camera` to identity **and clears `canvasLayout`**. Both arms then `updateVisibility()` + `updateLayout()`. |
| `var camera: DeskCamera` | `didSet` → `applyCamera()`, guarded on `!=`. |
| `var canvasRoot: DeskNode?` | `didSet` re-lays out, only while in canvas mode. `nil` → `derivedCanvasRoot()`. |
| `var canvasPins: [String: CGPoint]` | Same; handed straight to `DeskCanvas.layout`. |
| `private(set) var canvasLayout: DeskCanvasLayout?` | The canvas pass's output. `nil` in normal mode. |
| `var canvasCardSize: CGSize` | Always `bounds.size`. |
| `func derivedCanvasRoot() -> DeskNode` | root → one workspace node per project (first non-empty `descriptors[pane].project` in the group, `""` if none) → one session node per group in `groupOrder`. |
| `private func applyCamera()` | `layer.sublayerTransform = camera.transform`, inside a `CATransaction` with actions disabled. |
| `private func updateCanvasLayout()` | Every group's grid laid out in `layout.frames[group].insetBy(gridInset)`; only `activeGroup`'s dividers; all cards' holes pooled by frame; then `applyCamera()`, `updateAccessibilityLabels()`, `refreshFocusSubtitles()`. |
| `private func makeHolePlaceholder()` | Extracted from `syncHolePlaceholders(_:holeIDs:)`, behaviour unchanged. |
| `private func syncCanvasHolePlaceholders(_ frames: [CGRect])` | Canvas mode's tile pool, keyed by frame (a hole's cell id is only unique inside one grid). |

`updateVisibility()`'s one changed line is now `let visible = Set(isCanvasMode ? allPaneIDs : paneIDs)`.

## The one real deviation, and it is load-bearing

**The plan's `applyCamera()` was wrong, and the assertion written to check it caught it on the first run.**

The plan folded an extra `translate((scale - 1) * centre)` into the transform, on the premise that
`sublayerTransform` pivots about the **centre** of the layer's bounds. `DeskCamera.transform`'s own doc
comment (Task 3) said the opposite — that it assumes a **corner** anchor — and asked for the anchor to be
verified before being trusted. It was, by measurement:

- `sublayerTransform` pivots about the parent layer's **anchor point**. A sublayer whose frame origin is
  `(100, 100)` under a `0.5` scale converts to `(50, 50)` with an anchor of `(0, 0)` and to `(350, 250)`
  with `(0.5, 0.5)`. `isGeometryFlipped` (which AppKit sets on this view's layer, since `isFlipped`) does
  not change that.
- AppKit gives a layer-backed `NSView` an anchor of **`(0, 0)`** with `position` at the frame's origin —
  *not* UIKit's centred default. Measured on a real `PaneWorkspaceView`: `anchorPoint == (0, 0)`,
  `position == (0, 0)`, `bounds == (0, 0, 1200, 800)`, `isGeometryFlipped == true`.

So the pivot is the bounds corner and `camera.transform` goes on unchanged. Had the plan's fold shipped,
the whole canvas would have been offset by `(scale - 1) * (600, 400)` — half a viewport at fit-all zoom —
with every test still green, because the plan's test helper modelled the same wrong pivot.

Both halves of the claim are now asserted, not assumed, in
`testTheBackingLayerAnchorsAtItsCornerWhichIsWhatDeskCameraIsWrittenFor()`, and
`DeskCamera.transform`'s doc comment in `DeskCanvas.swift` was updated from "verify this" to the measured
answer. **Task 7's `flyCamera(to:)` should read that comment before animating `sublayerTransform`.**

## Smaller deviations

1. **The plan's `isHidden` assertion could not pass in this task.** It asserts
   `isHidden == !card.intersects(viewport)`, and its comment assumed the first card sits inside the
   default camera's viewport. With Task 2's actual layout it does not: at `cardSize` 1200×800 the cards
   land at `(0, 880)` and `(1344, 880)`, and the identity camera's viewport is `(0, 0, 1200, 800)` — so
   *neither* card intersects, the expected value is `true` for every pane, and Task 5 has no culling to
   make it true. Fixed by putting the camera at `DeskCamera.fitAll(content:in:)` before asserting, which
   is the state the assertion is actually about (everything on screen ⇒ a hidden pane could only be hidden
   for not being `activeGroup`). The formula is kept verbatim so it keeps meaning the same thing after
   Task 6a lands culling, and `fitAll` here is `≈0.393`, comfortably above `lodThreshold`, so Task 6b will
   not disturb it either.
2. **`DeskCamera.canvasViewport(in:)` does not exist yet** — it is Task 6a's, but the plan's Task 5 test
   already called it. The suite has a private `canvasViewport(of:in:)` helper built from
   `camera.canvasPoint(from:)` on the two viewport corners. Task 6a can delete it and use the real one.
3. **`try XCTUnwrap(group)` on a non-optional `String`** (twice in the plan's test) — dropped; the compiler
   rejects it (`generic parameter 'T' could not be inferred`).
4. **`derivedCanvasRoot()`'s doc comment in the plan claimed node ids are prefixed** ("so a project named
   `sess-grp-1` cannot collide") while its code does not prefix and the Global Constraints forbid it. The
   comment now states the constraint instead. Code unchanged.
5. **`updateCanvasLayout()`'s "no card rect" comment** referenced `onScreenPaneIDs()`, which is Task 6a's
   and does not exist yet; reworded to not name a symbol that is not there.
6. **`canvasLayout` is cleared when leaving canvas mode.** The plan does not say to, but Task 6a's
   interface list says it is "`nil` in normal mode", and a stale one is what a click would be resolved
   against. Asserted.
7. **Five tests beyond the plan's four** (9 total): the anchor measurement above, the derived tree's
   shape (node id *is* the group/project id), `canvasLayout`'s publish/clear lifecycle, a pinned session
   carrying its panes, and "a camera move schedules no PTY resize" — the spec calls for that last one
   explicitly and it is cheap here.

## For the next tasks

- `canvasLayout` is the storage Task 6a's `canvasRect(forGroup:)` reads: `canvasLayout?.frames[group]`.
  It is `nil` in normal mode.
- Camera assignment does **not** re-run layout — only `applyCamera()`. Task 6a adding `updateVisibility()`
  to `camera.didSet` is the missing half of viewport culling, and it is safe: no frame is touched.
- `canvasRoot`/`canvasPins` `didSet` re-run `updateLayout()` only while `isCanvasMode`.
- Dividers exist only for `activeGroup`'s card. Hole tiles exist for **every** card, pooled by frame, and
  carry no group in their callbacks — they are only safe to click at identity scale over `activeGroup`'s
  card, which is the interactivity rule Task 8 enforces.
- `updateCanvasLayout()` skips a group with no rect in the tree without writing `isHidden`;
  `updateVisibility()` stays the sole owner of visibility and suspension.
- Nothing here focuses, activates or animates: `flyCamera(to:)`, `enterSession(_:)` and `exitToCanvas()`
  are still unwritten, and `canvasMode = true` leaves the camera wherever it was (identity by default,
  which shows an empty patch of canvas above the tree — Task 7/10a is what puts it at `fitAll`).

## Left undone

Nothing in this task's scope. No pre-existing failures were observed: the suite was green before and after.
