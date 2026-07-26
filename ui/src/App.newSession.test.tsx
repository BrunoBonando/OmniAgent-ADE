// ⌘N end to end (founder brief, 2026-07-26): the chooser, then either the
// existing workspace flow or the new session flow — driven entirely from
// the keyboard, through the real `App.tsx` wiring and the real
// `NewChooserModal`/`NewSessionModal`.
//
// Same stubbing approach as the other `App.*.test.tsx` files. `Sidebar` is
// stubbed to a probe that reports whether App asked it to open the New
// Workspace dialog (that modal still lives inside the sidebar, since its
// "+" opens it too).
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LAYOUT_SETTING_KEY, type ProjectInfo, type TabInfo } from "./state/sessions";
import { NOTIFICATIONS_SETTING_KEY } from "./state/notifications";

const tauriMocks = vi.hoisted(() => ({
  getBriefingMock: vi.fn(),
  gitBranchMock: vi.fn(),
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
  gitBranch: tauriMocks.gitBranchMock,
  ingestionStatus: tauriMocks.ingestionStatusMock,
  listProjects: tauriMocks.listProjectsMock,
  rootsList: tauriMocks.rootsListMock,
  sessionCreate: tauriMocks.sessionCreateMock,
  sessionKill: tauriMocks.sessionKillMock,
  sessionStatus: tauriMocks.sessionStatusMock,
  settingsGet: tauriMocks.settingsGetMock,
  settingsSet: tauriMocks.settingsSetMock,
}));

const { openMock } = vi.hoisted(() => ({ openMock: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: openMock }));

vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    projects: ProjectInfo[];
    newWorkspaceOpen: boolean;
    onSelectProject: (p: ProjectInfo) => void;
    onNewSessionInProject?: (p: ProjectInfo) => void;
  }) {
    return (
      <div data-testid="sidebar-stub" data-new-workspace-open={String(props.newWorkspaceOpen)}>
        {props.projects.map((p) => (
          <button key={p.id} onClick={() => props.onSelectProject(p)}>{`select-${p.id}`}</button>
        ))}
        <button onClick={() => props.onNewSessionInProject?.(props.projects[1])}>sidebar-new-session-p2</button>
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: { tabs: TabInfo[] }) {
    return (
      <ul data-testid="workspace-stub">
        {props.tabs.map((t) => (
          <li key={t.id} data-testid="tab" data-group={t.group} data-cwd={t.cwd}>
            {`${t.id}:${t.engine}`}
          </li>
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

const P1: ProjectInfo = { id: "p1", label: "Project One", path: "/tmp/p1" };
const P2: ProjectInfo = { id: "p2", label: "Project Two", path: "/tmp/p2" };

beforeEach(() => {
  openMock.mockReset();
  tauriMocks.getBriefingMock.mockReset().mockResolvedValue("briefing");
  tauriMocks.gitBranchMock.mockReset().mockResolvedValue(null);
  tauriMocks.ingestionStatusMock.mockReset().mockResolvedValue({ running: false });
  tauriMocks.listProjectsMock.mockReset().mockResolvedValue([P1, P2]);
  tauriMocks.rootsListMock.mockReset().mockResolvedValue(["/tmp"]);
  tauriMocks.sessionKillMock.mockReset().mockResolvedValue(undefined);
  tauriMocks.sessionStatusMock.mockReset().mockResolvedValue(null);
  tauriMocks.settingsSetMock.mockReset().mockResolvedValue(undefined);
  let counter = 0;
  tauriMocks.sessionCreateMock
    .mockReset()
    .mockImplementation((project: string, engine: string, cwd: string) => {
      counter += 1;
      return Promise.resolve({ id: `sess-${counter}`, project, engine, cwd, created: 0 });
    });
  tauriMocks.settingsGetMock.mockReset().mockImplementation((key: string) => {
    if (key === LAYOUT_SETTING_KEY || key === NOTIFICATIONS_SETTING_KEY) return Promise.resolve(null);
    return Promise.resolve(null);
  });
});

async function boot() {
  render(<App />);
  await screen.findByText("select-p1");
  await waitFor(() => expect(tauriMocks.rootsListMock).toHaveBeenCalled());
}

function pressCmdN() {
  fireEvent.keyDown(window, { key: "n", metaKey: true });
}

describe("⌘N asks first", () => {
  it("opens the chooser, not the workspace dialog", async () => {
    await boot();
    pressCmdN();
    expect(await screen.findByRole("dialog", { name: "Create new" })).toBeInTheDocument();
    expect(screen.getByTestId("sidebar-stub").dataset.newWorkspaceOpen).toBe("false");
  });

  it("Escape closes it without creating anything", async () => {
    await boot();
    pressCmdN();
    const dialog = await screen.findByRole("dialog", { name: "Create new" });
    fireEvent.keyDown(dialog, { key: "Escape" });
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "Create new" })).not.toBeInTheDocument());
    expect(tauriMocks.sessionCreateMock).not.toHaveBeenCalled();
    expect(screen.getByTestId("sidebar-stub").dataset.newWorkspaceOpen).toBe("false");
  });

  it("choosing Workspace opens the existing New Workspace flow", async () => {
    await boot();
    pressCmdN();
    const dialog = await screen.findByRole("dialog", { name: "Create new" });
    fireEvent.keyDown(dialog, { key: "ArrowRight" });
    fireEvent.keyDown(dialog, { key: "Enter" });
    await waitFor(() => expect(screen.getByTestId("sidebar-stub").dataset.newWorkspaceOpen).toBe("true"));
  });
});

describe("⌘N -> Session: panes in the project you're already in", () => {
  it("Enter alone opens the session dialog for the selected project", async () => {
    await boot();
    pressCmdN();
    fireEvent.keyDown(await screen.findByRole("dialog", { name: "Create new" }), { key: "Enter" });
    const dialog = await screen.findByRole("dialog", { name: "New Session" });
    expect(dialog).toBeInTheDocument();
    expect(screen.getByText("FOLDER — PROJECT ONE")).toBeInTheDocument();
  });

  it("creates its panes in the project's own folder, grouped as one session", async () => {
    await boot();
    pressCmdN();
    fireEvent.keyDown(await screen.findByRole("dialog", { name: "Create new" }), { key: "Enter" });
    const dialog = await screen.findByRole("dialog", { name: "New Session" });
    fireEvent.click(screen.getByRole("checkbox", { name: /Shell/ }));
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(2));
    const tabs = screen.getAllByTestId("tab");
    expect(tabs.map((t) => t.textContent)).toEqual(["sess-1:claude", "sess-2:shell"]);
    // Same cwd (the project folder), same session group, both panes.
    expect(tabs.every((t) => t.dataset.cwd === "/tmp/p1")).toBe(true);
    expect(new Set(tabs.map((t) => t.dataset.group)).size).toBe(1);
    expect(tauriMocks.sessionCreateMock).toHaveBeenNthCalledWith(1, "p1", "claude", "/tmp/p1", "briefing");
    // Only claude gets a briefing — the zero-config wiring is engine-aware.
    expect(tauriMocks.sessionCreateMock).toHaveBeenNthCalledWith(2, "p1", "shell", "/tmp/p1", undefined);
  });

  it("creates them in a chosen subfolder instead, when one is picked", async () => {
    openMock.mockResolvedValue("/tmp/p1/ui/src");
    await boot();
    pressCmdN();
    fireEvent.keyDown(await screen.findByRole("dialog", { name: "Create new" }), { key: "Enter" });
    const dialog = await screen.findByRole("dialog", { name: "New Session" });
    fireEvent.click(screen.getByRole("button", { name: "Browse" }));
    await waitFor(() => expect(screen.getByText("ui/src")).toBeInTheDocument());
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(screen.getByTestId("tab").dataset.cwd).toBe("/tmp/p1/ui/src");
  });

  it("a second session is a second group in the same project", async () => {
    await boot();
    for (let i = 0; i < 2; i++) {
      pressCmdN();
      fireEvent.keyDown(await screen.findByRole("dialog", { name: "Create new" }), { key: "Enter" });
      fireEvent.keyDown(await screen.findByRole("dialog", { name: "New Session" }), { key: "Enter" });
      await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(i + 1));
    }
    const groups = screen.getAllByTestId("tab").map((t) => t.dataset.group);
    expect(new Set(groups).size).toBe(2);
  });

  it("follows the sidebar's selection: switch project, and the dialog scopes to it", async () => {
    await boot();
    fireEvent.click(screen.getByText("select-p2"));
    pressCmdN();
    fireEvent.keyDown(await screen.findByRole("dialog", { name: "Create new" }), { key: "Enter" });
    expect(await screen.findByText("FOLDER — PROJECT TWO")).toBeInTheDocument();
  });

  it("the sidebar's own '+ New session' opens the same dialog", async () => {
    await boot();
    fireEvent.click(screen.getByText("sidebar-new-session-p2"));
    expect(await screen.findByRole("dialog", { name: "New Session" })).toBeInTheDocument();
    expect(screen.getByText("FOLDER — PROJECT TWO")).toBeInTheDocument();
  });

  it("surfaces a failed engine without losing the ones that started", async () => {
    tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) => {
      if (engine === "shell") return Promise.reject(new Error("no shell"));
      return Promise.resolve({ id: `sess-${engine}`, project, engine, cwd, created: 0 });
    });
    await boot();
    pressCmdN();
    fireEvent.keyDown(await screen.findByRole("dialog", { name: "Create new" }), { key: "Enter" });
    const dialog = await screen.findByRole("dialog", { name: "New Session" });
    fireEvent.click(screen.getByRole("checkbox", { name: /Shell/ }));
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(await screen.findByText(/couldn't run Shell/i)).toBeInTheDocument();
  });
});
