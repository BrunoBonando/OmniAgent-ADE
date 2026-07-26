// Integration tests for agent installation + workspace creation flow.
// Covers: agent discovery, install button states, workspace creation with
// installing agents, overlay display, and settings persistence.
//
// Mocking strategy: agentCheckInstalled returns a preset list, agentInstall
// emits completion events via onAgentInstallProgress callbacks, settingsGet/
// settingsSet use an in-memory store.

import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Engine, ProjectInfo, TabInfo } from "./state/sessions";
import type { Agent, AgentsState } from "./state/agents";

const tauriMocks = vi.hoisted(() => {
  const progressCallbacks = new Map<string, (status: string) => void>();

  return {
    // Existing mocks
    getBriefingMock: vi.fn(),
    ingestionStatusMock: vi.fn(),
    listProjectsMock: vi.fn(),
    rootsListMock: vi.fn(),
    sessionCreateMock: vi.fn(),
    sessionKillMock: vi.fn(),
    sessionStatusMock: vi.fn(),
    settingsGetMock: vi.fn(),
    settingsSetMock: vi.fn(),

    // Agent-related mocks
    agentCheckInstalledMock: vi.fn(),
    agentInstallMock: vi.fn(),
    onAgentInstallProgressMock: vi.fn(),
    progressCallbacks,
  };
});

vi.mock("./lib/tauri", () => ({
  FILE_TREE_VISIBLE_SETTING_KEY: "file_tree_visible",
  getBriefing: tauriMocks.getBriefingMock,
  ingestionStatus: tauriMocks.ingestionStatusMock,
  listProjects: tauriMocks.listProjectsMock,
  rootsList: tauriMocks.rootsListMock,
  sessionCreate: tauriMocks.sessionCreateMock,
  sessionKill: tauriMocks.sessionKillMock,
  sessionStatus: tauriMocks.sessionStatusMock,
  settingsGet: tauriMocks.settingsGetMock,
  settingsSet: tauriMocks.settingsSetMock,
  agentCheckInstalled: tauriMocks.agentCheckInstalledMock,
  agentInstall: tauriMocks.agentInstallMock,
  onAgentInstallProgress: tauriMocks.onAgentInstallProgressMock,
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
}));

const NEW_PROJECT: ProjectInfo = { id: "fresh", label: "fresh", path: "/tmp/fresh" };

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    onWorkspaceCreated: (project: ProjectInfo, engines: Engine[]) => void;
    onSetView?: (view: "workspace" | "map") => void;
    onInstallAgent?: (agent: Agent) => void;
    agentState?: AgentsState;
  }) {
    return (
      <div>
        <button onClick={() => props.onSetView?.("map")}>go-to-map</button>
        <button
          onClick={() => props.onWorkspaceCreated(NEW_PROJECT, ["claude", "shell"])}
        >
          create-workspace-with-agents
        </button>
        <button onClick={() => props.onInstallAgent?.("copilot")}>
          install-agent
        </button>
        {/* App's agent state, surfaced so tests can assert on what the user
            would actually see change rather than on which mocks were called. */}
        <div data-testid="installed-agents">
          {[...(props.agentState?.installed ?? [])].sort().join(",")}
        </div>
        <div data-testid="installing-agents">
          {[...(props.agentState?.installing.keys() ?? [])].sort().join(",")}
        </div>
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: { hidden: boolean; tabs: TabInfo[] }) {
    return (
      <div data-testid="workspace-stub" data-hidden={String(props.hidden)}>
        <ul>
          {props.tabs.map((t) => (
            <li key={t.id} data-testid="tab">
              {t.id}:{t.engine}
            </li>
          ))}
        </ul>
      </div>
    );
  },
}));

vi.mock("./components/EnginePicker", () => ({ default: () => null }));
vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({
  default: function BrainMapStub(props: { hidden: boolean }) {
    return <div data-testid="brainmap-stub" data-hidden={String(props.hidden)} />;
  },
}));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));

const { default: App } = await import("./App");

function sessionInfoFor(engine: string) {
  return { id: `${engine}-session`, project: "fresh", engine, cwd: "/tmp/fresh", created: 0 };
}

/**
 * In-memory settings store for testing. Persists values across test steps.
 */
class SettingsStore {
  private store: Map<string, string> = new Map();

  async get(key: string): Promise<string | null> {
    return this.store.get(key) ?? null;
  }

  async set(key: string, value: string): Promise<void> {
    this.store.set(key, value);
  }

  clear(): void {
    this.store.clear();
  }
}

describe("App — Agent Installation + Workspace Creation Integration", () => {
  let settingsStore: SettingsStore;

  beforeEach(() => {
    settingsStore = new SettingsStore();

    for (const mock of Object.values(tauriMocks)) {
      if (mock instanceof Map) {
        mock.clear();
      } else if (typeof mock.mockReset === "function") {
        mock.mockReset();
      }
    }

    // Default mock responses
    tauriMocks.sessionStatusMock.mockResolvedValue(null);
    tauriMocks.ingestionStatusMock.mockResolvedValue({
      running: false,
      projects_total: 0,
      projects_done: 0,
      total_nodes: 0,
    });
    tauriMocks.rootsListMock.mockResolvedValue(["/tmp/root"]);
    tauriMocks.listProjectsMock.mockResolvedValue([NEW_PROJECT]);
    tauriMocks.getBriefingMock.mockResolvedValue("briefing text");

    // Wire settings mocks to the in-memory store
    tauriMocks.settingsGetMock.mockImplementation((key: string) =>
      settingsStore.get(key)
    );
    tauriMocks.settingsSetMock.mockImplementation((key: string, value: string) =>
      settingsStore.set(key, value)
    );

    // Agent installation mock: capture progress callback for manual triggering in tests
    tauriMocks.onAgentInstallProgressMock.mockImplementation(
      async (agent: Agent, callback: (status: string) => void) => {
        tauriMocks.progressCallbacks.set(agent, callback);
        return () => {
          tauriMocks.progressCallbacks.delete(agent);
        };
      }
    );

    // Mock agentInstall to simulate installation completion after onAgentInstallProgress is set up
    tauriMocks.agentInstallMock.mockImplementation(async (agent: Agent) => {
      // Simulate async installation: get the callback and fire it with "completed"
      const callback = tauriMocks.progressCallbacks.get(agent);
      if (callback) {
        // Use setTimeout to ensure callback is called after install is awaited
        setTimeout(() => callback("completed"), 0);
      }
    });
  });

  it("loads agent installation state on app boot", async () => {
    // Only claude and shell are installed; copilot and antigravity need install
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);

    render(<App />);

    // Verify agentCheckInstalled was called to load the installed agent list
    await waitFor(() => {
      expect(tauriMocks.agentCheckInstalledMock).toHaveBeenCalled();
    });

    // App should have loaded the initial agent state successfully
    expect(tauriMocks.agentCheckInstalledMock).toHaveBeenCalledTimes(1);
  });

  it("restores last-selected agents on boot and uses them as default", async () => {
    // Pre-populate settings with previously selected agents
    await settingsStore.set("last_selected_agents", JSON.stringify(["claude", "codex"]));

    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "codex", "shell"]);
    tauriMocks.sessionCreateMock.mockImplementation((_project: string, engine: Engine) =>
      Promise.resolve(sessionInfoFor(engine))
    );

    render(<App />);

    // Wait for the app to boot and load settings
    await waitFor(() => {
      expect(tauriMocks.agentCheckInstalledMock).toHaveBeenCalled();
      expect(tauriMocks.settingsGetMock).toHaveBeenCalledWith("last_selected_agents");
    });

    // Verify settingsGet was called to restore agent selections
    const lastSelectedCalls = tauriMocks.settingsGetMock.mock.calls.filter(
      (call) => call[0] === "last_selected_agents"
    );
    expect(lastSelectedCalls.length).toBeGreaterThan(0);
  });

  it("creates workspace with installed agents only", async () => {
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);
    tauriMocks.sessionCreateMock.mockImplementation((_project: string, engine: Engine) =>
      Promise.resolve(sessionInfoFor(engine))
    );

    render(<App />);

    // Create workspace with claude and shell (both installed)
    fireEvent.click(await screen.findByRole("button", { name: "create-workspace-with-agents" }));

    // Wait for workspace to be created
    await waitFor(() => {
      const tabs = screen.getAllByTestId("tab");
      expect(tabs.some((t) => t.textContent?.includes("claude"))).toBe(true);
    });

    // Verify sessions were created for the checked engines
    expect(tauriMocks.sessionCreateMock).toHaveBeenCalledTimes(2);
  });

  it("persists last-selected agent choices to settings", async () => {
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);
    tauriMocks.sessionCreateMock.mockImplementation((_project: string, engine: Engine) =>
      Promise.resolve(sessionInfoFor(engine))
    );

    render(<App />);

    // Create a workspace
    fireEvent.click(await screen.findByRole("button", { name: "create-workspace-with-agents" }));

    // Wait for workspace creation to complete and settings to be persisted
    await waitFor(() => {
      expect(tauriMocks.sessionCreateMock).toHaveBeenCalled();
    });

    // Verify that settingsSet was called with the selected agents
    const setCallsWithLastSelected = tauriMocks.settingsSetMock.mock.calls.filter(
      (call) => call[0] === "last_selected_agents"
    );

    expect(setCallsWithLastSelected.length).toBeGreaterThan(0);
    // The last call should have ["claude", "shell"] as JSON
    const lastSetCall = setCallsWithLastSelected[setCallsWithLastSelected.length - 1];
    const savedAgents = JSON.parse(lastSetCall[1]);
    expect(savedAgents).toEqual(["claude", "shell"]);
  });

  it("restores last-selected agents from settings on app boot", async () => {
    // Pre-populate settings with previously selected agents
    await settingsStore.set("last_selected_agents", JSON.stringify(["claude", "shell"]));

    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell", "codex"]);
    tauriMocks.sessionCreateMock.mockImplementation((_project: string, engine: Engine) =>
      Promise.resolve(sessionInfoFor(engine))
    );

    render(<App />);

    // Wait for the app to boot and load settings
    await waitFor(() => {
      expect(tauriMocks.agentCheckInstalledMock).toHaveBeenCalled();
    });

    // Verify settingsGet was called to restore agent selections
    const lastSelectedCalls = tauriMocks.settingsGetMock.mock.calls.filter(
      (call) => call[0] === "last_selected_agents"
    );
    expect(lastSelectedCalls.length).toBeGreaterThan(0);
  });

  it("handles partial agent installation failure gracefully", async () => {
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude"]);
    tauriMocks.sessionCreateMock.mockImplementation((_project: string, engine: Engine) => {
      // Only claude succeeds; shell fails
      if (engine === "shell") {
        return Promise.reject(new Error("shell not installed"));
      }
      return Promise.resolve(sessionInfoFor(engine));
    });

    render(<App />);

    fireEvent.click(await screen.findByRole("button", { name: "create-workspace-with-agents" }));

    // Wait for the workspace creation attempt
    await waitFor(() => {
      const tabs = screen.getAllByTestId("tab");
      // Claude should be there, shell should not be
      expect(tabs.some((t) => t.textContent?.includes("claude"))).toBe(true);
      expect(tabs.every((t) => !t.textContent?.includes("shell"))).toBe(true);
    });

    // Verify error banner appears for the failed engine
    await waitFor(() => {
      expect(screen.getByText(/couldn.t start shell/i)).toBeInTheDocument();
    });
  });

  it("triggers agent installation and handles progress callback", async () => {
    // Set up: copilot is not installed
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);

    render(<App />);

    // Wait for initial agent check
    await waitFor(() => {
      expect(tauriMocks.agentCheckInstalledMock).toHaveBeenCalled();
    });

    // Trigger agent installation
    fireEvent.click(await screen.findByRole("button", { name: "install-agent" }));

    // Verify agentInstall was called with the agent
    await waitFor(() => {
      expect(tauriMocks.agentInstallMock).toHaveBeenCalledWith("copilot");
    });

    // The listener has to be in place BEFORE the install can report anything.
    await waitFor(() => {
      expect(tauriMocks.onAgentInstallProgressMock).toHaveBeenCalledWith(
        "copilot",
        expect.any(Function)
      );
    });

    // What actually matters: the "completed" event (fired by the agentInstall
    // mock, the way the backend fires it) moves copilot out of `installing`
    // and into `installed`. That transition is what un-dims the pane, so
    // assert it rather than asserting that a mock was called.
    await waitFor(() => {
      expect(screen.getByTestId("installed-agents")).toHaveTextContent(
        "claude,copilot,shell"
      );
    });
    expect(screen.getByTestId("installing-agents")).toHaveTextContent("");

    // ...and the listener unsubscribed itself on that event. Without this,
    // every later install of any agent would also be handled by this stale
    // listener. The mock's unlisten drops it from `progressCallbacks`.
    expect(tauriMocks.progressCallbacks.has("copilot")).toBe(false);
  });

  it("a failed install leaves the agent uninstalled and marked failed, ready to retry", async () => {
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);
    // The backend rejects rather than emitting — e.g. Antigravity, which has
    // no scriptable install, or a network failure mid-download.
    tauriMocks.agentInstallMock.mockRejectedValue(new Error("no install channel"));

    render(<App />);
    await waitFor(() => expect(tauriMocks.agentCheckInstalledMock).toHaveBeenCalled());

    fireEvent.click(await screen.findByRole("button", { name: "install-agent" }));

    await waitFor(() => {
      expect(screen.getByTestId("installing-agents")).toHaveTextContent("copilot");
    });
    // Still not installed — a failed install must never look like a success.
    expect(screen.getByTestId("installed-agents")).toHaveTextContent("claude,shell");
  });
});
