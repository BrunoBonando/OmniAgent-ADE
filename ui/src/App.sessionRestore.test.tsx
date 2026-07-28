// End-to-end proof that tmux-backed session restore is actually wired
// (2026-07-26). The backend built it (`session_create({ …, restoreId })`
// reattaches to a surviving tmux session), but it stays completely inert
// unless the frontend persists the session id and hands it back on the next
// launch — which `PersistedTab`/`serializeLayout` deliberately never did.
//
// So this drives the real cycle rather than a hand-authored fixture: open
// real tabs through the real `App.tsx` wiring, capture EXACTLY what the real
// persist effect sent to the settings table, feed that exact payload into a
// fresh mount (the closest thing to a relaunch this environment can drive —
// the persisted state lives in a settings table, not the DOM), and assert on
// the real `session_create` argument list that came out the other side.
//
// Same stubbing approach as the other `App.*.test.tsx` files.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LAYOUT_SETTING_KEY, type ProjectInfo, type TabInfo } from "./state/sessions";

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
  reviewStatus: vi.fn().mockResolvedValue(null),
  gitBranch: vi.fn().mockResolvedValue(null),
  sendNativeNotification: vi.fn().mockResolvedValue(undefined),
  renameProject: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
}));

vi.mock("./components/StartupScreen", () => ({
  default: function StartupScreenStub(props: {
    loading: boolean;
    projects: ProjectInfo[];
    onSelectWorkspace: (p: ProjectInfo) => void;
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

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: { projects: ProjectInfo[]; onNewTabInProject: (p: ProjectInfo) => void }) {
    return (
      <div>
        {props.projects.map((p) => (
          <button key={p.id} onClick={() => props.onNewTabInProject(p)}>
            {`new-tab-${p.id}`}
          </button>
        ))}
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: { tabs: TabInfo[] }) {
    return (
      <ul>
        {props.tabs.map((t) => (
          <li key={t.id} data-testid="tab">{`${t.id}:${t.restored ? "restored" : "fresh"}`}</li>
        ))}
      </ul>
    );
  },
}));

vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({ default: () => null }));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));

const { default: App } = await import("./App");

const p1: ProjectInfo = { id: "p1", label: "Project One", path: "/tmp/p1" };

function resetMocks() {
  for (const mock of Object.values(tauriMocks)) mock.mockReset();
  tauriMocks.ingestionStatusMock.mockResolvedValue({
    running: false,
    projects_total: 0,
    projects_done: 0,
    total_nodes: 0,
  });
  tauriMocks.rootsListMock.mockResolvedValue(["/tmp/root"]);
  tauriMocks.listProjectsMock.mockResolvedValue([p1]);
  tauriMocks.getBriefingMock.mockResolvedValue(undefined);
  tauriMocks.settingsSetMock.mockResolvedValue(undefined);
  tauriMocks.sessionStatusMock.mockResolvedValue(null);
  // Auth gate must be pre-resolved so the startup screen exits loading state.
  tauriMocks.settingsGetMock.mockImplementation((key: string) => {
    if (key === "auth_gate_resolved") return Promise.resolve("true");
    return Promise.resolve(null);
  });
}

/** Runs "session 1": opens one tab, returns the exact layout payload the real
 * persist effect wrote. */
async function captureLayoutFromFirstRun(): Promise<string> {
  resetMocks();
  // No stored layout on first run — auth gate still resolved so loading exits.
  tauriMocks.settingsGetMock.mockImplementation((key: string) => {
    if (key === "auth_gate_resolved") return Promise.resolve("true");
    return Promise.resolve(null);
  });
  tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) =>
    Promise.resolve({
      id: "sess-1753500000-7",
      project,
      engine,
      cwd,
      created: 0,
      restored: false,
      persistent: true,
    }),
  );

  const first = render(<App />);
  // No persisted tabs → app shows startup chooser, not auto-restore. Click
  // the workspace card to advance to workspace-active where the Sidebar lives.
  fireEvent.click(await screen.findByRole("button", { name: "startup-select-p1" }));
  fireEvent.click(await screen.findByRole("button", { name: "new-tab-p1" }));
  await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));

  const layoutCalls = tauriMocks.settingsSetMock.mock.calls.filter(([key]) => key === LAYOUT_SETTING_KEY);
  expect(layoutCalls.length).toBeGreaterThan(0);
  const payload = layoutCalls[layoutCalls.length - 1][1] as string;
  first.unmount();
  return payload;
}

describe("App — session restore hands the persisted id back as restoreId", () => {
  beforeEach(resetMocks);

  it("persists the live session id, then sends it as restoreId on the next launch", async () => {
    const capturedPayload = await captureLayoutFromFirstRun();

    // The persisted payload itself must carry the id — this is the part that
    // did not exist before and without which everything below is impossible.
    expect(JSON.parse(capturedPayload).tabs[0].id).toBe("sess-1753500000-7");

    // -- "session 2": a fresh mount reading back EXACTLY that payload. -----
    resetMocks();
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === "auth_gate_resolved") return Promise.resolve("true");
      if (key === "last_selected_project") return Promise.resolve("p1");
      return Promise.resolve(key === LAYOUT_SETTING_KEY ? capturedPayload : null);
    });
    tauriMocks.sessionCreateMock.mockImplementation(
      (project: string, engine: string, cwd: string, _briefing: unknown, restoreId?: string) =>
        Promise.resolve({
          id: restoreId ?? "brand-new",
          project,
          engine,
          cwd,
          created: 0,
          // The backend found the tmux session still alive.
          restored: restoreId !== undefined,
          persistent: true,
        }),
    );

    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));

    // THE assertion: the real captured `session_create` payload contains the
    // id from last run, in the `restoreId` position.
    expect(tauriMocks.sessionCreateMock).toHaveBeenCalledWith(
      "p1",
      "claude",
      "/tmp/p1",
      undefined,
      "sess-1753500000-7",
    );
    // …and the pane came back as the same session, not a new one.
    expect(screen.getByTestId("tab").textContent).toBe("sess-1753500000-7:restored");
  });

  it("does not assume restored: true — a reattach that silently started fresh renders an ordinary pane", async () => {
    const capturedPayload = await captureLayoutFromFirstRun();

    resetMocks();
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === "auth_gate_resolved") return Promise.resolve("true");
      if (key === "last_selected_project") return Promise.resolve("p1");
      return Promise.resolve(key === LAYOUT_SETTING_KEY ? capturedPayload : null);
    });
    // tmux session gone (reboot, tmux uninstalled): same id, brand-new
    // engine, `restored: false`. Not an error — the normal fallback.
    tauriMocks.sessionCreateMock.mockImplementation(
      (project: string, engine: string, cwd: string, _briefing: unknown, restoreId?: string) =>
        Promise.resolve({ id: restoreId ?? "x", project, engine, cwd, created: 0, restored: false }),
    );

    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(screen.getByTestId("tab").textContent).toBe("sess-1753500000-7:fresh");
  });

  it("tolerates a backend with no restored/persistent fields at all", async () => {
    const capturedPayload = await captureLayoutFromFirstRun();

    resetMocks();
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === "auth_gate_resolved") return Promise.resolve("true");
      if (key === "last_selected_project") return Promise.resolve("p1");
      return Promise.resolve(key === LAYOUT_SETTING_KEY ? capturedPayload : null);
    });
    tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) =>
      Promise.resolve({ id: "sess-1753500000-7", project, engine, cwd, created: 0 }),
    );

    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(screen.getByTestId("tab").textContent).toBe("sess-1753500000-7:fresh");
  });

  it("falls back to a plain fresh spawn when the reattach is rejected, rather than losing the pane", async () => {
    const capturedPayload = await captureLayoutFromFirstRun();

    resetMocks();
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === "auth_gate_resolved") return Promise.resolve("true");
      if (key === "last_selected_project") return Promise.resolve("p1");
      return Promise.resolve(key === LAYOUT_SETTING_KEY ? capturedPayload : null);
    });
    tauriMocks.sessionCreateMock.mockImplementation(
      (project: string, engine: string, cwd: string, _briefing: unknown, restoreId?: string) =>
        restoreId !== undefined
          ? Promise.reject(new Error("session sess-1753500000-7 is already live in this app"))
          : Promise.resolve({ id: "fresh-session", project, engine, cwd, created: 0, restored: false }),
    );

    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(screen.getByTestId("tab").textContent).toBe("fresh-session:fresh");
    expect(tauriMocks.sessionCreateMock).toHaveBeenCalledTimes(2);
  });

  it("sends no restoreId at all for a layout written before ids were persisted", async () => {
    resetMocks();
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === "auth_gate_resolved") return Promise.resolve("true");
      if (key === "last_selected_project") return Promise.resolve("p1");
      if (key === LAYOUT_SETTING_KEY) return Promise.resolve(JSON.stringify({ tabs: [{ project: "p1", engine: "claude", cwd: "/tmp/p1" }] }));
      return Promise.resolve(null);
    });
    tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) =>
      Promise.resolve({ id: "legacy-restored", project, engine, cwd, created: 0 }),
    );

    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(tauriMocks.sessionCreateMock).toHaveBeenCalledWith("p1", "claude", "/tmp/p1", undefined, undefined);
  });

  it("keeps the restored session's id stable so the NEXT relaunch can restore it again", async () => {
    const capturedPayload = await captureLayoutFromFirstRun();

    resetMocks();
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === "auth_gate_resolved") return Promise.resolve("true");
      if (key === "last_selected_project") return Promise.resolve("p1");
      return Promise.resolve(key === LAYOUT_SETTING_KEY ? capturedPayload : null);
    });
    tauriMocks.sessionCreateMock.mockImplementation(
      (project: string, engine: string, cwd: string, _briefing: unknown, restoreId?: string) =>
        Promise.resolve({ id: restoreId ?? "x", project, engine, cwd, created: 0, restored: true }),
    );

    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));

    await waitFor(() => {
      const calls = tauriMocks.settingsSetMock.mock.calls.filter(([key]) => key === LAYOUT_SETTING_KEY);
      expect(calls.length).toBeGreaterThan(0);
      const next = JSON.parse(calls[calls.length - 1][1] as string);
      expect(next.tabs[0].id).toBe("sess-1753500000-7");
      // The live-process facts must never be written back into the layout.
      expect(next.tabs[0]).not.toHaveProperty("restored");
      expect(next.tabs[0]).not.toHaveProperty("status");
    });
  });
});
