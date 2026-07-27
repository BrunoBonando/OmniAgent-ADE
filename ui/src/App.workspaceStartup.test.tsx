import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LAYOUT_SETTING_KEY, type ProjectInfo } from "./state/sessions";

const mocks = vi.hoisted(() => ({
  agentCheckInstalled: vi.fn(),
  getBriefing: vi.fn(),
  ingestionStatus: vi.fn(),
  listProjects: vi.fn(),
  rootsList: vi.fn(),
  ptyDaemonStatus: vi.fn(),
  sessionCreate: vi.fn(),
  sessionKill: vi.fn(),
  sessionStatus: vi.fn(),
  sessionWrite: vi.fn(),
  settingsGet: vi.fn(),
  settingsSet: vi.fn(),
}));

vi.mock("./lib/tauri", () => ({
  agentCheckInstalled: mocks.agentCheckInstalled,
  agentInstall: vi.fn(),
  getBriefing: mocks.getBriefing,
  ingestionStatus: mocks.ingestionStatus,
  listProjects: mocks.listProjects,
  onAgentInstallProgress: vi.fn().mockResolvedValue(() => {}),
  renameProject: vi.fn(),
  rootsList: mocks.rootsList,
  ptyDaemonStatus: mocks.ptyDaemonStatus,
  sessionCreate: mocks.sessionCreate,
  sessionKill: mocks.sessionKill,
  sessionStatus: mocks.sessionStatus,
  sessionWrite: mocks.sessionWrite,
  settingsGet: mocks.settingsGet,
  settingsSet: mocks.settingsSet,
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
}));

vi.mock("./components/Sidebar", () => ({
  default: (props: {
    dormantSessions?: { project: string; group: string; label: string; cwd: string; paneCount: number }[];
    onSelectDormantSession?: (session: {
      project: string;
      group: string;
      label: string;
      cwd: string;
      paneCount: number;
    }) => void;
  }) => (
    <nav>
      {props.dormantSessions?.map((session) => (
        <button key={session.group} onClick={() => props.onSelectDormantSession?.(session)}>
          {session.label}
        </button>
      ))}
    </nav>
  ),
}));
vi.mock("./components/Workspace", () => ({
  default: (props: {
    tabs: { id: string }[];
    restoreState?: { status: "loading" | "error"; onRetry: () => void } | null;
  }) => (
    <>
      <ul>{props.tabs.map((tab) => <li key={tab.id}>{tab.id}</li>)}</ul>
      {props.restoreState?.status === "loading" && <p>Loading session…</p>}
      {props.restoreState?.status === "error" && (
        <button onClick={props.restoreState.onRetry}>Retry</button>
      )}
    </>
  ),
}));
vi.mock("./components/AppChrome", () => ({ default: () => null }));
vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/CodeReviewPanel", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({ default: () => null }));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));

const { default: App } = await import("./App");

const alpha: ProjectInfo = { id: "alpha", label: "Alpha", path: "/work/alpha" };
const beta: ProjectInfo = { id: "beta", label: "Beta", path: "/work/beta" };

describe("App workspace-first startup", () => {
  beforeEach(() => {
    for (const mock of Object.values(mocks)) mock.mockReset();
    mocks.agentCheckInstalled.mockResolvedValue([]);
    mocks.getBriefing.mockResolvedValue(undefined);
    mocks.ingestionStatus.mockResolvedValue({ running: false, projects_total: 0, projects_done: 0, total_nodes: 0 });
    mocks.listProjects.mockResolvedValue([alpha, beta]);
    mocks.rootsList.mockResolvedValue(["/work"]);
    mocks.ptyDaemonStatus.mockResolvedValue({ available: true });
    mocks.sessionCreate.mockImplementation((project: string, engine: string, cwd: string, _briefing: unknown, id?: string) =>
      Promise.resolve({ id: id ?? `${project}-new`, project, engine, cwd, created: 1, restored: true }),
    );
    mocks.sessionKill.mockResolvedValue(undefined);
    mocks.sessionStatus.mockResolvedValue(null);
    mocks.sessionWrite.mockResolvedValue(undefined);
    mocks.settingsSet.mockResolvedValue(undefined);
    mocks.settingsGet.mockImplementation((key: string) => {
      if (key === "auth_gate_resolved") return Promise.resolve("true");
      if (key === LAYOUT_SETTING_KEY) {
        return Promise.resolve(JSON.stringify({
          tabs: [
            { id: "alpha-one", project: "alpha", engine: "claude", cwd: "/work/alpha", group: "group-one", groupLabel: "Alpha One" },
            { id: "alpha-two", project: "alpha", engine: "shell", cwd: "/work/alpha", group: "group-two", groupLabel: "Alpha Two" },
            { id: "beta-one", project: "beta", engine: "shell", cwd: "/work/beta", group: "beta-group" },
          ],
        }));
      }
      return Promise.resolve(null);
    });
  });

  it("starts no terminal until a workspace is selected, then restores only its first session", async () => {
    render(<App />);

    expect(screen.getByText("Loading...")).toBeInTheDocument();
    const alphaButton = await screen.findByRole("button", { name: /Alpha/ });
    expect(mocks.sessionCreate).not.toHaveBeenCalled();

    fireEvent.click(alphaButton);

    await waitFor(() => expect(mocks.sessionCreate).toHaveBeenCalledOnce());
    expect(mocks.sessionCreate).toHaveBeenCalledWith(
      "alpha",
      "claude",
      "/work/alpha",
      undefined,
      "alpha-one",
    );
    expect(mocks.sessionCreate).not.toHaveBeenCalledWith(
      "alpha",
      "shell",
      "/work/alpha",
      undefined,
      "alpha-two",
    );
    expect(await screen.findByText("alpha-one")).toBeInTheDocument();
  });

  it("loads a dormant session on demand and exposes retry after failure", async () => {
    let rejectRestore!: (error: Error) => void;
    const delayedFailure = new Promise<never>((_resolve, reject) => {
      rejectRestore = reject;
    });
    mocks.sessionCreate.mockImplementation(
      (project: string, engine: string, cwd: string, _briefing: unknown, id?: string) => {
        if (id === "alpha-two") return delayedFailure;
        if (project === "alpha" && engine === "shell") return Promise.reject(new Error("daemon unavailable"));
        return Promise.resolve({ id: id ?? `${project}-new`, project, engine, cwd, created: 1, restored: true });
      },
    );

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: /Alpha/ }));
    await screen.findByText("alpha-one");

    fireEvent.click(screen.getByRole("button", { name: "Alpha Two" }));
    expect(screen.getByText("Loading session…")).toBeInTheDocument();

    rejectRestore(new Error("restore failed"));
    expect(await screen.findByRole("button", { name: "Retry" })).toBeInTheDocument();
  });
});
