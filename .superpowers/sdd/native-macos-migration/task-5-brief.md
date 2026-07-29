# Task 5 — Native pane workspace

Implement Phase 4 from `docs/plans/native-macos-migration.md` on the existing native slice.

Required:

- Replace the one-terminal content view with a custom AppKit `PaneWorkspaceView`.
- Keep pane identity and `TerminalSurfaceView` instances independent from cell position; mutations and swaps must not recreate live terminal views.
- Support only the approved capacities/shapes: 1, 1×2, 2×2, 2×3, 2×4; maximum eight; column-major fill; holes for incomplete rectangles; preserve the existing 2→3 lower-left placement.
- Preserve close, grouping metadata, swap, hole repair, and directional focus semantics from `ui/src/state/paneGrid.ts` and its fixtures/tests.
- Calculate pane/divider frames directly. During live divider drag update frames immediately and coalesce PTY resize to at most one send per display refresh.
- Add responder-chain commands for directional focus, split/add, close, numeric pane selection, and swap.
- Add native drag/drop swapping and minimum `NSAccessibility` pane/terminal descriptions.
- Preserve focus across swaps/tree changes/window activation.
- Fully occluded panes may suspend expensive drawing, but parser/output state must continue bounded; do not create a second renderer or scheduler unless measurements prove SwiftTerm needs it.
- Add focused XCTest coverage for shapes, holes, identity preservation, focus, swap/drop, accessibility, and resize coalescing. Add an attached eight-pane divider/renderer benchmark, label its limits honestly, and retain external hardware gate status.
- Keep code minimal and native; reuse `TerminalSurfaceView`, `SessionConnection`, AppKit drag/drop, responder chain, and display-link primitives already present.

Verification:

- `./macos/build.sh test`
- `./macos/build.sh build`
- affected Rust/Tauri protocol tests
- `git diff --check`

Commit all Task 5 work and write `.superpowers/sdd/native-macos-migration/task-5-report.md`.
