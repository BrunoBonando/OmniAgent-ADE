# Terminal Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Keep the UI responsive while opening up to eight terminals by spreading renderer work across frames and avoiding work for hidden panes.

**Architecture:** A small shared frame scheduler runs one terminal startup job at a time. Terminal output listeners remain active immediately and buffer bytes until their xterm instance exists. Visible panes initialize and fit progressively; hidden panes wait until visible. WebGL setup is queued separately so it cannot block first paint.

**Tech Stack:** React 19, TypeScript, xterm.js, Tauri events, Vitest.

## Global Constraints

- Preserve PTY output delivery for every session.
- Keep terminal identity stable across visibility changes.
- Do not add dependencies.
- Keep the existing Rust PTY contract unchanged.

### Task 1: Add the shared frame scheduler

**Files:**
- Create: `ui/src/lib/terminalScheduler.ts`
- Test: `ui/src/lib/terminalScheduler.test.ts`

- [x] Write a test proving queued jobs run one per animation frame and cancelled jobs do not run.
- [x] Run the focused test and verify it fails because the scheduler does not exist.
- [x] Implement the smallest queue using `requestAnimationFrame`, with a timeout fallback for non-browser tests.
- [x] Run the focused test and verify it passes.

### Task 2: Stagger terminal initialization and preserve output

**Files:**
- Modify: `ui/src/components/Terminal.tsx`

- [x] Subscribe to session output before renderer startup and buffer decoded bytes while `termRef.current` is empty.
- [x] Schedule xterm construction only when the pane is visible, one startup job per frame.
- [x] Flush buffered output after `term.open()` and retain the existing title, input, resize, drag-drop, and cleanup behavior.
- [x] Replace mount-time retry storms with frame-scheduled fits and ensure hidden panes do not fit or initialize.

### Task 3: Serialize optional WebGL setup

**Files:**
- Modify: `ui/src/components/Terminal.tsx`

- [x] Queue WebGL addon initialization after terminal startup, one job at a time, without delaying terminal output or focus.
- [x] Dispose or skip queued work during unmount.

### Task 4: Verify the performance path

- [x] Run `npm run test -- --run src/lib/terminalScheduler.test.ts src/components/Workspace.visibility.test.tsx` from the UI directory.
- [x] Run the full UI test suite: 76 files, 1177 passed, 8 skipped.
- [x] Run `npm run build`.
- [x] Inspect the diff and confirm unrelated working-tree changes remain untouched.
