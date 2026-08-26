# Remove the Spatial Desk Canvas — Design Spec

- **Date:** 2026-08-26
- **Status:** Approved (interactively, by Bruno)
- **Scope:** Native macOS app (`macos/`) only
- **Supersedes:** `2026-08-18-spatial-desk-canvas-design.md` (the Desk canvas this removes)

## Context

The Desk canvas (`You → Workspace → Sessions`, a zoomable/pannable organigram with a flying camera between session cards, shipped 2026-08-18) is the "spatial view." Bruno wants it gone entirely: sessions keep working exactly as they do today — click one and it opens — but without the canvas, the camera, or free positioning underneath that click.

This was raised alongside a real crash: `Application Specific Information: Invalid view geometry: y is NaN`, hit "moving from one side to the other or trying to search." Investigation (session memory, Aug 22) traced the *documented, reproducible* instance of this crash — triggered by clicking SEARCH — to `SessionHoverCard.swift`, the sidebar's hover-preview card, via `NavigationSidebar.rowFrameOnScreen()`. That is a separate component from the Desk canvas and is **not** touched by this spec; it's tracked as its own `systematic-debugging` item. This removal *does* incidentally delete the canvas's own camera-flight geometry math (a plausible independent source of NaN when stepping sessions with Previous/Next Session), but that's a side effect, not this spec's fix target — don't claim the SEARCH crash is resolved by this work.

## Goal

Delete the Desk canvas subsystem. Selecting a session (sidebar row, `⌘K` palette row, `⌃1…9`, Previous/Next Session, "Enter Session") switches to it **instantly** via the app's own pre-existing non-spatial path (`activateGroup`) — no camera, no flight animation, no interpolated geometry. Within a session, everything is unchanged: `PaneGrid` splitting, up to 12 panes, the filmstrip switcher.

## Non-goals

- Fixing the `SessionHoverCard` NaN crash (separate item).
- Any change to within-session pane splitting/grid/filmstrip.
- A replacement "see everything at once" overview. That capability is intentionally dropped with the canvas — sessions are switched one at a time, same as `activateGroup` already behaves today off-canvas.

## Files removed entirely

- `macos/OmniAgent/DeskCanvas.swift` — tidy-tree layout, `DeskCamera`
- `macos/OmniAgent/DeskCanvasState.swift` — `desk_canvas_native` persistence codec
- `macos/OmniAgent/DeskCanvasNodeViews.swift` — organigram node/chip rendering
- `macos/OmniAgent/PaneChipView.swift` — canvas-only card chip (confirmed: `PaneFilmstripItemView`'s reference to it is a doc-comment contrast, not a dependency)
- `macos/OmniAgentTests/DeskCanvasStateTests.swift`
- `macos/OmniAgentTests/DeskCanvasInputTests.swift`
- `macos/OmniAgentTests/DeskCameraFlightTests.swift`
- `macos/OmniAgentTests/WorkspaceWindowControllerDeskCanvasTests.swift`
- `macos/OmniAgentTests/DeskCanvasTests.swift`
- `macos/OmniAgentTests/DeskCanvasNodeViewsTests.swift`
- `macos/OmniAgentTests/DeskCanvasLODTests.swift`

## Code removed from `PaneWorkspaceView.swift`

- `canvasMode` and every conditional branching on it
- `camera`, `flyCamera(to:)`, `cameraFlightToken`, `cameraFlightStart`, `finishCameraFlight(_:)`
- `enterSession(_:)` (the camera-fly method — `activateGroup` is the only entry point left)
- `fitAll`, `exitToCanvas`, `carryCardToFocusedPane()`
- Viewport culling / visibility pass driven by the camera (`transitionViewport`, the `DeskCanvas.lodThreshold` check)
- `zoomCanvasIn(_:)`, `zoomCanvasOut(_:)`, `pinchCanvas(by:about:)`, `beginCanvasPan(at:)`, `panLastViewPoint`, `didPushPanCursor`
- The `canvasOwnsInput`-guarded branch of `scrollWheel(with:)` — keep the filmstrip-scroll branch above it untouched

## Code removed from `WorkspaceWindowController.swift`

- `enterDeskSession(_:)` collapses to a single line: `workspace.activateGroup(group); reloadOutline()`. Delete the `canvasMode` branch and its doc comment.
- `zoomDeskToFit(_:)` and its `validateMenuItem` case
- `applyRestoredDeskCanvas` and the `DeskCanvasCodec.deserialize(raw)` load call site (~line 4114)
- The `DeskCanvasState(...)` / `DeskCanvasCodec.serialize(state)` save call site (~lines 4187–4190)
- `validateMenuItem` cases for `zoomCanvasIn:`/`zoomCanvasOut:`

## Code removed from `AppDelegate.swift`

- The "Zoom In" / "Zoom Out" / "Zoom to Fit" items in the `Desk` menu (~line 291–297). Leave "Enter Session," "Previous Session," "Next Session," and the `⌃1…9` pane-selection items exactly as they are — they route through `enterDeskSession`/`stepSession`, which stays, just simpler underneath.

## Code removed from `CommandPalette.swift`

- The `.zoomDeskToFit` action case and its `PaletteCommand` row ("Zoom to fit", `⌘0`)

## Settings

- `SettingsKeys.swift`'s `deskCanvas` key and the `desk_canvas_native` row stop being read or written. No migration: an old row sitting unread is harmless (already the file's own stated design).

## Data flow after

Sidebar row click / `⌘K` row / `⌃1…9` / Previous·Next Session / "Enter Session" → `enterDeskSession(group)` → `workspace.activateGroup(group)` → `reloadOutline()`. One path, and it's already-live code today (the pre-existing "off the Desk" branch) — nothing new to write.

## Testing

- Delete the 7 Desk-canvas-specific test files listed above.
- `./macos/build.sh test` must pass clean — this is the real verification: any leftover reference to a deleted symbol fails the build immediately, and `WorkspaceWindowControllerTests.swift`'s existing coverage of `activateGroup`/session-switching should pass unmodified.
- No new tests: this is pure deletion, no new logic introduced.

## Rollout

Version bump per house rule (date-based `2026.8.26`, `.001` suffix if a same-day re-release is needed) via `scripts/rebuild-app.sh` — native app only, no Tauri build.
