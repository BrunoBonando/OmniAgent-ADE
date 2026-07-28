import { act, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LAYOUT_SETTING_KEY, type ProjectInfo } from "./state/sessions";
import { NOTIFICATIONS_SETTING_KEY } from "./state/notifications";

const eventHandlers = vi.hoisted(() => new Map<string, (id: string, payload: string) => void>());

const tauriMocks = vi.hoisted(() => ({
  agentCheckInstalledMock: vi.fn(),
  getBriefingMock: vi.fn(),
  ingestionStatusMock: vi.fn(),
  listProjectsMock: vi.fn(),
  rootsListMock: vi.fn(),
  sessionCreateMock: vi.fn(),
  sessionStatusMock: vi.fn(),
  settingsGetMock: vi.fn(),
  settingsSetMock: vi.fn(),
  systemStatsMock: vi.fn(),
  enrichQueuePendingCountMock: vi.fn(),
  reviewStatusMock: vi.fn(),
}));

vi.mock("./lib/tauri", () => ({
  agentCheckInstalled: tauriMocks.agentCheckInstalledMock,
  getBriefing: tauriMocks.getBriefingMock,
  ingestionStatus: tauriMocks.ingestionStatusMock,
  listProjects: tauriMocks.listProjectsMock,
  rootsList: tauriMocks.rootsListMock,
  sessionCreate: tauriMocks.sessionCreateMock,
  sessionStatus: tauriMocks.sessionStatusMock,
  sessionWrite: vi.fn(),
  settingsGet: tauriMocks.settingsGetMock,
  settingsSet: tauriMocks.settingsSetMock,
  onSessionWrite: vi.fn().mockReturnValue(() => {}),
  systemStats: tauriMocks.systemStatsMock,
  enrichQueuePendingCount: tauriMocks.enrichQueuePendingCountMock,
  reviewStatus: tauriMocks.reviewStatusMock,
  sendNativeNotification: vi.fn().mockResolvedValue(undefined),
  renameProject: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("./lib/usePerSessionEvent", () => ({
  usePerSessionEvent: (ids: string[], prefix: string, onEvent: (id: string, payload: unknown) => void) => {
    const live = new Set(ids);
    for (const key of [...eventHandlers.keys()]) {
      if (key.startsWith(prefix) && !live.has(key.slice(prefix.length))) {
        eventHandlers.delete(key);
      }
    }
    for (const id of ids) {
      eventHandlers.set(`${prefix}${id}`, onEvent as (id: string, payload: string) => void);
    }
  },
}));

vi.mock("./components/DashboardOverview", () => ({
  default: function DashboardOverviewStub(props: {
    hidden: boolean;
    project: ProjectInfo | null;
    analytics: { projects: Record<string, { totals: { tokenCount: number } }> };
  }) {
    const total = props.project ? props.analytics.projects[props.project.id]?.totals.tokenCount ?? 0 : 0;
    return (
      <div data-testid="dashboard-overview" data-hidden={String(props.hidden)}>
        <span data-testid="token-total">{total}</span>
      </div>
    );
  },
}));

vi.mock("./components/Sidebar", () => ({
  default: () => null,
}));
vi.mock("./components/Workspace", () => ({ default: () => null }));
vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/PlanBoard", () => ({ default: () => null }));
vi.mock("./components/FilesDashboard", () => ({ default: () => null }));
vi.mock("./components/CodeReviewPanel", () => ({ default: () => null }));
vi.mock("./components/AppChrome", () => ({ default: () => null }));
vi.mock("./components/StartupScreen", () => ({
  default: function StartupScreenStub(props: {
    loading: boolean;
    projects: ProjectInfo[];
    onSelectWorkspace: (project: ProjectInfo) => void;
  }) {
    if (props.loading) return null;
    return (
      <button onClick={() => props.onSelectWorkspace(props.projects[0])}>
        start
      </button>
    );
  },
}));
vi.mock("./components/LoadingOverlay", () => ({ default: () => null }));
vi.mock("./components/NewSessionModal", () => ({ default: () => null }));
vi.mock("./components/NewWorkspaceModal", () => ({ default: () => null }));
vi.mock("./components/ClosePaneConfirm", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({ default: () => null }));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));
vi.mock("./components/SystemStatusBar", () => ({ default: () => null }));

const { default: App } = await import("./App");

const PROJECT: ProjectInfo = { id: "p1", label: "Project One", path: "/tmp/p1" };

beforeEach(() => {
  eventHandlers.clear();
  tauriMocks.agentCheckInstalledMock.mockReset().mockResolvedValue(["claude"]);
  tauriMocks.getBriefingMock.mockReset().mockResolvedValue("briefing");
  tauriMocks.ingestionStatusMock.mockReset().mockResolvedValue({ running: false, total_nodes: 1 });
  tauriMocks.listProjectsMock.mockReset().mockResolvedValue([PROJECT]);
  tauriMocks.rootsListMock.mockReset().mockResolvedValue(["/tmp"]);
  tauriMocks.sessionStatusMock.mockReset().mockResolvedValue(null);
  tauriMocks.systemStatsMock.mockReset().mockResolvedValue({
    cpuPercent: null,
    ramUsedBytes: null,
    ramTotalBytes: null,
    mcpWired: false,
  });
  tauriMocks.enrichQueuePendingCountMock.mockReset().mockResolvedValue(0);
  tauriMocks.reviewStatusMock.mockReset().mockResolvedValue(null);
  tauriMocks.settingsSetMock.mockReset().mockResolvedValue(undefined);
  tauriMocks.sessionCreateMock.mockReset().mockImplementation(
    (project: string, engine: string, cwd: string, _briefing: unknown, restoreId?: string) =>
      Promise.resolve({
        id: restoreId ?? "sess-1",
        project,
        engine,
        cwd,
        created: 0,
      }),
  );
  tauriMocks.settingsGetMock.mockReset().mockImplementation((key: string) => {
    if (key === "auth_gate_resolved") return Promise.resolve("true");
    if (key === "last_selected_project") return Promise.resolve("p1");
    if (key === LAYOUT_SETTING_KEY) {
      return Promise.resolve(
        JSON.stringify({
          tabs: [
            { id: "sess-1", project: "p1", engine: "claude", cwd: "/tmp/p1", group: "g1" },
          ],
        }),
      );
    }
    if (key === NOTIFICATIONS_SETTING_KEY) return Promise.resolve(null);
    if (key === "usage_analytics_v1") return Promise.resolve(null);
    if (key === "last_selected_agents") return Promise.resolve(JSON.stringify(["claude"]));
    return Promise.resolve(null);
  });
});

describe("usage analytics live updates", () => {
  it("publishes token totals immediately when new output arrives", async () => {
    render(<App />);

    await waitFor(() => expect(screen.getByTestId("token-total")).toHaveTextContent("0"));
    await waitFor(() => expect(eventHandlers.get("session-output:sess-1")).toBeDefined());
    const handler = eventHandlers.get("session-output:sess-1");

    await act(async () => {
      handler?.("sess-1", btoa("usage tokens: 105"));
    });

    expect(screen.getByTestId("token-total")).toHaveTextContent("105");
  });
});
