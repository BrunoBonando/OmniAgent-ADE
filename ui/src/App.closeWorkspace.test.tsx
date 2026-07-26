// Closing a workspace (founder ask, 2026-07-26: "add the possibility to
// close a workspace, on hover") — the cascade, end to end through the real
// `App.tsx` wiring.
//
// What is being proved here is as much about what closing does NOT do: it
// kills the terminals of exactly one workspace, drops that row, remembers
// the choice, and touches nothing about the project in the brain (there is
// no `remove_project` call to make — see `state/closedWorkspaces.ts`).
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { CLOSED_WORKSPACES_SETTING_KEY } from "./state/closedWorkspaces";
import { LAYOUT_SETTING_KEY, type ProjectInfo, type TabInfo } from "./state/sessions";

const tauriMocks = vi.hoisted(() => ({
  getBriefingMock: vi.fn(),
  ingestionStatusMock: vi.fn(),
  listProjectsMock: vi.fn(),
  rootsListMock: vi.fn(),
  sessionCreateMock: vi.fn(),
  sessionKillMock: vi.fn(),
  sessionStatusMock: vi.fn(),
  settingsGetMock: vi.fn(),
  settingsSetMock: vi.fn(),
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
  settingsGet: tauriMocks.settingsGetMock,
  settingsSet: tauriMocks.settingsSetMock,
}));

vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    projects: ProjectInfo[];
    selectedProjectId: string | null;
    onNewTabInProject: (p: ProjectInfo) => void;
    onCloseWorkspace?: (p: ProjectInfo) => void;
  }) {
    return (
      <div>
        <span data-testid="selected">{props.selectedProjectId ?? "none"}</span>
        {props.projects.map((p) => (
          <div key={p.id} data-testid="workspace-row">
            {p.id}
            <button onClick={() => props.onNewTabInProject(p)}>{`new-tab-${p.id}`}</button>
            <button onClick={() => props.onCloseWorkspace?.(p)}>{`close-workspace-${p.id}`}</button>
          </div>
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
          <li key={t.id} data-testid="tab">{`${t.id}@${t.project}`}</li>
        ))}
      </ul>
    );
  },
}));

vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
// The map keeps seeing every project the brain knows, closed or not — that
// is the whole point of "closing a workspace is not unlearning a project" —
// and its "Open terminal here" is one of the ways a closed one comes back.
vi.mock("./map/BrainMap", () => ({
  default: function BrainMapStub(props: {
    projects: ProjectInfo[];
    onOpenTerminal: (p: ProjectInfo) => void;
  }) {
    return (
      <div>
        {props.projects.map((p) => (
          <button key={p.id} onClick={() => props.onOpenTerminal(p)}>{`map-open-${p.id}`}</button>
        ))}
      </div>
    );
  },
}));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));

const { default: App } = await import("./App");

const p1: ProjectInfo = { id: "p1", label: "Project One", path: "/tmp/p1" };
const p2: ProjectInfo = { id: "p2", label: "Project Two", path: "/tmp/p2" };

let sessionCounter = 0;

function resetMocks() {
  for (const mock of Object.values(tauriMocks)) mock.mockReset();
  sessionCounter = 0;
  tauriMocks.ingestionStatusMock.mockResolvedValue({
    running: false,
    projects_total: 0,
    projects_done: 0,
    total_nodes: 0,
  });
  tauriMocks.rootsListMock.mockResolvedValue(["/tmp/root"]);
  tauriMocks.listProjectsMock.mockResolvedValue([p1, p2]);
  tauriMocks.getBriefingMock.mockResolvedValue(undefined);
  tauriMocks.settingsSetMock.mockResolvedValue(undefined);
  tauriMocks.settingsGetMock.mockResolvedValue(null);
  tauriMocks.sessionStatusMock.mockResolvedValue(null);
  tauriMocks.sessionKillMock.mockResolvedValue(undefined);
  tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) => {
    sessionCounter += 1;
    return Promise.resolve({ id: `sess-${sessionCounter}`, project, engine, cwd, created: 0 });
  });
}

function workspaceIds(): string[] {
  return screen.queryAllByTestId("workspace-row").map((row) => row.textContent!.split("new-tab")[0]);
}

function liveTabs(): string[] {
  return screen.queryAllByTestId("tab").map((li) => li.textContent!);
}

async function openTerminal(project: string) {
  const before = screen.queryAllByTestId("tab").length;
  fireEvent.click(await screen.findByRole("button", { name: `new-tab-${project}` }));
  await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(before + 1));
}

function lastSetting(key: string): string | undefined {
  const calls = tauriMocks.settingsSetMock.mock.calls.filter(([k]) => k === key);
  return calls.length > 0 ? (calls[calls.length - 1][1] as string) : undefined;
}

describe("App — closing a workspace", () => {
  beforeEach(resetMocks);

  it("kills exactly that workspace's terminals, and leaves the other workspace running", async () => {
    render(<App />);
    await openTerminal("p1");
    await openTerminal("p1");
    await openTerminal("p2");

    fireEvent.click(screen.getByRole("button", { name: "close-workspace-p1" }));

    await waitFor(() => expect(liveTabs()).toEqual(["sess-3@p2"]));
    expect(tauriMocks.sessionKillMock.mock.calls.map(([id]) => id).sort()).toEqual(["sess-1", "sess-2"]);
  });

  it("takes the workspace out of the sidebar and remembers it", async () => {
    render(<App />);
    await openTerminal("p1");

    fireEvent.click(screen.getByRole("button", { name: "close-workspace-p1" }));

    await waitFor(() => expect(workspaceIds()).toEqual(["p2"]));
    await waitFor(() => expect(lastSetting(CLOSED_WORKSPACES_SETTING_KEY)).toBe(JSON.stringify(["p1"])));
  });

  it("moves the selection off the workspace it just closed", async () => {
    render(<App />);
    await openTerminal("p1");
    expect(screen.getByTestId("selected").textContent).toBe("p1");

    fireEvent.click(screen.getByRole("button", { name: "close-workspace-p1" }));
    await waitFor(() => expect(screen.getByTestId("selected").textContent).toBe("p2"));
  });

  it("leaves the persisted layout with only the surviving workspace's terminals", async () => {
    render(<App />);
    await openTerminal("p1");
    await openTerminal("p2");

    fireEvent.click(screen.getByRole("button", { name: "close-workspace-p1" }));
    await waitFor(() => {
      const layout = JSON.parse(lastSetting(LAYOUT_SETTING_KEY)!);
      expect(layout.tabs.map((t: { project: string }) => t.project)).toEqual(["p2"]);
    });
  });

  it("never touches the project in the brain — no rename, no re-ingest, nothing removed", async () => {
    render(<App />);
    await openTerminal("p1");
    const brainCallsBefore = tauriMocks.listProjectsMock.mock.calls.length;

    fireEvent.click(screen.getByRole("button", { name: "close-workspace-p1" }));
    await waitFor(() => expect(workspaceIds()).toEqual(["p2"]));

    // `list_projects` still returns p1 (the brain is untouched); the row is
    // gone purely because the frontend hides closed workspaces.
    expect(tauriMocks.listProjectsMock.mock.calls.length).toBe(brainCallsBefore);
    expect(await tauriMocks.listProjectsMock.mock.results[0].value).toEqual([p1, p2]);
  });

  it("closes a workspace with nothing running without killing anything", async () => {
    render(<App />);
    await screen.findByRole("button", { name: "close-workspace-p1" });

    fireEvent.click(screen.getByRole("button", { name: "close-workspace-p1" }));
    await waitFor(() => expect(workspaceIds()).toEqual(["p2"]));
    expect(tauriMocks.sessionKillMock).not.toHaveBeenCalled();
  });
});

describe("App — a closed workspace stays closed, and comes back when reopened", () => {
  beforeEach(resetMocks);

  it("is still hidden after a relaunch", async () => {
    tauriMocks.settingsGetMock.mockImplementation((key: string) =>
      Promise.resolve(key === CLOSED_WORKSPACES_SETTING_KEY ? JSON.stringify(["p1"]) : null),
    );

    render(<App />);
    await waitFor(() => expect(workspaceIds()).toEqual(["p2"]));
  });

  it("comes back the moment a terminal is opened in it (from the map, the palette, anywhere)", async () => {
    render(<App />);
    await openTerminal("p1");
    fireEvent.click(screen.getByRole("button", { name: "close-workspace-p1" }));
    await waitFor(() => expect(workspaceIds()).toEqual(["p2"]));

    // `BrainMap`'s "Open terminal here" and `CommandPalette` both land in
    // `requestNewTab`, which is where reopening lives — and the map still
    // lists p1, because the brain never stopped knowing about it.
    fireEvent.click(screen.getByRole("button", { name: "map-open-p1" }));
    await waitFor(() => expect(workspaceIds()).toEqual(["p1", "p2"]));
    await waitFor(() => expect(lastSetting(CLOSED_WORKSPACES_SETTING_KEY)).toBe(JSON.stringify([])));
  });

  it("restores a layout whose panes belong to a closed workspace without resurrecting the row", async () => {
    // Belt and braces: the layout should not contain them (closing removed
    // them), but a hand-edited settings table must not be able to put a
    // closed workspace back on screen.
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === CLOSED_WORKSPACES_SETTING_KEY) return Promise.resolve(JSON.stringify(["p1"]));
      if (key === LAYOUT_SETTING_KEY) {
        return Promise.resolve(
          JSON.stringify({ tabs: [{ id: "sess-old", project: "p1", engine: "claude", cwd: "/tmp/p1" }] }),
        );
      }
      return Promise.resolve(null);
    });

    render(<App />);
    await waitFor(() => expect(workspaceIds()).toEqual(["p2"]));
  });
});
