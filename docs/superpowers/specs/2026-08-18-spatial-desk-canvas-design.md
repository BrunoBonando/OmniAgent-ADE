# Spatial Desk Canvas — Design Spec

Date: 2026-08-18
Status: approved in brainstorming; awaiting implementation plan

## Overview

Give the native macOS Desk two things it does not have today:

1. **Sessions.** The Desk stops being one flat grid of panes and becomes a set of *sessions*, each holding up to 12 panes. Hierarchy: `Workspace → Desk (one) → Sessions (many) → ≤12 panes`.
2. **A spatial canvas.** Selecting DESK loads a zoomable, pannable organigram of the running system — `You → Workspace → Sessions` — with each session drawn as a card containing its **real, live** pane grid. Zooming into a session card is not a transition to another view; at `scale == 1.0` over a card you *are* in that session's Desk.

The two are one project because the second is meaningless without the first, but they are sequenced: the session model ships and is usable before the canvas exists.

## Goals

- Multiple named sessions per Desk, each with its own pane grid and its own 12-pane cap.
- Every session's panes stay live at all times. An agent working in a session you are not looking at keeps working.
- A spatial view of the whole running system, reached by selecting DESK, showing live miniature panes.
- Continuous zoom and pan; entering and leaving a session is one camera animation, never a view swap.
- Nodes are draggable to arbitrary positions and stay where they are put.
- The existing pane focus mode (`⌘↩`), grid ladder, dividers, and restore all keep working unchanged inside a session.

## Non-goals (v1) / future work

- **Cross-session pane drag.** Moving a pane from one session to another is not in v1.
- **Scroll momentum, rubber-banding at the zoom clamps, minimap.** Add if the canvas feels dead without them.
- **Collision avoidance between pinned nodes.** Two dragged nodes may overlap; it is the user's canvas.
- **Zoom above 1.0.** There is nothing new to see past it and text goes blurry-large.
- **A session-level dashboard node.** The canvas shows structure and live panes, not aggregate metrics.

## Naming

The daemon and the existing Swift code already call one PTY/pane a "session" (`sessionID`, `MAX_SESSIONS`, `SessionConnection`). The new user-facing "Session" is a *group* of those. To keep the collision from becoming a maintenance hazard:

- **UI and user-facing strings:** "Session".
- **Swift and daemon internals:** `PaneGroup` / `groupID`, matching the `group` / `groupLabel` fields already in `PersistedTab`.

## 1. The session model (P1)

**The model already exists and is already persisted.** `PersistedTab` (`macos/OmniAgent/PersistedLayout.swift`) carries `group` and `groupLabel`, and `PersistedLayoutCodec` round-trips both. The web build has a complete, tested implementation in `ui/src/state/sessionGroups.ts`. The native app has been *preserving those fields and ignoring them*: `WorkspaceWindowController` puts every restored pane into one grid, with no filter on project or group.

P1 is therefore a port, not a new design:

- **`macos/OmniAgent/SessionGroups.swift`** — pure functions, no AppKit, ported from `ui/src/state/sessionGroups.ts`: `groupTabsBySession`, `visibleSessionGroupID`, `tabsInSession`, `currentSessionGroupID`, `adjacentSessionTab`, `nextSessionName`, `defaultSessionName`, `sessionEngineBreakdown`, `newSessionGroupID`. `sessionGroups.test.ts` ports alongside it as the oracle, the same way `PaneGrid.swift` was ported from `paneGrid.ts`.
- **No schema change and no migration.** The row the web build writes is the row the native app reads.
- **`WorkspaceWindowController` gains `visibleGroupID`.** The grid is built from `tabsInSession(project:group:)` rather than from every restored pane.
- **Panes outside the visible session stay mounted and live.** They are simply not in the grid. The daemon owns the PTY; a view is only an attached consumer. This separation already holds and is what makes "nothing stops in a session you are not looking at" a property rather than a feature.
- **`MAX_SESSIONS` becomes per-session (12).** The daemon's global cap is raised accordingly.
- **Switching:** `⌃1…⌃9` and a toolbar control. Both survive P2 — flying a camera between two sessions you are alternating between is worse than a keystroke.
- **Creating:** the existing empty-pane Dock row creates *panes within the current session* and is unchanged. A new **session** is created from the toolbar switcher's `+` and from the command palette ("New Session"), and in P2 also from a `+` node on the canvas. Named `Session N` by default (`nextSessionName`, checked against stored names so a derived default can never collide with a typed one) and renameable.

### First-launch behaviour change

The native app currently has no per-project scoping either, so this is also the moment panes stop being one undifferentiated pile. An existing layout of mixed panes becomes one ungrouped session per project on first launch after shipping. `UNGROUPED_SESSION_ID` exists for exactly this and the web build already exercises the path.

## 2. Canvas architecture (P2)

One view, one camera, real panes. `DeskCanvasView: NSView` (layer-backed) replaces `PaneWorkspaceView` as the Desk's content root and owns:

- **`contentLayer`** — a single sublayer holding everything. Every node sits at its position in *canvas coordinates*, unaware of zoom.
- **`camera: (scale: CGFloat, origin: CGPoint)`** — the only mutable view state, applied as one `CATransform3D` on `contentLayer`. Nothing else in the tree knows the zoom level.
- **N × `PaneWorkspaceView`** — one per session, mounted as a subview at its node rect and laid out at its natural size. The camera scales them. A session at `scale == 1.0` filling the viewport is not a picture of the Desk; it is the Desk, with its real grid, real dividers, and working focus mode.
- **`edgeLayer: CAShapeLayer`** — every connector as one path, rebuilt on layout change. One layer, not one per edge.

**Precedent.** `PaneWorkspaceView.place` / `zoomLayer` already animate *live* SwiftTerm panes by `CATransform3D` scale, deliberately: the code comments record that animating `bounds` instead read as a reveal rather than a zoom, because only a scale carries the drawn content with it. Live content inside a scaled layer is a proven pattern in this app, not a gamble.

**Hit testing.** `hitTest(_:)` maps the point through the inverse camera before delegating. That is the whole input story: once the point is in canvas space, AppKit's own conversion chain handles the rest, because the panes are real views at real unscaled frames.

**LOD.** `PaneContentView` already declares `suspendsDrawing`. Below `scale < 0.2` each pane sets it and its container draws a chip instead — engine icon, title, status dot. Above the threshold, live terminals. This is not a compromise on live miniatures: at 0.2, 12pt type is 2.4pt. There is no information in those pixels, only cost.

**Culling is rendering-only, never lifecycle.** A session outside the viewport sets `isHidden = true`. Its PTYs keep running. The `sessionKiller` seam is never involved.

**Why not `NSScrollView` magnification.** It gives pan and zoom for free but owns the transform, fights a non-integral scale, and its clip view's coordinate conversions are what make transformed input painful. A camera we own is small and testable without a window.

## 3. Layout, node sizing, and drag

**Session card size is forced, not chosen.** A card must be exactly the size of the Desk viewport, because that is what makes "camera at 1.0 over this card" identical to "you are in this session". Every session card is therefore the same rectangle, containing whatever grid its pane count produces. A 1-pane session and a 12-pane session are the same size — correct, because that is what the Desk looks like with one pane. Resizing the window re-lays out the canvas.

**Chips size relative to the card** (~25% of its width) so the tree stays legible at fit-all zoom instead of vanishing while the cards dominate.

**Node hierarchy.** `You (account) → Workspace → Sessions`. The Desk level is folded into the workspace node (`OmniAgent-ADE › Desk`): it is 1:1 with Workspace, always holds all the sessions, and as its own level only makes the tree taller and every fit-all zoom a step further out.

**Auto layout** is a plain recursive tidy tree, bottom-up: children packed left-to-right by actual width, parent centred over its children's span. Deterministic, no dependency. Reingold–Tilford contour handling buys nothing at three levels with uniformly-sized leaves.

**Drag pins.** Dragging a node translates it *and its subtree* — moving a workspace without its sessions knots the edges. A dragged node becomes **pinned**: excluded from packing, with the auto layout arranging only the unpinned remainder around it. Absolute position, not an offset from an auto slot, so adding a session elsewhere does not drag a pinned node along.

**Persistence** lives in its own settings row, `desk_canvas_native`, following the `browser_panes_native` / `editor_panes_native` precedent — a separate row precisely because the web build rewrites the shared `layout` row and drops fields it does not know. It stores pinned positions and the last camera. Unpinned nodes are recomputed every launch.

## 4. Navigation and animation

**One operation.** Click a card, double-click, `⌃1…⌃9`, or keep zooming past a threshold — all four resolve to *animate the camera so that rect maps onto the viewport*. Exiting (`⌘0`, pinch out, `Esc`) is the same operation aimed at `fitAll`. `⌃2` while inside Session 1 flies sideways to Session 2 rather than teleporting. There is one code path, which is what buys "always smoothly animated" without a pile of special cases.

**Landing is exact.** The camera arrives at `scale == 1.0` with an integral origin and snaps the transform to identity on completion. Without the snap, text is permanently soft in a way that is invisible until it is not.

**Duration and curve** come from the existing `zoomTransition` constants, so canvas zoom and pane focus zoom read as one system rather than two animations that nearly match.

**Zoom clamps to `[fitAll, 1.0]`.** `fitAll` is the whole tree plus ~20% margin, recomputed on resize.

**Keyboard focus follows the camera.** Below `scale == 1.0` no pane is first responder — the canvas is. Arrows move the selection between nodes, `↩` enters. Typing cannot leak into a terminal that is not readable. At 1.0, first responder hands back to the session's focused pane. `⌘↩` while zoomed out flies to the session first, then engages pane focus mode. Focus mode's overlay host is the window content view, so it composites above the canvas; it is reachable only at identity scale.

**Gestures.** `magnify(with:)` for pinch, `scrollWheel(with:)` for pan, `⌘+` / `⌘-` for stepped zoom, double-click to enter.

**Sidebar coherence.** Entering a session sets `visibleGroupID` and `selectedProjectID`, so Level 2 tracks the camera instead of disagreeing with it.

## 5. Testing

Most of this is pure functions and tests without a window.

- **`SessionGroupsTests.swift`** — `sessionGroups.test.ts` ported as the oracle. Grouping order, `UNGROUPED_SESSION_ID` fallback, derived-vs-stored name resolution, adjacency.
- **Camera** — a plain struct: `fitAll`, `transform(toFit:)`, inverse mapping for hit tests, clamp behaviour, identity-snap on arrival.
- **Tree layout** — deterministic positions for a given tree, parent centring, pinned nodes excluded from packing while unpinned ones close the gap.
- **LOD** — crossing 0.2 in both directions sets and clears `suspendsDrawing`.
- **Culling never kills** — an off-viewport session hides its view and the `sessionKiller` seam is never called.
- **Visual** — offscreen render to PNG at `fitAll` and at 1.0, per the convention already used in this repo.
- **Regression** — the existing suite stays green, with attention on the restore and pane-grid tests, which now run inside a session scope rather than a flat pile.

## Risks

- **Transformed input.** Hit testing through the inverse camera is the load-bearing assumption for Approach A. If text input, IME, or cursor rects turn out to be a swamp at non-identity scale, the fallback is a separate lightweight overview view that hands off to the real `PaneWorkspaceView` on entry — at the cost of losing live miniatures and gaining a visible seam at exactly the moment the animation is meant to sell the illusion. The mitigation is that panes are only interactive at identity scale, where the transform *is* identity.
- **N × 12 live panes.** Raising the daemon's global cap makes the ceiling the machine rather than a constant. Worth a real measurement before shipping the cap change, not a guess.
- **`PaneWorkspaceView` is 3,274 lines** and gains a per-session multiplicity it was not written for. Extracting the canvas-facing surface is part of the work, not a follow-up.
