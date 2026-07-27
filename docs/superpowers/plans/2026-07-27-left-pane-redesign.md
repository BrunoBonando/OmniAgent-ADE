# Left Pane (Workspaces · Sessions · Terminals · Files) Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the left sidebar to the new design (`design/OmniAgent ADE.dc.html` + `design/ANALYSIS.md`): single active workspace with a switcher + dropdown, session rows with status-dot clusters and layout badges, terminal rows with masked status marks, an in-sidebar FILES tree with live git badges, and fully working New Terminal (⌘T), New Session (⌘N) and New Workspace modals. Login/auth gate untouched.

**Architecture:** This is a restyle + restructure of existing components, not new architecture. State stays in `App.tsx` (`useReducer` + pure modules in `ui/src/state/`), all Tauri IPC stays in `ui/src/lib/tauri.ts`, all styling stays in `ui/src/App.css` with the existing token/`.is-*` conventions. One new Rust command (`folder_stats`) backs the New Workspace stats strip; everything else reuses existing commands (`review_status`, `roots_set_paused`, `add_project`, `session_write`, …).

**Tech Stack:** React 19 + TS 5.8 + Vite 7, vitest 4 + jsdom + @testing-library/react, Tauri 2 (Rust).

## Global Constraints

- **No new JS dependencies.** Rust side may use the `ignore` crate only if already in the workspace; otherwise `walkdir`-free manual walk (see Task 12).
- **Working directory for all UI work:** `/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/ui`. Ignore `.claude/worktrees/agent-picker/` — stale copy.
- **Status vocabulary is fixed:** `SessionStatus = "ready" | "thinking" | "tool_execution" | "awaiting_approval" | "error"` (`ui/src/state/sessionStatus.ts`). The design's blue/amber/green/gray dots map through `statusPresentation()` → `colorVar`/`motion`. Never introduce "working/done/idle/failed" names.
- **Limits:** `MAX_PANES = 8`, `LAYOUT_PRESETS = [1, 2, 4, 6, 8]` (`ui/src/state/paneGrid.ts`).
- **Engines:** `AVAILABLE_AGENTS = ["claude", "codex", "shell", "copilot", "antigravity"]` (`ui/src/state/agents.ts`). Labels/hints/icons from `ui/src/theme.ts` (`ENGINE_LABEL`, `ENGINE_HINT`, `ENGINE_COLOR`, `AGENT_ICON`) — never hardcode engine names in components.
- **CSS:** all rules appended to `ui/src/App.css`; state via `.is-*` classes; per-instance values via inline CSS custom properties (`--session-tint`, `--pct`, …). Tokens from Task 1 (`--accent`, `--accent-hi`, `--accent-btn`, …) — no raw `#8b95ff` literals outside `:root`.
- **Tests:** vitest; component tests follow `Sidebar.test.tsx` pattern (`vi.hoisted` mock bag → `vi.mock("../lib/tauri", …)` → dynamic import → `setup(overrides)` helper). App tests follow `App.closeWorkspace.test.tsx` (stub child components with button-emitting stand-ins). Existing tests assert on CSS class names — every task that renames/removes a class greps `ui/src/**/*.test.tsx` for it and updates.
- **Do not remove working features not present in the mock:** SessionHoverCard, Workspace/Map view toggle, import flow, close confirms, ProjectMenu (rename/pause/re-ingest). They get re-homed, not deleted (Tasks 2–3).
- **Copy strings verbatim from the design** (each task lists its strings). Placeholder numbers in the mock (41,208 nodes, +1284 −312, "8m ago") are narrative — real values come from `ingestionStatus().total_nodes`, `review_status`, etc.
- **Login:** `AuthGate`/onboarding auth files are out of scope. Do not touch `onboarding/authGateState.ts`.
- Conventional commits, one commit per task minimum. Run `npm test` from `ui/` before every commit.

## Design → Task map

| Design piece (ANALYSIS.md §) | Task |
|---|---|
| Accent/indigo tokens, focus ring, keyframes (§4) | 1 |
| Workspace dropdown (§3 `workspaceMenu`) | 2 |
| Workspace switcher + single-workspace sidebar skeleton (§2 Sidebar) | 3 |
| Session rows: accent bar, chevron, dot cluster, layout badge (§2) | 4 |
| Terminal rows + "New terminal" row (§2) | 5 |
| FILES section in sidebar: header, filter, tree (§2) | 6 |
| Git badges: "14 changed", folder counts, M/A letters (§2) | 7 |
| Account row: "Brain indexed · Xm ago" (§2) | 8 |
| New terminal modal ⌘T (§3) | 9 |
| New session modal ⌘N: prompt-as-name, layout thumbs, engine-per-terminal (§3) | 10 |
| Prompt becomes first prompt in the terminal (§3) | 11 |
| New workspace modal: stats strip, toggles (§3) | 12 |
| ⌘N direct, retire chooser, shortcut sheet, cleanup (§ keyboard map) | 13 |

---

### Task 1: Accent tokens + modal/switch primitives

**Files:**
- Modify: `ui/src/App.css` (`:root` block, lines ~38–171; append new section at end of file)

**Interfaces:**
- Produces CSS custom properties every later task uses: `--accent`, `--accent-hi`, `--accent-btn`, `--accent-btn-hover`, `--accent-tint`, `--accent-tint-strong`, `--accent-ring`.
- Produces shared classes: `.modal-panel`, `.modal-header`, `.modal-footer`, `.modal-field-label`, `.modal-text-input`, `.btn-primary`, `.btn-ghost`, `.switch` — used by Tasks 9, 10, 12.

- [ ] **Step 1: Add tokens to `:root`**

In `ui/src/App.css`, inside the existing `:root` block, add:

```css
  /* Redesign accent — brand indigo (design/ANALYSIS.md §4). */
  --accent: #8b95ff;
  --accent-hi: #a7afff;
  --accent-btn: #5f6bff;
  --accent-btn-hover: #7079ff;
  --accent-tint: rgba(139, 149, 255, 0.14);
  --accent-tint-strong: rgba(139, 149, 255, 0.18);
  --accent-ring: rgba(139, 149, 255, 0.16);
```

- [ ] **Step 2: Append modal/button/switch primitives**

At the end of `App.css`, add a clearly-bannered section:

```css
/* ============================================================ redesign:
   shared modal + control primitives (Tasks 9/10/12 consume these). */
.modal-panel {
  border-radius: 14px;
  background: rgba(32, 32, 36, 0.98);
  border: 0.5px solid rgba(255, 255, 255, 0.14);
  box-shadow: 0 40px 90px rgba(0, 0, 0, 0.7);
  overflow: hidden;
}
.modal-header {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 14px 16px 12px;
  border-bottom: 0.5px solid rgba(255, 255, 255, 0.08);
  font: 600 14px/1 var(--sans);
  color: var(--ink);
}
.modal-header-context { font: 400 11.5px/1 var(--sans); color: #7c7c86; }
.modal-header-key { margin-left: auto; font: 500 10px/1 var(--mono); color: #5c5c66; }
.modal-footer {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 11px 16px;
  background: rgba(0, 0, 0, 0.25);
  border-top: 0.5px solid rgba(255, 255, 255, 0.08);
}
.modal-footer-hint { flex: 1; font: 400 10.5px/1.35 var(--sans); color: #6d6d78; }
.modal-field-label {
  font: 600 10px/1 var(--sans);
  letter-spacing: 0.07em;
  color: #65656f;
  margin-bottom: 7px;
  text-transform: uppercase;
}
.modal-field-help { font: 400 10.5px/1.4 var(--sans); color: #5c5c66; margin-top: 6px; }
.modal-text-input {
  width: 100%;
  height: 36px;
  padding: 0 11px;
  border-radius: 9px;
  background: rgba(0, 0, 0, 0.35);
  border: 1px solid rgba(255, 255, 255, 0.1);
  font: 400 13px/1 var(--sans);
  color: #e8e8ee;
  outline: none;
}
.modal-text-input:focus {
  border-color: rgba(139, 149, 255, 0.55);
  box-shadow: 0 0 0 3px var(--accent-ring);
}
.btn-primary {
  appearance: none;
  border: 0;
  background: var(--accent-btn);
  color: #fff;
  font: 600 11.5px/1 var(--sans);
  padding: 8px 15px;
  border-radius: 8px;
  cursor: pointer;
  box-shadow: 0 2px 10px rgba(95, 107, 255, 0.35);
}
.btn-primary:hover { background: var(--accent-btn-hover); }
.btn-primary:disabled { opacity: 0.45; cursor: default; }
.btn-ghost {
  appearance: none;
  border: 0.5px solid rgba(255, 255, 255, 0.14);
  background: rgba(255, 255, 255, 0.05);
  color: #c2c2cb;
  font: 500 11.5px/1 var(--sans);
  padding: 8px 14px;
  border-radius: 8px;
  cursor: pointer;
}
.btn-ghost:hover { background: rgba(255, 255, 255, 0.1); }
.switch {
  appearance: none;
  width: 34px;
  height: 20px;
  flex: none;
  border-radius: 10px;
  background: rgba(255, 255, 255, 0.13);
  position: relative;
  cursor: pointer;
  border: 0;
  transition: background 120ms ease;
}
.switch::after {
  content: "";
  position: absolute;
  top: 2px;
  left: 2px;
  width: 16px;
  height: 16px;
  border-radius: 50%;
  background: #8b8b95;
  transition: transform 120ms ease, background 120ms ease;
}
.switch[aria-checked="true"] { background: var(--accent-btn); }
.switch[aria-checked="true"]::after { transform: translateX(14px); background: #fff; }
```

- [ ] **Step 3: Verify build**

Run from `ui/`: `npm run build`
Expected: build succeeds (CSS is append-only, nothing consumes it yet).

- [ ] **Step 4: Commit**

```bash
git add ui/src/App.css
git commit -m "feat(theme): accent tokens + shared modal/button/switch primitives"
```

---

### Task 2: WorkspaceMenu dropdown

**Files:**
- Create: `ui/src/components/WorkspaceMenu.tsx`
- Test: `ui/src/components/WorkspaceMenu.test.tsx`
- Modify: `ui/src/App.css` (append `.workspace-menu*` rules)

**Interfaces:**
- Consumes: `ProjectInfo` from `../state/sessions`; `idColor` — currently a private helper in `Sidebar.tsx` (L151–157, `PROJECT_AVATAR_COLORS`). **Move both into a new `ui/src/state/projectColors.ts`** (`export const PROJECT_AVATAR_COLORS`, `export function idColor(id: string): string` — bodies unchanged) and re-import in Sidebar. Do NOT export from Sidebar.tsx: WorkspaceMenu/WorkspaceSwitcher importing Sidebar would be circular and would drag Sidebar's tauri imports into their tests.
- Produces (Task 3 consumes):

```ts
export function sessionCountLabel(n: number): string; // "no sessions" | "1 session" | "3 sessions"

export interface WorkspaceMenuProps {
  projects: ProjectInfo[];
  activeProjectId: string | null;
  sessionCounts: Map<string, number>; // project.id -> session count
  onSelect: (project: ProjectInfo) => void;
  onNewWorkspace: () => void;
  onImport: () => void;
  onManage: (project: ProjectInfo) => void; // opens existing ProjectMenu for rename/pause/re-ingest
  onClose: () => void;
}
export function WorkspaceMenu(props: WorkspaceMenuProps): JSX.Element;
```

- [ ] **Step 1: Write the failing test**

`ui/src/components/WorkspaceMenu.test.tsx`:

```tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { WorkspaceMenu, sessionCountLabel } from "./WorkspaceMenu";
import type { ProjectInfo } from "../state/sessions";

const projects: ProjectInfo[] = [
  { id: "omni", label: "OmniAgent", path: "/u/b/OmniAgent-ADE" },
  { id: "voice", label: "Voice", path: "/u/b/voice-latency" },
];

function setup(overrides: Partial<Parameters<typeof WorkspaceMenu>[0]> = {}) {
  const props = {
    projects,
    activeProjectId: "omni",
    sessionCounts: new Map([["omni", 3], ["voice", 1]]),
    onSelect: vi.fn(),
    onNewWorkspace: vi.fn(),
    onImport: vi.fn(),
    onManage: vi.fn(),
    onClose: vi.fn(),
    ...overrides,
  };
  return { ...render(<WorkspaceMenu {...props} />), props };
}

describe("sessionCountLabel", () => {
  it("pluralizes", () => {
    expect(sessionCountLabel(0)).toBe("no sessions");
    expect(sessionCountLabel(1)).toBe("1 session");
    expect(sessionCountLabel(3)).toBe("3 sessions");
  });
});

describe("WorkspaceMenu", () => {
  it("lists workspaces with counts, active row checked", () => {
    const { container } = setup();
    expect(screen.getByText("WORKSPACES")).toBeInTheDocument();
    expect(screen.getByText("3 sessions")).toBeInTheDocument();
    expect(screen.getByText("1 session")).toBeInTheDocument();
    const active = container.querySelector(".workspace-menu-row.is-active");
    expect(active).toHaveTextContent("OmniAgent");
  });

  it("selects an inactive workspace and closes", () => {
    const { props } = setup();
    fireEvent.click(screen.getByText("Voice"));
    expect(props.onSelect).toHaveBeenCalledWith(projects[1]);
    expect(props.onClose).toHaveBeenCalled();
  });

  it("New workspace and Import rows fire and close", () => {
    const { props } = setup();
    fireEvent.click(screen.getByText("New workspace"));
    expect(props.onNewWorkspace).toHaveBeenCalled();
    fireEvent.click(screen.getByText("Import projects…"));
    expect(props.onImport).toHaveBeenCalled();
  });

  it("backdrop click and Escape close without selecting", () => {
    const { container, props } = setup();
    fireEvent.mouseDown(container.querySelector(".workspace-menu-backdrop")!);
    expect(props.onClose).toHaveBeenCalledTimes(1);
    expect(props.onSelect).not.toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run from `ui/`: `npx vitest run src/components/WorkspaceMenu.test.tsx`
Expected: FAIL — module `./WorkspaceMenu` not found.

- [ ] **Step 3: Implement `WorkspaceMenu.tsx`**

```tsx
// Workspace dropdown (design ANALYSIS.md §3 "workspaceMenu"): anchored under
// the sidebar's workspace switcher. Lists every open workspace with its
// session count, checkmarks the active one, and carries the New-workspace
// and Import entry points that used to live in the sidebar header.
import { useEffect, useRef } from "react";
import type { ProjectInfo } from "../state/sessions";
import { idColor } from "../state/projectColors";

export function sessionCountLabel(n: number): string {
  if (n === 0) return "no sessions";
  return n === 1 ? "1 session" : `${n} sessions`;
}

export interface WorkspaceMenuProps {
  projects: ProjectInfo[];
  activeProjectId: string | null;
  sessionCounts: Map<string, number>;
  onSelect: (project: ProjectInfo) => void;
  onNewWorkspace: () => void;
  onImport: () => void;
  onManage: (project: ProjectInfo) => void;
  onClose: () => void;
}

export function WorkspaceMenu({
  projects, activeProjectId, sessionCounts,
  onSelect, onNewWorkspace, onImport, onManage, onClose,
}: WorkspaceMenuProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  useEffect(() => { panelRef.current?.focus(); }, []);

  return (
    <>
      <div className="workspace-menu-backdrop" onMouseDown={onClose} />
      <div
        className="workspace-menu"
        role="menu"
        tabIndex={-1}
        ref={panelRef}
        onKeyDown={(e) => { if (e.key === "Escape") onClose(); }}
      >
        <div className="workspace-menu-header">
          <span className="workspace-menu-title">WORKSPACES</span>
          <span className="workspace-menu-count">{projects.length}</span>
        </div>
        {projects.map((p) => {
          const active = p.id === activeProjectId;
          return (
            <div
              key={p.id}
              role="menuitem"
              className={`workspace-menu-row${active ? " is-active" : ""}`}
              onClick={() => { if (!active) onSelect(p); onClose(); }}
            >
              <span
                className="workspace-menu-avatar"
                style={{ background: idColor(p.id) }}
                aria-hidden
              >
                {p.label.slice(0, 1).toUpperCase()}
              </span>
              <span className="workspace-menu-identity">
                <span className="workspace-menu-name">{p.label}</span>
                <span className="workspace-menu-path">{p.path ?? ""}</span>
              </span>
              <span className="workspace-menu-sessions">
                {sessionCountLabel(sessionCounts.get(p.id) ?? 0)}
              </span>
              <button
                type="button"
                className="workspace-menu-manage"
                title="Workspace settings"
                onClick={(e) => { e.stopPropagation(); onManage(p); }}
              >
                ⋯
              </button>
              {active ? (
                <span className="workspace-menu-check" aria-label="Active workspace">✓</span>
              ) : (
                <span className="workspace-menu-check-slot" />
              )}
            </div>
          );
        })}
        <div className="workspace-menu-divider" />
        <div role="menuitem" className="workspace-menu-new" onClick={() => { onNewWorkspace(); onClose(); }}>
          <span className="workspace-menu-new-tile">+</span>
          <span>New workspace</span>
        </div>
        <div role="menuitem" className="workspace-menu-new" onClick={() => { onImport(); onClose(); }}>
          <span className="workspace-menu-new-tile">⇥</span>
          <span>Import projects…</span>
        </div>
      </div>
    </>
  );
}
```

And create `ui/src/state/projectColors.ts` by cutting `PROJECT_AVATAR_COLORS` + `idColor` out of `Sidebar.tsx` (bodies unchanged, both `export`ed); Sidebar imports them from there.

- [ ] **Step 4: Append `.workspace-menu*` CSS to App.css**

```css
/* redesign: workspace dropdown under the switcher (Task 2). */
.workspace-menu-backdrop { position: fixed; inset: 0; z-index: 50; }
.workspace-menu {
  position: absolute;
  top: 46px;
  left: 9px;
  z-index: 60;
  width: 264px;
  border-radius: 12px;
  background: rgba(34, 34, 38, 0.98);
  backdrop-filter: blur(30px) saturate(180%);
  border: 0.5px solid rgba(255, 255, 255, 0.14);
  box-shadow: 0 24px 56px rgba(0, 0, 0, 0.62);
  padding: 5px;
  outline: none;
}
.workspace-menu-header { display: flex; align-items: center; gap: 6px; padding: 7px 9px 6px; }
.workspace-menu-title { font: 600 9.5px/1 var(--sans); letter-spacing: 0.09em; color: #65656f; }
.workspace-menu-count { font: 600 9.5px/1 var(--mono); color: #4a4a53; }
.workspace-menu-row {
  display: flex;
  align-items: center;
  gap: 9px;
  padding: 7px 8px;
  border-radius: 8px;
  cursor: pointer;
}
.workspace-menu-row:hover { background: rgba(255, 255, 255, 0.07); }
.workspace-menu-row.is-active { background: var(--accent-tint-strong); cursor: default; }
.workspace-menu-avatar {
  width: 22px; height: 22px; flex: none;
  border-radius: 5px;
  display: flex; align-items: center; justify-content: center;
  font: 600 10px/1 var(--sans); color: #fff;
}
.workspace-menu-identity { flex: 1; min-width: 0; }
.workspace-menu-name {
  display: block;
  font: 500 11.5px/1.3 var(--sans); color: #d2d2da;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.workspace-menu-row.is-active .workspace-menu-name { font-weight: 600; color: var(--ink); }
.workspace-menu-path {
  display: block;
  font: 400 9.5px/1.3 var(--mono); color: #65656f;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.workspace-menu-sessions { flex: none; font: 500 9.5px/1 var(--sans); color: #65656f; }
.workspace-menu-check { flex: none; width: 12px; color: var(--accent-hi); font-size: 11px; }
.workspace-menu-check-slot { flex: none; width: 12px; }
.workspace-menu-manage {
  appearance: none; border: 0; background: transparent;
  color: #7c7c86; width: 18px; height: 18px; border-radius: 5px;
  cursor: pointer; display: none;
}
.workspace-menu-row:hover .workspace-menu-manage { display: block; }
.workspace-menu-manage:hover { background: rgba(255, 255, 255, 0.1); color: var(--ink); }
.workspace-menu-divider { height: 0.5px; background: rgba(255, 255, 255, 0.09); margin: 5px 9px; }
.workspace-menu-new {
  display: flex; align-items: center; gap: 9px;
  padding: 8px 9px; border-radius: 8px; cursor: pointer;
  font: 600 11.5px/1.3 var(--sans); color: #dfe2ff;
}
.workspace-menu-new:hover { background: var(--accent-tint-strong); }
.workspace-menu-new-tile {
  width: 22px; height: 22px; flex: none;
  border-radius: 6px;
  background: var(--accent-tint-strong);
  border: 0.5px dashed rgba(139, 149, 255, 0.5);
  display: flex; align-items: center; justify-content: center;
  color: var(--accent-hi); font: 400 13px/1 var(--sans);
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `npx vitest run src/components/WorkspaceMenu.test.tsx`
Expected: PASS (all 5).

- [ ] **Step 6: Commit**

```bash
git add ui/src/components/WorkspaceMenu.tsx ui/src/components/WorkspaceMenu.test.tsx ui/src/state/projectColors.ts ui/src/components/Sidebar.tsx ui/src/App.css
git commit -m "feat(sidebar): workspace dropdown menu with session counts"
```

---

### Task 3: WorkspaceSwitcher + single-workspace sidebar skeleton

The structural pivot: the sidebar stops listing every project and instead shows **one active workspace** (switcher at top) with its sessions below. Other workspaces are reached through Task 2's dropdown.

**Files:**
- Create: `ui/src/components/WorkspaceSwitcher.tsx`
- Test: `ui/src/components/WorkspaceSwitcher.test.tsx`
- Modify: `ui/src/components/Sidebar.tsx` (render tree, ~L400–590), `ui/src/components/Sidebar.test.tsx`, `ui/src/App.tsx` (one new prop), `ui/src/App.css`

**Interfaces:**
- Consumes: `WorkspaceMenu`, `sessionCountLabel` (Task 2); `idColor` (exported in Task 2).
- Produces:

```ts
export interface WorkspaceSwitcherProps {
  project: ProjectInfo | null; // null → "No workspace" / "choose or add one"
  open: boolean;               // menu open → chevrons highlighted
  onToggle: () => void;
}
export function WorkspaceSwitcher(props: WorkspaceSwitcherProps): JSX.Element;
```

- New `SidebarProps` member (App passes it): `onOpenNewTerminal: () => void;` — Task 5's "New terminal" row and Task 9's modal both route through it. In this task App wires it to the existing `requestNewTab(selectedProject)` behavior (Task 9 swaps the handler to open the modal).
- Sidebar keeps ALL existing props. `projects`, `onSelectProject`, `onOpenNewWorkspace`, import/rename/close/pause plumbing now feed the switcher + menu instead of the row list.

- [ ] **Step 1: Write the failing WorkspaceSwitcher test**

`ui/src/components/WorkspaceSwitcher.test.tsx`:

```tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { WorkspaceSwitcher } from "./WorkspaceSwitcher";

describe("WorkspaceSwitcher", () => {
  it("shows active workspace name, path and WORKSPACE microlabel", () => {
    render(
      <WorkspaceSwitcher
        project={{ id: "omni", label: "OmniAgent", path: "/u/b/OmniAgent-ADE" }}
        open={false}
        onToggle={vi.fn()}
      />,
    );
    expect(screen.getByText("OmniAgent")).toBeInTheDocument();
    expect(screen.getByText("/u/b/OmniAgent-ADE")).toBeInTheDocument();
    expect(screen.getByText("WORKSPACE")).toBeInTheDocument();
  });

  it("falls back when no workspace is open", () => {
    render(<WorkspaceSwitcher project={null} open={false} onToggle={vi.fn()} />);
    expect(screen.getByText("No workspace")).toBeInTheDocument();
    expect(screen.getByText("choose or add one")).toBeInTheDocument();
  });

  it("toggles the menu on click", () => {
    const onToggle = vi.fn();
    render(
      <WorkspaceSwitcher
        project={{ id: "omni", label: "OmniAgent", path: null }}
        open={false}
        onToggle={onToggle}
      />,
    );
    fireEvent.click(screen.getByRole("button"));
    expect(onToggle).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run it — expect FAIL** (`npx vitest run src/components/WorkspaceSwitcher.test.tsx`, module not found)

- [ ] **Step 3: Implement `WorkspaceSwitcher.tsx`**

```tsx
// The sidebar's top control (design ANALYSIS.md §2 "Workspace switcher"):
// active workspace identity + the trigger for WorkspaceMenu. The sidebar
// shows exactly one workspace at a time; this is how you leave it.
import type { ProjectInfo } from "../state/sessions";
import { idColor } from "../state/projectColors";

export interface WorkspaceSwitcherProps {
  project: ProjectInfo | null;
  open: boolean;
  onToggle: () => void;
}

export function WorkspaceSwitcher({ project, open, onToggle }: WorkspaceSwitcherProps) {
  return (
    <button
      type="button"
      className={`workspace-switcher${open ? " is-open" : ""}`}
      onClick={onToggle}
      aria-haspopup="menu"
      aria-expanded={open}
    >
      <span
        className="workspace-switcher-avatar"
        style={{ background: project ? idColor(project.id) : "rgba(255,255,255,.12)" }}
        aria-hidden
      >
        {project ? project.label.slice(0, 1).toUpperCase() : "?"}
      </span>
      <span className="workspace-switcher-identity">
        <span className="workspace-switcher-name">{project?.label ?? "No workspace"}</span>
        <span className="workspace-switcher-path">{project?.path ?? "choose or add one"}</span>
      </span>
      <span className="workspace-switcher-microlabel">WORKSPACE</span>
      <span className="workspace-switcher-chevrons" aria-hidden>⌃⌄</span>
    </button>
  );
}
```

CSS (append to App.css):

```css
/* redesign: workspace switcher (Task 3). */
.workspace-switcher {
  appearance: none;
  width: calc(100% - 18px);
  margin: 9px 9px 7px;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 7px 8px;
  border-radius: 7px;
  border: 0.5px solid rgba(255, 255, 255, 0.08);
  background: rgba(255, 255, 255, 0.045);
  cursor: pointer;
  text-align: left;
}
.workspace-switcher:hover, .workspace-switcher.is-open { background: rgba(255, 255, 255, 0.08); }
.workspace-switcher-avatar {
  width: 20px; height: 20px; flex: none;
  border-radius: 5px;
  display: flex; align-items: center; justify-content: center;
  font: 600 9.5px/1 var(--sans); color: #fff;
}
.workspace-switcher-identity { flex: 1; min-width: 0; }
.workspace-switcher-name {
  display: block;
  font: 600 11.5px/1.25 var(--sans); color: #e6e6ec;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.workspace-switcher-path {
  display: block;
  font: 400 9.5px/1.3 var(--mono); color: #65656f;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.workspace-switcher-microlabel { flex: none; font: 500 9px/1 var(--sans); color: #5c5c66; padding-right: 2px; }
.workspace-switcher-chevrons { flex: none; font: 400 8px/0.5 var(--sans); color: #8a8a94; letter-spacing: -1px; }
```

- [ ] **Step 4: Run the switcher test — expect PASS**

- [ ] **Step 5: Restructure `Sidebar.tsx`**

Replace the header + `.project-list` block with the new skeleton. Concretely:

1. Add local state `menuOpen` (boolean) next to the existing `menuProjectId` state.
2. Derive `selectedProject = projects.find(p => p.id === selectedProjectId) ?? null` and `sessionCounts` (from the existing `groupTabsBySession(tabs, activeTabId)` result: `Map(project.id -> sessions.length)`).
3. New render tree (keep `.sidebar` root class):

```tsx
<div className="sidebar">
  <div className="sidebar-switcher-anchor">
    <WorkspaceSwitcher project={selectedProject} open={menuOpen} onToggle={() => setMenuOpen(o => !o)} />
    {menuOpen && (
      <WorkspaceMenu
        projects={projects}
        activeProjectId={selectedProjectId}
        sessionCounts={sessionCounts}
        onSelect={onSelectProject}
        onNewWorkspace={onOpenNewWorkspace}
        onImport={() => setImportOpen(true)}
        onManage={(p) => setMenuProjectId(p.id)}
        onClose={() => setMenuOpen(false)}
      />
    )}
  </div>
  {/* keep the existing Workspace/Map view toggle block verbatim */}
  <div className="sidebar-sessions-header">
    <span className="sidebar-microlabel">SESSIONS</span>
    <span className="sidebar-microcount">{selectedSessions.length}</span>
    <span className="sidebar-spacer" />
    <button className="sidebar-sessions-add" title="New session"
      onClick={() => selectedProject && onNewSessionInProject?.(selectedProject)}>+</button>
  </div>
  <div className="sidebar-session-list">
    {selectedSessions.map(session => (
      <SidebarSessionRow key={session.id} ... /> /* unchanged props in this task */
    ))}
  </div>
  {/* FILES section arrives in Task 6; account footer stays as-is */}
  <div className="sidebar-footer"><AccountBadge ... /></div>
  {/* keep all existing overlays: AboutPanel, ReviewPanel, NewWorkspaceModal,
     ImportProjectsFlow, CloseSessionConfirm, CloseWorkspaceConfirm, and
     ProjectMenu (now anchored to the menu row via menuProjectId) */}
</div>
```

Where `selectedSessions` = the `SessionGroup[]` for `selectedProjectId` from the existing `groupTabsBySession` derivation (empty array when no project). The old per-project rows (`.project-row*`), `attentionByProject` dots, pressure badge and header import/add buttons are removed from the render tree — their functions now live in the switcher menu (add/import/manage) and the session rows themselves. Keep `pausedProjects`/`staleness` state: `ProjectMenu` still consumes them via `onManage`.

Supporting CSS (append):

```css
/* redesign: sidebar skeleton (Task 3). */
.sidebar-switcher-anchor { position: relative; flex: none; }
.sidebar-sessions-header { flex: none; display: flex; align-items: center; gap: 6px; padding: 4px 14px 5px; }
.sidebar-microlabel { font: 600 9.5px/1 var(--sans); letter-spacing: 0.1em; color: #65656f; }
.sidebar-microcount { font: 600 9.5px/1 var(--mono); color: #4a4a53; }
.sidebar-spacer { flex: 1; }
.sidebar-sessions-add {
  appearance: none; border: 0; background: transparent;
  color: #7c7c86; width: 18px; height: 18px; border-radius: 5px;
  cursor: pointer; font: 400 13px/1 var(--sans);
  display: flex; align-items: center; justify-content: center;
}
.sidebar-sessions-add:hover { background: rgba(255, 255, 255, 0.1); color: var(--ink); }
.sidebar-session-list { flex: none; padding: 0 6px 6px; display: flex; flex-direction: column; gap: 1px; }
```

4. In `App.tsx`: pass `onOpenNewTerminal={() => { if (selectedProject) void requestNewTab(selectedProject); }}` (find `selectedProject` derivation already used for ⌘T at L1267–1293 and reuse it). Add `onOpenNewTerminal: () => void;` to `SidebarProps`.

- [ ] **Step 6: Update `Sidebar.test.tsx`**

Rewrite assertions that referenced `.project-row*` structure: the multi-project expectations become menu expectations. Keep the `setup(overrides)` helper; add `onOpenNewTerminal: vi.fn()` to its default props. Replace removed cases with:

```tsx
it("shows the active workspace in the switcher, not a project list", () => {
  const { container } = setup();
  expect(container.querySelector(".workspace-switcher")).toBeInTheDocument();
  expect(container.querySelector(".project-list")).toBeNull();
});

it("opens the workspace menu and switches project", () => {
  const { container, props } = setup();
  fireEvent.click(container.querySelector(".workspace-switcher")!);
  fireEvent.click(screen.getByText(/other project label/i));
  expect(props.onSelectProject).toHaveBeenCalled();
});

it("SESSIONS header + shows only the selected project's sessions", () => {
  const { container } = setup();
  expect(screen.getByText("SESSIONS")).toBeInTheDocument();
  // sessions of the non-selected project must not render
});
```

(Adapt names to the helper's existing fixture projects/tabs.)

- [ ] **Step 7: Run the full suite**

Run: `npm test`
Expected: PASS. App-level tests stub Sidebar, so only `Sidebar.test.tsx` needed the rewrite; fix any stragglers that grep `.project-row` (`grep -rn "project-row" src/**/*.test.tsx`).

- [ ] **Step 8: Commit**

```bash
git add -A ui/src
git commit -m "feat(sidebar): single-workspace skeleton with switcher + dropdown"
```

---

### Task 4: Session rows — accent bar, chevron, status-dot cluster, layout badge

**Files:**
- Modify: `ui/src/components/SidebarSessionRow.tsx`, `ui/src/components/SidebarSessionRow.test.tsx`, `ui/src/components/Sidebar.tsx` (pass new props), `ui/src/App.css`
- Modify: `ui/src/state/sessionGroups.ts` + `ui/src/state/sessionGroups.test.ts` (new pure helper)

**Interfaces:**
- Consumes: `statusPresentation` from `../state/sessionStatus` (per-tab dot color/motion), `gridShape` from `../state/paneGrid`.
- Produces in `state/sessionGroups.ts`:

```ts
/** "1" | "1×2" | "2×2" | "3×2" | "4×2" — sidebar layout badge (rows×cols of gridShape). */
export function sessionShapeBadge(paneCount: number): string;
```

- New `SidebarSessionRowProps` (Task 5 adds terminal rows inside):

```ts
interface SidebarSessionRowProps {
  session: SessionGroup;
  isCurrent: boolean;
  expanded: boolean;
  activeTabId: string | null;
  onActivate: () => void;
  onToggleExpanded: () => void;
  onActivateTab: (tabId: string) => void;
  onRename: (name: string) => void;
  onClose?: () => void;
  onOpenNewTerminal?: () => void; // rendered as the "New terminal" row when current (Task 5)
}
```

- Expansion state lives in Sidebar: `expandedSessions: Set<string>` initialized empty; a session is expanded when `expandedSessions.has(session.id) || session.isCurrent` (current session always open, matching the mock).

- [ ] **Step 1: Write failing tests**

Add to `ui/src/state/sessionGroups.test.ts`:

```ts
import { sessionShapeBadge } from "./sessionGroups";

describe("sessionShapeBadge", () => {
  it("matches the design's badges", () => {
    expect(sessionShapeBadge(1)).toBe("1");
    expect(sessionShapeBadge(2)).toBe("1×2");
    expect(sessionShapeBadge(4)).toBe("2×2");
    expect(sessionShapeBadge(6)).toBe("2×3");
    expect(sessionShapeBadge(8)).toBe("2×4");
  });
});
```

Rewrite `SidebarSessionRow.test.tsx` core cases (keep the file's existing mock scaffolding for `useGitBranch`/tauri):

```tsx
it("renders one status dot per pane, colored by status", () => {
  const { container } = setup({
    session: sessionWith([
      tab({ id: "a", status: "thinking" }),
      tab({ id: "b", status: "awaiting_approval" }),
      tab({ id: "c", status: "ready" }),
      tab({ id: "d", status: undefined }),
    ]),
  });
  const dots = container.querySelectorAll(".session-row-dot");
  expect(dots).toHaveLength(4);
  expect(dots[0].getAttribute("data-status")).toBe("thinking");
  expect(dots[1].getAttribute("data-status")).toBe("awaiting_approval");
  expect(dots[3].getAttribute("data-status")).toBe("unknown");
});

it("shows the layout badge", () => {
  setup({ session: sessionWith([tab({}), tab({}), tab({}), tab({})]) });
  expect(screen.getByText("2×2")).toBeInTheDocument();
});

it("current row gets the accent bar and rotated chevron", () => {
  const { container } = setup({ isCurrent: true, expanded: true });
  expect(container.querySelector(".session-row.is-current .session-row-accent")).toBeInTheDocument();
  expect(container.querySelector(".session-row-chevron.is-expanded")).toBeInTheDocument();
});

it("chevron toggles expansion without activating", () => {
  const { container, props } = setup({ expanded: false });
  fireEvent.click(container.querySelector(".session-row-chevron")!);
  expect(props.onToggleExpanded).toHaveBeenCalled();
  expect(props.onActivate).not.toHaveBeenCalled();
});
```

(`sessionWith`/`tab` are tiny local fixture builders — add them to the test file: `tab` fills `{id, project:"p", engine:"claude", cwd:"/p", createdAt:1, group:"g"}`, `sessionWith(tabs)` fills a `SessionGroup`.)

- [ ] **Step 2: Run — expect FAIL** (`npx vitest run src/state/sessionGroups.test.ts src/components/SidebarSessionRow.test.tsx`)

- [ ] **Step 3: Implement**

`state/sessionGroups.ts` (import `gridShape` from `./paneGrid`):

```ts
export function sessionShapeBadge(paneCount: number): string {
  const { cols, rows } = gridShape(paneCount);
  return cols === 1 && rows === 1 ? "1" : `${rows}×${cols}`;
}
```

Note: the mock labels a 6-pane grid "2×3" and gridShape(6) = {cols: 3, rows: 2} → "2×3" ✓ (rows first).

`SidebarSessionRow.tsx` — replace the mini pane map (`.session-row-panes` block, L158–216) with the dot cluster + badge; add accent bar + chevron; keep dblclick-rename, `useGitBranch` branch chip, `SessionHoverCard`, and `.session-row-close`:

```tsx
<div className={`session-row${isCurrent ? " is-current" : ""}`} onClick={onActivate} …>
  {isCurrent && <span className="session-row-accent" />}
  <button
    type="button"
    className={`session-row-chevron${expanded ? " is-expanded" : ""}`}
    aria-label={expanded ? "Collapse session" : "Expand session"}
    onClick={(e) => { e.stopPropagation(); onToggleExpanded(); }}
  >
    ›
  </button>
  {/* existing name / rename-input span */}
  <span className="session-row-dots" aria-hidden>
    {session.tabs.map((t) => {
      const p = statusPresentation(t.status);
      return (
        <span
          key={t.id}
          className="session-row-dot"
          data-status={p.key}
          data-motion={p.motion}
          style={{ background: `var(${p.colorVar})` }}
        />
      );
    })}
  </span>
  <span className="session-row-shape">{sessionShapeBadge(session.tabs.length)}</span>
  {/* existing close button + hover card */}
</div>
{expanded && (
  <div className="session-row-children">
    {/* Task 5 renders SidebarTerminalRow list + New-terminal row here;
       until then render nothing */}
  </div>
)}
```

Check `statusPresentation`'s exact signature in `sessionStatus.ts` before use (it takes the optional status and returns `{ key, colorVar, motion, … }`).

CSS (append; the old `.session-row-panes`/`.session-row-pane-hole` rules at L5910–6172 get deleted in the same edit):

```css
/* redesign: session row (Task 4). */
.session-row-accent {
  position: absolute; left: 2px; top: 7px; bottom: 7px; width: 2.5px;
  border-radius: 2px; background: var(--accent);
}
.session-row.is-current { background: var(--accent-tint); }
.session-row-chevron {
  appearance: none; border: 0; background: transparent;
  flex: none; width: 14px; height: 14px; padding: 0;
  color: #7c7c86; font: 400 12px/1 var(--sans); cursor: pointer;
  transition: transform 120ms ease;
}
.session-row-chevron.is-expanded { transform: rotate(90deg); color: var(--accent-hi); }
.session-row-dots { flex: none; display: flex; align-items: center; gap: 2px; }
.session-row-dot { width: 5px; height: 5px; border-radius: 50%; }
.session-row-dot[data-motion="sweep"], .session-row-dot[data-motion="chase"] {
  animation: om-dot-pulse 1.8s ease-in-out infinite;
}
.session-row-dot[data-motion="breathe"] { animation: om-dot-pulse 2.2s ease-in-out infinite; }
.session-row-dot[data-motion="flash"] { animation: om-dot-pulse 1.1s ease-in-out infinite; }
.session-row-shape { flex: none; font: 500 9.5px/1 var(--mono); color: var(--accent); }
.session-row:not(.is-current) .session-row-shape { color: #5c5c66; }
.session-row-children { display: flex; flex-direction: column; gap: 1px; }
@keyframes om-dot-pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.35; }
}
@media (prefers-reduced-motion: reduce) {
  .session-row-dot { animation: none !important; }
}
```

**Important:** the old `.session-row.is-current` rule (App.css L5966–5972, `--brand-blue` gradient) must be replaced by the flat `--accent-tint` above — grep for it and delete the gradient block.

`Sidebar.tsx`: add `expandedSessions` state + pass the new props:

```tsx
const [expandedSessions, setExpandedSessions] = useState<Set<string>>(new Set());
const toggleSession = (id: string) =>
  setExpandedSessions(prev => {
    const next = new Set(prev);
    next.has(id) ? next.delete(id) : next.add(id);
    return next;
  });
// per row:
expanded={session.isCurrent || expandedSessions.has(session.id)}
activeTabId={activeTabId}
onToggleExpanded={() => toggleSession(session.id)}
onActivateTab={onActivateTab}   // NEW SidebarProps member: (id: string) => void — App passes activateTab
```

Add `onActivateTab: (tabId: string) => void;` to `SidebarProps`; in `App.tsx` pass the existing tab-activation function (the one `onActivateTab` prop already maps to — reuse it verbatim).

- [ ] **Step 4: Run — expect PASS**, then run `npm test` for the sweep (SessionHoverCard tests may reference removed classes — update).

- [ ] **Step 5: Commit**

```bash
git add -A ui/src
git commit -m "feat(sidebar): session rows with status dots, layout badge and expand chevron"
```

---

### Task 5: Terminal rows + "New terminal" row

**Files:**
- Create: `ui/src/components/SidebarTerminalRow.tsx`
- Test: `ui/src/components/SidebarTerminalRow.test.tsx`
- Modify: `ui/src/components/SidebarSessionRow.tsx` (render rows in `.session-row-children`), `ui/src/App.css`

**Interfaces:**
- Consumes: `Icon` + `AGENT_ICON`, `ENGINE_LABEL`, `ENGINE_COLOR` from `../theme` / `./Icon`; `SessionStatusLight` (`status`, `size`, `decorative` props); `tabDisplayLabel(tab)` from `../state/sessions` (L368).
- Produces:

```ts
interface SidebarTerminalRowProps {
  tab: TabInfo;
  isActive: boolean;       // this pane is the focused pane in the grid
  onActivate: () => void;  // activate tab (and its session grid)
}
export function SidebarTerminalRow(props: SidebarTerminalRowProps): JSX.Element;
```

- [ ] **Step 1: Write the failing test**

```tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { SidebarTerminalRow } from "./SidebarTerminalRow";
import type { TabInfo } from "../state/sessions";

const base: TabInfo = {
  id: "t1", project: "p", engine: "claude", cwd: "/p", createdAt: 1,
  group: "g", status: "thinking",
};

describe("SidebarTerminalRow", () => {
  it("shows engine icon, display label and status mark", () => {
    const { container } = render(
      <SidebarTerminalRow tab={{ ...base, label: "token rotation" }} isActive={false} onActivate={vi.fn()} />,
    );
    expect(screen.getByText("token rotation")).toBeInTheDocument();
    expect(container.querySelector(".terminal-row-engine")).toBeInTheDocument();
    expect(container.querySelector(".session-light[data-status='thinking']")).toBeInTheDocument();
  });

  it("falls back to the engine name when unnamed", () => {
    render(<SidebarTerminalRow tab={base} isActive={false} onActivate={vi.fn()} />);
    expect(screen.getByText("claude")).toBeInTheDocument();
  });

  it("activates on click and marks the active pane", () => {
    const onActivate = vi.fn();
    const { container } = render(
      <SidebarTerminalRow tab={base} isActive={true} onActivate={onActivate} />,
    );
    expect(container.querySelector(".terminal-row.is-active")).toBeInTheDocument();
    fireEvent.click(container.querySelector(".terminal-row")!);
    expect(onActivate).toHaveBeenCalled();
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (module not found)

- [ ] **Step 3: Implement `SidebarTerminalRow.tsx`**

```tsx
// One terminal (pane/PTY) inside an expanded sidebar session (design
// ANALYSIS.md §2 "Terminal rows"): engine glyph, display label, and the
// masked-logo status mark — the same SessionStatusLight the pane header
// uses, at 12px.
import type { TabInfo } from "../state/sessions";
import { tabDisplayLabel } from "../state/sessions";
import { AGENT_ICON, ENGINE_COLOR } from "../theme";
import { Icon } from "./Icon";
import { SessionStatusLight } from "./SessionStatusLight";

interface SidebarTerminalRowProps {
  tab: TabInfo;
  isActive: boolean;
  onActivate: () => void;
}

export function SidebarTerminalRow({ tab, isActive, onActivate }: SidebarTerminalRowProps) {
  return (
    <div
      className={`terminal-row${isActive ? " is-active" : ""}`}
      role="button"
      tabIndex={0}
      onClick={onActivate}
      onKeyDown={(e) => { if (e.key === "Enter") onActivate(); }}
    >
      <span className="terminal-row-engine" style={{ color: ENGINE_COLOR[tab.engine] }} aria-hidden>
        <Icon name={AGENT_ICON[tab.engine]} />
      </span>
      <span className="terminal-row-label">{tabDisplayLabel(tab)}</span>
      <SessionStatusLight status={tab.status} size={12} decorative />
    </div>
  );
}
```

Check `Icon`'s props in `components/Icon.tsx` (it takes `name: IconName` plus size styling via CSS) — if it requires a `size` prop, pass `11`.

CSS:

```css
/* redesign: terminal rows under an expanded session (Task 5). */
.terminal-row {
  display: flex; align-items: center; gap: 7px;
  padding: 4px 8px 4px 24px;
  border-radius: 6px; cursor: pointer;
}
.terminal-row:hover { background: rgba(255, 255, 255, 0.045); }
.terminal-row.is-active { background: rgba(255, 255, 255, 0.045); }
.terminal-row-engine { flex: none; width: 11px; height: 11px; display: flex; }
.terminal-row-engine svg { width: 11px; height: 11px; }
.terminal-row-label {
  flex: 1; min-width: 0;
  font: 400 11px/1.3 var(--sans); color: #c2c2cb;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
}
.terminal-row.is-active .terminal-row-label { color: #e2e2e8; }
.terminal-row-new {
  display: flex; align-items: center; gap: 7px;
  padding: 4px 8px 4px 24px; border-radius: 6px; cursor: pointer;
  font: 500 11px/1.3 var(--sans); color: var(--accent);
}
.terminal-row-new:hover { background: var(--accent-tint); }
.terminal-row-new-key { font: 500 9.5px/1 var(--mono); color: #5c5c66; }
```

- [ ] **Step 4: Render rows in `SidebarSessionRow.tsx`**

Fill the `.session-row-children` block from Task 4:

```tsx
{expanded && (
  <div className="session-row-children">
    {session.tabs.map((t) => (
      <SidebarTerminalRow
        key={t.id}
        tab={t}
        isActive={t.id === activeTabId}
        onActivate={() => onActivateTab(t.id)}
      />
    ))}
    {isCurrent && onOpenNewTerminal && session.tabs.length < MAX_PANES && (
      <div className="terminal-row-new" role="button" onClick={onOpenNewTerminal}>
        <span aria-hidden>+</span>
        <span style={{ flex: 1 }}>New terminal</span>
        <span className="terminal-row-new-key">⌘T</span>
      </div>
    )}
  </div>
)}
```

Import `MAX_PANES` from `../state/paneGrid`. Sidebar passes `onOpenNewTerminal` (Task 3's prop) down to the current session's row.

Add a SidebarSessionRow test:

```tsx
it("expanded current session lists terminals and the New terminal row", () => {
  const { container } = setup({
    isCurrent: true, expanded: true,
    session: sessionWith([tab({ id: "a" }), tab({ id: "b" })]),
    onOpenNewTerminal: vi.fn(),
  });
  expect(container.querySelectorAll(".terminal-row")).toHaveLength(2);
  expect(screen.getByText("New terminal")).toBeInTheDocument();
});

it("hides the New terminal row at MAX_PANES", () => {
  const { container } = setup({
    isCurrent: true, expanded: true,
    session: sessionWith(Array.from({ length: 8 }, (_, i) => tab({ id: `t${i}` }))),
    onOpenNewTerminal: vi.fn(),
  });
  expect(container.querySelector(".terminal-row-new")).toBeNull();
});
```

- [ ] **Step 5: Run — expect PASS** (`npx vitest run src/components/SidebarTerminalRow.test.tsx src/components/SidebarSessionRow.test.tsx`), then `npm test`.

- [ ] **Step 6: Commit**

```bash
git add -A ui/src
git commit -m "feat(sidebar): terminal rows with engine glyph + status mark, New-terminal row"
```

---

### Task 6: FILES section — FileTree embedded in the sidebar

The tree moves from the right dock into the sidebar's lower half (design §2 FILES). The 948-line `FileTree.tsx` (lazy `list_dir`, watcher, rename/move/trash context ops) is reused, not rewritten — it gains an `embedded` variant and a `filter` prop.

**Files:**
- Modify: `ui/src/components/FileTree.tsx`, `ui/src/components/FileTree.test.tsx`, `ui/src/components/Sidebar.tsx`, `ui/src/App.tsx` (remove right-dock rendering), `ui/src/App.css`
- App tests to sweep: any test stubbing/asserting the FileTree dock (`grep -rn "file-tree\|FileTree" src/App*.test.tsx`)

**Interfaces:**
- `FileTreeProps` gains:

```ts
interface FileTreeProps {
  project: ProjectInfo | null;
  activeTabId: string | null;
  onClose: () => void;
  embedded?: boolean;  // true → no resize handle, no dock chrome/close header
  filter?: string;     // case-insensitive name substring; hides non-matching loaded rows
}
```

- Sidebar renders the section; filter state is Sidebar-local:

```tsx
<div className="sidebar-files">
  <div className="sidebar-files-header">
    <span className="sidebar-microlabel">FILES</span>
    <span className="sidebar-spacer" />
    {/* Task 7 puts the "N changed" chip here */}
  </div>
  <input
    className="sidebar-files-filter"
    placeholder="Filter files"
    value={fileFilter}
    onChange={(e) => setFileFilter(e.target.value)}
  />
  <div className="sidebar-files-body">
    <FileTree project={selectedProject} activeTabId={activeTabId} onClose={() => {}} embedded filter={fileFilter} />
  </div>
</div>
```

- `fileTreeVisible`/`onToggleFileTree` SidebarProps and the App-side right-dock (`fileTreeVisible` conditional render + `.sidebar-filetree-trigger` button) are **removed**; the `file_tree_visible`/`file_tree_width` settings keys become unused (leave the tauri.ts wrappers — dead but harmless; deleting them breaks nothing either, implementer's choice, one line in the commit message).

- [ ] **Step 1: Write failing tests**

Add to `FileTree.test.tsx` (reuse its existing tauri mock scaffolding — it already mocks `listDir`, `watchDir`, etc.):

```tsx
it("embedded mode renders no resize handle and no dock header", async () => {
  const { container } = await setupTree({ embedded: true }); // adapt to the file's existing setup helper
  expect(container.querySelector(".file-tree-resize-handle")).toBeNull();
  expect(container.querySelector(".file-tree.is-embedded")).toBeInTheDocument();
});

it("filter hides non-matching loaded rows by name substring", async () => {
  const { container } = await setupTree({ filter: "token" });
  // fixture dirs from the existing mock: assert a row named e.g. "README.md" is hidden
  expect(container.querySelector("[data-file-tree-path$='README.md']")).toBeNull();
});
```

(Adapt fixture names to the mock `listDir` data already in the file — it seeds a known entry list.)

- [ ] **Step 2: Run — expect FAIL** (`npx vitest run src/components/FileTree.test.tsx`)

- [ ] **Step 3: Implement in `FileTree.tsx`**

1. Root element: `className={`file-tree${embedded ? " is-embedded" : ""}`}`; skip rendering the resize handle and the dock header/close button when `embedded`.
2. Filtering — at the single place rows are rendered (the row-mapping in the body), wrap with:

```tsx
const q = (filter ?? "").trim().toLowerCase();
const visible = q.length === 0 ? entries : entries.filter((e) => e.name.toLowerCase().includes(q));
```

Directories filter by their own name like files. (`// ponytail: name-only filter on loaded rows; deep search needs a walk command — add if asked`)

CSS:

```css
/* redesign: FILES section in the sidebar (Task 6). */
.sidebar-files { flex: 1; min-height: 0; display: flex; flex-direction: column; border-top: 0.5px solid rgba(255, 255, 255, 0.06); margin-top: 2px; }
.sidebar-files-header { flex: none; display: flex; align-items: center; gap: 6px; padding: 8px 14px 5px; }
.sidebar-files-filter {
  flex: none; margin: 0 9px 7px; height: 24px; padding: 0 8px;
  border-radius: 6px; background: rgba(255, 255, 255, 0.05);
  border: 0.5px solid rgba(255, 255, 255, 0.06);
  font: 400 11px/1 var(--sans); color: var(--ink); outline: none;
}
.sidebar-files-filter::placeholder { color: #5c5c66; }
.sidebar-files-filter:focus { border-color: rgba(139, 149, 255, 0.55); }
.sidebar-files-body { flex: 1; min-height: 0; overflow: auto; padding: 0 6px 8px; }
.file-tree.is-embedded { width: 100%; border: 0; background: transparent; }
```

3. `App.tsx`: delete the right-dock conditional render of `<FileTree>` and the `fileTreeVisible` state/props; delete the `.sidebar-filetree-trigger` button from Sidebar. Grep test files for both and update (App tests that clicked the toggle stub now assert the tree renders inside Sidebar's stub boundary — since App tests stub Sidebar entirely, mostly these tests just delete).

- [ ] **Step 4: Run — expect PASS**, then `npm test` full sweep.

- [ ] **Step 5: Commit**

```bash
git add -A ui/src
git commit -m "feat(sidebar): embed the file tree in the sidebar with name filter"
```

---

### Task 7: Git badges — "N changed", folder counts, M/A letters

**Files:**
- Create: `ui/src/state/fileGitStatus.ts`, `ui/src/state/fileGitStatus.test.ts`, `ui/src/lib/useReviewStatus.ts`
- Modify: `ui/src/components/FileTree.tsx` (row badges), `ui/src/components/Sidebar.tsx` (header chip), `ui/src/App.css`

**Interfaces:**
- Consumes: `reviewStatus(repoPath)` → `ReviewStatus` and `ChangedFile { path, status, added, removed, … }` from `../lib/tauri` (L456–485); `statusGlyph(status): { letter, label }` from `../state/codeReviewState` (L61).
- Produces:

```ts
// state/fileGitStatus.ts — pure
export type DirTone = "add" | "mod";
export interface GitBadges {
  byFile: Map<string, ChangeStatus>;            // absolute path -> status
  byDir: Map<string, { count: number; tone: DirTone }>; // absolute dir -> descendant changes
  total: number;
}
export function buildGitBadges(status: ReviewStatus | null): GitBadges;

// lib/useReviewStatus.ts — hook
export const REVIEW_STATUS_POLL_MS = 15_000;
export function useReviewStatus(root: string | null): ReviewStatus | null;
```

- FileTree gains `gitBadges?: GitBadges`; Sidebar computes both (`const review = useReviewStatus(selectedProject?.path ?? null); const badges = useMemo(() => buildGitBadges(review), [review]);`).

- [ ] **Step 1: Write failing tests for the pure module**

`ui/src/state/fileGitStatus.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { buildGitBadges } from "./fileGitStatus";
import type { ReviewStatus } from "../lib/tauri";

function status(files: Array<[string, string]>): ReviewStatus {
  return {
    repo_root: "/repo", branch: "main", detached: false, has_head: true,
    files: files.map(([path, s]) => ({
      path, status: s as never, added: 1, removed: 0, binary: false,
    })),
    file_count: files.length, added: files.length, removed: 0,
    binary_count: 0, truncated: false,
  };
}

describe("buildGitBadges", () => {
  it("maps files to absolute paths and totals", () => {
    const b = buildGitBadges(status([["src/auth/token.ts", "modified"]]));
    expect(b.total).toBe(1);
    expect(b.byFile.get("/repo/src/auth/token.ts")).toBe("modified");
  });

  it("accumulates ancestor dir counts", () => {
    const b = buildGitBadges(status([
      ["src/auth/token.ts", "modified"],
      ["src/auth/token.spec.ts", "added"],
      ["src/stripe/pay.ts", "added"],
    ]));
    expect(b.byDir.get("/repo/src")).toEqual({ count: 3, tone: "mod" });
    expect(b.byDir.get("/repo/src/auth")).toEqual({ count: 2, tone: "mod" });
    expect(b.byDir.get("/repo/src/stripe")).toEqual({ count: 1, tone: "add" });
  });

  it("tone is add only when every descendant is added/untracked", () => {
    const b = buildGitBadges(status([["a/x.ts", "untracked"], ["a/y.ts", "added"]]));
    expect(b.byDir.get("/repo/a")?.tone).toBe("add");
  });

  it("null status yields empty badges", () => {
    const b = buildGitBadges(null);
    expect(b.total).toBe(0);
    expect(b.byFile.size).toBe(0);
  });
});
```

- [ ] **Step 2: Run — expect FAIL** (module not found)

- [ ] **Step 3: Implement `state/fileGitStatus.ts`**

```ts
// Sidebar git decoration (design §2 FILES): fold `review_status`'s flat
// ChangedFile list into per-file letters and per-ancestor-dir counts, keyed
// by ABSOLUTE path so FileTree rows (which know absolute paths) can look
// themselves up directly.
import type { ChangeStatus, ReviewStatus } from "../lib/tauri";

export type DirTone = "add" | "mod";
export interface GitBadges {
  byFile: Map<string, ChangeStatus>;
  byDir: Map<string, { count: number; tone: DirTone }>;
  total: number;
}

const EMPTY: GitBadges = { byFile: new Map(), byDir: new Map(), total: 0 };

export function buildGitBadges(status: ReviewStatus | null): GitBadges {
  if (!status || status.files.length === 0) return EMPTY;
  const byFile = new Map<string, ChangeStatus>();
  const byDir = new Map<string, { count: number; tone: DirTone }>();
  for (const f of status.files) {
    const abs = `${status.repo_root}/${f.path}`;
    byFile.set(abs, f.status);
    const isAdd = f.status === "added" || f.status === "untracked";
    const parts = f.path.split("/").slice(0, -1);
    let dir = status.repo_root;
    for (const part of parts) {
      dir = `${dir}/${part}`;
      const prev = byDir.get(dir);
      byDir.set(dir, {
        count: (prev?.count ?? 0) + 1,
        tone: prev == null ? (isAdd ? "add" : "mod") : (prev.tone === "add" && isAdd ? "add" : "mod"),
      });
    }
  }
  return { byFile, byDir, total: status.files.length };
}
```

- [ ] **Step 4: Run pure tests — expect PASS**

- [ ] **Step 5: Implement `lib/useReviewStatus.ts`**

Follow `lib/useGitBranch.ts`'s shape (read it first — same poll-and-set pattern):

```ts
// Poll `review_status` for the active workspace so the sidebar's FILES
// section can show live git badges. 15s poll matches the "glanceable, not
// real-time" bar set by useGitBranch's 30s.
// ponytail: poll-only; if it ever needs to be instant, refresh on the
// existing dir-changed events instead of shortening the interval.
import { useEffect, useState } from "react";
import { reviewStatus, type ReviewStatus } from "./tauri";

export const REVIEW_STATUS_POLL_MS = 15_000;

export function useReviewStatus(root: string | null): ReviewStatus | null {
  const [status, setStatus] = useState<ReviewStatus | null>(null);
  useEffect(() => {
    if (!root) { setStatus(null); return; }
    let alive = true;
    const load = () =>
      reviewStatus(root).then(
        (s) => { if (alive) setStatus(s); },
        () => { if (alive) setStatus(null); }, // not a repo → no badges
      );
    void load();
    const t = setInterval(load, REVIEW_STATUS_POLL_MS);
    return () => { alive = false; clearInterval(t); };
  }, [root]);
  return status;
}
```

- [ ] **Step 6: Wire badges into FileTree rows + Sidebar header**

`FileTree.tsx` — where a row renders (dir and file branches), append:

```tsx
{gitBadges && entry.is_dir && gitBadges.byDir.has(entry.path) && (
  <span className={`file-tree-dir-badge is-${gitBadges.byDir.get(entry.path)!.tone}`}>
    {gitBadges.byDir.get(entry.path)!.count}
  </span>
)}
{gitBadges && !entry.is_dir && gitBadges.byFile.has(entry.path) && (
  <span className={`file-tree-git-letter is-${gitBadges.byFile.get(entry.path)!}`}>
    {statusGlyph(gitBadges.byFile.get(entry.path)!).letter}
  </span>
)}
```

Sidebar header chip (in `.sidebar-files-header` from Task 6):

```tsx
{badges.total > 0 && (
  <span className="sidebar-files-changed">
    {badges.total}<span> changed</span>
  </span>
)}
```

FileTree component test (uses the existing mocked `listDir` fixtures): pass a hand-built `gitBadges` prop and assert a `.file-tree-git-letter` with text "M" renders on the matching row, and a dir badge count on its parent.

CSS:

```css
/* redesign: git badges in the file tree (Task 7). */
.sidebar-files-changed { display: flex; gap: 4px; font: 500 9.5px/1 var(--mono); color: var(--status-ready); }
.sidebar-files-changed span { color: #4a4a53; }
.file-tree-dir-badge { flex: none; font: 600 9px/1 var(--mono); }
.file-tree-dir-badge.is-add { color: var(--status-ready); }
.file-tree-dir-badge.is-mod { color: var(--status-approval); }
.file-tree-git-letter { flex: none; font: 600 9.5px/1 var(--mono); }
.file-tree-git-letter.is-modified, .file-tree-git-letter.is-renamed { color: var(--status-approval); }
.file-tree-git-letter.is-added, .file-tree-git-letter.is-untracked { color: var(--status-ready); }
.file-tree-git-letter.is-deleted { color: var(--status-error); }
```

(Use the existing status color vars — check exact names in `:root` (`--status-ready`, `--status-approval`, `--status-error`) before committing; they exist per App.css L38–171.)

- [ ] **Step 7: Run `npm test` — expect PASS. Commit**

```bash
git add -A ui/src
git commit -m "feat(files): live git badges — changed count, folder counts, status letters"
```

---

### Task 8: Account row — "Brain indexed · Xm ago"

**Files:**
- Modify: `ui/src/state/accountBadgeState.ts`, `ui/src/state/accountBadgeState.test.ts` (extend existing test file), `ui/src/components/AccountBadge.tsx`, `ui/src/components/AccountBadge.test.tsx`, `ui/src/components/Sidebar.tsx`, `ui/src/App.css`

**Interfaces:**
- Consumes: `IngestionStatus { running, projects_total, projects_done, current_project?, total_nodes, error? }` from `../lib/tauri` (L316) — Sidebar already receives `ingestion` as a prop.
- Produces in `state/accountBadgeState.ts`:

```ts
export interface BrainLine { text: string; tone: "good" | "busy" | "idle" | "error"; }
/** Sub-line under the account name (design §2 "Brain indexed · 8m ago").
 * `lastIndexedAt` is persisted by Sidebar whenever ingestion transitions
 * running→false (epoch ms), null when never indexed. `now` injected for tests. */
export function brainLine(ingestion: IngestionStatus | null, lastIndexedAt: number | null, now: number): BrainLine;
```

- `AccountBadgeProps` gains `brainLine?: BrainLine | null` (renders the sub-line in place of the current subtitle when present).

- [ ] **Step 1: Write failing tests** (append to `accountBadgeState.test.ts`)

```ts
import { brainLine } from "./accountBadgeState";

describe("brainLine", () => {
  const MIN = 60_000;
  it("running ingestion wins", () => {
    expect(
      brainLine({ running: true, projects_total: 4, projects_done: 1, total_nodes: 10 }, null, 0),
    ).toEqual({ text: "Ingesting · 1 of 4 projects", tone: "busy" });
  });
  it("error surfaces", () => {
    expect(
      brainLine({ running: false, projects_total: 0, projects_done: 0, total_nodes: 0, error: "boom" }, null, 0),
    ).toEqual({ text: "Ingest failed — open About to rebuild", tone: "error" });
  });
  it("indexed shows relative minutes", () => {
    expect(brainLine(null, 1_000_000, 1_000_000 + 8 * MIN)).toEqual({ text: "Brain indexed · 8m ago", tone: "good" });
  });
  it("indexed over an hour ago shows hours", () => {
    expect(brainLine(null, 0, 90 * MIN).text).toBe("Brain indexed · 1h ago");
  });
  it("never indexed", () => {
    expect(brainLine(null, null, 0)).toEqual({ text: "Nothing indexed yet", tone: "idle" });
  });
});
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement `brainLine` in `accountBadgeState.ts`**

```ts
export interface BrainLine { text: string; tone: "good" | "busy" | "idle" | "error"; }

export function brainLine(
  ingestion: IngestionStatus | null,
  lastIndexedAt: number | null,
  now: number,
): BrainLine {
  if (ingestion?.error) return { text: "Ingest failed — open About to rebuild", tone: "error" };
  if (ingestion?.running) {
    return { text: `Ingesting · ${ingestion.projects_done} of ${ingestion.projects_total} projects`, tone: "busy" };
  }
  if (lastIndexedAt == null) return { text: "Nothing indexed yet", tone: "idle" };
  const mins = Math.max(0, Math.floor((now - lastIndexedAt) / 60_000));
  const rel = mins < 1 ? "just now" : mins < 60 ? `${mins}m ago` : `${Math.floor(mins / 60)}h ago`;
  return { text: `Brain indexed · ${rel}`, tone: "good" };
}
```

(import `IngestionStatus` type from `../lib/tauri`.)

- [ ] **Step 4: Wire through**

- Sidebar: track `lastIndexedAt` in a `useRef`+`useState` pair — when the `ingestion` prop transitions from `running: true` to `running: false` without error, `setLastIndexedAt(Date.now())`. Compute `const line = brainLine(ingestion ?? null, lastIndexedAt, Date.now())` per render and pass to `<AccountBadge brainLine={line} …/>`. (`// ponytail: lastIndexedAt is session-local, resets on relaunch to "Nothing indexed yet" until the first ingest completes; persist via settingsSet if it matters`)
- `AccountBadge.tsx`: render `<span className={`account-badge-brain is-${brainLine.tone}`}>{brainLine.text}</span>` as the sub-line under the name when the prop is set (falling back to the current subtitle otherwise). Add an AccountBadge test asserting the text renders.

CSS:

```css
/* redesign: brain status sub-line in the account row (Task 8). */
.account-badge-brain { display: block; font: 400 9.5px/1.3 var(--sans); }
.account-badge-brain.is-good { color: var(--status-ready); }
.account-badge-brain.is-busy { color: var(--status-thinking); }
.account-badge-brain.is-idle { color: #6d6d78; }
.account-badge-brain.is-error { color: var(--status-error); }
```

- [ ] **Step 5: Run `npm test` — expect PASS. Commit**

```bash
git add -A ui/src
git commit -m "feat(account): brain-indexed status sub-line in the account row"
```

---

### Task 9: New Terminal modal (⌘T)

⌘T stops spawning the default engine silently and opens the design's 452px modal: NAME (pre-filled `Terminal #N`) + ENGINE list with ⌘-digit picks, uninstalled engines dimmed with an install affordance. Confirm joins the current session's next free slot.

**Files:**
- Create: `ui/src/state/newTerminalState.ts`, `ui/src/state/newTerminalState.test.ts`, `ui/src/components/NewTerminalModal.tsx`, `ui/src/components/NewTerminalModal.test.tsx`
- Modify: `ui/src/App.tsx` (⌘T handler + modal render + `requestNewTab` extension), `ui/src/state/keyboardShortcuts.ts`, `ui/src/App.css`

**Interfaces:**
- Consumes: `SessionGroup`, `AgentsState`, `ENGINE_LABEL`/`ENGINE_HINT`/`AGENT_ICON` from theme, `MAX_PANES`, Task 1's modal primitives.
- Produces:

```ts
// state/newTerminalState.ts
export interface NewTerminalState { name: string; engine: Engine; }
export function defaultTerminalName(existingCount: number): string; // `Terminal #${existingCount + 1}`
export function initialNewTerminalState(existingCount: number, agents: AgentsState): NewTerminalState;
export type NewTerminalKeyAction =
  | { type: "engine"; engine: Engine }
  | { type: "confirm" } | { type: "cancel" } | null;
/** ⌘1 claude · ⌘2 codex · ⌘3 antigravity · ⌘0 shell · Enter confirm · Escape cancel */
export function terminalKeyAction(e: { key: string; metaKey: boolean }): NewTerminalKeyAction;

// components/NewTerminalModal.tsx
interface NewTerminalModalProps {
  session: SessionGroup;      // the on-screen session the terminal joins
  agentState: AgentsState;
  onCreate: (name: string, engine: Engine) => void;
  onInstallAgent: (agent: Agent) => void;
  onClose: () => void;
}
```

- `App.tsx` `requestNewTab` gains options: `requestNewTab(project, opts?: { engine?: Engine; label?: string })` — existing callers unchanged; when `opts.engine` set it overrides `defaultEngineFor`, when `opts.label` set App dispatches `{ type: "tab/renamed", id, label }` right after `tab/opened`.

- [ ] **Step 1: Write failing state tests**

`ui/src/state/newTerminalState.test.ts`:

```ts
import { describe, expect, it } from "vitest";
import { defaultTerminalName, initialNewTerminalState, terminalKeyAction } from "./newTerminalState";
import { initialAgentsState } from "./agents";

describe("newTerminalState", () => {
  it("names the next slot", () => {
    expect(defaultTerminalName(4)).toBe("Terminal #5");
  });

  it("initial engine prefers installed claude, falls back to shell", () => {
    const none = initialNewTerminalState(0, initialAgentsState);
    expect(none.engine).toBe("shell");
    const withClaude = initialNewTerminalState(0, { ...initialAgentsState, installed: new Set(["claude"]) });
    expect(withClaude.engine).toBe("claude");
  });

  it("maps ⌘-digits, Enter, Escape", () => {
    expect(terminalKeyAction({ key: "1", metaKey: true })).toEqual({ type: "engine", engine: "claude" });
    expect(terminalKeyAction({ key: "2", metaKey: true })).toEqual({ type: "engine", engine: "codex" });
    expect(terminalKeyAction({ key: "3", metaKey: true })).toEqual({ type: "engine", engine: "antigravity" });
    expect(terminalKeyAction({ key: "0", metaKey: true })).toEqual({ type: "engine", engine: "shell" });
    expect(terminalKeyAction({ key: "Enter", metaKey: false })).toEqual({ type: "confirm" });
    expect(terminalKeyAction({ key: "Escape", metaKey: false })).toEqual({ type: "cancel" });
    expect(terminalKeyAction({ key: "1", metaKey: false })).toBeNull();
  });
});
```

- [ ] **Step 2: Run — expect FAIL. Implement `state/newTerminalState.ts`**

```ts
// ⌘T modal state (design §3 "New terminal modal"): tiny enough that a
// reducer would be ceremony — two fields plus the keyboard map.
import type { Engine } from "./sessions";
import type { AgentsState } from "./agents";

export interface NewTerminalState { name: string; engine: Engine; }

export function defaultTerminalName(existingCount: number): string {
  return `Terminal #${existingCount + 1}`;
}

export function initialNewTerminalState(existingCount: number, agents: AgentsState): NewTerminalState {
  return {
    name: defaultTerminalName(existingCount),
    engine: agents.installed.has("claude") ? "claude" : "shell",
  };
}

const KEY_ENGINE: Record<string, Engine> = { "1": "claude", "2": "codex", "3": "antigravity", "0": "shell" };

export type NewTerminalKeyAction =
  | { type: "engine"; engine: Engine }
  | { type: "confirm" } | { type: "cancel" } | null;

export function terminalKeyAction(e: { key: string; metaKey: boolean }): NewTerminalKeyAction {
  if (e.metaKey && KEY_ENGINE[e.key]) return { type: "engine", engine: KEY_ENGINE[e.key] };
  if (e.key === "Enter") return { type: "confirm" };
  if (e.key === "Escape") return { type: "cancel" };
  return null;
}
```

Run — expect PASS.

- [ ] **Step 3: Write failing component test**

`ui/src/components/NewTerminalModal.test.tsx` (mirror `NewWorkspaceModal.test.tsx`'s pattern — no tauri mock needed, the modal is pure):

```tsx
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { NewTerminalModal } from "./NewTerminalModal";
import { initialAgentsState } from "../state/agents";
import type { SessionGroup } from "../state/sessionGroups";

const session: SessionGroup = {
  id: "g", project: "p", label: "session restore", cwd: "/p", isCurrent: true,
  tabs: Array.from({ length: 4 }, (_, i) => ({
    id: `t${i}`, project: "p", engine: "claude" as const, cwd: "/p", createdAt: i, group: "g",
  })),
};

function setup(overrides = {}) {
  const props = {
    session,
    agentState: { ...initialAgentsState, installed: new Set(["claude", "shell"] as const) },
    onCreate: vi.fn(),
    onInstallAgent: vi.fn(),
    onClose: vi.fn(),
    ...overrides,
  };
  return { ...render(<NewTerminalModal {...props} />), props };
}

describe("NewTerminalModal", () => {
  it("shows session context and slot count", () => {
    setup();
    expect(screen.getByText("New terminal")).toBeInTheDocument();
    expect(screen.getByText("in session restore · 4 of 8 used")).toBeInTheDocument();
  });

  it("pre-fills the name with the next slot number", () => {
    setup();
    expect(screen.getByRole("textbox")).toHaveValue("Terminal #5");
  });

  it("uninstalled engines are dimmed and route to install", () => {
    const { container, props } = setup();
    const row = container.querySelector(".engine-row.is-unavailable");
    expect(row).toBeInTheDocument();
    fireEvent.click(row!);
    expect(props.onInstallAgent).toHaveBeenCalled();
    expect(props.onCreate).not.toHaveBeenCalled();
  });

  it("confirms with edited name and selected engine", () => {
    const { props } = setup();
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "token rotation" } });
    fireEvent.click(screen.getByText("Open terminal ⏎"));
    expect(props.onCreate).toHaveBeenCalledWith("token rotation", "claude");
  });

  it("⌘2 selects codex when installed", () => {
    const { container, props } = setup({
      agentState: { ...initialAgentsState, installed: new Set(["claude", "codex"] as const) },
    });
    fireEvent.keyDown(container.querySelector(".modal-panel")!, { key: "2", metaKey: true });
    fireEvent.keyDown(container.querySelector(".modal-panel")!, { key: "Enter" });
    expect(props.onCreate).toHaveBeenCalledWith(expect.any(String), "codex");
  });
});
```

- [ ] **Step 4: Run — expect FAIL. Implement `NewTerminalModal.tsx`**

```tsx
// ⌘T (design §3): name + engine, joins the on-screen session's next free
// slot. Copy is verbatim from the mock; slot math from session.tabs.length.
import { useEffect, useRef, useState } from "react";
import type { Agent, AgentsState } from "../state/agents";
import { AVAILABLE_AGENTS } from "../state/agents";
import type { Engine } from "../state/sessions";
import type { SessionGroup } from "../state/sessionGroups";
import { MAX_PANES } from "../state/paneGrid";
import { initialNewTerminalState, terminalKeyAction } from "../state/newTerminalState";
import { AGENT_ICON, ENGINE_HINT, ENGINE_LABEL } from "../theme";
import { Icon } from "./Icon";

const KEY_HINT: Partial<Record<Engine, string>> = { claude: "⌘1", codex: "⌘2", antigravity: "⌘3", shell: "⌘0" };

interface NewTerminalModalProps {
  session: SessionGroup;
  agentState: AgentsState;
  onCreate: (name: string, engine: Engine) => void;
  onInstallAgent: (agent: Agent) => void;
  onClose: () => void;
}

export function NewTerminalModal({ session, agentState, onCreate, onInstallAgent, onClose }: NewTerminalModalProps) {
  const [state, setState] = useState(() => initialNewTerminalState(session.tabs.length, agentState));
  const inputRef = useRef<HTMLInputElement>(null);
  useEffect(() => { inputRef.current?.select(); }, []);

  const confirm = () => onCreate(state.name.trim() || state.name, state.engine);

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        className="modal-panel new-terminal-panel"
        role="dialog"
        aria-label="New terminal"
        onMouseDown={(e) => e.stopPropagation()}
        onKeyDown={(e) => {
          const action = terminalKeyAction(e);
          if (!action) return;
          e.preventDefault();
          if (action.type === "cancel") onClose();
          else if (action.type === "confirm") confirm();
          else if (agentState.installed.has(action.engine) || action.engine === "shell") {
            setState((s) => ({ ...s, engine: action.engine }));
          }
        }}
      >
        <div className="modal-header">
          <span>New terminal</span>
          <span className="modal-header-context">
            in {session.label} · {session.tabs.length} of {MAX_PANES} used
          </span>
          <span className="modal-header-key">⌘T</span>
        </div>
        <div className="modal-section">
          <div className="modal-field-label">Name</div>
          <input
            ref={inputRef}
            className="modal-text-input"
            value={state.name}
            onChange={(e) => setState((s) => ({ ...s, name: e.target.value }))}
          />
          <div className="modal-field-help">Pre-filled — rename any time by double-clicking the terminal header.</div>
        </div>
        <div className="modal-section">
          <div className="modal-field-label">Engine</div>
          <div className="engine-row-list">
            {AVAILABLE_AGENTS.map((engine) => {
              const available = agentState.installed.has(engine) || engine === "shell";
              const selected = state.engine === engine;
              return (
                <div
                  key={engine}
                  className={`engine-row${selected ? " is-selected" : ""}${available ? "" : " is-unavailable"}`}
                  role="option"
                  aria-selected={selected}
                  onClick={() =>
                    available ? setState((s) => ({ ...s, engine })) : onInstallAgent(engine)
                  }
                >
                  <span className="engine-row-icon"><Icon name={AGENT_ICON[engine]} /></span>
                  <span className="engine-row-text">
                    <span className="engine-row-name">{ENGINE_LABEL[engine]}</span>
                    <span className="engine-row-hint">
                      {available ? ENGINE_HINT[engine] : "Not installed — install CLI"}
                    </span>
                  </span>
                  {available && KEY_HINT[engine] && (
                    <span className="engine-row-key">{KEY_HINT[engine]}</span>
                  )}
                </div>
              );
            })}
          </div>
        </div>
        <div className="modal-footer">
          <span className="modal-footer-hint">Opens in the session's next free slot.</span>
          <button type="button" className="btn-ghost" onClick={onClose}>Cancel</button>
          <button type="button" className="btn-primary" onClick={confirm}>Open terminal ⏎</button>
        </div>
      </div>
    </div>
  );
}
```

CSS:

```css
/* redesign: new-terminal modal (Task 9). */
.new-terminal-panel { width: 452px; }
.modal-section { padding: 13px 16px 6px; }
.engine-row-list { display: flex; flex-direction: column; gap: 5px; }
.engine-row {
  display: flex; align-items: center; gap: 9px;
  padding: 8px 9px; border-radius: 8px; cursor: pointer;
  background: rgba(255, 255, 255, 0.03);
  border: 1px solid rgba(255, 255, 255, 0.07);
}
.engine-row:hover { background: rgba(255, 255, 255, 0.07); }
.engine-row.is-selected {
  background: var(--accent-tint-strong);
  border-color: rgba(139, 149, 255, 0.45);
}
.engine-row.is-unavailable { opacity: 0.5; }
.engine-row-icon { flex: none; width: 15px; height: 15px; display: flex; }
.engine-row-icon svg { width: 15px; height: 15px; }
.engine-row-text { flex: 1; min-width: 0; }
.engine-row-name { display: block; font: 500 11.5px/1.25 var(--sans); color: #e0e0e6; }
.engine-row.is-selected .engine-row-name { font-weight: 600; color: var(--ink); }
.engine-row-hint { display: block; font: 400 10px/1.3 var(--sans); color: #7c7c86; }
.engine-row-key { flex: none; font: 500 10px/1 var(--mono); color: #5c5c66; }
.engine-row.is-selected .engine-row-key { color: var(--accent-hi); }
```

Run component tests — expect PASS.

- [ ] **Step 5: Wire App**

1. State: `const [newTerminalOpen, setNewTerminalOpen] = useState(false);`
2. ⌘T handler (App.tsx L1267–1293): replace the direct `requestNewTab(selectedProject)` call with: no project → keep the existing error banner; visible session at `MAX_PANES` → existing full-session error path from `requestNewTab`; otherwise `setNewTerminalOpen(true)`. Sidebar's `onOpenNewTerminal` (Task 3) points at the same setter now.
3. `requestNewTab` extension (L666–721): add the `opts` parameter as specified in Interfaces; `engine: opts?.engine ?? defaultEngineFor(...)`; after the `tab/opened` dispatch, if `opts?.label` differs from `defaultTerminalName(count)` → dispatch `tab/renamed`. Actually simpler and still correct: always dispatch `tab/renamed` with `opts.label` when provided (the reducer trims and no-ops empty).
4. Render (next to the other modals in App's overlay block):

```tsx
{newTerminalOpen && selectedProject && visibleSession && (
  <NewTerminalModal
    session={visibleSession}
    agentState={agentState}
    onCreate={(name, engine) => {
      setNewTerminalOpen(false);
      void requestNewTab(selectedProject, { engine, label: name });
    }}
    onInstallAgent={handleInstallAgent}
    onClose={() => setNewTerminalOpen(false)}
  />
)}
```

`visibleSession` = the `SessionGroup` for `visibleSessionGroupId(...)` — App already derives the visible session id for the grid/breadcrumb; reuse that derivation (do not fork it — see `state/sessionGroups.ts` contract).

5. App test `ui/src/App.newTerminalModal.test.tsx` (clone `App.requestNewTab.test.tsx`'s mock scaffolding):

```tsx
it("⌘T opens the modal instead of spawning; confirm spawns with chosen engine and name", async () => {
  // render App with one project + one session of 1 tab (existing scaffolding)
  fireEvent.keyDown(window, { key: "t", metaKey: true });
  expect(await screen.findByText("New terminal")).toBeInTheDocument();
  fireEvent.click(screen.getByText("Open terminal ⏎"));
  await waitFor(() => expect(mocks.sessionCreate).toHaveBeenCalledTimes(1));
});
```

6. `state/keyboardShortcuts.ts`: confirm the ⌘T entry's description reads "New terminal" (update copy if it described direct-spawn).

- [ ] **Step 6: Run `npm test` — expect PASS. Commit**

```bash
git add -A ui/src
git commit -m "feat(terminal): ⌘T opens the new-terminal modal — name + engine, joins current session"
```

---

### Task 10: New Session modal — prompt-as-name, layout thumbnails, engine-per-terminal

**Files:**
- Modify: `ui/src/state/newSessionState.ts`, `ui/src/state/newSessionState.test.ts`, `ui/src/components/NewSessionModal.tsx`, `ui/src/components/NewSessionModal.test.tsx`, `ui/src/App.tsx` (`handleSessionCreated`), `ui/src/App.newSession.test.tsx`, `ui/src/App.css`

**Interfaces:**
- The state module's shape changes (breaking, contained to this task + Task 12's caller):

```ts
export interface NewSessionState {
  projectRoot: string;
  path: string;
  prompt: string;          // NEW — session name + first prompt
  layout: LayoutPreset;
  slots: Engine[];         // NEW — length === layout, one engine per pane
  submitting: boolean;
  error: string | null;
}
export function initialNewSessionStateFor(project: ProjectInfo, agents: AgentsState): NewSessionState; // layout 2, slots filled with default engine
export function resizeSlots(slots: Engine[], layout: LayoutPreset, fallback: Engine): Engine[]; // preserve prefix, pad with fallback, truncate
export function sessionNameFromPrompt(prompt: string): string | undefined; // trim, collapse whitespace, cap 60 chars, undefined when empty
// actions: {type:"prompt";value:string} | {type:"layout";layout:LayoutPreset} | {type:"slot";index:number;engine:Engine} | {type:"path";path:string} | existing submit/error actions
```

- Modal callback changes to: `onCreate: (project: ProjectInfo, cwd: string, slots: Engine[], prompt: string) => void`.
- `App.handleSessionCreated(project, cwd, slots, prompt)` (L911–953 rework): `group = crypto.randomUUID()` (match existing group-id creation — read the current body and keep its mechanism), `groupLabel = sessionNameFromPrompt(prompt)`, spawn one `createSessionTab(project, slots[i], group, groupLabel, cwd)` per slot, dispatch `tabs/opened_bulk`, and hand the first non-shell tab id + prompt to Task 11's delivery map (this task just leaves a `pendingFirstPrompt` TODO-free seam: store nothing yet, Task 11 adds it — the signature already carries `prompt`).
- Consumes: `LayoutGlyph` (already exported from `NewSessionModal.tssx` — keep it), `LAYOUT_PRESETS`, `isInsideProjectRoot` (existing reducer guard), `getDefaultAgentSelection`.

- [ ] **Step 1: Write failing state tests** (rework `newSessionState.test.ts`)

```ts
describe("slots", () => {
  it("initial state: layout 2, slots padded with the default engine", () => {
    const s = initialNewSessionStateFor(project, agentsWith(["claude"]));
    expect(s.layout).toBe(2);
    expect(s.slots).toEqual(["claude", "claude"]);
    expect(s.prompt).toBe("");
  });

  it("resizeSlots preserves prefix and pads", () => {
    expect(resizeSlots(["claude", "codex"], 4, "claude")).toEqual(["claude", "codex", "claude", "claude"]);
    expect(resizeSlots(["claude", "codex", "shell", "shell"], 2, "claude")).toEqual(["claude", "codex"]);
  });

  it("layout action resizes slots", () => {
    let s = initialNewSessionStateFor(project, agentsWith(["claude"]));
    s = newSessionReducer(s, { type: "layout", layout: 4 });
    expect(s.slots).toHaveLength(4);
  });

  it("slot action swaps one engine", () => {
    let s = initialNewSessionStateFor(project, agentsWith(["claude", "codex"]));
    s = newSessionReducer(s, { type: "slot", index: 1, engine: "codex" });
    expect(s.slots).toEqual(["claude", "codex"]);
  });
});

describe("sessionNameFromPrompt", () => {
  it("trims, collapses, caps at 60", () => {
    expect(sessionNameFromPrompt("  coalesce   refresh-token rotation  ")).toBe("coalesce refresh-token rotation");
    expect(sessionNameFromPrompt("x".repeat(80))).toHaveLength(60);
    expect(sessionNameFromPrompt("   ")).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run — expect FAIL. Implement in `newSessionState.ts`**

```ts
export function resizeSlots(slots: Engine[], layout: LayoutPreset, fallback: Engine): Engine[] {
  return Array.from({ length: layout }, (_, i) => slots[i] ?? fallback);
}

export function sessionNameFromPrompt(prompt: string): string | undefined {
  const clean = prompt.trim().replace(/\s+/g, " ");
  return clean.length === 0 ? undefined : clean.slice(0, 60);
}
```

`initialNewSessionStateFor`: `const fallback = getDefaultAgentSelection(agents)[0] ?? "shell"; slots: resizeSlots([], 2, fallback)`. Reducer cases `prompt`/`layout`/`slot` as in the tests; keep the existing `path` case with its `isInsideProjectRoot` guard. Delete the old `engines: Record<Engine, boolean>` field and its actions; grep the file's other consumers (`NewWorkspaceModal` has its own state module — unaffected; `checkedEngines` helper: delete if now unused by this module).

Run — expect PASS.

- [ ] **Step 3: Rework `NewSessionModal.tsx`**

Structure (copy verbatim strings from the mock):

```tsx
<div className="overlay-backdrop" onMouseDown={onClose}>
  <div className="modal-panel new-session-panel" role="dialog" aria-label="New session"
       onMouseDown={(e) => e.stopPropagation()} onKeyDown={handleKeyDown}>
    <div className="modal-header">
      <span>New session</span>
      <span className="modal-header-context">in {project.label} workspace</span>
      <span className="modal-header-key">⌘N</span>
    </div>

    <div className="modal-section">
      <div className="modal-field-label">What are you doing?</div>
      <input ref={promptRef} className="modal-text-input" value={state.prompt}
             onChange={(e) => dispatch({ type: "prompt", value: e.target.value })} />
      <div className="modal-field-help">Becomes the session name and the first prompt. Leave empty for a bare terminal.</div>
    </div>

    <div className="modal-section">
      <div className="modal-field-row">
        <span className="modal-field-label">Terminal layout</span>
        <span className="modal-field-note">max {MAX_PANES} terminals per session</span>
      </div>
      <div className="layout-thumb-row">
        {LAYOUT_PRESETS.map((preset) => (
          <button key={preset} type="button"
            className={`layout-thumb${state.layout === preset ? " is-selected" : ""}`}
            onClick={() => dispatch({ type: "layout", layout: preset })}>
            <LayoutGlyph preset={preset} />
            <span className="layout-thumb-caption">{sessionShapeBadge(preset)}</span>
          </button>
        ))}
      </div>
    </div>

    <div className="modal-section">
      <div className="modal-field-row">
        <span className="modal-field-label">Engine per terminal</span>
        <span className="modal-field-note">each terminal runs its own agent or shell</span>
      </div>
      <div className="slot-grid">
        {state.slots.map((engine, i) => (
          <SlotPicker key={i} index={i} engine={engine} agentState={agentState}
            onPick={(eng) => dispatch({ type: "slot", index: i, engine: eng })} />
        ))}
      </div>
    </div>

    <div className="modal-section modal-section-last">
      <div className="modal-field-label">Working folder</div>
      <div className="folder-row">
        <span className="folder-row-path">{state.path}</span>
        <button type="button" className="folder-row-change" onClick={pickFolder}>Change</button>
      </div>
    </div>

    <div className="modal-footer">
      <span className="modal-footer-hint">
        <span className="modal-footer-dot" />
        {state.layout} terminals boot briefed on {nodeCount.toLocaleString()} brain nodes
      </span>
      <button type="button" className="btn-ghost" onClick={onClose}>Cancel</button>
      <button type="button" className="btn-primary" onClick={confirm}>Start session ⏎</button>
    </div>
  </div>
</div>
```

Details:
- `SlotPicker` is a private component in the same file: a button showing `{i + 1}` + engine icon + `ENGINE_LABEL[engine]` + chevron; clicking toggles a small absolutely-positioned menu (`.slot-picker-menu`) listing every installed engine + shell; picking calls `onPick` and closes; `Escape`/outside-click closes. No portal — the modal is `overflow: visible` for `.slot-picker-menu` (change `overflow: hidden` to `visible` on `.new-session-panel` only, or render the menu inside the grid cell with `position: absolute`).
- `nodeCount`: modal fetches once on mount via `ingestionStatus()` from `../lib/tauri` (`.total_nodes`, fallback 0 on error) — mirrors how other dialogs fetch on mount. Mock it in tests.
- `pickFolder`: existing `open({ directory: true })` + `path` action (unchanged from current modal).
- `handleKeyDown`: `Escape` → close; `Enter` (when the prompt input has focus or nothing has) → confirm; digits `1–5` map to `LAYOUT_PRESETS[digit - 1]` **only when the prompt input is not focused** (typing "2×2 grid" into the prompt must not flip layouts — guard with `document.activeElement !== promptRef.current`).
- `confirm()`: `onCreate(project, state.path, state.slots, state.prompt)`.
- Import `sessionShapeBadge` from `../state/sessionGroups` (Task 4) for thumbnail captions — note `sessionShapeBadge(6)` = "2×3", matching the mock.

CSS (append; adjust names only if collisions surface):

```css
/* redesign: new-session modal (Task 10). */
.new-session-panel { width: 560px; }
.modal-field-row { display: flex; align-items: baseline; gap: 8px; margin-bottom: 7px; }
.modal-field-row .modal-field-label { margin-bottom: 0; }
.modal-field-note { font: 400 10px/1 var(--sans); color: #4a4a53; }
.modal-section-last { padding-bottom: 14px; }
.layout-thumb-row { display: flex; gap: 7px; }
.layout-thumb {
  appearance: none; flex: 1; padding: 8px; border-radius: 9px; cursor: pointer;
  background: rgba(255, 255, 255, 0.03); border: 1px solid rgba(255, 255, 255, 0.08);
  text-align: center;
}
.layout-thumb:hover { background: rgba(255, 255, 255, 0.07); }
.layout-thumb.is-selected {
  background: var(--accent-tint);
  border-color: rgba(139, 149, 255, 0.55);
  box-shadow: 0 0 0 3px rgba(139, 149, 255, 0.12);
}
.layout-thumb-caption { display: block; margin-top: 6px; font: 600 10px/1 var(--mono); color: #8b8b95; }
.layout-thumb.is-selected .layout-thumb-caption { color: #dfe2ff; }
.slot-grid { display: grid; grid-template-columns: 1fr 1fr; gap: 7px; }
.slot-picker { position: relative; }
.slot-picker-trigger {
  appearance: none; width: 100%;
  display: flex; align-items: center; gap: 8px;
  padding: 7px 9px; border-radius: 9px; cursor: pointer;
  background: rgba(255, 255, 255, 0.035); border: 1px solid rgba(255, 255, 255, 0.08);
}
.slot-picker-trigger:hover { background: rgba(255, 255, 255, 0.07); }
.slot-picker-index { font: 600 9.5px/1 var(--mono); color: #5c5c66; width: 12px; }
.slot-picker-name { flex: 1; text-align: left; font: 500 11px/1 var(--sans); color: #d8d8de; }
.slot-picker-menu {
  position: absolute; top: calc(100% + 4px); left: 0; right: 0; z-index: 10;
  border-radius: 9px; background: rgba(40, 40, 45, 0.98);
  border: 0.5px solid rgba(255, 255, 255, 0.14);
  box-shadow: 0 16px 40px rgba(0, 0, 0, 0.55);
  padding: 4px; display: flex; flex-direction: column; gap: 2px;
}
.slot-picker-option {
  display: flex; align-items: center; gap: 8px;
  padding: 6px 8px; border-radius: 6px; cursor: pointer;
  font: 500 11px/1 var(--sans); color: #d8d8de;
}
.slot-picker-option:hover { background: rgba(255, 255, 255, 0.08); }
.slot-picker-option.is-selected { background: var(--accent-tint); color: var(--ink); }
.folder-row {
  display: flex; align-items: center; gap: 7px; height: 32px; padding: 0 10px;
  border-radius: 8px; background: rgba(255, 255, 255, 0.045);
  border: 0.5px solid rgba(255, 255, 255, 0.09);
}
.folder-row-path {
  flex: 1; min-width: 0; font: 400 11px/1 var(--mono); color: #c6c6d0;
  overflow: hidden; text-overflow: ellipsis; white-space: nowrap; direction: rtl;
}
.folder-row-change { appearance: none; border: 0; background: transparent; font: 500 10px/1 var(--sans); color: var(--accent); cursor: pointer; }
.modal-footer-dot { width: 5px; height: 5px; border-radius: 50%; background: var(--accent); display: inline-block; margin-right: 6px; }
```

- [ ] **Step 4: Rework `NewSessionModal.test.tsx`**

Keep the tauri/dialog mock scaffolding; add `ingestionStatus` to the tauri mock returning `{ running: false, projects_total: 0, projects_done: 0, total_nodes: 41208 }`. Core cases:

```tsx
it("prompt field + helper copy render", …)           // "Becomes the session name and the first prompt. Leave empty for a bare terminal."
it("layout picks resize the slot grid", …)           // click "2×2" thumb → 4 slot pickers
it("slot picker swaps one terminal's engine", …)     // open slot 2's menu, pick Codex
it("confirm passes (project, cwd, slots, prompt)", …)
it("typing digits into the prompt does not change layout", …)
```

- [ ] **Step 5: Rework `App.handleSessionCreated` + `App.newSession.test.tsx`**

Update the callback signature and spawn loop as described in Interfaces (one tab per slot, `groupLabel = sessionNameFromPrompt(prompt)`). Update the App test to assert: 4 slots → 4 `sessionCreate` calls; `groupLabel` set from the prompt; empty prompt → `groupLabel` undefined (existing positional naming kicks in).

- [ ] **Step 6: Run `npm test` — expect PASS. Commit**

```bash
git add -A ui/src
git commit -m "feat(session): new-session modal — prompt-as-name, layout thumbnails, engine per terminal"
```

---

### Task 11: First-prompt delivery to the spawned terminal

"Becomes … the first prompt": after the session's first agent terminal boots, the prompt text lands in its input (no auto-submit — the user presses Enter).

**Files:**
- Modify: `ui/src/App.tsx` (`handleSessionCreated` + the per-session status handler at L496–514)
- Test: `ui/src/App.sessionPrompt.test.tsx`

**Interfaces:**
- Consumes: `sessionWrite(id, data)` from `./lib/tauri` (L107); Task 10's `handleSessionCreated(project, cwd, slots, prompt)`.
- Produces: no exports — an App-internal `pendingFirstPrompt: React.MutableRefObject<Map<string, string>>` (tabId → prompt).

- [ ] **Step 1: Write the failing App test**

`ui/src/App.sessionPrompt.test.tsx` — clone `App.newSession.test.tsx`'s mock scaffolding (`vi.hoisted` bag, `vi.mock("./lib/tauri")`, `vi.mock("@tauri-apps/api/event")` capturing per-session listeners, stubbed children, dynamic `import("./App")`). The event mock must expose the captured `session-status:{id}` callbacks (the scaffolding already does this for status-driven tests — copy from `App.sessionRestore.test.tsx` if not).

```tsx
it("writes the prompt into the first agent pane once it reports status", async () => {
  // drive the stubbed NewSessionModal to call onCreate(project, "/p", ["claude", "shell"], "rotate tokens")
  fireEvent.click(screen.getByTestId("stub-create-session"));
  await waitFor(() => expect(mocks.sessionCreate).toHaveBeenCalledTimes(2));
  const claudeTabId = mocks.sessionCreate.mock.results[0].value // adapt: the id returned for the claude spawn
  emitSessionStatus(claudeTabId, { id: claudeTabId, status: "ready", notify: false, engine: "claude" });
  await waitFor(() => expect(mocks.sessionWrite).toHaveBeenCalledWith(claudeTabId, "rotate tokens"));
});

it("writes exactly once", async () => {
  // …same setup, emit status twice, assert sessionWrite still called once
});

it("all-shell sessions get no prompt write", async () => {
  // onCreate(project, "/p", ["shell"], "rotate tokens") → emit status → sessionWrite never called
});

it("empty prompt writes nothing", async () => {
  // onCreate(project, "/p", ["claude"], "") → emit status → sessionWrite never called
});
```

- [ ] **Step 2: Run — expect FAIL**

- [ ] **Step 3: Implement in App.tsx**

```tsx
// Session prompt (design §3 New session): delivered to the first agent pane
// after its first status event — the engine's CLI is accepting input by the
// time it starts reporting status. Written WITHOUT a trailing newline so
// nothing auto-executes; the user reviews and presses Enter.
// ponytail: if an engine ever swallows early stdin, gate this on
// status === "ready" instead of first-event.
const pendingFirstPrompt = useRef<Map<string, string>>(new Map());
```

In `handleSessionCreated`, after spawning the slot tabs:

```tsx
const promptText = prompt.trim();
if (promptText.length > 0) {
  const target = spawned.find((t) => t.engine !== "shell");
  if (target) pendingFirstPrompt.current.set(target.id, promptText);
}
```

In the existing `usePerSessionEvent(tabIds, "session-status:", …)` callback (L496–514), before/alongside the `tab/status` dispatch:

```tsx
const queued = pendingFirstPrompt.current.get(event.id);
if (queued !== undefined) {
  pendingFirstPrompt.current.delete(event.id);
  void sessionWrite(event.id, queued);
}
```

- [ ] **Step 4: Run — expect PASS (`npx vitest run src/App.sessionPrompt.test.tsx`), then `npm test`. Commit**

```bash
git add ui/src/App.tsx ui/src/App.sessionPrompt.test.tsx
git commit -m "feat(session): deliver the session prompt to the first agent pane"
```

---

### Task 12: New Workspace modal — stats strip + toggles (+ Rust `folder_stats`)

Design drops the old name/engines/layout sections: folder + FOUND IN THIS FOLDER stats + two toggles. Workspace name derives from the folder basename (rename later via the workspace menu's ⋯ → ProjectMenu). After "Add workspace", App selects it and immediately opens the New Session modal — that's how the first terminals now get created.

**Files:**
- Modify: `src-tauri/src/commands/mod.rs` (new command + unit test), `src-tauri/src/lib.rs` (register in `invoke_handler`)
- Modify: `ui/src/lib/tauri.ts` (wrapper), `ui/src/state/newWorkspaceState.ts` + test, `ui/src/components/NewWorkspaceModal.tsx` + test, `ui/src/App.tsx` (`handleWorkspaceCreated` rework), `ui/src/App.newWorkspace.test.tsx`, `ui/src/App.css`
- Sweep: `ui/src/components/Sidebar.tsx` + `EmptyWorkspace.tsx`/onboarding callers of `onCreate(project, engines, layout)` → new signature

**Interfaces:**

```rust
// src-tauri/src/commands/mod.rs
#[derive(serde::Serialize, Clone)]
pub struct FolderStats {
    pub files: u64,
    pub languages: Vec<String>, // top 2 by file count, e.g. ["TS", "Rust"]
    pub git: bool,
    pub branches: u32,
}
#[tauri::command]
pub fn folder_stats(path: String) -> Result<FolderStats, String>;
```

```ts
// ui/src/lib/tauri.ts
export interface FolderStats { files: number; languages: string[]; git: boolean; branches: number; }
export async function folderStats(path: string): Promise<FolderStats>;

// ui/src/state/newWorkspaceState.ts (replaces engines/layout/name fields)
export interface NewWorkspaceState {
  path: string | null;
  stats: FolderStats | "loading" | null;
  ingestNow: boolean;      // default true
  reviewNotes: boolean;    // default false — mirrors REVIEW_MEMORY_SETTING_KEY
  submitting: boolean;
  error: string | null;
}
export function workspaceNameFromPath(path: string): string; // basename, "~"-safe
```

- Modal callback becomes `onCreate: (project: ProjectInfo) => void`; `SidebarProps.onWorkspaceCreated` / `App.handleWorkspaceCreated` drop the `(engines, layout)` params: reload projects → select project → `setNewSessionOpen(true)`.
- Consumes: `addProject(path, name)`, `rootsSetPaused(project, paused)` (tauri.ts L350), `settingsSet(REVIEW_MEMORY_SETTING_KEY, …)` — read tauri.ts L282–308 first: review_memory is a plain settings key via `settingsGet`/`settingsSet`; match whatever string encoding `ReviewPanel` writes ("on"/"true" — copy the existing writer verbatim).

- [ ] **Step 1: Rust — write the failing unit test**

In `src-tauri/src/commands/mod.rs` (`#[cfg(test)] mod folder_stats_tests`):

```rust
#[test]
fn language_mapping_and_top2() {
    use super::{language_for, top_languages};
    assert_eq!(language_for("ts"), Some("TS"));
    assert_eq!(language_for("tsx"), Some("TS"));
    assert_eq!(language_for("rs"), Some("Rust"));
    assert_eq!(language_for("py"), Some("Python"));
    assert_eq!(language_for("lock"), None);
    let mut counts = std::collections::HashMap::new();
    counts.insert("TS", 120u64);
    counts.insert("Rust", 40);
    counts.insert("Python", 2);
    assert_eq!(top_languages(&counts), vec!["TS".to_string(), "Rust".to_string()]);
}

#[test]
fn stats_walk_counts_files_and_detects_git() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(dir.path().join("a.ts"), "x").unwrap();
    std::fs::write(dir.path().join("b.rs"), "x").unwrap();
    std::fs::create_dir(dir.path().join(".git")).unwrap();
    let stats = super::folder_stats(dir.path().to_string_lossy().into()).unwrap();
    assert_eq!(stats.files, 2);
    assert!(stats.git);
    assert_eq!(stats.languages, vec!["Rust".to_string(), "TS".to_string()]); // alphabetical tiebreak
}
```

Run: `cargo test -p omniagent-ade folder_stats` from `src-tauri/` (check the actual package name in `src-tauri/Cargo.toml` first; `tempfile` — add to `[dev-dependencies]` if absent, it's already a transitive dev-dep in most Tauri workspaces).
Expected: FAIL (functions missing).

- [ ] **Step 2: Implement `folder_stats`**

```rust
const LANGUAGES: &[(&str, &str)] = &[
    ("ts", "TS"), ("tsx", "TS"), ("js", "JS"), ("jsx", "JS"),
    ("rs", "Rust"), ("py", "Python"), ("go", "Go"), ("swift", "Swift"),
    ("css", "CSS"), ("html", "HTML"), ("java", "Java"), ("rb", "Ruby"),
];

fn language_for(ext: &str) -> Option<&'static str> {
    LANGUAGES.iter().find(|(e, _)| *e == ext).map(|(_, l)| *l)
}

fn top_languages(counts: &std::collections::HashMap<&'static str, u64>) -> Vec<String> {
    let mut v: Vec<_> = counts.iter().collect();
    v.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
    v.into_iter().take(2).map(|(l, _)| l.to_string()).collect()
}

#[tauri::command]
pub fn folder_stats(path: String) -> Result<FolderStats, String> {
    let root = std::path::Path::new(&path);
    if !root.is_dir() { return Err(format!("not a directory: {path}")); }
    let mut files = 0u64;
    let mut counts: std::collections::HashMap<&'static str, u64> = Default::default();
    // Reuse the ingest walker so counts respect .gitignore, matching what
    // ingestion will actually walk. brain_ingest::walk is already a
    // dependency of this crate (list_dir goes through it).
    for entry in brain_ingest::walk::walk_files(root).map_err(|e| e.to_string())? {
        files += 1;
        if let Some(ext) = entry.extension().and_then(|e| e.to_str()) {
            if let Some(lang) = language_for(&ext.to_ascii_lowercase()) {
                *counts.entry(lang).or_insert(0) += 1;
            }
        }
    }
    let git = root.join(".git").exists();
    let branches = if git {
        std::process::Command::new("git")
            .args(["-C", &path, "branch", "--format=%(refname:short)"])
            .output()
            .ok()
            .map(|o| String::from_utf8_lossy(&o.stdout).lines().count() as u32)
            .unwrap_or(0)
    } else { 0 };
    Ok(FolderStats { files, languages: top_languages(&counts), git, branches })
}
```

**Adaptation note (not a placeholder — a required check):** open `crates/brain-ingest/src/walk.rs` and use its actual public walking API; if it exposes only `list_dir` (one level), do the recursion here with a simple stack over `list_dir`, which already honors gitignore. Register `folder_stats` in `src-tauri/src/lib.rs`'s `invoke_handler` list. Run the tests — expect PASS. Then `cargo check`.

- [ ] **Step 3: TS wrapper + state rework (failing tests first)**

`lib/tauri.ts`:

```ts
export interface FolderStats { files: number; languages: string[]; git: boolean; branches: number; }
export async function folderStats(path: string): Promise<FolderStats> {
  return invoke<FolderStats>("folder_stats", { path });
}
```

`newWorkspaceState.test.ts` rework:

```ts
it("workspaceNameFromPath takes the basename", () => {
  expect(workspaceNameFromPath("/Users/b/Bruno.Digital/omniagent-web")).toBe("omniagent-web");
  expect(workspaceNameFromPath("/x/y/")).toBe("y");
});
it("defaults: ingest on, review notes off, no stats", () => {
  const s = initialNewWorkspaceState();
  expect(s).toMatchObject({ path: null, stats: null, ingestNow: true, reviewNotes: false });
});
it("picking a path marks stats loading", () => {
  const s = newWorkspaceReducer(initialNewWorkspaceState(), { type: "path", path: "/p" });
  expect(s.path).toBe("/p");
  expect(s.stats).toBe("loading");
});
it("toggles flip", () => { /* {type:"ingestNow"} and {type:"reviewNotes"} invert */ });
```

Implement: `workspaceNameFromPath = (p) => p.replace(/\/+$/, "").split("/").pop() ?? p;` plus the reducer/fields per the interface. Delete `engines`/`agentsCollapsed`/`layout`/`name` and their actions; `initialNewWorkspaceStateFor(agents)` becomes argless `initialNewWorkspaceState()`.

- [ ] **Step 4: Rework `NewWorkspaceModal.tsx` + its test**

- PROJECT FOLDER row: path (mono, rtl-ellipsis) + `Browse…` (`open({ directory: true })` as today); on pick dispatch `path`, then `folderStats(path)` → dispatch `{ type: "stats", stats }` (add that action; on error dispatch `stats: null`).
- FOUND IN THIS FOLDER strip (render only when `path` set): three cells — `{stats.files.toLocaleString()} / "files to walk"`, `{stats.languages.join(" · ") || "—"} / "languages"`, `{stats.git ? "git ✓" : "no git"} / {stats.git ? `${stats.branches} branches` : "init later"}`. While `"loading"`: cells show "…".
- Toggles (use Task 1's `.switch`, `role="switch"` + `aria-checked`):
  - "Ingest into the brain now" / "Walk, parse and link in the background — you can start working immediately."
  - "Review memory notes before commit" / "Off: session notes auto-commit to your repo."
- Footer hint: "Scoped access — only this folder is readable." Buttons: Cancel / **Add workspace ⏎** (disabled until `path` set).
- `confirm()`:

```tsx
const project = await addProject(state.path, workspaceNameFromPath(state.path));
if (!state.ingestNow) await rootsSetPaused(project.id, true);
await settingsSet(REVIEW_MEMORY_SETTING_KEY, state.reviewNotes ? /* copy ReviewPanel's on-value */ : /* off-value */);
onCreate(project);
```

- Modal test rework (mock `folderStats`, `addProject`, `rootsSetPaused`, `settingsSet`, plugin-dialog `open`): stats strip renders after folder pick; ingest-off calls `rootsSetPaused(project.id, true)`; confirm passes the project; disabled confirm without a path.

CSS:

```css
/* redesign: new-workspace modal stats strip + toggle rows (Task 12). */
.new-workspace-panel-v2 { width: 520px; }
.stats-strip {
  display: flex; border-radius: 9px; overflow: hidden;
  background: rgba(255, 255, 255, 0.035); border: 0.5px solid rgba(255, 255, 255, 0.07);
}
.stats-strip-cell { flex: 1; padding: 10px 12px; }
.stats-strip-cell + .stats-strip-cell { border-left: 0.5px solid rgba(255, 255, 255, 0.07); }
.stats-strip-value { font: 600 15px/1 var(--mono); color: #eaeaf0; }
.stats-strip-value.is-good { color: var(--status-ready); }
.stats-strip-label { font: 400 10px/1.3 var(--sans); color: #6d6d78; margin-top: 3px; }
.toggle-row { display: flex; align-items: center; gap: 10px; }
.toggle-row-text { flex: 1; }
.toggle-row-title { display: block; font: 500 11.5px/1.3 var(--sans); color: #e8e8ee; }
.toggle-row-sub { display: block; font: 400 10.5px/1.35 var(--sans); color: #6d6d78; }
```

- [ ] **Step 5: Rework App wiring + tests**

`handleWorkspaceCreated(project)` (App.tsx L846–893): drop the engine-spawn loop and `last_selected_agents` write; body becomes reload projects → `onSelectProject(project)`-equivalent state update → `setNewSessionOpen(true)`. Update `SidebarProps.onWorkspaceCreated` type, Sidebar pass-through, `EmptyWorkspace`/onboarding call sites (grep `onWorkspaceCreated\|handleWorkspaceCreated`), and `App.newWorkspace.test.tsx`: creating a workspace now asserts the New Session modal opens instead of tabs spawning.

- [ ] **Step 6: Run everything — `cargo test` (src-tauri), `npm test`, `npm run build` — expect PASS. Commit**

```bash
git add -A ui/src src-tauri
git commit -m "feat(workspace): new-workspace modal with folder stats and ingest/review toggles"
```

---

### Task 13: ⌘N direct, retire the chooser, shortcut sheet, cleanup

**Files:**
- Modify: `ui/src/App.tsx` (⌘N handler, remove chooser render + `handleCreateChoice`), `ui/src/state/keyboardShortcuts.ts`
- Delete: `ui/src/components/NewChooserModal.tsx`, `ui/src/components/NewChooserModal.test.tsx`, `ui/src/state/newChooserState.ts`, `ui/src/state/newChooserState.test.ts`, `ui/src/components/EnginePicker.tsx`
- Modify: `ui/src/App.css` (delete `.new-chooser-*`; migrate `.engine-picker-footer` usages to `.modal-footer` — grep first, `NewChooserModal` was its main consumer)

**Interfaces:** none new. ⌘N behavior: `selectedProject ? setNewSessionOpen(true) : setNewWorkspaceOpen(true)`.

- [ ] **Step 1: Write the failing test** (extend `App.newSession.test.tsx`)

```tsx
it("⌘N opens the new-session modal directly for the selected workspace", async () => {
  fireEvent.keyDown(window, { key: "n", metaKey: true });
  expect(await screen.findByTestId("stub-new-session-modal")).toBeInTheDocument();
});

it("⌘N with no workspace opens the new-workspace modal", async () => {
  // scaffolding variant with zero projects
  fireEvent.keyDown(window, { key: "n", metaKey: true });
  expect(await screen.findByTestId("stub-new-workspace-modal")).toBeInTheDocument();
});
```

- [ ] **Step 2: Run — expect FAIL. Implement**

⌘N branch in the App key handler (L1267–1293) per Interfaces; delete `newChooserOpen` state, `handleCreateChoice` (L981–988), the chooser render, then the four chooser/EnginePicker files; grep `chooserKeyAction\|NewChooserModal\|EnginePicker\|new-chooser\|engine-picker-footer` across `ui/src` and resolve every hit (App.css: keep `.engine-picker*` rules only if a live consumer remains — otherwise delete the block).

- [ ] **Step 3: Update `state/keyboardShortcuts.ts`**

Per its module doc (every listed key must exist in code), the final map must read: `⌘T` "New terminal" · `⌘N` "New session" · `⌘K` palette · `⌘W` close pane (existing) — plus any entries that already exist. `KeyboardShortcutsSheet` renders from this list; no other change needed.

- [ ] **Step 4: Full verification**

```bash
cd ui && npm test && npm run build
cd ../src-tauri && cargo check && cargo test
```

Expected: all green. Then a manual smoke pass (launch via the repo's dev command, `npm run tauri dev` from the repo root or `ui` — check package.json scripts): switcher opens menu → switch workspace → new workspace with stats + toggles → auto-opens new session → prompt/layout/slots → session appears with dots + badge → expand → terminal rows live-update status → New terminal row → ⌘T modal → files section shows git letters → filter narrows.

- [ ] **Step 5: Commit**

```bash
git add -A ui/src
git commit -m "feat(shortcuts): ⌘N opens new session directly; retire chooser modal and EnginePicker"
```

---

## Post-plan notes for the executor

- **Order:** 1 → 2 → 3 → 4 → 5 are strictly sequential. 6 → 7 sequential but independent of 4–5. 8 independent after 3. 9–13 sequential-ish (9 before 13; 10 before 11; 12 before 13's final sweep). If parallelizing with worktrees: {4,5}, {6,7}, {8}, {9}, {10,11}, {12} after 3 lands.
- **The mock's right-hand panes/review/notifications/status-bar are OUT of scope** — this plan is the left pane + its modals only.
- Design deviations locked in here (all deliberate): colored-initial avatars instead of the mock's logo images (no per-project logo asset exists); Workspace/Map view toggle kept; Import moved into the workspace menu; SessionHoverCard kept; workspace name derived from folder basename (mock has no name field); first-prompt written without newline (user confirms with Enter).




