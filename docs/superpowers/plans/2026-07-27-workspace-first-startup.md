# Workspace-first Startup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace eager terminal restoration with an impressive workspace chooser, then restore sessions only when the user selects them.

**Architecture:** `App.tsx` reads persisted layout as inert metadata during boot and owns the `booting | choosing-workspace | workspace-active` phase. A focused `StartupScreen` renders the loading/chooser experience. One `restoreSession(project, group)` callback is the only path that turns persisted panes into live `TabInfo` entries through the native PTY daemon.

**Tech Stack:** React 19, TypeScript, CSS, Vitest, Testing Library, existing Tauri wrappers.

## Global Constraints

- Use the native PTY daemon; add no tmux behavior.
- Add no dependency and change no MCP/Tauri command shape.
- Reuse the existing logo assets, theme tokens, persistence format, reducers, and new-workspace flow.
- Never call `getBriefing` or `sessionCreate` before explicit workspace selection.
- Respect `prefers-reduced-motion`.
- Preserve unrelated working-tree changes.

---

### Task 1: Startup loading and workspace chooser

**Files:**
- Create: `ui/src/components/StartupScreen.tsx`
- Create: `ui/src/components/StartupScreen.test.tsx`
- Modify: `ui/src/App.css`

**Interfaces:**
- Consumes: `ProjectInfo[]`, `loading: boolean`, `onSelectWorkspace(ProjectInfo)`, and `onStartFromScratch()`.
- Produces: `StartupScreen`, the full-window loading/chooser surface.

- [ ] **Step 1: Write failing component tests**

Test real rendered behavior:

```tsx
render(<StartupScreen loading projects={[]} onSelectWorkspace={vi.fn()} onStartFromScratch={vi.fn()} />);
expect(screen.getByText("Loading…")).toBeInTheDocument();
expect(screen.queryByRole("button")).not.toBeInTheDocument();
```

Then render `loading={false}` and assert `Start from scratch`, every workspace
button, and click/keyboard callbacks.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `npm --prefix ui run test -- StartupScreen.test.tsx`

Expected: FAIL because `StartupScreen` does not exist.

- [ ] **Step 3: Implement the minimum component**

Use the existing `omniagent-mark-mask.png` as a CSS mask so the mark can glow
blue. Render one semantic heading, the creation card first, and workspace
buttons in persisted order. Use a roving index only for Left/Right arrow focus;
native buttons provide Tab, Enter, Space, and focus behavior.

- [ ] **Step 4: Add focused CSS**

Add `.startup-screen`, `.startup-brand`, `.startup-logo`, `.startup-workspaces`,
and card styles. Use CSS keyframes for the blink and ready transition. Add a
`prefers-reduced-motion: reduce` block that removes animation.

- [ ] **Step 5: Run the focused test and verify GREEN**

Run: `npm --prefix ui run test -- StartupScreen.test.tsx`

Expected: PASS.

---

### Task 2: Defer boot restoration until workspace selection

**Files:**
- Create: `ui/src/App.workspaceStartup.test.tsx`
- Modify: `ui/src/App.tsx`

**Interfaces:**
- Consumes: `StartupScreen` from Task 1 and existing `deserializeLayout`,
  `getBriefing`, `sessionCreate`, and `sessionsReducer`.
- Produces: explicit startup phase, inert `PersistedTab[]` boot metadata, and
  `restoreSession(projectId, groupId?)`.

- [ ] **Step 1: Write the failing integration test**

Hold `listProjects` pending and assert `Loading…`. Resolve it and assert the
workspace chooser appears while `sessionCreate` remains untouched. Click a
workspace and assert only panes from its first persisted group are passed to
`sessionCreate`; panes from another group/project are not.

- [ ] **Step 2: Run the focused test and verify RED**

Run: `npm --prefix ui run test -- App.workspaceStartup.test.tsx`

Expected: FAIL because the existing app eagerly calls `sessionCreate`.

- [ ] **Step 3: Split metadata loading from live restoration**

In `App.tsx`:

```ts
type StartupPhase = "booting" | "choosing-workspace" | "workspace-active";
const [startupPhase, setStartupPhase] = useState<StartupPhase>("booting");
const [persistedTabs, setPersistedTabs] = useState<PersistedTab[]>([]);
const restoredGroupsRef = useRef(new Set<string>());
```

The boot effect reads and stores `deserializeLayout(raw)` but performs no
briefing or session creation. Once project, roots, closed-workspace, auth, and
layout metadata reads settle, set `choosing-workspace`.

- [ ] **Step 4: Add one lazy restore callback**

`restoreSession` filters `persistedTabs` by project and group, guards duplicate
loads through `restoredGroupsRef`, then reuses the existing per-pane
briefing/restore/fallback logic. It dispatches one `tabs/opened_bulk` after the
selected session resolves and records errors in the existing banner.

Selecting a workspace sets its id, enters `workspace-active`, and restores the
first persisted group in stored order. A workspace with no persisted panes
shows the existing empty-workspace flow.

- [ ] **Step 5: Gate the shell**

Before the normal return, render `StartupScreen` during `booting` and
`choosing-workspace`. Its creation action opens the existing
`NewWorkspaceModal`; successful creation enters the workspace shell and opens
the existing `NewSessionModal`.

- [ ] **Step 6: Run the focused tests and verify GREEN**

Run:

```sh
npm --prefix ui run test -- StartupScreen.test.tsx App.workspaceStartup.test.tsx App.bootRestore.test.tsx App.sessionRestore.test.tsx
```

Expected: PASS after adapting the two legacy restoration tests to click a
workspace before expecting live sessions.

---

### Task 3: Lazy hidden-session selection and restoration feedback

**Files:**
- Modify: `ui/src/components/Sidebar.tsx`
- Modify: `ui/src/components/Workspace.tsx`
- Modify: `ui/src/App.tsx`
- Modify: `ui/src/App.workspaceStartup.test.tsx`
- Modify: `ui/src/App.css`

**Interfaces:**
- Consumes: persisted session metadata and `restoreSession` from Task 2.
- Produces: selectable dormant session rows and a workspace-scoped
  `Loading session…` / retry surface.

- [ ] **Step 1: Extend the failing integration test**

After the first session restores, click a persisted-but-dormant session row.
Assert only that group starts. Hold its `sessionCreate` promise and assert
`Loading session…`; reject it and assert `Couldn’t restore this terminal` and
`Retry`.

- [ ] **Step 2: Run the test and verify RED**

Run: `npm --prefix ui run test -- App.workspaceStartup.test.tsx`

Expected: FAIL because dormant sessions and restoration feedback do not exist.

- [ ] **Step 3: Render dormant session metadata**

Derive project/group metadata from `PersistedTab[]` in `App.tsx` and pass only
the selected workspace's dormant groups to `Sidebar`. Render them using the
existing session-row visual language, but without live status/actions. Clicking
one calls `restoreSession(project, group)`.

- [ ] **Step 4: Render loading and retry states**

Track the one group currently restoring and failed groups in `App.tsx`. Pass
the visible restoring/error state to `Workspace`; render the compact blue mark
and `Loading session…`, or the failure copy and Retry button, instead of an
empty terminal area.

- [ ] **Step 5: Run focused and full verification**

Run:

```sh
npm --prefix ui run test -- App.workspaceStartup.test.tsx
npm --prefix ui run test
npm --prefix ui run build
```

Expected: all tests pass and the production build exits 0.

