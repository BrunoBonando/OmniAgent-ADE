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
