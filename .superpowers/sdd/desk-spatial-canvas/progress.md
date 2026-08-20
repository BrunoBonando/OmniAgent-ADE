# SDD ledger — plan: docs/superpowers/plans/2026-08-18-desk-spatial-canvas.md

Baseline:
- Worktree: `.claude/worktrees/desk-canvas`
- Branch: worktree-desk-canvas
- Start: 8a84f138569ee22580ab8812ba1b076a488b007e
- Spec: `docs/superpowers/specs/2026-08-18-spatial-desk-canvas-design.md`

## Tasks

| # | Task | Status | Notes |
|---|---|---|---|
| 1 | Task 1: Close the SessionOutline gap | done | |
| 2 | Task 1b: Route the three "new pane" rows through the visible session | done | landed with Task 1 |
| 3 | Task 2: DeskCanvas node tree and tidy-tree layout | done | |
| 4 | Task 3: DeskCamera math | done | |
| 5 | Task 4: The `desk_canvas_native` settings row | done | |
| 6 | Task 5: Canvas mode in `PaneWorkspaceView` | done | |
| 7 | Task 6a: Level of detail, part 1 — viewport culling | done | |
| 8 | Task 6b: Level of detail, part 2 — the chip threshold | done | |
| 9 | Task 6c: Level of detail, part 3 — blink suppression | done | |
| 10 | Task 7: The camera flight, and every way into and out of a session | done | |
| 11 | Task 8: Inverse-camera hit testing, node drag, and the canvas gestures | done | |
| — | Review-b: the canvas keeps mouse and keyboard for the whole entry flight | done | out-of-plan fix |
| 12 | Task 9: The organigram visuals — chips and connectors | done | |
| 13 | Task 9b: Install the chips and connectors on the canvas | done | |
| 14 | Task 10a: Selecting DESK loads canvas mode | done | landed with 10c + 10d |
| 15 | Task 10b: The Desk menu — ⌘0, ⌃1…⌃9, and session stepping | done | |
| 16 | Task 10c: Toolbar items for Zoom to Fit and Enter Session | done | landed with 10a |
| 17 | Task 10d: Palette rows for Zoom to fit and Enter session | done | landed with 10a |
| 18 | Task 10e: `desk_canvas_native` — read on connect, write on change | done | |
| 19 | Task 10f: Whole suite, packaged build and install | done | + two gap fixes, see its report |

Every task's own report is beside this file, `task-<id>-report.md`. They are the
detail; this table is only the roll-call.

## Suite

- Planning-time baseline: 708 passed / 0 failed.
- After Task 10e: 982 passed / 0 failed.
- After Task 10f's four extra tests: 986 passed / 0 failed / 0 skipped
  (`caffeinate -disu ./macos/build.sh test`, 2026-08-20).

## What is NOT done

Honest list, from the task reports plus Task 10f's own reading of the tree.

1. **`dist.sh verify`'s packaged-PTY smoke check still fails on every build.**
   Pre-existing and documented in `CLAUDE.md`: `scripts/native-macos-pty-harness.py`
   still speaks the pre-Task-2 per-request JSON protocol, not the daemon's
   persistent 16-byte-envelope framing. Nothing in this plan touched it.
2. **⌃1…⌃9 cannot be verified by a test.** macOS ships "Switch to Desktop N" on
   the same chords once a second Desktop exists, and the system binding wins.
   Must be checked by hand on the installed app; the recorded fallback is to
   rebind the loop in `ApplicationMenus.install()` to ⌥⌘1…⌥⌘9.
3. **`PaneWorkspaceView.onCanvasPinsChanged` (Task 8) has no consumer.** Pins
   persist through `onDeskCanvasChanged` instead — one callback for the whole
   row. The unused hook was left in place rather than deleted.
4. **No test drives a real `.magnify` or `.scrollWheel` `NSEvent`** — AppKit
   exposes no way to build one carrying a magnification or scrolling delta.
   Both overrides are three-line adapters over methods that *are* covered.
5. **The cutover gate is untouched and stays closed** (`scripts/cutover.sh
   status`: 0/2). This was a local build, not a release-candidate cycle shipped
   to users. The web terminal hot path stays in the tree.
6. **Not merged to `main`.** The branch is pushed; the merge is Bruno's call —
   `main` has another session's uncommitted work in it.

## Log
