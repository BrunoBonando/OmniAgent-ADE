# Agent Installation & Workspace Creation Design

**Date:** 2026-07-26  
**Status:** Design approved

## Overview

This redesigns agent selection in workspace creation. Currently, users select from 3 hardcoded engines (Claude, Codex, Shell). This design shifts to **5 agents** (Claude, Codex, Shell, Copilot, Antigravity) with on-demand installation. Users install agents as needed via "Install" button in the workspace modal, then create workspaces with those agents. During initialization, installing agents show a dimmed terminal pane with a centered OmniAgent logo.

The key UX improvement: agents that aren't yet installed show an "Install" button. Users install on-demand, then create workspaces with those agents. During workspace initialization, agents being installed show a dimmed terminal pane with a centered OmniAgent logo and "Installing…" text. Once installation completes, the overlay disappears and the agent starts automatically.

## Goals

1. Support 5 agents (claude, codex, shell, copilot, antigravity) instead of hardcoded 3
2. Users install agents on-demand via "Install" button in workspace modal
3. Track which agents are installed and remember user's last selections
4. Show beautiful installation progress (dimmed pane with centered logo)
5. Keep installation non-blocking — users can create workspaces while agents install in background

## Architecture

### 1. Agent Registry State (`ui/src/state/agents.ts`)

A pure reducer managing three pieces of state:

```typescript
export const AVAILABLE_AGENTS = ["claude", "codex", "shell", "copilot", "antigravity"] as const;
export type Agent = (typeof AVAILABLE_AGENTS)[number];

export interface AgentsState {
  installed: Set<Agent>;
  lastSelected: Agent[];
  installing: Map<Agent, 'in_progress' | 'failed'>;
}

export type AgentsAction =
  | { type: "agents/loaded"; installed: Agent[] }
  | { type: "agents/selected"; agents: Agent[] }
  | { type: "agents/install_started"; agent: Agent }
  | { type: "agents/install_completed"; agent: Agent }
  | { type: "agents/install_failed"; agent: Agent };
```

**State meanings:**
- `installed` — agents available now (from settings or Tauri backend check)
- `lastSelected` — agents user picked in their most recent workspace (persisted in settings)
- `installing` — agents currently downloading/installing, keyed by status

**Reducer behavior:**
- `agents/loaded` — called on app startup; populates `installed` from settings/backend
- `agents/selected` — called after successful workspace creation; saves to settings for next time
- `agents/install_started` — adds agent to `installing` with status='in_progress'
- `agents/install_completed` — moves agent from `installing` to `installed`; removes from map
- `agents/install_failed` — keeps in `installing` with status='failed' (user can retry)

### 2. Pre-fill Logic

Pure function determining initial checkbox state when modal opens:

```typescript
export function getDefaultAgentSelection(state: AgentsState): Agent[] {
  const { installed, lastSelected } = state;
  
  // If all last-selected agents are still installed, use them
  if (lastSelected.length > 0 && lastSelected.every(a => installed.has(a))) {
    return lastSelected;
  }
  
  // If only one agent is installed, use it
  if (installed.size === 1) {
    return Array.from(installed);
  }
  
  // Otherwise default to shell (always available, simplest)
  return ["shell"];
}
```

Called once when `NewWorkspaceModal` mounts, before user interacts with it.

### 3. NewWorkspaceModal Changes

**UI changes:**
- Agent rows split into two columns: checkbox + label, and action
- Installed agent row: checkbox (enabled), no action
- Not installed: checkbox (disabled), "Install" button
- Installing: checkbox (disabled), spinner + "Installing…"
- Install failed: checkbox (disabled), "Retry" button

**Interaction:**
- Clicking "Install" dispatches `agents/install_started` (stays in modal)
- Clicking "Create Workspace" validates selected agents and calls `onCreate()`
- On successful workspace creation, dispatch `agents/selected` with the selected agents
- Disabled agents (not installed, installing, or failed) cannot be checked

**Note:** The modal does not wait for installations to complete. User creates workspace immediately; panes for installing agents show overlay while installation runs.

### 4. Pane Installation Overlay

**New component: `PaneInstallOverlay.tsx`**

Renders on top of a pane's terminal when the agent is in `installing` state:

```tsx
interface PaneInstallOverlayProps {
  agent: Agent;
  status: 'in_progress' | 'failed';
}

export default function PaneInstallOverlay({ agent, status }: PaneInstallOverlayProps) {
  return (
    <div className="pane-install-overlay">
      {/* Dimmed terminal behind */}
      <div className="pane-install-backdrop" />
      
      {/* Centered content */}
      <div className="pane-install-content">
        <OmniAgentLogo /> {/* ~200px SVG, centered */}
        <p className="pane-install-text">
          {status === 'in_progress' ? 'Installing…' : 'Installation failed'}
        </p>
      </div>
    </div>
  );
}
```

**Styling:**
- Backdrop: semi-transparent dark overlay over terminal (e.g., `rgba(0, 0, 0, 0.4)`)
- Logo: large (200px), centered both horizontally and vertically
- Text: below logo, small gray text
- Positioning: absolute, full pane size, z-index above terminal

**Lifecycle:**
- Mounts when `agentState.installing.has(tab.engine)` and tab is visible
- Auto-unmounts when `agents/install_completed` fires for that agent
- Agent process automatically starts after overlay unmounts

### 5. Data Flow

```
App startup
  ↓
[Tauri] Check installed agents → agents/loaded
  ↓
User clicks "New Workspace"
  ↓
NewWorkspaceModal opens
  getDefaultAgentSelection(agentState) → pre-fill checkboxes
  ↓
User selects agents + clicks "Install" on uninstalled ones
  ↓
agents/install_started → [Tauri backend starts download]
  ↓
User clicks "Create Workspace"
  ↓
addProject() succeeds
  onCreate(project, selectedAgents, layout) → creates tabs
  agents/selected → save selectedAgents to settings
  ↓
Workspace opens with panes
  For each tab with engine in agentState.installing:
    → <PaneInstallOverlay> renders
    → [Terminal output visible behind overlay]
  ↓
[Backend] Installation completes
  agents/install_completed → remove from installing, add to installed
  ↓
Overlay unmounts → Agent starts → Terminal fully interactive
```

## Component Changes

### New Files
- `ui/src/state/agents.ts` — Agent registry reducer + pre-fill logic
- `ui/src/components/PaneInstallOverlay.tsx` — Installation overlay component
- `ui/src/state/agents.test.ts` — Reducer tests + pre-fill logic tests

### Modified Files
- `ui/src/App.tsx`
  - Initialize agents state on startup (call Tauri backend to list installed)
  - Wire workspace creation to `agents/selected` dispatch
  - Thread `agentState` to `Workspace` component
  
- `ui/src/components/NewWorkspaceModal.tsx`
  - Read `agentState` to render install status
  - Disabled checkboxes for non-installed agents
  - "Install" button dispatches `agents/install_started`
  
- `ui/src/components/Workspace.tsx`
  - Receive `agentState` prop
  - Pass to `Pane` component (or render overlay here)
  
- `ui/src/components/Pane.tsx` (or `PaneHeader.tsx`)
  - Render `<PaneInstallOverlay>` conditionally based on `agentState.installing`

- `ui/src/state/sessions.ts`
  - **Replace hardcoded `ENGINES = ["claude", "codex", "shell"]` with `AVAILABLE_AGENTS` import from `agents.ts`**
  - This makes agents.ts the single source of truth for the full agent list (5 agents, not 3)
  - The Engine type still exists and uses the same agents; just sourced from agents.ts now

- `ui/src/theme.ts`
  - Extend `ENGINE_COLOR` and `ENGINE_LABEL` to include copilot and antigravity
  - These map every agent to a display color and label

## State Persistence

- **Installed agents:** Checked on app startup via Tauri backend (filesystem or settings check)
- **Last selected:** Saved to settings table after successful workspace creation
  - Key: `"last_selected_agents"` → value: JSON array `["claude", "codex"]`
  - On next app open, loaded as part of `agents/loaded`

## Error Handling

**Installation failures:**
- If install fails, agent moves to `installing: { status: 'failed' }`
- Pane overlay shows "Installation failed"
- User can click "Retry" button (dispatches `agents/install_started` again)
- User can still create workspaces; that agent's pane stays dimmed until retry succeeds

**Invalid persisted state:**
- Corrupt `last_selected_agents` setting → fall back to `getDefaultAgentSelection`
- Unknown agent name in settings → filter out, use remaining valid ones

## Testing Strategy

**Unit tests (`agents.test.ts`):**
- Reducer: each action type → state change
- Pre-fill logic: all three branches (last selected valid, only one installed, default to shell)
- Edge cases: empty installed set, lastSelected with unknown agents, etc.

**Integration tests:**
- NewWorkspaceModal with various install states (all installed, mixed, none installed)
- Overlay renders/unmounts correctly on agent install lifecycle
- Settings persistence (selected agents saved, loaded on next open)

**Manual testing:**
- Create workspace with mix of installed and uninstalled agents
- Install an agent while modal is open
- Create workspace with partially-installed agents
- Verify overlay dimming and logo centering
- Verify agent starts after installation completes

## Out of Scope

- Agent uninstall (v2)
- Agent updates (v2)
- Per-workspace agent customization (agents are app-wide)
- Agent download progress percentage (just shows "Installing…")

