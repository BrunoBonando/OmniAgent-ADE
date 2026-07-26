# Terminal Focus Navigation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show which terminal body is focused and navigate visible panes and workspace sessions with Ctrl shortcuts.

**Architecture:** `Workspace` owns pane navigation because it owns each visible mosaic tree and its visual pane order. A small pure helper in `sessionGroups.ts` selects adjacent sessions for App-level arrow shortcuts without adding state.

**Tech Stack:** React 19, TypeScript, Vitest, Testing Library, CSS, react-mosaic-component

## Global Constraints

- `Ctrl+Tab` cycles only terminals in the visible session and wraps.
- `Ctrl+ArrowUp` and `Ctrl+ArrowDown` move between sessions without wrapping.
- Session order is the existing first-seen order.
- Add no dependency or shortcut configuration.

---

### Task 1: Focus cue and visible-pane cycling

**Files:**
- Modify: `ui/src/components/Workspace.tsx`
- Modify: `ui/src/App.css`
- Test: `ui/src/components/Workspace.visibility.test.tsx`

**Interfaces:**
- Consumes: `paneIds(tree): string[]`, `activeTabId`, `hidden`, `onActivateTab(id)`
- Produces: `.pane-body.is-focused` and visible-grid `Ctrl+Tab` behavior

- [ ] **Step 1: Write failing behavior tests**

Render two panes in one visible session. Assert the active pane body has
`is-focused`; fire `Ctrl+Tab` on `window` and assert `onActivateTab` receives
the next pane, then rerender with it active and assert the next press wraps.
Render the same grid with `hidden={true}` and assert the shortcut is ignored.

- [ ] **Step 2: Verify the tests fail**

Run: `npm test -- Workspace.visibility.test.tsx`

Expected: FAIL because pane bodies lack `is-focused` and no Ctrl+Tab handler
activates a pane.

- [ ] **Step 3: Add the minimal implementation**

In `ProjectPaneGrid`, attach a `keydown` listener whose Ctrl+Tab branch returns
when `hidden`, obtains `const ids = paneIds(tree)`, and calls
`onActivateTab(ids[(Math.max(ids.indexOf(activeTabId ?? ""), 0) + 1) % ids.length])`
when at least two panes exist. Prevent the default only when handled. Add
`is-focused` to the active pane body's class and style it:

```css
.pane-body.is-focused {
  box-shadow: inset 0 0 0 1px color-mix(in srgb, var(--signal) 58%, transparent);
}
```

- [ ] **Step 4: Verify the focused tests pass**

Run: `npm test -- Workspace.visibility.test.tsx`

Expected: PASS.

---

### Task 2: Bounded session navigation

**Files:**
- Modify: `ui/src/state/sessionGroups.ts`
- Test: `ui/src/state/sessionGroups.test.ts`
- Modify: `ui/src/App.tsx`
- Test: `ui/src/App.newSession.test.tsx`

**Interfaces:**
- Produces: `adjacentSessionTab(tabs, project, activeTabId, offset): TabInfo | null`
- Consumes: `activateTab(id)` from `App.tsx`

- [ ] **Step 1: Write failing pure helper tests**

For three ordered session groups in one project, assert offset `1` selects the
first pane in the next group, offset `-1` selects the previous group, and both
outer boundaries return `null`.

- [ ] **Step 2: Verify helper tests fail**

Run: `npm test -- sessionGroups.test.ts`

Expected: FAIL because `adjacentSessionTab` is not exported.

- [ ] **Step 3: Implement the pure helper**

Use `groupTabsBySession(tabs, activeTabId)` to find the project sessions and
current index. Return `sessions[index + offset]?.tabs[0] ?? null`; when focus is
outside the project, use the visible first session as the starting index.

- [ ] **Step 4: Verify helper tests pass**

Run: `npm test -- sessionGroups.test.ts`

Expected: PASS.

- [ ] **Step 5: Write failing App shortcut tests**

Restore panes in three sessions, fire `Ctrl+ArrowDown` and assert the next
session becomes current. Repeat at the final session and assert it stays
there; cover `Ctrl+ArrowUp` and the first-session boundary.

- [ ] **Step 6: Verify App tests fail**

Run: `npm test -- App.newSession.test.tsx`

Expected: FAIL because App has no Ctrl+Arrow shortcut branch.

- [ ] **Step 7: Wire the shortcuts**

Extend App's existing window `keydown` effect with a Ctrl-only arrow branch.
Call `adjacentSessionTab` using `selectedProjectId`, `state.tabs`, and
`state.activeTabId`; prevent the default and call `activateTab(next.id)` only
when a destination exists.

- [ ] **Step 8: Run complete verification**

Run: `npm test`

Run: `npm run build`

Expected: all tests pass and TypeScript/Vite build succeeds.
