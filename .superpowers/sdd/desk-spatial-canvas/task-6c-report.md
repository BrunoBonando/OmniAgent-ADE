# Task 6c — Level of detail, part 3: blink suppression

**Status:** complete. `./macos/build.sh build` succeeds; `caffeinate -disu ./macos/build.sh test` is **912 executed, 0 failures** (907 before this task, +5 here).

## What was built

Selection came apart from the focus ring, so the canvas can show *which pane you will land on* without paying for a blinking cursor in it.

### `PaneContainerView` (`macos/OmniAgent/PaneWorkspaceView.swift`)

`isFocused`'s `didSet` no longer writes `surface.isSelected`. It now does only the two chrome things it was always about:

```swift
var isFocused = false {
    didSet {
        guard isFocused != oldValue else { return }
        header.isFocused = isFocused
        updateChrome()
    }
}
```

and a new sibling owns the blink:

```swift
var isSelected = false {
    didSet {
        guard isSelected != oldValue else { return }
        surface.isSelected = isSelected
    }
}
```

That one line is the whole mechanism: `TerminalSurfaceView.isSelected`'s `didSet` swaps the cursor style for `steadyTwin(of:)`, and the cursor **style** is the only input SwiftTerm's 0.7s blink `Timer` reads. Nothing else — not `isHidden`, not `suspendsDrawing`, not the chip — stops that timer waking a full-resolution Metal frame.

### `PaneWorkspaceView`

Two new private members, immediately below `updateVisibility()`:

- `private var selectablePaneID: String?` — normal mode answers `focusedPaneID` verbatim; canvas mode answers `nil` unless the focused pane's group **is** `activeGroup` *and* `camera.isIdentity`. That conjunction is deliberate: `adoptFocus(from:)` can leave `focusedPaneID` in a session the camera is not on (it never touches `activeGroup`), and identity scale is the only state in which a pane accepts input at all.
- `private func updateSelection()` — the single writer of `PaneContainerView.isSelected`, mirroring the way `updateVisibility()` is the single writer of `isHidden`/`suspendsDrawing`.

`updateSelection()` is called from exactly two places, because either half of the answer can change without the other:

- the tail of `updateFocusRings()` — the focus half; `updateFocusRings()` is already the sole writer of `container.isFocused` (verified by grep, one call site), so every focus path in the file reaches selection for free.
- the tail of `updateVisibility()` — the camera half; `camera`'s `didSet` runs `updateVisibility()` and no layout pass, so this is the only hook a camera move has.

## Tests added (`macos/OmniAgentTests/DeskCanvasLODTests.swift`, +5, file now 16)

`// MARK: - Blink suppression`

1. `testNoCursorBlinksWhileTheCameraIsOutOnTheCanvas` — off identity, the focused pane keeps `isFocused` (the ring still points at it) but loses `isSelected`, and its terminal's `cursorStyle` is `.steadyBlock`.
2. `testTheFocusedPaneBlinksAgainOnceTheCameraHasLandedAtIdentity` — and `.blinkBlock` returns the instant the camera lands.
3. `testASessionTheCameraIsNotOnNeverBlinksEvenAtIdentity` — the `adoptFocus` case: focus in a foreign session at identity scale still blinks nowhere.
4. `testNormalModeStillGivesTheFocusedPaneItsBlink` — the regression fence for the grid.

`// MARK: - Lifecycle`

5. `testLevelOfDetailNeverKillsASession` — the guard the plan asked for: a real `WorkspaceWindowController` with a `sessionKiller` probe, driven at identity → culled → chipped → back out of canvas mode, asserting `killed == []` and `allPaneIDs` unchanged. Passed first run, as intended; it exists so a later "reap invisible panes" change fails here rather than in someone's terminal.

## Deviations from the plan

One, cosmetic. `selectablePaneID`'s first guard reads `guard isCanvasMode else` rather than the plan's `guard canvasMode else`. `canvasMode`'s getter is literally `{ isCanvasMode }`, so this is the same expression; the private stored property is what the neighbouring `onScreenPaneIDs()` already reads, and going through the computed property from inside the class would be the odd one out. No behavioural difference.

Everything else is the plan verbatim, including all five test bodies and both doc comments.

## What the next task needs to know

- **`PaneContainerView.isSelected` is written by `PaneWorkspaceView.updateSelection()` and nowhere else.** If a later task adds a path that moves focus without going through `updateFocusRings()`, or moves the camera without going through the `camera` setter, the blink will be left behind on the wrong pane. Both funnels are single-call-site today.
- **Task 7's camera flight must respect this ordering.** `selectablePaneID` requires `camera.isIdentity` — which is "scale exactly 1 and a finite whole-point origin". The flight sets `camera` to its destination on frame one and snaps `sublayerTransform` to identity on landing; because the *model* value already reads identity at take-off, the focused pane re-selects at the **start** of the inbound flight, not on arrival. That is a deliberate, harmless lead (it is the pane you are flying to), but if Task 7 wants the blink to appear only on arrival it must gate on its own landing token, not on `camera`.
- **`isFocused` and `isSelected` are now independently true/false.** Anything reading "is this pane the one being typed into" should read `isSelected`; anything reading "which pane does the ring point at" should read `isFocused`. In normal mode they are always equal.
- `carryCardToFocusedPane()`'s doc comment still says the blink follows `PaneContainerView.isFocused` into `TerminalSurfaceView.isSelected`. That sentence is now one hop out of date (it goes through `isSelected`), but the invariant it is arguing for — the blink and the card show the same pane — is unchanged, and rewriting a comment in the focus-mode path was outside this task's file list. Worth a one-line touch-up whenever Task 7 edits that region.

## Left undone

Nothing in this task's scope.
