import { describe, expect, it } from "vitest";
import {
  AVAILABLE_AGENTS,
  agentsReducer,
  getDefaultAgentSelection,
  initialAgentsState,
  type Agent,
} from "./agents";

describe("agentsReducer — agents/loaded", () => {
  it("sets the installed set from the loaded list", () => {
    const installed: Agent[] = ["claude", "shell"];
    const next = agentsReducer(initialAgentsState, {
      type: "agents/loaded",
      installed,
    });
    expect(next.installed).toEqual(new Set(installed));
  });

  it("handles an empty installed list", () => {
    const next = agentsReducer(initialAgentsState, {
      type: "agents/loaded",
      installed: [],
    });
    expect(next.installed.size).toBe(0);
  });

  it("replaces the previous installed set entirely", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/loaded",
      installed: ["claude", "shell"],
    });
    state = agentsReducer(state, {
      type: "agents/loaded",
      installed: ["codex"],
    });
    expect(state.installed).toEqual(new Set(["codex"]));
  });

  it("preserves other state properties", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/selected",
      agents: ["claude"],
    });
    state = agentsReducer(state, {
      type: "agents/loaded",
      installed: ["shell"],
    });
    expect(state.lastSelected).toEqual(["claude"]);
  });
});

describe("agentsReducer — agents/selected", () => {
  it("saves the lastSelected array", () => {
    const agents: Agent[] = ["claude", "shell"];
    const next = agentsReducer(initialAgentsState, {
      type: "agents/selected",
      agents,
    });
    expect(next.lastSelected).toEqual(agents);
  });

  it("handles an empty selection", () => {
    const next = agentsReducer(initialAgentsState, {
      type: "agents/selected",
      agents: [],
    });
    expect(next.lastSelected).toEqual([]);
  });

  it("replaces the previous selection", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/selected",
      agents: ["claude"],
    });
    state = agentsReducer(state, {
      type: "agents/selected",
      agents: ["shell", "codex"],
    });
    expect(state.lastSelected).toEqual(["shell", "codex"]);
  });

  it("preserves other state properties", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/loaded",
      installed: ["claude"],
    });
    state = agentsReducer(state, {
      type: "agents/selected",
      agents: ["shell"],
    });
    expect(state.installed).toEqual(new Set(["claude"]));
  });
});

describe("agentsReducer — agents/install_started", () => {
  it("adds an agent to the installing map with in_progress status", () => {
    const next = agentsReducer(initialAgentsState, {
      type: "agents/install_started",
      agent: "claude",
    });
    expect(next.installing.get("claude")).toBe("in_progress");
  });

  it("preserves existing entries in the installing map", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/install_started",
      agent: "claude",
    });
    state = agentsReducer(state, {
      type: "agents/install_started",
      agent: "shell",
    });
    expect(state.installing.get("claude")).toBe("in_progress");
    expect(state.installing.get("shell")).toBe("in_progress");
  });

  it("can restart an installation for a failed agent", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/install_started",
      agent: "claude",
    });
    state = agentsReducer(state, {
      type: "agents/install_failed",
      agent: "claude",
    });
    expect(state.installing.get("claude")).toBe("failed");
    state = agentsReducer(state, {
      type: "agents/install_started",
      agent: "claude",
    });
    expect(state.installing.get("claude")).toBe("in_progress");
  });

  it("preserves other state properties", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/loaded",
      installed: ["codex"],
    });
    state = agentsReducer(state, {
      type: "agents/install_started",
      agent: "claude",
    });
    expect(state.installed).toEqual(new Set(["codex"]));
  });
});

describe("agentsReducer — agents/install_completed", () => {
  it("adds the agent to installed and removes from installing", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/install_started",
      agent: "claude",
    });
    state = agentsReducer(state, {
      type: "agents/install_completed",
      agent: "claude",
    });
    expect(state.installed).toEqual(new Set(["claude"]));
    expect(state.installing.has("claude")).toBe(false);
  });

  it("handles completion of a non-installed agent", () => {
    const next = agentsReducer(initialAgentsState, {
      type: "agents/install_completed",
      agent: "shell",
    });
    expect(next.installed).toEqual(new Set(["shell"]));
  });

  it("preserves other agents in installing", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/install_started",
      agent: "claude",
    });
    state = agentsReducer(state, {
      type: "agents/install_started",
      agent: "shell",
    });
    state = agentsReducer(state, {
      type: "agents/install_completed",
      agent: "claude",
    });
    expect(state.installed).toEqual(new Set(["claude"]));
    expect(state.installing.get("shell")).toBe("in_progress");
    expect(state.installing.has("claude")).toBe(false);
  });

  it("preserves other state properties", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/selected",
      agents: ["claude"],
    });
    state = agentsReducer(state, {
      type: "agents/install_completed",
      agent: "claude",
    });
    expect(state.lastSelected).toEqual(["claude"]);
  });
});

describe("agentsReducer — agents/install_failed", () => {
  it("sets an agent in installing map to failed status", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/install_started",
      agent: "claude",
    });
    state = agentsReducer(state, {
      type: "agents/install_failed",
      agent: "claude",
    });
    expect(state.installing.get("claude")).toBe("failed");
  });

  it("preserves other agents in installing", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/install_started",
      agent: "claude",
    });
    state = agentsReducer(state, {
      type: "agents/install_started",
      agent: "shell",
    });
    state = agentsReducer(state, {
      type: "agents/install_failed",
      agent: "claude",
    });
    expect(state.installing.get("claude")).toBe("failed");
    expect(state.installing.get("shell")).toBe("in_progress");
  });

  it("can mark an agent as failed that was not in installing (edge case)", () => {
    const next = agentsReducer(initialAgentsState, {
      type: "agents/install_failed",
      agent: "codex",
    });
    expect(next.installing.get("codex")).toBe("failed");
  });

  it("preserves other state properties", () => {
    let state = agentsReducer(initialAgentsState, {
      type: "agents/loaded",
      installed: ["shell"],
    });
    state = agentsReducer(state, {
      type: "agents/install_failed",
      agent: "claude",
    });
    expect(state.installed).toEqual(new Set(["shell"]));
  });
});

describe("getDefaultAgentSelection — pre-fill logic", () => {
  it("returns lastSelected if all agents are still installed", () => {
    const state = {
      installed: new Set<Agent>(["claude", "shell", "codex"]),
      lastSelected: ["claude", "shell"] as Agent[],
      installing: new Map(),
    };
    const selection = getDefaultAgentSelection(state);
    expect(selection).toEqual(["claude", "shell"]);
  });

  it("returns single installed agent if only one is available", () => {
    const state = {
      installed: new Set<Agent>(["shell"]),
      lastSelected: [] as Agent[],
      installing: new Map(),
    };
    const selection = getDefaultAgentSelection(state);
    expect(selection).toEqual(["shell"]);
  });

  it("defaults to shell when nothing else applies", () => {
    const state = {
      installed: new Set<Agent>(["claude", "codex"]),
      lastSelected: [] as Agent[],
      installing: new Map(),
    };
    const selection = getDefaultAgentSelection(state);
    expect(selection).toEqual(["shell"]);
  });

  it("ignores lastSelected if any agent is no longer installed, falls back to single installed", () => {
    const state = {
      installed: new Set<Agent>(["claude"]),
      lastSelected: ["claude", "shell"] as Agent[],
      installing: new Map(),
    };
    const selection = getDefaultAgentSelection(state);
    expect(selection).toEqual(["claude"]); // lastSelected is invalid, so use the only installed agent
  });

  it("ignores lastSelected if any agent is no longer installed, then defaults to shell if multiple installed", () => {
    const state = {
      installed: new Set<Agent>(["claude", "codex"]),
      lastSelected: ["claude", "shell"] as Agent[],
      installing: new Map(),
    };
    const selection = getDefaultAgentSelection(state);
    expect(selection).toEqual(["shell"]); // lastSelected invalid, multiple installed, so default to shell
  });

  it("ignores empty lastSelected and falls through to defaults", () => {
    const state = {
      installed: new Set<Agent>(["claude", "codex"]),
      lastSelected: [] as Agent[],
      installing: new Map(),
    };
    const selection = getDefaultAgentSelection(state);
    expect(selection).toEqual(["shell"]);
  });

  it("returns the single installed agent over the default when one is available", () => {
    const state = {
      installed: new Set<Agent>(["codex"]),
      lastSelected: [] as Agent[],
      installing: new Map(),
    };
    const selection = getDefaultAgentSelection(state);
    expect(selection).toEqual(["codex"]);
  });

  it("prioritizes lastSelected over single installed when all lastSelected are present", () => {
    const state = {
      installed: new Set<Agent>(["codex", "shell"]),
      lastSelected: ["shell"] as Agent[],
      installing: new Map(),
    };
    const selection = getDefaultAgentSelection(state);
    expect(selection).toEqual(["shell"]); // lastSelected takes precedence
  });

  it("handles no agents installed at all (returns shell as default)", () => {
    const state = {
      installed: new Set<Agent>(),
      lastSelected: [] as Agent[],
      installing: new Map(),
    };
    const selection = getDefaultAgentSelection(state);
    expect(selection).toEqual(["shell"]); // shell as fallback even if not installed
  });

  it("preserves the order of lastSelected agents when returning them", () => {
    const state = {
      installed: new Set<Agent>(["shell", "claude", "codex"]),
      lastSelected: ["codex", "shell", "claude"] as Agent[],
      installing: new Map(),
    };
    const selection = getDefaultAgentSelection(state);
    expect(selection).toEqual(["codex", "shell", "claude"]);
  });
});

describe("AVAILABLE_AGENTS constant", () => {
  it("contains exactly five agents", () => {
    expect(AVAILABLE_AGENTS.length).toBe(5);
  });

  it("contains the expected agent names", () => {
    expect(AVAILABLE_AGENTS).toContain("claude");
    expect(AVAILABLE_AGENTS).toContain("codex");
    expect(AVAILABLE_AGENTS).toContain("shell");
    expect(AVAILABLE_AGENTS).toContain("copilot");
    expect(AVAILABLE_AGENTS).toContain("antigravity");
  });

  it("contains no duplicates", () => {
    const unique = new Set(AVAILABLE_AGENTS);
    expect(unique.size).toBe(AVAILABLE_AGENTS.length);
  });
});
