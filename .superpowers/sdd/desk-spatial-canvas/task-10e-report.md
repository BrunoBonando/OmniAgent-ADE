# Task 10e — `desk_canvas_native`: read on connect, write on change

**Status:** complete. `./macos/build.sh build` succeeds; `caffeinate -disu ./macos/build.sh test` is
**982 executed, 0 failures**. The Desk canvas class alone is 12 executed, 0 failures.

## What now exists

The canvas's pinned nodes and its camera survive a quit, in their own native-only settings row, on
the `browser_panes_native` / `editor_panes_native` recipe: two flags, a one-shot dispatched gate that
re-arms on failure, and a *completed* gate that alone opens writes.

`PaneWorkspaceView`

- `var onDeskCanvasChanged: (() -> Void)?` — raised when the canvas's persistable state changes.
- `var isEnteringSession: Bool` — `pendingSessionEntry != nil`, read-only. The one thing an outside
  observer could not otherwise tell: for the whole 0.38s of an entry, `canvasMode` is still on and
  `camera` is already at the destination.
- `canvasPins`'s `didSet` now raises `onDeskCanvasChanged` **unconditionally** and keeps the relayout
  gated on `isCanvasMode` (it was one guard covering both). A restore hands the pins over before the
  canvas is on screen, and the controller still has to learn it now holds the row's contents.
- `panCanvas(by:)`, `zoomCanvas(by:about:)` and `finishCameraFlight(_:)` raise it too — see the
  deviation below for why those three and not `camera`'s own `didSet`.
- `finishCameraFlight` swapped its `guard let group = pendingSessionEntry else { return }` for an
  `if let`, so the raise at the tail is reached by a fitAll landing as well as an entry landing. No
  behaviour changed for either.

`WorkspaceWindowController`

- `deskCanvasReadDispatched` / `deskCanvasReadCompleted` / `deskCanvasWriteToken`,
  `static let deskCanvasWriteDelay: TimeInterval = 0.25`.
- `restoreDeskCanvasIfNeeded()` — dispatched from `applyRestoredPanes` as a **sibling** of the
  browser and editor reads, not chained behind them.
- `applyRestoredDeskCanvas(_:)` — pins, then the camera (or `exitToCanvas()` when there is none).
- `persistDeskCanvas()` — debounced behind a token, wired to `workspace.onDeskCanvasChanged` in `init`.

`SettingsKey.deskCanvas` already existed (Task 4), so Step 1's fallback was not needed.

## Deviations from the plan, and why

Three, all of them about *when* a camera value is worth storing. The plan was written before Task 7
decided how a landing works, and its literal recipe stores a camera that means nothing.

**1. `onDeskCanvasChanged` is not hung off `camera`'s `didSet`.** Normal mode is *entered* by
resetting the camera to the identity — `canvasMode`'s setter does it on the way out, `landSession`
does it on the way in — so a persistence path on that setter writes "the canvas is parked in its own
corner" over the camera the user actually left, every time they enter a session or leave the Desk.
(Task 10a's report flagged exactly this.) Raising it from `panCanvas`, `zoomCanvas` and the flight's
arrival covers every path where a camera value means something, and covers pan/zoom at all — which a
settle-only rule would not, since neither gesture flies.

**2. `persistDeskCanvas` gates on `workspace.canvasMode` as well as on `deskCanvasReadCompleted`,
and captures the state at schedule time rather than reading it back when the timer fires.** The gate
is belt to the raise-site braces: a flight that lands *into* a session raises the callback with the
mode already off, and without the gate the row is rewritten as
`{"camera":{"scale":1,"x":0,"y":0},…}` — verified, by removing the gate and watching
`testEnteringASessionLeavesTheStoredCameraWhereTheCanvasWas` fail with exactly that string. Capturing
at schedule time is what lets the gate be a schedule-time question: the user may fly into a session
inside the quarter-second, and the value already captured is still a true canvas state. Each change
re-schedules, so the last change is still the one written.

Consequence, and it is the intended semantics: **entering a session stores nothing.** The row keeps
the camera the *canvas* was last left at. "You were inside a session" is restored by the restore
chain's own `focusPane(lastFocusedPaneOnLaunch)`, which on the canvas is a flight into that session —
not by a stored camera. This is a correction to the plan's prose ("an identity camera parked over one
session's card"): `landSession` snaps the camera to `(1, .zero)`, which is the canvas's *corner*, not
a card, so that value is unrecoverable as a location. And a camera that did name the card
(`focus(on: card)`) would restore into the state Task 10a's report calls out as wrong — a session
filling the viewport while `canvasOwnsInput` swallows every keystroke.

**3. `applyRestoredDeskCanvas` seats the camera only when `workspace.canvasMode && !workspace.isEnteringSession`,
and opens the gate last.** The read completes after the browser restore has already put focus back
where the user left it, which on the canvas is a flight. The no-camera branch is the dangerous one:
`exitToCanvas()` clears `pendingSessionEntry`, so the plan's unconditional version cancels the
arrival — the restore's last step undoing what the restore is for. Verified by removing the
condition and watching `testARestoredCanvasDoesNotCancelTheEntryTheRestoreIsAlreadyFlying` land on
`grp-2` instead of `grp-1`. Seating a camera while `canvasMode` is off would be worse still: a
`sublayerTransform` over a *normal-mode* layout is one session drawn at a third of its size with
nothing to say so. Opening the gate at the end of the method rather than the start keeps the restore
from writing the row it just read back over itself.

Minor: the plan's Step 6 comment says "the codec takes a non-optional String, unlike its browser and
editor siblings". Task 4 shipped `deserialize(_ raw: String?)`, so `raw` is passed straight through
like the other two and the comment is dropped.

## Tests

`macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift`, +6:

- the plan's four — gate closed before the read, a pin written after it, five changes coalescing into
  one write, a failed read re-arming without opening the gate;
- `testEnteringASessionLeavesTheStoredCameraWhereTheCanvasWas` and
  `testARestoredCanvasDoesNotCancelTheEntryTheRestoreIsAlreadyFlying`, one per deviation above. Both
  were confirmed to fail when their guard is removed, with the failure text quoted above — they are
  not decoration.

A private `twoSessionPlan()` helper joins `settleCameraFlight()` in the class's Helpers section.

## For whoever comes next

- **`onCanvasPinsChanged` (Task 8) still has no consumer.** Pins persist through
  `onDeskCanvasChanged` instead — one callback for the whole row rather than one per field. Task 8's
  warning that it fires ~60/s during a drag applies unchanged to this one, and the 0.25s debounce is
  the answer.
- **The known gap Task 10a recorded is still open and is not made worse here:** Desk → Dashboard →
  Desk comes back at scale 1 / origin 0 because `canvasMode`'s setter destroys the camera. Nothing
  now writes that value to the row (the gate refuses it), so ⌘0 still recovers, and the *next launch*
  is correct — but the within-session round trip is still not.
- **First launch opens on the whole organigram**, as the spec asks: no stored camera → `exitToCanvas`
  → `fitAll`. Second launch opens where the canvas was left, unless the focus restore flies into a
  session first, in which case the flight wins by design.
