# Spatial Desk Canvas — Design Spec

Date: 2026-08-18
Status: approved in brainstorming; revised 2026-08-18 after codebase research; awaiting implementation plan

## Revision note (2026-08-18, same day)

The first draft of this spec was written on a wrong premise and is corrected below. It claimed the native Desk was one flat grid with no notion of sessions, and made "port the session model" half the work. **That was already shipped.** Commit `89bdafe feat(macos): 12 panes per session on a 4x3 grid` gave `PaneWorkspaceView` one `PaneGrid` per session, per-session 12-pane caps, a raised global ceiling, and hide-don't-tear-down session switching; `SessionOutline.swift` is already the native port of `ui/src/state/sessionGroups.ts`; the daemon is already at `MAX_SESSIONS = 96` with `const_assert!(MAX_SESSIONS >= 8 * 12)`.

Three consequences, all of which make the work smaller:

1. **P1 is not a project.** What is left of it is a short gap list (§1).
2. **The canvas needs no `DeskCanvasView` hosting N `PaneWorkspaceView`s.** One instance already owns every session's panes. Canvas mode is a second layout mode on the view that already exists (§2).
3. **The original LOD mechanism does not work.** `suspendsDrawing` gates only this app's renderer kick, not SwiftTerm's own draw path (§3).

## Overview

Selecting DESK loads a zoomable, pannable organigram of the running system — `You → Workspace → Sessions` — with each session drawn as a card containing its **real, live** pane grid. Zooming into a session card is not a transition to another view; at `scale == 1.0` over a card you *are* in that session's Desk.

Hierarchy, unchanged and already implemented: `Workspace → Desk (one) → Sessions (many) → ≤12 panes`.

## Goals

- A spatial view of the whole running system, reached by selecting DESK, showing live miniature panes.
- Continuous zoom and pan; entering and leaving a session is one camera animation, never a view swap.
- Nodes are draggable to arbitrary positions and stay where they are put.
- The existing pane focus mode (`⌘↩`), grid ladder, dividers, drag-and-drop, and restore all keep working unchanged inside a session.
- Every session's panes stay live at all times. **Already true** — see `updateVisibility`'s doc comment.

## Non-goals (v1) / future work

- **Cross-session pane drag on the canvas.** Dragging a pane between session cards is not in v1.
- **Scroll momentum, rubber-banding at the zoom clamps, minimap.**
- **Collision avoidance between pinned nodes.** Two dragged nodes may overlap; it is the user's canvas.
- **Zoom above 1.0.** Nothing new to see, and `metalRenderingScaleFactor()` clamps at `max(1, …)`, so a terminal cannot rasterize sharper than 1× anyway without `metalScaleFactorOverride`.
- **Interactive panes below identity scale.** See §4 — this is a correctness boundary, not a feature cut.

## Naming

The daemon and the Swift code call one PTY/pane a "session" (`sessionID`, `MAX_SESSIONS`). The user-facing "Session" is a *group* of those, and the existing code already uses `group` / `groupID` / `activeGroup` for it. Follow that: **"Session" in UI strings, `group` in code.**

## 1. What P1 still needs

Already shipped, verified in `main`:

- `PaneWorkspaceView.grids: [String: PaneGrid]`, `groupOrder`, `activeGroup`, `activateGroup(_:)`, `paneCount(inGroup:)`, `hasRoomForAnotherPane(inGroupOf:)`, `allPaneIDs` vs `paneIDs`.
- `PaneGrid.maxPanes = 12`, enforced per session. `PaneWorkspaceView.maxTerminals = 96` app-wide. Daemon `MAX_SESSIONS = 96`.
- `updateVisibility()` — non-active sessions hidden, never torn down.
- `SessionOutline.swift` — the port of `sessionGroups.ts`: `group`, `defaultSessionName`, `newSessionGroupID`, `nextSessionName`, the lowest-free-number rule.
- Sidebar session rows with select/rename/new; `newPane(in:)`, `newBrowser(in:)`, `newEditor(in:)`, `renameSession(_:to:)`; command palette session entries.

The remaining gap, and the whole of P1:

- **`visibleSessionGroupID(panes:project:focusedPaneID:)`** is not ported. It is the "which session should this project render" answer, distinct from "which session holds focus": selecting a workspace deliberately does not move focus, so focus routinely belongs to another project. Without it, the canvas has no defined answer for a project whose sessions contain no focused pane.
- **`currentSessionGroupID`** and **`adjacentSessionTab`** are not ported. `adjacentSessionTab` is what `⌃1…⌃9`-style session stepping needs, and its end behaviour is JS index semantics — index `-1` and index `>= count` both yield `null`, no wrapping. A Swift port must guard explicitly; `sessions[-1]` traps.
- **`sessionEngineBreakdown`** is not ported. The canvas chips need it. Note `SessionGroupNode` carries only `paneIDs`, not descriptors, so this takes `[PaneDescriptor]` or the node gains descriptors.
- **The ported oracle tests** for the above, added to `SessionOutlineTests.swift` (already headed "Ported from `ui/src/state/sessionGroups.test.ts`").

## 2. Canvas architecture

**One view, one camera, real panes — in the view that already exists.**

`PaneWorkspaceView` already stores every session's grid and every session's containers, laying out and showing only `activeGroup`. Canvas mode is the second answer to the same question:

- **Normal mode** (today): `activeGroup`'s grid fills `bounds`; every other group's containers are hidden.
- **Canvas mode**: *every* group's grid is laid out at its node rect in canvas coordinates, and the camera decides what you see.

The camera is **`layer.sublayerTransform`**. It applies to every sublayer without touching the view's own frame or any container's frame, so container frames stay in canvas coordinates and nothing downstream learns about zoom. Edges and chips are sublayers of the same layer and inherit it for free.

New units:

- **`DeskCanvas.swift`** — pure value types, no AppKit view code: the node tree (`root → workspace → session`), the tidy-tree layout, pinned-node handling, camera math (`fitAll`, `transform(toFit:)`, clamping, inverse mapping). Fully testable without a window, the way `PaneGrid` is.
- **`DeskCanvasChipView`** — the `You` / `Workspace` nodes, and the per-pane chip used below the LOD threshold.
- **`DeskCanvasEdgeLayer`** — one `CAShapeLayer`, all connectors as one path.

`PaneWorkspaceView` gains `canvasMode` and consults `DeskCanvas` for each group's rect in `updateLayout()`, plus the visibility rule in §3.

**Why not a separate `DeskCanvasView` hosting N instances.** Zoom must be single-owner. `applyZoom` tracks exactly one `overlayPaneID` and unconditionally lands a foreign card first; its comment records the bug that guard fixes — *"A live terminal and its session, off screen with no way back."* N instances means N `overlayPaneID`s over one shared overlay host, and that failure mode returns.

**Why not `NSScrollView` magnification.** It owns the transform, fights a non-integral scale, and its clip view's conversions are what make transformed input painful.

## 3. Rendering cost and level of detail

**The original mechanism was wrong.** `TerminalSurfaceView.suspendsDrawing` guards one thing: `requestRendererDraw()` at `TerminalSurfaceView.swift:237`. SwiftTerm's own `feedFinish() → queuePendingDisplay() → setNeedsDisplay` path runs on every feed regardless. Suspending a pane does not stop it rendering.

What actually works, and what the plan must use:

- **`isHidden` on the surface is the real lever.** A hidden view is not composited and its `setNeedsDisplay` schedules nothing. This is already how `updateVisibility` gets its win today, and `viewDidHide`/`viewDidUnhide` already exist on `PaneWorkspaceView` for the destination switch, so AppKit's propagation is already relied on here.
- **Two visibility rules in canvas mode**, replacing the single active-group rule:
  1. A session whose node rect does not intersect the viewport is hidden entirely.
  2. An on-screen session below `scale < 0.2` hides its pane *surfaces* and shows chips instead — engine icon, title, status dot.
- **Chips are a fourth sibling in `PaneContainerView`, not a replacement surface.** `surface` is `let surface: any PaneContentView`. The chip must be threaded through `applyLayout()` and `roundChildren(inside:)`, which today hard-codes the header/surface/approvalBar triple.
- **Blink timers are a real cost and are not covered by any of the above.** One selected pane per session = one 0.7s `Timer` forcing a full-resolution Metal frame, driven by cursor *style* alone. `TerminalSurfaceView.isSelected`'s `didSet` swapping in `steadyTwin(of:)` is the only thing that stops it. Canvas mode must deselect every non-current session's focused pane.
- **Camera moves cost zero PTY resizes.** An ancestor transform does not call `setFrameSize` on descendants, so `processSizeChange → terminal.resize(cols:rows:)` never fires. Worth an explicit regression test, not just an assumption.

The 0.2 threshold is not a compromise on live miniatures: at 0.2, 12pt type is 2.4pt. There is no information in those pixels, only cost.

## 4. Layout, node sizing, and drag

**Session card size is forced, not chosen.** A card is exactly the size of the Desk viewport, because that is what makes "camera at 1.0 over this card" identical to "you are in this session". Every card is therefore the same rectangle. A 1-pane session and a 12-pane session are the same size — correct, because that is what the Desk looks like with one pane. Resizing the window re-lays out the canvas.

**Chips size relative to the card** (~25% of its width) so the tree stays legible at fit-all zoom.

**Node hierarchy.** `You (account) → Workspace → Sessions`. The Desk level is folded into the workspace node (`OmniAgent-ADE › Desk`): it is 1:1 with Workspace and as its own level only makes the tree taller.

**Auto layout** is a plain recursive tidy tree, bottom-up: children packed left-to-right by width, parent centred over its children's span. Deterministic, no dependency.

**Drag pins.** Dragging a node translates it *and its subtree*. A dragged node becomes **pinned**: excluded from packing, with the auto layout arranging only the unpinned remainder around it. Absolute position, not an offset from an auto slot.

**Coordinate convention must be stated once and honoured.** `PaneWorkspaceView.isFlipped == true`; the window is not. `PaneDividerView.mouseDragged` already depends on this. Canvas node positions and the camera origin are defined in the view's flipped space.

**Persistence** is a new native-only settings row, `desk_canvas_native`, following the `browser_panes_native` / `editor_panes_native` recipe — a separate row precisely because the web build rewrites the shared `layout` row and drops fields it does not know. It stores pinned positions and the last camera. Unpinned nodes are recomputed every launch.

## 5. Navigation and animation

**One operation.** Click a card, double-click, a session shortcut, or keep zooming past a threshold — all resolve to *animate the camera so that rect maps onto the viewport*. Exiting (`⌘0`, pinch out, `Esc`) is the same operation aimed at `fitAll`.

**`focusPane` must not swap the grid underneath the user.** Its comment today: *"Focusing a pane in another session brings that session to the screen. This is the single rule that makes the sidebar work."* In canvas mode that rule becomes *fly the camera to that session*, not *switch `activeGroup` instantly*. Any new focus path must still call `carryCardToFocusedPane()`, or the blinking cursor is left behind on a pane nobody can see.

**Landing is exact.** The camera arrives at `scale == 1.0` with an integral origin and snaps `sublayerTransform` to identity on completion. Without the snap, text is permanently soft.

**Animation mechanics must follow the file's existing rules, which exist for recorded reasons:**

- Raw `CAAnimation`, never `NSView.animator()` — `place`'s comment records two `_NSWindowTransformAnimation`s alive on one view when a second transition began inside the first's 0.32s.
- Completions scheduled with `DispatchQueue.main.asyncAfter` guarded by a token, never an animation group's completion block — with no window (the test suite) or under Reduce Motion, that completion is not guaranteed to arrive at all. The identity-snap must follow this or it will hang in tests.
- Remove animations **by key**, never `removeAllAnimations()`.

**Zoom clamps to `[fitAll, 1.0]`.** `fitAll` is the whole tree plus ~20% margin, recomputed on resize.

**Interactivity below identity scale is off, and this is a correctness boundary.** `NSView` coordinate conversion and `event.locationInWindow` are blind to `CALayer` transforms, and roughly ten call sites in `PaneWorkspaceView` depend on them — dividers, drop overlays, cursor rects, tracking areas. Panes accept input only at `scale == 1.0`, where the transform *is* identity and every one of those sites is already correct. Below 1.0 the canvas is first responder: arrows move node selection, `↩` enters, and typing cannot leak into an unreadable terminal.

`PaneWorkspaceView` has no `hitTest` override today. The canvas's inverse-camera hit testing is entirely new code and is only ever exercised below identity scale, where it routes to nodes rather than to pane internals.

**`PaneFocusOverlayView.forwardedCommands` is a deliberately closed set of nine selectors.** Any canvas command must be added to it explicitly.

## 6. Testing

- **`DeskCanvasTests`** — layout determinism, parent centring, pinned exclusion, `fitAll`, `transform(toFit:)`, clamping, inverse mapping. Pure, no window.
- **`SessionOutlineTests`** — the newly ported oracle cases for `visibleSessionGroupID`, `currentSessionGroupID`, `adjacentSessionTab` (both ends, no wrapping), `sessionEngineBreakdown`.
- **Visibility rules** — off-viewport session hidden; below-threshold session shows chips; `sessionKiller` never called by either.
- **No PTY churn on camera moves** — animate the camera, assert the resize coalescer's flush count and the resize send count are unchanged.
- **Blink suppression** — non-current sessions' panes are deselected in canvas mode.
- **Visual** — offscreen render at `fitAll` and at 1.0. Note the harness's known blind spot: `CALayer.render(in:)` skips the compositor's geometry flips, so it cannot catch a `maskedCorners` mistake in the new chip child.
- **Regression** — the existing suite stays green.

## Risks

- **Rendering cost is the real risk, and it is now quantified.** Today AppKit displays ≤12 panes. On the canvas it is up to 96. The mitigations in §3 are viewport culling, the 0.2 chip threshold, and blink suppression — all three are needed, and the ceiling should be measured on real hardware before the threshold constants are treated as final.
- **`PaneWorkspaceView` is ~3,480 lines and under concurrent edit.** Anchor every change by symbol, never by line number, and check mtimes before staging.
- **Transformed hit testing.** Contained by the identity-scale rule, but it is the assumption the whole approach rests on. If it fails, the fallback is a separate lightweight overview that hands off on entry — at the cost of live miniatures and a visible seam.
