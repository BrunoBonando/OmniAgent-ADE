// Integration tests for App's agent-installation lifecycle, plus what
// adding a workspace does now.
//
// **Reworked for Task 12.** Two things moved:
//
// 1. Adding a workspace no longer spawns a session per checked engine (the
//    dialog stopped asking for engines), so the old "creates workspace with
//    installed agents only" / "persists last-selected agents" / "partial
//    engine failure" cases are gone from here. That spawn loop now lives in
//    `handleSessionCreated`, covered by `App.newSession.test.tsx`; the
//    handoff itself is covered by `App.newWorkspace.test.tsx`.
// 2. `Sidebar` no longer carries `agentState`/`onInstallAgent` — those props
//    existed only to feed the old dialog's AI AGENTS grid. The surviving
//    in-app install affordance is `NewTerminalModal`, so these tests drive
//    installs through it: open a terminal in the project (which creates a
//    session to join), then open the New Terminal modal from the sidebar
//    row and hit its install button.
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
  sessionWriteMock: vi.fn(),
    settingsGetMock: vi.fn(),
    settingsSetMock: vi.fn(),

    // Agent-related mocks
    agentCheckInstalledMock: vi.fn(),
    agentInstallMock: vi.fn(),
    onAgentInstallProgressMock: vi.fn(),
    onSessionWriteMock: vi.fn(),
    systemStatsMock: vi.fn(),
    enrichQueuePendingCountMock: vi.fn(),
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
  sessionWrite: tauriMocks.sessionWriteMock,
  settingsGet: tauriMocks.settingsGetMock,
  settingsSet: tauriMocks.settingsSetMock,
  agentCheckInstalled: tauriMocks.agentCheckInstalledMock,
  agentInstall: tauriMocks.agentInstallMock,
  onAgentInstallProgress: tauriMocks.onAgentInstallProgressMock,
  onSessionWrite: tauriMocks.onSessionWriteMock,
  systemStats: tauriMocks.systemStatsMock,
  enrichQueuePendingCount: tauriMocks.enrichQueuePendingCountMock,
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
}));

const NEW_PROJECT: ProjectInfo = { id: "fresh", label: "fresh", path: "/tmp/fresh" };

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    onWorkspaceCreated: (project: ProjectInfo) => void;
    onSetView?: (view: "workspace" | "map") => void;
    onNewTabInProject: (project: ProjectInfo) => void;
    onOpenNewTerminal: () => void;
  }) {
    return (
      <div>
        <button onClick={() => props.onSetView?.("map")}>go-to-map</button>
        <button onClick={() => props.onWorkspaceCreated(NEW_PROJECT)}>create-workspace</button>
        <button onClick={() => props.onNewTabInProject(NEW_PROJECT)}>new-tab</button>
        <button onClick={() => props.onOpenNewTerminal()}>open-new-terminal</button>
      </div>
    );
  },
}));

// The surviving in-app install affordance. Stubbed to a probe: the install
// button plus App's own agent state, surfaced so tests can assert on what
// the user would actually see change rather than on which mocks were called.
vi.mock("./components/NewTerminalModal", () => ({
  // A named export, not a default — matches App.tsx's own import.
  NewTerminalModal: function NewTerminalModalStub(props: {
    agentState: AgentsState;
    onInstallAgent: (agent: Agent) => void;
  }) {
    return (
      <div>
        <button onClick={() => props.onInstallAgent("copilot")}>install-agent</button>
        <div data-testid="installed-agents">
          {[...props.agentState.installed].sort().join(",")}
        </div>
        <div data-testid="installing-agents">
          {[...props.agentState.installing.keys()].sort().join(",")}
        </div>
        <div data-testid="last-selected-agents">{props.agentState.lastSelected.join(",")}</div>
      </div>
    );
  },
}));

// Workspace creation hands straight over to this dialog now (Task 12), and
// it is also where engines are chosen — so it owns the `last_selected_agents`
// write. `create-session` fires with a duplicate slot on purpose: `slots` is
// one engine PER PANE, and what gets remembered must be the deduplicated set.
vi.mock("./components/NewSessionModal", () => ({
  default: function NewSessionModalStub(props: {
    project: ProjectInfo;
    onCreate: (project: ProjectInfo, cwd: string, slots: Engine[], prompt: string) => void;
  }) {
    return (
      <div data-testid="new-session-modal">
        <button
          onClick={() =>
            props.onCreate(props.project, "/tmp/fresh", ["claude", "claude", "shell"], "")
          }
        >
          create-session
        </button>
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

vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({
  default: function BrainMapStub(props: { hidden: boolean }) {
    return <div data-testid="brainmap-stub" data-hidden={String(props.hidden)} />;
  },
}));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));
vi.mock("./components/StartupScreen", () => ({
  default: function StartupScreenStub(props: {
    onSelectWorkspace: (project: ProjectInfo) => void;
    onStartFromScratch: () => void;
  }) {
    return (
      <div>
        <button onClick={() => props.onSelectWorkspace(NEW_PROJECT)}>select-workspace</button>
        <button onClick={props.onStartFromScratch}>start-from-scratch</button>
      </div>
    );
  },
}));

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
    // The install tests open a terminal purely to give `NewTerminalModal` a
    // session to join; tests that care about spawning override this.
    tauriMocks.sessionCreateMock.mockImplementation((_project: string, engine: Engine) =>
      Promise.resolve(sessionInfoFor(engine)),
    );

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

  it("adding a workspace starts no engines — it opens the session dialog instead", async () => {
    // Task 12: the dialog stopped asking which engines to boot, so this
    // path no longer spawns anything or writes `last_selected_agents`.
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "select-workspace" }));
    fireEvent.click(await screen.findByRole("button", { name: "create-workspace" }));

    await waitFor(() => expect(screen.getByTestId("new-session-modal")).toBeInTheDocument());
    expect(tauriMocks.sessionCreateMock).not.toHaveBeenCalled();
    expect(
      tauriMocks.settingsSetMock.mock.calls.filter(([key]) => key === "last_selected_agents"),
    ).toHaveLength(0);
  });

  it("persists last-selected agent choices to settings when a session is created", async () => {
    // The founder rule ("the last one that they created should be
    // pre-selected", `getDefaultAgentSelection`) needs a writer, or
    // `lastSelected` stays `[]` forever and every dialog falls through to
    // `["shell"]`. That writer used to live in the workspace-creation
    // engine loop; since Task 12 removed it, the session dialog — which is
    // what actually chooses engines now — owns it.
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);
    let n = 0;
    tauriMocks.sessionCreateMock.mockImplementation((_project: string, engine: Engine) =>
      Promise.resolve({ ...sessionInfoFor(engine), id: `s${n++}` }),
    );

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "select-workspace" }));
    fireEvent.click(await screen.findByRole("button", { name: "create-workspace" }));
    fireEvent.click(await screen.findByRole("button", { name: "create-session" }));

    // Deduplicated, in slot order — not ["claude", "claude", "shell"].
    await waitFor(() =>
      expect(tauriMocks.settingsSetMock).toHaveBeenCalledWith(
        "last_selected_agents",
        JSON.stringify(["claude", "shell"]),
      ),
    );

    // ...and it reached the reducer too, so the pre-fill is right for the
    // rest of this run and not only after a relaunch.
    fireEvent.click(screen.getByRole("button", { name: "open-new-terminal" }));
    expect(await screen.findByTestId("last-selected-agents")).toHaveTextContent("claude,shell");
  });

  it("restores those choices on the next boot", async () => {
    // The other half of the round trip: what the session dialog wrote is
    // what App reads back at startup.
    await settingsStore.set("last_selected_agents", JSON.stringify(["claude", "shell"]));
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "select-workspace" }));
    fireEvent.click(await screen.findByRole("button", { name: "new-tab" }));
    await waitFor(() => expect(tauriMocks.sessionCreateMock).toHaveBeenCalled());
    fireEvent.click(screen.getByRole("button", { name: "open-new-terminal" }));

    expect(await screen.findByTestId("last-selected-agents")).toHaveTextContent("claude,shell");
  });

  it("opens a shell pane and runs the install command when Install is clicked", async () => {
    // Set up: copilot is not installed
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "select-workspace" }));

    // Wait for initial agent check
    await waitFor(() => {
      expect(tauriMocks.agentCheckInstalledMock).toHaveBeenCalled();
    });

    // NewTerminalModal is where an install can be triggered from now, and it
    // only renders for a session that a new pane could join — so open a
    // terminal in the project first, then the modal.
    fireEvent.click(await screen.findByRole("button", { name: "new-tab" }));
    await waitFor(() => expect(tauriMocks.sessionCreateMock).toHaveBeenCalled());
    fireEvent.click(screen.getByRole("button", { name: "open-new-terminal" }));

    // Trigger install flow
    fireEvent.click(await screen.findByRole("button", { name: "install-agent" }));

    // Installs now run inside a shell pane in-session.
    await waitFor(() => {
      expect(tauriMocks.sessionCreateMock).toHaveBeenCalledWith(
        "fresh",
        "shell",
        expect.any(String),
        undefined,
      );
    });

    await waitFor(() => {
      expect(tauriMocks.sessionWriteMock).toHaveBeenCalledWith(
        "shell-session",
        expect.stringContaining("npm install -g @github/copilot"),
      );
    });
  });

  it("does not call backend agents_install or progress listeners anymore", async () => {
    tauriMocks.agentCheckInstalledMock.mockResolvedValue(["claude", "shell"]);

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "select-workspace" }));
    await waitFor(() => expect(tauriMocks.agentCheckInstalledMock).toHaveBeenCalled());

    // NewTerminalModal is where an install can be triggered from now, and it
    // only renders for a session that a new pane could join — so open a
    // terminal in the project first, then the modal.
    fireEvent.click(await screen.findByRole("button", { name: "new-tab" }));
    await waitFor(() => expect(tauriMocks.sessionCreateMock).toHaveBeenCalled());
    fireEvent.click(screen.getByRole("button", { name: "open-new-terminal" }));

    fireEvent.click(await screen.findByRole("button", { name: "install-agent" }));

    expect(tauriMocks.agentInstallMock).not.toHaveBeenCalled();
    expect(tauriMocks.onAgentInstallProgressMock).not.toHaveBeenCalled();
  });
});
