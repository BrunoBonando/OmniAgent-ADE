// Coverage for Task 9's ⌘T rewiring — App.tsx's global keydown handler no
// longer calls `requestNewTab` directly on "t"; it opens `NewTerminalModal`
// (name + engine), and only THAT modal's confirm calls `requestNewTab` (now
// with `opts.engine`/`opts.label`). Mirrors `App.requestNewTab.test.tsx`'s
// mock scaffolding (same hoisted tauri mocks, same component stubs) rather
// than reinventing it — this file only adds what Task 9 actually changed:
// the modal appearing on ⌘T instead of an immediate spawn, and the
// full-session refusal still firing BEFORE the modal ever shows.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo, TabInfo } from "./state/sessions";
import { MAX_PANES } from "./state/paneGrid";

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

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
}));

// Extended past App.requestNewTab.test.tsx's own Sidebar stub with an
// "open-new-terminal" button, so the same wiring test can exercise
// `onOpenNewTerminal` (the sidebar's "New terminal" row, Task 5) alongside
// ⌘T — both are supposed to land on the exact same `setNewTerminalOpen`.
vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    projects: ProjectInfo[];
    onNewTabInProject: (p: ProjectInfo) => void;
    onOpenNewTerminal: () => void;
  }) {
    return (
      <div>
        {props.projects.map((p) => (
          <button key={p.id} onClick={() => props.onNewTabInProject(p)}>
            {`new-tab-${p.id}`}
          </button>
        ))}
        <button onClick={() => props.onOpenNewTerminal()}>open-new-terminal-row</button>
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: { tabs: TabInfo[] }) {
    return (
      <ul>
        {props.tabs.map((t) => (
          <li key={t.id} data-testid="tab-info">
            {`${t.project}:${t.engine}:${t.label ?? ""}`}
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

describe("App — ⌘T opens the New Terminal modal (Task 9)", () => {
  const a: ProjectInfo = { id: "A", label: "Project A", path: "/tmp/a" };

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
    tauriMocks.settingsSetMock.mockResolvedValue(undefined);
    tauriMocks.getBriefingMock.mockResolvedValue(undefined);
    tauriMocks.settingsGetMock.mockResolvedValue(null);
    tauriMocks.listProjectsMock.mockResolvedValue([a]);
    let created = 0;
    tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) =>
      Promise.resolve({ id: `${project}-sess-${++created}`, project, engine, cwd, created: 0 }),
    );
  });

  /** Seeds one open session (one tab) via the existing "new-tab-A" stub
   * button — the "existing scaffolding" the brief points at — then clears
   * the sessionCreate call count so each test's own assertions only count
   * calls made AFTER the seed. */
  async function seedOneTab() {
    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "new-tab-A" }));
    await waitFor(() => expect(screen.getAllByTestId("tab-info")).toHaveLength(1));
    tauriMocks.sessionCreateMock.mockClear();
  }

  it("⌘T opens the modal instead of spawning directly", async () => {
    await seedOneTab();

    fireEvent.keyDown(window, { key: "t", metaKey: true });

    expect(await screen.findByText("New terminal")).toBeInTheDocument();
    // The whole point of Task 9: no session was created just from pressing
    // the key.
    expect(tauriMocks.sessionCreateMock).not.toHaveBeenCalled();
  });

  it("confirm spawns with the chosen engine and typed name, joining the on-screen session", async () => {
    await seedOneTab();

    fireEvent.keyDown(window, { key: "t", metaKey: true });
    await screen.findByText("New terminal");
    // No agent is reported "installed" in this fixture (agentCheckInstalled
    // isn't mocked, so the boot effect's try/catch swallows it and
    // `agentState.installed` stays empty) — the modal's own default engine
    // is then "shell" (`initialNewTerminalState`'s own fallback).
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "token rotation" } });
    fireEvent.click(screen.getByText("Open terminal ⏎"));

    await waitFor(() => expect(tauriMocks.sessionCreateMock).toHaveBeenCalledTimes(1));
    expect(tauriMocks.sessionCreateMock).toHaveBeenCalledWith("A", "shell", "/tmp/a", undefined);
    expect(await screen.findByText("A:shell:token rotation")).toBeInTheDocument();
    // The modal itself is gone once it hands off to `requestNewTab`.
    expect(screen.queryByText("New terminal")).not.toBeInTheDocument();
  });

  it("Escape cancels the modal without creating a session", async () => {
    await seedOneTab();

    fireEvent.keyDown(window, { key: "t", metaKey: true });
    const panel = await screen.findByRole("dialog", { name: "New terminal" });
    fireEvent.keyDown(panel, { key: "Escape" });

    await waitFor(() => expect(screen.queryByText("New terminal")).not.toBeInTheDocument());
    expect(tauriMocks.sessionCreateMock).not.toHaveBeenCalled();
  });

  it(`refuses ⌘T outright once the on-screen session already has ${MAX_PANES} terminals — never opens the modal`, async () => {
    render(<App />);
    const newTab = await screen.findByRole("button", { name: "new-tab-A" });
    for (let i = 1; i <= MAX_PANES; i++) {
      fireEvent.click(newTab);
      await waitFor(() => expect(screen.getAllByTestId("tab-info")).toHaveLength(i));
    }
    tauriMocks.sessionCreateMock.mockClear();

    fireEvent.keyDown(window, { key: "t", metaKey: true });

    expect(await screen.findByText(new RegExp(`already has ${MAX_PANES} terminals`))).toBeInTheDocument();
    expect(screen.queryByText("New terminal")).not.toBeInTheDocument();
    expect(tauriMocks.sessionCreateMock).not.toHaveBeenCalled();
  });

  it("the sidebar's New terminal row opens the exact same modal ⌘T does", async () => {
    await seedOneTab();

    fireEvent.click(screen.getByRole("button", { name: "open-new-terminal-row" }));

    expect(await screen.findByText("New terminal")).toBeInTheDocument();
    expect(screen.getByText("in Session 1 · 1 of 8 used")).toBeInTheDocument();
  });
});
