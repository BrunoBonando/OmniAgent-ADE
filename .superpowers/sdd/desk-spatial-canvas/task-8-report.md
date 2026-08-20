# Task 8 — Inverse-camera hit testing, node drag, and the canvas gestures

**Branch:** `worktree-desk-canvas` · **Commits:** `131a54f`, `0a24ee6`, `9b8b872`, `c3f6485`, `f4cca41`, `cf15907`, `12f4e30`
**Suite:** 946 executed, 0 failures (923 at the end of Task 7 + 23 new).

## What now exists

A whole `// MARK: - Canvas input` section on `PaneWorkspaceView`, placed exactly where the plan put
it — after `validateMenuItem(_:)`, before `hasNeighbor(_:)` — plus a gated `place(_:at:from:)`, two
new cases in `validateMenuItem`, and two more selectors in `PaneFocusOverlayView.forwardedCommands`.

**The boundary.** `hitTest(_:)` is the first override this view has ever had. At `camera.isIdentity`
it defers to `super` and the panes behave exactly as they do with no canvas at all; below identity
the canvas answers every hit inside its own `frame` and no descendant ever sees a mouse event. That
is what keeps the ~10 window-space call sites in this file correct, all of which are blind to a
`CALayer` transform. `acceptsFirstResponder` is the keyboard half of the same rule: true only in
canvas mode below identity, so inside a session this view keeps never accepting first responder.

**Hit testing and selection.** `canvasNode(at:)` inverts the camera by hand (`canvasPoint(from:)`)
and picks the smallest-area frame containing the point, ties broken by node id — a chip dropped on
a card is what you clicked. `selectedNodeID` announces through `onCanvasSelectionChanged`.
`moveNodeSelection(_:)` walks geometrically in flipped space (`.down` is the larger y) and, with
nothing selected, starts from the node nearest the viewport centre.

**Drag.** `moveNode(_:to:)` moves a node to an absolute canvas position, carries its whole subtree by
the same delta, pins every node it moved, relays out, and announces through `onCanvasPinsChanged`.
The mouse path is `mouseDown`/`mouseDragged`/`mouseUp`, with the 3pt threshold measured **in canvas
units** (at 0.2 a 3pt window twitch is 15pt of canvas). A double-click routes to `enterCanvasNode`.

**Camera gestures.** `panCanvas(by:)`, `zoomCanvas(by:about:)` (anchored, clamped to
`[minimumCanvasScale, 1.0]`), `pinchCanvas(by:about:)`, `zoomCanvasIn:`/`zoomCanvasOut:` (viewport
centre, validated at the clamps), `magnify(with:)` and `scrollWheel(with:)`.

**One perf fix on a hot path.** `place` scheduled a PTY resize on any frame change; it now schedules
on a *size* change (with `start != nil` still counting, for the reparenting case). Twenty node-drag
steps across three sessions used to cost one resize per pane per drag; now zero.

## New API later tasks consume

```swift
// PaneWorkspaceView
var selectedNodeID: String?                              // announces via onCanvasSelectionChanged
var onCanvasPinsChanged: (([String: CGPoint]) -> Void)?  // Task 10e's save hook
var onCanvasSelectionChanged: ((String?) -> Void)?       // Task 9b's selection ring
var deskCanvasLoaded: Bool                               // Task 10a MUST write this — see below
var minimumCanvasScale: CGFloat
static let canvasZoomStep: CGFloat = 1.25
static let canvasDragThreshold: CGFloat = 3
static let canvasPinchOutFactor: CGFloat = 0.98
func canvasNode(at viewPoint: CGPoint) -> String?
func moveNode(_ id: String, to canvasPoint: CGPoint)
func panCanvas(by delta: CGSize)
func zoomCanvas(by factor: CGFloat, about viewPoint: CGPoint)
func pinchCanvas(by factor: CGFloat, about viewPoint: CGPoint)
func enterCanvasNode(_ id: String)
func moveNodeSelection(_ direction: PaneDirection)
@objc func zoomCanvasIn(_ sender: Any?)
@objc func zoomCanvasOut(_ sender: Any?)
override var acceptsFirstResponder / hitTest / mouseDown / mouseDragged / mouseUp / magnify /
    scrollWheel / keyDown
```

Private: `canvasTree`, `deskNode(_:in:)`, `deskSubtreeIDs(of:)`, `canvasSubtreeRect(of:)`,
`nodeNearest(_:)`, and the four drag-state stored properties.

## Deviations from the plan, and why

1. **`canvasTree` instead of `guard let root = canvasRoot`** (plan Steps 11, 15, 19). `canvasRoot` is
   `nil` by default and `nil` *means* "derive it" — `updateCanvasLayout()` reads
   `canvasRoot ?? derivedCanvasRoot()`. The plan's guard would have made `pinchCanvas`, `moveNode`
   and `enterCanvasNode` silent no-ops in the only configuration that exists today. Every reader now
   goes through `private var canvasTree: DeskNode { canvasRoot ?? derivedCanvasRoot() }`, so hit
   resolution can never disagree with the tree the layout pass used. The test helper mirrors it.

2. **`testAtIdentityScaleHitTestingIsExactlyWhatItAlwaysWas` enters a session** rather than assigning
   `DeskCamera(scale: 1, origin: .zero)` in canvas mode. The plan's version cannot pass and would
   have proved nothing: in canvas mode with a zero origin the viewport looks at canvas
   `(0,0)–(1200,800)`, where the tidy tree has put the root chip and *no* pane (the session cards
   start at y = 880), so `super.hitTest` returns the workspace itself and "a pane answers" is false.
   Entering is the state the app actually rests in at identity — `landSession` turns canvas mode off
   as it snaps the transform — and with no window the flight lands in the same turn.

3. **Two zoom tests seat the camera at `fitAll` first.** A fresh canvas-mode camera is
   `DeskCamera(scale: 1, origin: .zero)`, i.e. already at the ceiling, so "and it did zoom in" has no
   answer up there. Affects `testZoomingAboutAPointLeavesThatCanvasPointUnderThePointer` and
   `testTheSteppedZoomKeepsTheViewportCentre`.

4. **`testDoubleClickingASessionCardEntersThatSession` spins the run loop** for
   `zoomTransitionDuration + 0.2`. That fixture has a window, so the landing is scheduled with
   `DispatchQueue.main.asyncAfter` (Task 7) and `activeGroup` is not set synchronously.
   `DeskCameraFlightTests` waits the same way.

5. **Step 32's test referenced an undefined `fit` menu item** — a leftover from before Step 34 moved
   ⌘0 to the controller. Dropped from the loop; for the same reason the forwarding test and the
   `forwardedCommands` doc comment say **two** canvas commands, not three.

6. **`pinchCanvas` owns the out-of-session branch; `magnify` is a pure adapter.** The plan put the
   "pinch out at identity ⇒ `exitToCanvas()`" decision inside `magnify(with:)`. There is no public
   API to synthesize an `NSEvent` carrying a `magnification`, so that branch would have shipped
   untested. It now lives in `pinchCanvas`, which is event-free and tested from both directions.

7. **New: `deskCanvasLoaded` and `canvasPinchOutFactor`.** This is Task 7's recorded left-undone item.
   Inside a session `canvasMode` is **false** (`landSession` turns it off), so a gesture guarded only
   on `canvasMode` cannot fire from the one place the way *out* is needed. `deskCanvasLoaded` is the
   destination's answer to "is the Desk on screen", written by the controller (Task 10a) and by
   nothing else. Gating `magnify` on `canvasMode || camera.isIdentity` instead was rejected: it would
   make a pinch on an ordinary pane grid, off the Desk entirely, switch the view into canvas mode.

8. **Fixture is terminals-only**, following `DeskCanvasLODTests` ("a WKWebView pane costs the test
   host a renderer process for nothing") rather than the plan's kind-switching factory. The input
   rules are kind-neutral.

9. **Guards read the stored `isCanvasMode`, not the computed `canvasMode`.** Same value; it is the
   convention the rest of the file already uses (`updateLayout`, `updateVisibility`,
   `selectablePaneID`) and it keeps a read away from a property whose setter has side effects.

## What the next tasks need to know

- **Task 10a must write `workspace.deskCanvasLoaded = isTerminals` alongside `canvasMode`.** Without
  it, pinch-out from inside a session is dead code. It is one line beside the one the plan already
  specifies.
- **Task 10a still has Task 7's other half to solve.** Coming back to Desk *from inside a session*
  sets `canvasMode = true` with the camera at `(1.0, .zero)` — which shows the empty canvas around
  the root chip, not the session the user left. `exitToCanvas()` already contains the recipe (turn
  canvas mode on, then re-seat the camera with `DeskCamera.focus(on: card, in: bounds)` in the same
  turn so nothing is ever drawn with the layout changed and the camera not). Task 10e's restored
  camera may cover the launch case but not the round trip.
- **`onCanvasPinsChanged` fires once per `moveNode`, i.e. once per drag *step*** — about 60/s during
  a live drag, not once per drag. Task 10e's throttle is the `write(_:to:)` string-equality dedupe
  the Task 4 codec was built for; if that turns out to be too hot, the honest fix is to announce on
  `mouseUp` as well as debounce, not to change `moveNode`.
- **A workspace node's id is the project id, which is `""` for panes with no project.** The empty
  string is a legitimate key in `canvasLayout.frames`; do not treat it as absent.
- **`minimumCanvasScale` answers `DeskCamera.maxScale` (1.0) when there is no layout yet**, so a zoom
  out before the first canvas pass is a no-op rather than a jump to nowhere. That also means
  `validateMenuItem` greys out Zoom Out until the canvas has been laid out once.
- **`canvasNode(at:)` is smallest-area-first**, so Task 9b's chips will win over the card behind
  them once they are laid out — which is what the eye expects, and why overlap needs no z-order.
- **`enterCanvasNode` on a root/workspace node frames that node's subtree** (`focus` clamped by
  `minimumCanvasScale`); only a session node enters a session. Task 10c/10d's "Enter Session" should
  route through it or through `enterSession(_:)`, not re-derive a camera.

## Left undone / honest gaps

- `deskCanvasLoaded` has **no writer** until Task 10a. Until then the pinch-out-of-a-session path is
  reachable only from tests. Everything else in this task is live the moment canvas mode is on.
- `keyDown`'s esc reaches `exitToCanvas()` only while the canvas holds first responder, i.e. below
  identity. Inside a session esc belongs to the terminal; ⌘0 (Task 10b) is the way out there. That
  is the intended split, not a gap — but it means "esc leaves a session" is Task 10b's to deliver.
- Interactivity below identity scale is off, as specified. Hole tiles, dividers, header buttons and
  editor-tab drops are unreachable on the canvas by design; the identity landing is what restores
  them.
- No test drives a real `NSEvent` of type `.magnify` or `.scrollWheel` — AppKit exposes no way to
  build one with a magnification or a scrolling delta. Those two overrides are three-line adapters
  over `pinchCanvas`/`panCanvas`/`zoomCanvas`, all of which are covered.
