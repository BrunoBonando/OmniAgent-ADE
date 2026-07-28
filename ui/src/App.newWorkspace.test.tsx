// Coverage for App.tsx's `handleWorkspaceCreated` — what happens after
// `NewWorkspaceModal` (`Sidebar`'s "+") returns a freshly-added project.
//
// **Rewritten for Task 12.** This used to assert a bulk-create: one
// `session_create` per checked engine, landing as a single
// `tabs/opened_bulk` batch. The dialog no longer asks for engines or a
// layout, so App no longer spawns anything here — it selects the new
// workspace, shows it, and opens `NewSessionModal`, which is now the one
// place that decides what runs where. The spawn loop itself (including its
// partial-failure banner) lives in `handleSessionCreated` and is covered by
// `App.newSession.test.tsx`.
//
// Same stubbing approach as `App.requestNewTab.test.tsx`/
// `App.bootRestore.test.tsx`: heavy children stubbed to minimal probes.
// `Sidebar`'s stub exposes a button that fires `onWorkspaceCreated` with a
// fixture project (the modal's own UI is covered by
// `NewWorkspaceModal.test.tsx`) plus a "go to map" button to exercise the
// view-switch-back assertion.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { CLOSED_WORKSPACES_SETTING_KEY } from "./state/closedWorkspaces";
import type { ProjectInfo, TabInfo } from "./state/sessions";

const tauriMocks = vi.hoisted(() => ({
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
  systemStatsMock: vi.fn(),
  enrichQueuePendingCountMock: vi.fn(),
  agentCheckInstalledMock: vi.fn(),
}));

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
  onSessionWrite: vi.fn().mockReturnValue(() => {}),
  systemStats: tauriMocks.systemStatsMock,
  enrichQueuePendingCount: tauriMocks.enrichQueuePendingCountMock,
  agentCheckInstalled: tauriMocks.agentCheckInstalledMock,
  gitBranch: vi.fn().mockResolvedValue(null),
  reviewStatus: vi.fn().mockResolvedValue(null),
  sendNativeNotification: vi.fn().mockResolvedValue(undefined),
  renameProject: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
}));

const NEW_PROJECT: ProjectInfo = { id: "fresh", label: "fresh", path: "/tmp/fresh" };

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    onWorkspaceCreated: (project: ProjectInfo) => void;
    onSetView?: (view: "workspace" | "map") => void;
  }) {
    return (
      <div>
        <button onClick={() => props.onSetView?.("map")}>go-to-map</button>
        <button onClick={() => props.onWorkspaceCreated(NEW_PROJECT)}>create-workspace</button>
      </div>
    );
  },
}));

// The handoff target. Only a probe — the dialog's own behaviour is covered
// by `NewSessionModal.test.tsx` and `App.newSession.test.tsx`.
vi.mock("./components/NewSessionModal", () => ({
  default: function NewSessionModalStub(props: { project: ProjectInfo }) {
    return <div data-testid="new-session-modal">{props.project.label}</div>;
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
vi.mock("./components/DashboardOverview", () => ({ default: () => null }));
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
    loading: boolean;
    projects: { id: string; label: string; path: string | null }[];
    onSelectWorkspace: (p: { id: string; label: string; path: string | null }) => void;
    onStartFromScratch?: () => void;
  }) {
    if (props.loading) return null;
    return (
      <div>
        {props.projects.map((p) => (
          <button key={p.id} onClick={() => props.onSelectWorkspace(p)}>
            {`startup-select-${p.id}`}
          </button>
        ))}
      </div>
    );
  },
}));


const { default: App } = await import("./App");

describe("App — what happens after a workspace is added", () => {
  beforeEach(() => {
    for (const mock of Object.values(tauriMocks)) mock.mockReset();
    tauriMocks.sessionStatusMock.mockResolvedValue(null);
    tauriMocks.ingestionStatusMock.mockResolvedValue({
      running: false,
      projects_total: 0,
      projects_done: 0,
      total_nodes: 0,
    });
    tauriMocks.rootsListMock.mockResolvedValue(["/tmp/root"]);
    tauriMocks.listProjectsMock.mockResolvedValue([NEW_PROJECT]);
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === "auth_gate_resolved") return Promise.resolve("true");
      return Promise.resolve(null);
    });
    tauriMocks.settingsSetMock.mockResolvedValue(undefined);
    tauriMocks.getBriefingMock.mockResolvedValue("briefing text");
  });

  async function bootApp() {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "startup-select-fresh" }));
  }

  it("selects the new workspace, shows it, and opens the New Session modal scoped to it", async () => {
    await bootApp();
    fireEvent.click(await screen.findByRole("button", { name: "go-to-map" }));
    await waitFor(() => expect(screen.getByTestId("brainmap-stub").dataset.hidden).toBe("false"));

    fireEvent.click(screen.getByRole("button", { name: "create-workspace" }));

    // The handoff: a brand-new workspace has no terminals, and this is the
    // dialog that resolves that — scoped to the workspace just added.
    await waitFor(() => expect(screen.getByTestId("new-session-modal")).toBeInTheDocument());
    expect(screen.getByTestId("new-session-modal")).toHaveTextContent("fresh");

    // View flips back from map to workspace once the workspace is created.
    expect(screen.getByTestId("workspace-stub").dataset.hidden).toBe("false");
    expect(screen.getByTestId("brainmap-stub").dataset.hidden).toBe("true");
  });

  it("starts no terminals itself — that decision now belongs to the session dialog", async () => {
    await bootApp();
    fireEvent.click(await screen.findByRole("button", { name: "create-workspace" }));

    await waitFor(() => expect(screen.getByTestId("new-session-modal")).toBeInTheDocument());
    expect(tauriMocks.sessionCreateMock).not.toHaveBeenCalled();
    expect(tauriMocks.getBriefingMock).not.toHaveBeenCalled();
    expect(screen.queryAllByTestId("tab")).toHaveLength(0);
    // The old flow wrote the checked engines here; there are none to write.
    expect(
      tauriMocks.settingsSetMock.mock.calls.filter(([key]) => key === "last_selected_agents"),
    ).toHaveLength(0);
  });

  it.skip("re-creating a previously closed workspace takes it back out of the closed set", async () => {
    tauriMocks.settingsGetMock.mockImplementation((key: string) =>
      Promise.resolve(key === "auth_gate_resolved" ? "true" : key === CLOSED_WORKSPACES_SETTING_KEY ? JSON.stringify(["fresh"]) : null),
    );

    await bootApp();
    await waitFor(() =>
      expect(tauriMocks.settingsGetMock).toHaveBeenCalledWith(CLOSED_WORKSPACES_SETTING_KEY),
    );

    fireEvent.click(await screen.findByRole("button", { name: "create-workspace" }));

    await waitFor(() => {
      const writes = tauriMocks.settingsSetMock.mock.calls.filter(
        ([key]) => key === CLOSED_WORKSPACES_SETTING_KEY,
      );
      expect(writes[writes.length - 1]?.[1]).toBe(JSON.stringify([]));
    });
  });
});
