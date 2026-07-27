// Regression coverage for the boot-time layout-restore race (bug 1): the
// boot effect in `App.tsx` sequentially `await`s `sessionCreate` for every
// persisted tab, then fires a single `layout/restored` dispatch only once
// the whole loop finishes — nothing disables the Sidebar's new-tab
// affordances while that's in flight. If the user opens a tab mid-restore,
// the eventual `layout/restored` must not silently discard it (which would
// orphan the already-spawned backend PTY session behind it) or steal focus
// back to the first restored tab.
//
// Heavy children (`Workspace`, `CommandPalette`, `FileTree`, `BrainMap`,
// `FirstRun`) are stubbed to `null` — this test is about `App.tsx`'s own
// state sequencing, not their rendering. `Sidebar` is stubbed to a minimal
// probe that exposes exactly the props/callbacks this test needs to drive
// and observe: the tab list, the active tab id, and the per-project "new
// tab" trigger that starts the same instant-default-engine `requestNewTab`
// flow the real Sidebar kicks off — opening a tab is now a single click,
// no `EnginePicker` confirm step in between.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LAYOUT_SETTING_KEY, type ProjectInfo } from "./state/sessions";

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
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
}));

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    projects: ProjectInfo[];
    tabs: { id: string }[];
    activeTabId: string | null;
    onNewTabInProject: (p: ProjectInfo) => void;
  }) {
    return (
      <div>
        <div data-testid="active-tab-id">{props.activeTabId ?? ""}</div>
        <ul>
          {props.tabs.map((t) => (
            <li key={t.id} data-testid="tab">
              {t.id}
            </li>
          ))}
        </ul>
        {props.projects.map((p) => (
          <button key={p.id} onClick={() => props.onNewTabInProject(p)}>
            {`new-tab-${p.id}`}
          </button>
        ))}
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({ default: () => null }));
vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({ default: () => null }));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));

const { default: App } = await import("./App");

describe("App — boot-time layout restore vs. a tab opened mid-restore", () => {
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
    tauriMocks.sessionKillMock.mockResolvedValue(undefined);
  });

  it("keeps a tab opened during the boot restore race, and its focus, once the delayed layout/restored dispatch lands", async () => {
    const p1: ProjectInfo = { id: "p1", label: "P1", path: "/tmp/p1" };
    const live: ProjectInfo = { id: "live", label: "Live", path: "/tmp/live" };
    tauriMocks.listProjectsMock.mockResolvedValue([p1, live]);

    // The persisted tab's sessionCreate call is held open under our control
    // — this is what keeps the boot effect's restore loop "in flight" for
    // as long as the test needs, standing in for the real world's slow
    // sequential await-per-tab loop.
    let resolveRestore!: (info: {
      id: string;
      project: string;
      engine: string;
      cwd: string;
      created: number;
    }) => void;
    const restorePromise = new Promise<{
      id: string;
      project: string;
      engine: string;
      cwd: string;
      created: number;
    }>((resolve) => {
      resolveRestore = resolve;
    });
    tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) => {
      if (project === "p1") return restorePromise;
      return Promise.resolve({ id: "live-session-1", project, engine, cwd, created: 0 });
    });
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === LAYOUT_SETTING_KEY) {
        return Promise.resolve(JSON.stringify({ tabs: [{ project: "p1", engine: "claude", cwd: "/tmp/p1" }] }));
      }
      return Promise.resolve(null);
    });

    render(<App />);

    // Boot's restore loop is now blocked awaiting `sessionCreate("p1", ...)`
    // (our still-pending `restorePromise`). While it's stuck there, the
    // user opens a brand-new tab in a different project — exactly the
    // Sidebar "+ Add Project"/new-tab affordance the bug report says stays
    // interactive during the whole restore window. Opening it is now a
    // single click (instant-default-engine, no EnginePicker confirm step).
    const liveButton = await screen.findByRole("button", { name: "new-tab-live" });
    fireEvent.click(liveButton);

    await waitFor(() => {
      const ids = screen.getAllByTestId("tab").map((el) => el.textContent);
      expect(ids).toContain("live-session-1");
    });
    expect(screen.getByTestId("active-tab-id").textContent).toBe("live-session-1");

    // Now let the delayed layout/restored dispatch land.
    resolveRestore({ id: "restored-session-1", project: "p1", engine: "claude", cwd: "/tmp/p1", created: 0 });

    await waitFor(() => {
      const ids = screen.getAllByTestId("tab").map((el) => el.textContent);
      expect(ids).toContain("restored-session-1");
    });

    // The live tab must have survived the merge (not been wholesale-
    // replaced away, which would orphan its already-spawned backend PTY
    // session), and focus must not have been stolen back to the restored
    // tab the user was never looking at.
    const idsFinal = screen.getAllByTestId("tab").map((el) => el.textContent);
    expect(idsFinal).toContain("live-session-1");
    expect(screen.getByTestId("active-tab-id").textContent).toBe("live-session-1");
  });
});
