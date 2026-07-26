# Agent Installation & Workspace Creation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement on-demand agent installation for workspace creation, expanding from 3 hardcoded engines to 5 agents (claude, codex, shell, copilot, antigravity) with install UI and dimmed overlay during installation.

**Architecture:** Agent availability is tracked in a new `agents.ts` reducer tracking installed, installing, and last-selected agents. When a user creates a workspace, uninstalled agents show disabled checkboxes + "Install" buttons. Clicking Install dispatches a Tauri command to download/enable the agent. Creating the workspace spawns panes for selected agents; panes with installing agents show a dimmed overlay with centered OmniAgent logo. Once backend signals install completion, overlay auto-dismisses and the agent starts. Last selections are persisted in settings.

**Tech Stack:** React, TypeScript, Tauri (Rust backend), XTerm.js terminal, CSS overlays

## Global Constraints

- Five agents only: `["claude", "codex", "shell", "copilot", "antigravity"]` (replaces hardcoded 3)
- Install before workspace creation (not concurrent with creation)
- Pre-fill logic: last-selected if all available → single installed → default to shell
- Installation status persisted per-session: `last_selected_agents` in settings table
- Pane overlay: centered OmniAgent logo (~200px) + "Installing…" text, no progress percentage
- Partial failures allowed: user can create workspace with mix of installed/installing agents; failed installs show "Retry" button
- Reuse patterns: settingsGet/settingsSet, createSessionTab loop, partial-failure error banner, CSS overlay from App.css

---

## File Structure

### New Files
- `ui/src/state/agents.ts` — Agent registry reducer, pre-fill logic, types
- `ui/src/state/agents.test.ts` — Reducer tests, pre-fill logic tests
- `ui/src/components/PaneInstallOverlay.tsx` — Installation overlay component (logo + text)
- `ui/src/components/PaneInstallOverlay.test.tsx` — Overlay rendering tests
- `src-tauri/src/commands/agents.rs` — Tauri backend: check_installed, install_agent commands
- `docs/superpowers/plans/2026-07-26-agent-installation-plan.md` — This file

### Modified Files
- `ui/src/state/sessions.ts` — Replace `ENGINES` with `AVAILABLE_AGENTS` from agents.ts
- `ui/src/theme.ts` — Extend `ENGINE_LABEL`, `ENGINE_COLOR`, `ENGINE_HINT` for copilot + antigravity
- `ui/src/components/NewWorkspaceModal.tsx` — Show install status, "Install" buttons, dispatch agents/selected
- `ui/src/components/Workspace.tsx` — Thread `agentState` prop to panes
- `ui/src/components/Terminal.tsx` — Render `<PaneInstallOverlay>` conditionally
- `ui/src/App.tsx` — Initialize agents state, handle install dispatch, wire into session creation
- `ui/src/lib/tauri.ts` — Add `agentCheckInstalled()` and `agentInstall()` wrappers
- `src-tauri/src/main.rs` — Register agents command module
- `src-tauri/src/lib.rs` — Add `mod commands::agents` declaration

---

## Tasks

### Task 1: Backend Agent Commands (Tauri/Rust)

**Files:**
- Create: `src-tauri/src/commands/agents.rs`
- Modify: `src-tauri/src/lib.rs`
- Modify: `src-tauri/src/main.rs`

**Interfaces:**
- Produces:
  - `#[tauri::command] async fn agents_check_installed() -> Result<Vec<String>>` — returns list of installed agent names
  - `#[tauri::command] async fn agents_install(agent: String) -> Result<()>` — downloads and installs agent, emits `agent-install-progress:{agent}` events

- [ ] **Step 1: Create `src-tauri/src/commands/agents.rs`**

```rust
use std::process::Command;
use tauri::{State, Emitter};

/// Check which agents are installed by looking for them on PATH
/// Returns a Vec of installed agent names
#[tauri::command]
pub async fn agents_check_installed() -> Result<Vec<String>, String> {
    let agents = vec!["claude", "codex", "shell", "copilot", "antigravity"];
    let mut installed = Vec::new();

    for agent in agents {
        // Check if agent binary exists on PATH
        match which::which(agent) {
            Ok(_) => installed.push(agent.to_string()),
            Err(_) => {} // Not installed, skip
        }
    }

    Ok(installed)
}

/// Install an agent (download + enable)
/// Emits progress events: agent-install-progress:{agent}
#[tauri::command]
pub async fn agents_install(agent: String, window: tauri::Window) -> Result<(), String> {
    // Map agent name to install script/command
    let install_cmd = match agent.as_str() {
        "claude" => "pip install claude-code",
        "codex" => "pip install codex",
        "copilot" => "npm install -g copilot",
        "antigravity" => "pip install antigravity",
        "shell" => return Err("shell is built-in".to_string()),
        _ => return Err(format!("Unknown agent: {}", agent)),
    };

    // Emit starting event
    let _ = window.emit(&format!("agent-install-progress:{}", agent), "installing");

    // Execute install command
    match Command::new("sh")
        .arg("-c")
        .arg(install_cmd)
        .output()
    {
        Ok(output) => {
            if output.status.success() {
                // Emit completion event
                let _ = window.emit(&format!("agent-install-progress:{}", agent), "completed");
                Ok(())
            } else {
                let err = String::from_utf8_lossy(&output.stderr);
                let _ = window.emit(&format!("agent-install-progress:{}", agent), "failed");
                Err(format!("Installation failed: {}", err))
            }
        }
        Err(e) => {
            let _ = window.emit(&format!("agent-install-progress:{}", agent), "failed");
            Err(format!("Failed to run install: {}", e))
        }
    }
}
```

- [ ] **Step 2: Add module declaration to `src-tauri/src/lib.rs`**

Find the `pub mod commands;` section and add:

```rust
pub mod agents;
```

Full location: `src-tauri/src/lib.rs`, within `pub mod commands { ... }` block

- [ ] **Step 3: Register commands in `src-tauri/src/main.rs`**

Find the `.invoke_handler()` call (around line 45-60) and add to the commands list:

```rust
.invoke_handler(tauri::generate_handler![
    // ... existing commands ...
    crate::commands::agents::agents_check_installed,
    crate::commands::agents::agents_install,
])
```

- [ ] **Step 4: Run Tauri build to verify**

```bash
cd src-tauri
cargo check
```

Expected: No errors

- [ ] **Step 5: Commit**

```bash
git add src-tauri/src/commands/agents.rs src-tauri/src/lib.rs src-tauri/src/main.rs
git commit -m "feat(agents): add backend check_installed and install commands"
```

---

### Task 2: Agent Registry State (Frontend)

**Files:**
- Create: `ui/src/state/agents.ts`
- Create: `ui/src/state/agents.test.ts`

**Interfaces:**
- Produces:
  - `export type Agent = "claude" | "codex" | "shell" | "copilot" | "antigravity"`
  - `export const AVAILABLE_AGENTS: readonly Agent[]`
  - `export interface AgentsState { installed: Set<Agent>; lastSelected: Agent[]; installing: Map<Agent, 'in_progress' | 'failed'>; }`
  - `export type AgentsAction = { type: "agents/loaded"; installed: Agent[] } | { type: "agents/selected"; agents: Agent[] } | { type: "agents/install_started"; agent: Agent } | { type: "agents/install_completed"; agent: Agent } | { type: "agents/install_failed"; agent: Agent }`
  - `export function agentsReducer(state: AgentsState, action: AgentsAction): AgentsState`
  - `export function getDefaultAgentSelection(state: AgentsState): Agent[]` — returns pre-filled agents list

- [ ] **Step 1: Create `ui/src/state/agents.ts`**

```typescript
export const AVAILABLE_AGENTS = ["claude", "codex", "shell", "copilot", "antigravity"] as const;
export type Agent = (typeof AVAILABLE_AGENTS)[number];

export interface AgentsState {
  installed: Set<Agent>;
  lastSelected: Agent[];
  installing: Map<Agent, 'in_progress' | 'failed'>;
}

export const initialAgentsState: AgentsState = {
  installed: new Set(),
  lastSelected: [],
  installing: new Map(),
};

export type AgentsAction =
  | { type: "agents/loaded"; installed: Agent[] }
  | { type: "agents/selected"; agents: Agent[] }
  | { type: "agents/install_started"; agent: Agent }
  | { type: "agents/install_completed"; agent: Agent }
  | { type: "agents/install_failed"; agent: Agent };

export function agentsReducer(state: AgentsState, action: AgentsAction): AgentsState {
  switch (action.type) {
    case "agents/loaded":
      return {
        ...state,
        installed: new Set(action.installed),
      };

    case "agents/selected":
      return {
        ...state,
        lastSelected: action.agents,
      };

    case "agents/install_started":
      return {
        ...state,
        installing: new Map(state.installing).set(action.agent, 'in_progress'),
      };

    case "agents/install_completed": {
      const next = new Map(state.installing);
      next.delete(action.agent);
      return {
        ...state,
        installed: new Set(state.installed).add(action.agent),
        installing: next,
      };
    }

    case "agents/install_failed":
      return {
        ...state,
        installing: new Map(state.installing).set(action.agent, 'failed'),
      };

    default:
      return state;
  }
}

/**
 * Pre-fill logic for agent selection in NewWorkspaceModal:
 * 1. If all lastSelected agents are installed, use them
 * 2. If only one agent is installed, use it
 * 3. Otherwise default to shell
 */
export function getDefaultAgentSelection(state: AgentsState): Agent[] {
  const { installed, lastSelected } = state;

  // All last-selected agents still available?
  if (lastSelected.length > 0 && lastSelected.every(a => installed.has(a))) {
    return lastSelected;
  }

  // Only one agent installed?
  if (installed.size === 1) {
    return Array.from(installed);
  }

  // Default to shell
  return ["shell"];
}
```

- [ ] **Step 2: Write failing tests for agents.ts**

Create `ui/src/state/agents.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import {
  agentsReducer,
  initialAgentsState,
  getDefaultAgentSelection,
  type Agent,
} from "./agents";

describe("agentsReducer", () => {
  it("agents/loaded: sets installed agents", () => {
    const state = agentsReducer(initialAgentsState, {
      type: "agents/loaded",
      installed: ["claude", "codex"],
    });
    expect(state.installed).toEqual(new Set(["claude", "codex"]));
  });

  it("agents/selected: saves last-selected agents", () => {
    const state = agentsReducer(initialAgentsState, {
      type: "agents/selected",
      agents: ["claude", "shell"],
    });
    expect(state.lastSelected).toEqual(["claude", "shell"]);
  });

  it("agents/install_started: adds agent to installing map", () => {
    const state = agentsReducer(initialAgentsState, {
      type: "agents/install_started",
      agent: "copilot",
    });
    expect(state.installing.get("copilot")).toBe("in_progress");
  });

  it("agents/install_completed: moves agent to installed, removes from installing", () => {
    const partialState = {
      ...initialAgentsState,
      installing: new Map([["copilot", "in_progress" as const]]),
    };
    const state = agentsReducer(partialState, {
      type: "agents/install_completed",
      agent: "copilot",
    });
    expect(state.installed.has("copilot")).toBe(true);
    expect(state.installing.has("copilot")).toBe(false);
  });

  it("agents/install_failed: updates installing status to failed", () => {
    const partialState = {
      ...initialAgentsState,
      installing: new Map([["copilot", "in_progress" as const]]),
    };
    const state = agentsReducer(partialState, {
      type: "agents/install_failed",
      agent: "copilot",
    });
    expect(state.installing.get("copilot")).toBe("failed");
  });
});

describe("getDefaultAgentSelection", () => {
  it("returns lastSelected if all are installed", () => {
    const state = {
      installed: new Set<Agent>(["claude", "codex", "shell"]),
      lastSelected: ["claude", "codex"] as Agent[],
      installing: new Map(),
    };
    expect(getDefaultAgentSelection(state)).toEqual(["claude", "codex"]);
  });

  it("returns single installed agent if only one is available", () => {
    const state = {
      installed: new Set<Agent>(["claude"]),
      lastSelected: [] as Agent[],
      installing: new Map(),
    };
    expect(getDefaultAgentSelection(state)).toEqual(["claude"]);
  });

  it("defaults to shell if nothing else applies", () => {
    const state = {
      installed: new Set<Agent>(),
      lastSelected: [] as Agent[],
      installing: new Map(),
    };
    expect(getDefaultAgentSelection(state)).toEqual(["shell"]);
  });

  it("ignores lastSelected if any agent is no longer installed", () => {
    const state = {
      installed: new Set<Agent>(["claude"]),
      lastSelected: ["codex", "shell"] as Agent[], // codex not installed anymore
      installing: new Map(),
    };
    // Should not use lastSelected, fall through to single-installed case
    expect(getDefaultAgentSelection(state)).toEqual(["claude"]);
  });
});
```

- [ ] **Step 3: Run tests to verify they all pass**

```bash
cd ui && npm test -- agents.test.ts
```

Expected: All tests PASS

- [ ] **Step 4: Commit**

```bash
git add ui/src/state/agents.ts ui/src/state/agents.test.ts
git commit -m "feat(agents): add agent registry reducer and pre-fill logic"
```

---

### Task 3: PaneInstallOverlay Component

**Files:**
- Create: `ui/src/components/PaneInstallOverlay.tsx`
- Create: `ui/src/components/PaneInstallOverlay.test.tsx`

**Interfaces:**
- Consumes: `Agent` type from agents.ts
- Produces: `export default function PaneInstallOverlay({ agent, status }: { agent: Agent; status: 'in_progress' | 'failed' }): JSX.Element`

- [ ] **Step 1: Create `ui/src/components/PaneInstallOverlay.tsx`**

```typescript
import "./PaneInstallOverlay.css";
import type { Agent } from "../state/agents";

interface PaneInstallOverlayProps {
  agent: Agent;
  status: 'in_progress' | 'failed';
}

function OmniAgentLogo() {
  // Simple SVG logo placeholder (200px)
  return (
    <svg
      width="200"
      height="200"
      viewBox="0 0 200 200"
      fill="none"
      aria-hidden
      className="pane-install-logo"
    >
      {/* Simplified OmniAgent logo: concentric circles with agent theme color */}
      <circle cx="100" cy="100" r="80" stroke="currentColor" strokeWidth="2" />
      <circle cx="100" cy="100" r="60" stroke="currentColor" strokeWidth="2" />
      <circle cx="100" cy="100" r="40" fill="currentColor" opacity="0.3" />
      <text
        x="100"
        y="105"
        textAnchor="middle"
        fontSize="24"
        fontWeight="bold"
        fill="currentColor"
      >
        OA
      </text>
    </svg>
  );
}

export default function PaneInstallOverlay({
  agent,
  status,
}: PaneInstallOverlayProps): JSX.Element {
  return (
    <div className="pane-install-overlay">
      {/* Dimmed backdrop over terminal */}
      <div className="pane-install-backdrop" />

      {/* Centered content */}
      <div className="pane-install-content">
        <OmniAgentLogo />
        <p className="pane-install-text">
          {status === 'in_progress' ? 'Installing…' : 'Installation failed'}
        </p>
        {status === 'failed' && (
          <p className="pane-install-hint">Check your network and try again</p>
        )}
      </div>
    </div>
  );
}
```

- [ ] **Step 2: Create `ui/src/components/PaneInstallOverlay.css`**

```css
.pane-install-overlay {
  position: absolute;
  top: 0;
  left: 0;
  right: 0;
  bottom: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  z-index: 10;
  font-family: var(--font-sans);
}

.pane-install-backdrop {
  position: absolute;
  inset: 0;
  background: rgba(0, 0, 0, 0.4);
  backdrop-filter: blur(2px);
}

.pane-install-content {
  position: relative;
  z-index: 11;
  text-align: center;
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 1.5rem;
}

.pane-install-logo {
  color: var(--color-text-secondary);
  opacity: 0.9;
}

.pane-install-text {
  font-size: 1rem;
  font-weight: 500;
  color: var(--color-text);
  margin: 0;
}

.pane-install-hint {
  font-size: 0.875rem;
  color: var(--color-text-tertiary);
  margin: 0;
}
```

- [ ] **Step 3: Write failing test**

Create `ui/src/components/PaneInstallOverlay.test.tsx`:

```typescript
import { describe, it, expect } from "vitest";
import { render, screen } from "@testing-library/react";
import PaneInstallOverlay from "./PaneInstallOverlay";

describe("PaneInstallOverlay", () => {
  it("renders logo and 'Installing…' text when in_progress", () => {
    render(<PaneInstallOverlay agent="claude" status="in_progress" />);
    expect(screen.getByText("Installing…")).toBeInTheDocument();
  });

  it("renders logo and 'Installation failed' text when failed", () => {
    render(<PaneInstallOverlay agent="copilot" status="failed" />);
    expect(screen.getByText("Installation failed")).toBeInTheDocument();
  });

  it("renders hint text only when failed", () => {
    const { rerender } = render(
      <PaneInstallOverlay agent="claude" status="in_progress" />
    );
    expect(
      screen.queryByText("Check your network and try again")
    ).not.toBeInTheDocument();

    rerender(<PaneInstallOverlay agent="claude" status="failed" />);
    expect(
      screen.getByText("Check your network and try again")
    ).toBeInTheDocument();
  });

  it("renders with correct CSS classes for styling", () => {
    const { container } = render(
      <PaneInstallOverlay agent="shell" status="in_progress" />
    );
    expect(container.querySelector(".pane-install-overlay")).toBeInTheDocument();
    expect(
      container.querySelector(".pane-install-backdrop")
    ).toBeInTheDocument();
    expect(
      container.querySelector(".pane-install-content")
    ).toBeInTheDocument();
  });
});
```

- [ ] **Step 4: Run tests**

```bash
cd ui && npm test -- PaneInstallOverlay.test.tsx
```

Expected: All tests PASS

- [ ] **Step 5: Commit**

```bash
git add ui/src/components/PaneInstallOverlay.tsx ui/src/components/PaneInstallOverlay.css ui/src/components/PaneInstallOverlay.test.tsx
git commit -m "feat(ui): add PaneInstallOverlay component with centered logo"
```

---

### Task 4: Extend Theme for New Agents

**Files:**
- Modify: `ui/src/theme.ts`

**Interfaces:**
- Consumes: Nothing (top-level theme constants)
- Produces: Extended `ENGINE_LABEL`, `ENGINE_COLOR`, `ENGINE_HINT` with copilot and antigravity entries

- [ ] **Step 1: Read current theme.ts to understand structure**

```bash
head -50 ui/src/theme.ts
```

- [ ] **Step 2: Extend `ENGINE_LABEL` in theme.ts**

Find the `ENGINE_LABEL` object and add two new entries:

```typescript
export const ENGINE_LABEL: Record<Engine, string> = {
  claude: "Claude Code",
  codex: "Codex",
  shell: "Shell",
  copilot: "GitHub Copilot",
  antigravity: "AntiGravity",
};
```

- [ ] **Step 3: Extend `ENGINE_COLOR` in theme.ts**

Find the `ENGINE_COLOR` object and add two new entries:

```typescript
export const ENGINE_COLOR: Record<Engine, string> = {
  claude: "#cc96f2",
  codex: "#a2e7f9",
  shell: "#9a9ca6",
  copilot: "#2ea043", // GitHub green
  antigravity: "#ff7f50", // Coral/orange
};
```

- [ ] **Step 4: Extend `ENGINE_HINT` in theme.ts** (if it exists)

If `ENGINE_HINT` exists, add:

```typescript
export const ENGINE_HINT: Record<Engine, string> = {
  // ... existing ...
  copilot: "GitHub Copilot AI",
  antigravity: "AntiGravity agent",
};
```

- [ ] **Step 5: Verify theme.ts compiles**

```bash
cd ui && npm run type-check
```

Expected: No TypeScript errors

- [ ] **Step 6: Commit**

```bash
git add ui/src/theme.ts
git commit -m "feat(theme): add colors and labels for copilot and antigravity agents"
```

---

### Task 5: Update ENGINES to Use AVAILABLE_AGENTS

**Files:**
- Modify: `ui/src/state/sessions.ts`

**Interfaces:**
- Consumes: `AVAILABLE_AGENTS` from agents.ts
- Produces: `ENGINES` now imports from agents.ts (type stays same)

- [ ] **Step 1: Add import at top of sessions.ts**

Add to imports section (around line 1-10):

```typescript
import { AVAILABLE_AGENTS, type Agent } from "./agents";
```

- [ ] **Step 2: Replace ENGINES definition**

Find line 11:

```typescript
export const ENGINES = ["claude", "codex", "shell"] as const;
export type Engine = (typeof ENGINES)[number];
```

Replace with:

```typescript
export const ENGINES = AVAILABLE_AGENTS;
export type Engine = Agent;
```

- [ ] **Step 3: Update isEngine function** (if needed)

If there's an `isEngine` function, ensure it still works:

```typescript
export function isEngine(value: unknown): value is Engine {
  return ENGINES.includes(value as Engine);
}
```

- [ ] **Step 4: Verify no compilation errors**

```bash
cd ui && npm run type-check
```

Expected: No errors (Engine type is now properly unified with Agent)

- [ ] **Step 5: Run existing sessions tests to ensure no breakage**

```bash
cd ui && npm test -- sessions.test.ts
```

Expected: All tests still pass

- [ ] **Step 6: Commit**

```bash
git add ui/src/state/sessions.ts
git commit -m "refactor(sessions): use AVAILABLE_AGENTS from agents state"
```

---

### Task 6: Add Tauri Wrappers for Agent Commands

**Files:**
- Modify: `ui/src/lib/tauri.ts`

**Interfaces:**
- Consumes: Tauri invoke backend (agents_check_installed, agents_install)
- Produces:
  - `export async function agentCheckInstalled(): Promise<string[]>`
  - `export async function agentInstall(agent: string): Promise<void>`
  - `export function onAgentInstallProgress(agent: string, callback: (status: string) => void): Unlistener`

- [ ] **Step 1: Add agent command wrappers to end of tauri.ts**

```typescript
/**
 * Check which agents are installed
 */
export async function agentCheckInstalled(): Promise<string[]> {
  return await invoke("agents_check_installed");
}

/**
 * Install an agent
 */
export async function agentInstall(agent: string): Promise<void> {
  return await invoke("agents_install", { agent });
}

/**
 * Listen for agent install progress events
 * Returns unlistener function
 */
export function onAgentInstallProgress(
  agent: string,
  callback: (status: string) => void
): () => void {
  const eventName = `agent-install-progress:${agent}`;
  const unlistener = appWindow.listen(eventName, (event) => {
    callback(event.payload as string);
  });
  return () => {
    unlistener.then((f) => f());
  };
}
```

- [ ] **Step 2: Verify TypeScript compilation**

```bash
cd ui && npm run type-check
```

Expected: No errors

- [ ] **Step 3: Commit**

```bash
git add ui/src/lib/tauri.ts
git commit -m "feat(tauri): add agent check and install command wrappers"
```

---

### Task 7: Update NewWorkspaceModal to Show Install Status

**Files:**
- Modify: `ui/src/components/NewWorkspaceModal.tsx`

**Interfaces:**
- Consumes: `agentState: AgentsState` (new prop from parent), `AVAILABLE_AGENTS` from agents.ts
- Produces: Modified modal that shows disabled checkboxes + Install buttons

- [ ] **Step 1: Add agentState prop to NewWorkspaceModal**

At the top, update the interface:

```typescript
interface NewWorkspaceModalProps {
  onCreate: (project: ProjectInfo, engines: Engine[], layout: LayoutPreset) => void;
  onClose: () => void;
  agentState: AgentsState; // NEW
  onInstallAgent: (agent: Agent) => void; // NEW
}

export default function NewWorkspaceModal({
  onCreate,
  onClose,
  agentState,
  onInstallAgent,
}: NewWorkspaceModalProps) {
  // ... rest of component
```

- [ ] **Step 2: Update agent rows rendering**

Find the agent list section (around line 209-225) and replace with:

```typescript
{!state.agentsCollapsed && (
  <ul className="new-workspace-agent-list">
    {AVAILABLE_AGENTS.map((agent) => {
      const isInstalled = agentState.installed.has(agent);
      const isInstalling = agentState.installing.has(agent);
      const installStatus = agentState.installing.get(agent);
      
      return (
        <li key={agent} className="new-workspace-agent-row">
          <label>
            <input
              type="checkbox"
              checked={state.engines[agent as Engine]}
              onChange={() => dispatch({ type: "engine_toggled", engine: agent as Engine })}
              disabled={!isInstalled}
            />
            <span className="engine-dot" style={{ background: ENGINE_COLOR[agent as Engine] }} aria-hidden />
            <span className="new-workspace-agent-label">{ENGINE_LABEL[agent as Engine]}</span>
          </label>
          {!isInstalled && !isInstalling && (
            <button
              type="button"
              className="new-workspace-install-btn"
              onClick={() => onInstallAgent(agent)}
            >
              Install
            </button>
          )}
          {isInstalling && (
            <span className="new-workspace-agent-status">
              {installStatus === 'failed' ? (
                <>
                  <span className="status-failed">Failed</span>
                  <button
                    type="button"
                    className="new-workspace-retry-btn"
                    onClick={() => onInstallAgent(agent)}
                  >
                    Retry
                  </button>
                </>
              ) : (
                <span className="status-installing">Installing…</span>
              )}
            </span>
          )}
        </li>
      );
    })}
  </ul>
)}
```

- [ ] **Step 3: Add CSS for install buttons and status**

Add to existing NewWorkspaceModal CSS (find the stylesheet and append):

```css
.new-workspace-install-btn {
  padding: 0.4rem 0.8rem;
  font-size: 0.875rem;
  background: var(--color-primary);
  color: white;
  border: none;
  border-radius: 4px;
  cursor: pointer;
  transition: opacity 0.2s;
}

.new-workspace-install-btn:hover {
  opacity: 0.9;
}

.new-workspace-agent-status {
  display: flex;
  gap: 0.5rem;
  align-items: center;
  font-size: 0.875rem;
}

.status-installing {
  color: var(--color-text-tertiary);
  animation: pulse 2s infinite;
}

.status-failed {
  color: var(--color-error);
}

.new-workspace-retry-btn {
  padding: 0.3rem 0.6rem;
  font-size: 0.75rem;
  background: var(--color-error);
  color: white;
  border: none;
  border-radius: 3px;
  cursor: pointer;
}

.new-workspace-retry-btn:hover {
  opacity: 0.9;
}

@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.5; }
}
```

- [ ] **Step 4: Add necessary imports**

At top of file, add:

```typescript
import { type AgentsState, type Agent, AVAILABLE_AGENTS } from "../state/agents";
```

- [ ] **Step 5: Run tests if they exist**

```bash
cd ui && npm test -- NewWorkspaceModal
```

Expected: Existing tests still pass (component is backward compatible via prop)

- [ ] **Step 6: Commit**

```bash
git add ui/src/components/NewWorkspaceModal.tsx
git commit -m "feat(modal): show install status and Install buttons for uninstalled agents"
```

---

### Task 8: App.tsx - Initialize and Wire Agent State

**Files:**
- Modify: `ui/src/App.tsx`

**Interfaces:**
- Consumes: `agentsReducer`, `getDefaultAgentSelection`, `agentCheckInstalled()`, `agentInstall()` from earlier tasks
- Produces: App now manages `agentState`, initializes on boot, dispatches install actions

- [ ] **Step 1: Add agents reducer to App.tsx**

Find the `useReducer` calls (around line 99) and add:

```typescript
import { agentsReducer, initialAgentsState, getDefaultAgentSelection, type AgentsState, type Agent } from "./state/agents";
import { agentCheckInstalled, agentInstall, onAgentInstallProgress } from "./lib/tauri";

// Inside App component:
const [agentState, agentDispatch] = useReducer(agentsReducer, initialAgentsState);
```

- [ ] **Step 2: Add boot effect to load installed agents**

Find the boot effects section (around line 246-268) and add:

```typescript
// Load installed agents on startup
useEffect(() => {
  (async () => {
    try {
      const installed = await agentCheckInstalled();
      agentDispatch({ type: "agents/loaded", installed });
      
      // Load last-selected from settings
      const lastSelected = await settingsGet("last_selected_agents");
      if (lastSelected) {
        try {
          const parsed = JSON.parse(lastSelected);
          if (Array.isArray(parsed)) {
            agentDispatch({ type: "agents/selected", agents: parsed });
          }
        } catch {
          // Ignore parse errors
        }
      }
    } catch (err) {
      console.error("Failed to load agent state", err);
    }
  })();
}, []);
```

- [ ] **Step 3: Add install handler**

Add a new function in App:

```typescript
async function handleInstallAgent(agent: Agent) {
  agentDispatch({ type: "agents/install_started", agent });
  
  try {
    // Listen for install progress
    const unlistener = onAgentInstallProgress(agent, (status) => {
      if (status === "completed") {
        agentDispatch({ type: "agents/install_completed", agent });
      } else if (status === "failed") {
        agentDispatch({ type: "agents/install_failed", agent });
      }
    });
    
    // Trigger install in backend
    await agentInstall(agent);
  } catch (err) {
    console.error(`Failed to install ${agent}:`, err);
    agentDispatch({ type: "agents/install_failed", agent });
  }
}
```

- [ ] **Step 4: Update handleWorkspaceCreated to save selections**

Find `handleWorkspaceCreated` (around line 772) and modify:

```typescript
async function handleWorkspaceCreated(
  project: ProjectInfo,
  engines: Engine[],
  layout: LayoutPreset
) {
  // ... existing code ...
  
  // NEW: Save selected agents
  await settingsSet("last_selected_agents", JSON.stringify(engines));
  agentDispatch({ type: "agents/selected", agents: engines as Agent[] });
  
  // ... rest of existing code ...
}
```

- [ ] **Step 5: Pass agentState and handler to NewWorkspaceModal**

Find where `<NewWorkspaceModal>` is rendered and update:

```typescript
<NewWorkspaceModal
  onCreate={handleWorkspaceCreated}
  onClose={closeNewWorkspaceModal}
  agentState={agentState}
  onInstallAgent={handleInstallAgent}
/>
```

- [ ] **Step 6: Thread agentState to Workspace component**

Find `<Workspace>` render and add prop:

```typescript
<Workspace
  project={selectedProject}
  agentState={agentState}
  // ... other props ...
/>
```

- [ ] **Step 7: Verify no TypeScript errors**

```bash
cd ui && npm run type-check
```

Expected: No errors

- [ ] **Step 8: Commit**

```bash
git add ui/src/App.tsx
git commit -m "feat(app): initialize and wire agent state, add install handler"
```

---

### Task 9: Update Workspace and Terminal Components

**Files:**
- Modify: `ui/src/components/Workspace.tsx`
- Modify: `ui/src/components/Terminal.tsx`

**Interfaces:**
- Consumes: `agentState: AgentsState` (threaded from App.tsx)
- Produces: Terminal renders `<PaneInstallOverlay>` when agent is installing

- [ ] **Step 1: Update Workspace.tsx to accept and pass agentState**

At top of Workspace component, add to props:

```typescript
interface ProjectPaneGridProps {
  project: ProjectInfo;
  agentState: AgentsState; // NEW
  // ... other props ...
}

export default function Workspace({
  project,
  agentState,
  // ... other props ...
}: ProjectPaneGridProps) {
  // ...
```

Then pass to Pane/Terminal:

```typescript
{/* Inside MosaicWindow rendering */}
<Terminal
  sessionId={tab.id}
  visible={visibleTabs.has(tab.id)}
  focused={state.activeTabId === tab.id}
  agentState={agentState}
  tabEngine={tab.engine}
/>
```

- [ ] **Step 2: Update Terminal.tsx to render overlay**

At top of Terminal component, add to props:

```typescript
interface TerminalProps {
  sessionId: string;
  visible: boolean;
  focused: boolean;
  agentState: AgentsState; // NEW
  tabEngine: Engine; // NEW
  // ... other props ...
}

export default function Terminal({
  sessionId,
  visible,
  focused,
  agentState,
  tabEngine,
  // ... other props ...
}: TerminalProps) {
  // ... existing code ...
```

- [ ] **Step 3: Import PaneInstallOverlay in Terminal.tsx**

Add import:

```typescript
import PaneInstallOverlay from "./PaneInstallOverlay";
```

- [ ] **Step 4: Render overlay conditionally**

Find where `<div ref={containerRef}>` is rendered and wrap content:

```typescript
<div ref={containerRef} className="terminal-container">
  {agentState.installing.has(tabEngine) && (
    <PaneInstallOverlay
      agent={tabEngine}
      status={agentState.installing.get(tabEngine)!}
    />
  )}
  {/* Existing terminal content */}
</div>
```

- [ ] **Step 5: Verify TypeScript**

```bash
cd ui && npm run type-check
```

Expected: No errors

- [ ] **Step 6: Commit**

```bash
git add ui/src/components/Workspace.tsx ui/src/components/Terminal.tsx
git commit -m "feat(ui): thread agent state to Terminal, render install overlay"
```

---

### Task 10: Settings Persistence (Last Selected Agents)

**Files:**
- Modify: `ui/src/App.tsx` (already partially done in Task 8)

**Interfaces:**
- Produces: Settings key `"last_selected_agents"` persisted as JSON array

- [ ] **Step 1: Verify boot load in App.tsx (Task 8, Step 2)**

Check that the boot effect includes:

```typescript
const lastSelected = await settingsGet("last_selected_agents");
if (lastSelected) {
  try {
    const parsed = JSON.parse(lastSelected);
    if (Array.isArray(parsed)) {
      agentDispatch({ type: "agents/selected", agents: parsed });
    }
  } catch {
    // Ignore parse errors
  }
}
```

- [ ] **Step 2: Verify save on workspace creation (Task 8, Step 4)**

Check that `handleWorkspaceCreated` includes:

```typescript
await settingsSet("last_selected_agents", JSON.stringify(engines));
```

- [ ] **Step 3: Manual test persistence**

- Create a new workspace with agents `["claude", "copilot"]`
- Restart the app
- Open New Workspace modal
- Verify that `["claude", "copilot"]` are pre-checked

Expected: Settings persist across app restarts

- [ ] **Step 4: Commit** (if not already committed in Task 8)

```bash
git add ui/src/App.tsx
git commit -m "feat(persistence): save and restore last-selected agents"
```

---

### Task 11: Integration Test - Full Installation Flow

**Files:**
- Create: `ui/src/components/NewWorkspaceModal.integration.test.tsx` (if not exists)
- OR Modify: `ui/src/App.newWorkspace.test.tsx`

**Interfaces:**
- Consumes: All components from previous tasks
- Produces: Test verifying install button → dispatch → overlay → completion flow

- [ ] **Step 1: Write integration test**

Create or add to test file:

```typescript
import { describe, it, expect, vi } from "vitest";
import { render, screen, fireEvent, waitFor } from "@testing-library/react";
import App from "./App";

// Mock Tauri commands
vi.mock("./lib/tauri", () => ({
  agentCheckInstalled: vi.fn(async () => ["claude", "shell"]),
  agentInstall: vi.fn(async (agent) => {
    // Simulate async install
    await new Promise((r) => setTimeout(r, 100));
  }),
  onAgentInstallProgress: vi.fn((agent, cb) => {
    // Simulate completion after delay
    setTimeout(() => cb("completed"), 150);
    return () => {};
  }),
  // ... other mocked functions ...
}));

describe("Agent installation flow (integration)", () => {
  it("shows Install button for uninstalled agents", async () => {
    render(<App />);
    
    // Open New Workspace modal
    fireEvent.click(screen.getByRole("button", { name: /new workspace/i }));
    
    // Find uninstalled agent (copilot)
    await waitFor(() => {
      const installBtn = screen.queryByText("Install");
      expect(installBtn).toBeInTheDocument();
    });
  });

  it("disables agent checkbox until installed", async () => {
    render(<App />);
    fireEvent.click(screen.getByRole("button", { name: /new workspace/i }));
    
    await waitFor(() => {
      const checkboxes = screen.getAllByRole("checkbox");
      // Copilot checkbox should be disabled
      const copilotCheckbox = checkboxes.find((cb) =>
        cb.closest("li")?.textContent.includes("Copilot")
      );
      expect(copilotCheckbox).toBeDisabled();
    });
  });

  it("shows PaneInstallOverlay while agent is installing", async () => {
    render(<App />);
    
    // ... workflow to create workspace with installing agent ...
    // After workspace creation with copilot (installing):
    
    await waitFor(() => {
      expect(screen.getByText("Installing…")).toBeInTheDocument();
    });
  });

  it("removes overlay after installation completes", async () => {
    render(<App />);
    
    // ... workflow ...
    
    await waitFor(() => {
      expect(screen.queryByText("Installing…")).not.toBeInTheDocument();
    });
  });
});
```

- [ ] **Step 2: Run integration tests**

```bash
cd ui && npm test -- integration
```

Expected: All tests PASS

- [ ] **Step 3: Commit**

```bash
git add ui/src/App.newWorkspace.test.tsx ui/src/components/NewWorkspaceModal.integration.test.tsx
git commit -m "test(integration): add agent installation flow tests"
```

---

### Task 12: Manual Testing Checklist

**Scope:** End-to-end verification in the running app

- [ ] **Scenario 1: Fresh install, shell is default**

1. Delete settings to simulate fresh install
2. Launch app
3. Open New Workspace modal
4. Verify: shell checkbox is pre-checked, others are unchecked
5. Verify: all agents except shell show "Install" button
6. Expected: shell is the only selectable agent

- [ ] **Scenario 2: Install an agent**

1. Click "Install" on copilot
2. Verify: button changes to "Installing…" spinner
3. Wait for install to complete
4. Verify: spinner disappears, copilot checkbox is now enabled
5. Close modal and reopen
6. Verify: copilot is still installed (persisted)

- [ ] **Scenario 3: Create workspace with installing agent**

1. Click "Install" on antigravity
2. While installing, click "Create Workspace" with antigravity + claude selected
3. Workspace opens
4. Verify: antigravity pane shows dimmed overlay with centered logo + "Installing…"
5. Wait for install to complete
6. Verify: overlay disappears, antigravity terminal becomes interactive

- [ ] **Scenario 4: Installation failure and retry**

1. Trigger install failure (network disconnect or mock failure)
2. Verify: install status shows "Failed" with "Retry" button
3. Click "Retry"
4. Verify: retries installation

- [ ] **Scenario 5: Last-selected persistence**

1. Create workspace with agents ["claude", "copilot"]
2. Close app completely
3. Reopen app
4. Open New Workspace modal
5. Verify: ["claude", "copilot"] are pre-checked (from last creation)

- [ ] **Scenario 6: Single installed agent fallback**

1. Uninstall all agents except codex (mock by deleting from PATH)
2. Close and reopen app
3. Open New Workspace modal
4. Verify: codex is pre-checked (single-installed fallback)

Expected: All scenarios pass without errors or visual glitches

---

## Verification

### Pre-Merge Checklist

- [ ] All tests pass: `npm test`
- [ ] TypeScript compiles: `npm run type-check`
- [ ] Manual testing scenarios pass (see Task 12)
- [ ] No console errors or warnings in dev tools
- [ ] Pane overlay is centered and dimmed (visual inspection)
- [ ] Install button state matches agent status
- [ ] Settings persist across app restart

### Post-Merge

- [ ] Run full app test suite in CI
- [ ] Deploy to staging and verify with real agent download/install
- [ ] Smoke test on macOS and Linux (PATH resolution varies)

---

## Rollback Plan

If critical issues arise:

1. Revert commits in reverse order: Task 12, 11, 10, ... Task 1
2. Reset ENGINES back to hardcoded `["claude", "codex", "shell"]`
3. Remove agents.ts and related state from App.tsx

Estimated time to rollback: ~5 minutes (one git reset, one commit revert)

