# Review B fixes — level of detail, the camera flight, inverse-camera input

Both findings were verified against the code before anything was changed, and both
are real. Both are now fixed, each with a regression test that was confirmed to fail
with the fix reverted and to pass with it in place.

## Finding 1 (blocking) — `camera.isIdentity` is not "the transform is identity"

**Verified.** `DeskCamera.isIdentity` is `scale == 1 && origin integral`.
`DeskCamera.focus(on:in:)` over a session card — which is *exactly* the viewport by
design — always yields `scale == 1, origin == -card.origin`, and `DeskCanvas.place`
rounds every card origin. So every entry flight spends its whole 0.38s at
`isIdentity == true` with `sublayerTransform` translated by a whole card. The
temporary-revert run printed the review's own numbers back:
`DeskCamera(scale: 1.0, origin: (-1344.0, -880.0))`.

Both consequences reproduce:

- **Mis-hit.** With session 1's card dragged onto the canvas origin, its pane's
  *frame* covers the viewport. During a flight to session 3, `hitTest(600, 400)`
  returned a view inside session 1's pane — a click into the wrong PTY, with the
  dividers, hole tiles and `PaneHeaderButton.mouseUp` conversions wrong by the same
  translation.
- **Wedge.** `landSession`'s `guard grids[group] != nil else { return }` left
  `canvasMode` on with the camera parked over a card that no longer exists, nothing
  accepting input and no landing left to come.

### What changed

- `DeskCamera.isIdentityTransform` (`macos/OmniAgent/DeskCanvas.swift`) — `scale == 1
  && origin == .zero`, the transform actually being identity. `isIdentity` keeps its
  definition and its landing semantics; its doc now says plainly that it is *not* the
  transform test and points at the new one.
- `PaneWorkspaceView.canvasOwnsInput` — `isCanvasMode && !camera.isIdentityTransform`.
  `hitTest`, `mouseDown`, `mouseDragged`, `mouseUp`, `keyDown`, `scrollWheel` and
  `acceptsFirstResponder` all guard on it, so the canvas keeps input for the whole
  flight and hands it back only once `landSession` has re-laid the card out in
  `bounds`.
- `landSession`'s `guard grids[group] != nil` now falls back to `exitToCanvas()`
  instead of returning, so a session that dies mid-flight puts the user on the canvas
  rather than nowhere.
- `selectablePaneID` also moved to `isIdentityTransform` — see Deviations.

`pinchCanvas` deliberately still asks `isIdentity`; see Deviations.

## Finding 2 (important) — `exitToCanvas()` left the keyboard on the terminal

**Verified.** Nothing on the exit path called `makeFirstResponder`; the only such
call was in `mouseDown`, and a pinch/⌘0/esc is not a click. `exitToCanvas()` now ends
with `window?.makeFirstResponder(self)`. This only works *because* of the finding-1
fix: at the moment `exitToCanvas` re-seats the camera on the departing card, the old
`acceptsFirstResponder` was false (loose `isIdentity` true) and the call would have
been refused.

## Tests added (4)

| Test | File |
| --- | --- |
| `testTheCanvasKeepsEveryHitForTheWholeEntryFlight` | `DeskCanvasInputTests` |
| `testLeavingASessionTakesTheKeyboardOffTheTerminalWithNoClickInvolved` | `DeskCanvasInputTests` |
| `testASessionThatDiesMidFlightLandsTheUserBackOnTheCanvas` | `DeskCameraFlightTests` |
| `testNothingBlinksWhileTheCameraIsFlyingAtACardEvenAtScaleOne` | `DeskCanvasLODTests` |

The first pins the mis-hit concretely (a pinned card over the canvas origin, then a
flight elsewhere) rather than relying on a fixture where no container happens to
cover the point — the weaker version passed even with the bug present. The two
flight tests skip under Reduce Motion, where the landing is synchronous and there is
nothing in the air.

All four were run with the fixes reverted: 7 assertion failures, exactly the ones the
findings describe. With the fixes: 950 tests, 0 failures.

## Deviations

1. **`selectablePaneID` moved to `isIdentityTransform` too.** The finding names the
   blink under "consequences" ("keeps the departing session's focused pane blinking at
   full resolution for the whole flight") but the suggested fix says to keep
   `isIdentity` for "the landing/blink semantics". Leaving it would have kept a 0.7s
   full-resolution Metal timer alive for every entry flight *and* made that property's
   own doc false — it justifies itself as "precisely the state in which a pane accepts
   input at all", which is now the strict predicate. The three existing blink tests all
   fixture the camera at `(1, .zero)` and are unaffected.
2. **`pinchCanvas` still guards on `isIdentity`, not `canvasOwnsInput`,** and this is
   deliberate and commented in place. At scale 1 over a card — inside a session *or*
   mid-flight — there is nothing to zoom in to, and pinching out is the way back.
   Routed through `zoomCanvas` instead, a pinch during an entry flight would move the
   camera and the flight would still land the session 0.38s later; `exitToCanvas()` is
   the one that also cancels `pendingSessionEntry`.
3. **A mouse event during an entry flight does not cancel the entry.** With input
   ownership fixed, a click mid-flight now selects a node or starts a drag on the
   canvas while the flight still lands. That is strictly better than routing it into
   the wrong PTY, and cancelling the arrival on any canvas input was outside the
   findings; noted here in case a later task wants it.

## For the next task

- `PaneWorkspaceView.canvasOwnsInput` is the predicate to guard any *new* canvas input
  path on — not `canvasMode`, and not `camera.isIdentity`. Task 10a/10b: ⌘0 and the
  DESK destination reach `exitToCanvas()`, which now also claims first responder, so
  neither needs to do it itself.
- `DeskCamera` now has two identity questions and they are not interchangeable:
  `isIdentity` = "an arrival worth landing" (scale 1, whole-pixel origin);
  `isIdentityTransform` = "no transform at all" (scale 1, origin zero). Input, hit
  testing and the cursor blink ask the second.

## Left undone

Nothing from the two findings. No pre-existing failures were observed — the suite was
green (950/950) before and after.
