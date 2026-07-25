// End-to-end regression coverage for the founder's persistence ask (Bruno,
// mid-session, verbatim): "remember that every session, terminal, names,
// etc must be saved so whenever opening the app again, it should be saved
// regardless of the project." `sessions.ts`'s own tests already prove
// `serializeLayout`/`deserializeLayout` round-trip a multi-project batch and
// a custom label in isolation (see `state/sessions.test.ts`'s "layout
// serialize/deserialize round trip" describe block); `App.bootRestore.
// test.tsx` proves the boot-restore-vs-mid-restore-race behavior with a
// hand-authored persisted-layout fixture. Neither exercises the actual
// user-visible cycle this founder ask is about: rename real tabs across
// real DIFFERENT projects through the real `App.tsx` wiring, capture
// EXACTLY what the real persist effect (`settingsSet(LAYOUT_SETTING_KEY,
// serializeLayout(state.tabs))`) sent to the settings table, then feed that
// EXACT captured payload into a fresh mount (the closest thing to a real
// relaunch this environment can drive — the persisted state lives in a
// local settings table, not the DOM, so a fresh mount reading it back is
// the actual relaunch mechanism, not a stand-in for it) and confirm every
// tab, every project, every custom label survives.
//
// Same stubbing approach as the other `App.*.test.tsx` files: heavy
// children stubbed to minimal probes. `Sidebar`'s stub exposes one
// "new-tab-<projectId>" button per project (`App.requestNewTab.test.tsx`'s
// pattern); `EnginePicker`'s stub confirms with whatever default engine it
// was given (`App.newWorkspace.test.tsx`'s pattern); `Workspace`'s stub
// renders each tab's project/engine/id/label plus a rename trigger, since
// renaming only exists on that side of the tree (`PaneHeader`'s `onRename`,
// wired through `Workspace.tsx` -> `App.tsx`'s `renameTab` — the Sidebar has
// no rename affordance at all).
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LAYOUT_SETTING_KEY, type Engine, type ProjectInfo, type TabInfo } from "./state/sessions";

const tauriMocks = vi.hoisted(() => ({
  getBriefingMock: vi.fn(),
  ingestionStatusMock: vi.fn(),
  listProjectsMock: vi.fn(),
  rootsListMock: vi.fn(),
  sessionCreateMock: vi.fn(),
  sessionKillMock: vi.fn(),
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
  settingsGet: tauriMocks.settingsGetMock,
  settingsSet: tauriMocks.settingsSetMock,
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn().mockResolvedValue(() => {}),
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

vi.mock("./components/EnginePicker", () => ({
  default: function EnginePickerStub(props: {
    project: ProjectInfo;
    defaultEngine: Engine;
    onConfirm: (engine: Engine) => void;
  }) {
    return (
      <div data-testid="engine-picker">
        <span data-testid="picker-project">{props.project.id}</span>
        <button onClick={() => props.onConfirm(props.defaultEngine)}>confirm-engine</button>
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: { tabs: TabInfo[]; onRenameTab: (id: string, label: string) => void }) {
    return (
      <ul>
        {props.tabs.map((t) => (
          <li key={t.id} data-testid="tab">
            <span data-testid="tab-info">{`${t.project}:${t.engine}:${t.id}:${t.label ?? ""}`}</span>
            <button onClick={() => props.onRenameTab(t.id, `renamed-${t.project}`)}>{`rename-${t.id}`}</button>
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

describe("App — session/layout persistence survives a relaunch, across every project", () => {
  const p1: ProjectInfo = { id: "p1", label: "Project One", path: "/tmp/p1" };
  const p2: ProjectInfo = { id: "p2", label: "Project Two", path: "/tmp/p2" };

  beforeEach(() => {
    for (const mock of Object.values(tauriMocks)) mock.mockReset();
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
  });

  it("renamed tabs opened across two different projects both land in one settingsSet payload, and both come back — correct project, engine, AND custom label — on a fresh mount reading that exact payload back", async () => {
    // -- "session 1": no persisted layout yet, open + rename a tab in each
    // of two different projects. ------------------------------------------
    tauriMocks.settingsGetMock.mockResolvedValue(null);
    tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) =>
      Promise.resolve({ id: `${project}-${engine}-sess`, project, engine, cwd, created: 0 }),
    );

    const first = render(<App />);

    fireEvent.click(await screen.findByRole("button", { name: "new-tab-p1" }));
    fireEvent.click(await screen.findByRole("button", { name: "confirm-engine" }));
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    fireEvent.click(screen.getByRole("button", { name: "rename-p1-claude-sess" }));
    await waitFor(() =>
      expect(screen.getByTestId("tab-info").textContent).toBe("p1:claude:p1-claude-sess:renamed-p1"),
    );

    fireEvent.click(screen.getByRole("button", { name: "new-tab-p2" }));
    fireEvent.click(await screen.findByRole("button", { name: "confirm-engine" }));
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(2));
    fireEvent.click(screen.getByRole("button", { name: "rename-p2-claude-sess" }));
    await waitFor(() => {
      const texts = screen.getAllByTestId("tab-info").map((el) => el.textContent);
      expect(texts).toContain("p2:claude:p2-claude-sess:renamed-p2");
    });

    // The real persist effect (`App.tsx`: `settingsSet(LAYOUT_SETTING_KEY,
    // serializeLayout(state.tabs))`) fires on every `state.tabs` change —
    // grab the LAST payload it actually sent, covering both projects' tabs
    // with their final (renamed) labels.
    const layoutCalls = tauriMocks.settingsSetMock.mock.calls.filter(([key]) => key === LAYOUT_SETTING_KEY);
    expect(layoutCalls.length).toBeGreaterThan(0);
    const capturedPayload = layoutCalls[layoutCalls.length - 1][1] as string;
    const parsed = JSON.parse(capturedPayload);
    expect(parsed.tabs).toEqual(
      expect.arrayContaining([
        expect.objectContaining({ project: "p1", engine: "claude", label: "renamed-p1" }),
        expect.objectContaining({ project: "p2", engine: "claude", label: "renamed-p2" }),
      ]),
    );
    expect(parsed.tabs).toHaveLength(2);

    first.unmount();

    // -- "session 2": a fresh mount (the relaunch) whose settingsGet for
    // LAYOUT_SETTING_KEY returns EXACTLY what session 1 actually persisted
    // -- not a hand-authored fixture standing in for it. ---------------
    for (const mock of Object.values(tauriMocks)) mock.mockReset();
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
    tauriMocks.settingsGetMock.mockImplementation((key: string) =>
      Promise.resolve(key === LAYOUT_SETTING_KEY ? capturedPayload : null),
    );
    tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) =>
      Promise.resolve({ id: `${project}-${engine}-restored`, project, engine, cwd, created: 0 }),
    );

    render(<App />);

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(2));
    const restoredTexts = screen.getAllByTestId("tab-info").map((el) => el.textContent);
    // Both projects, both engines, and — the actual founder ask — both
    // custom labels, all restored from one fresh mount reading back exactly
    // what got persisted, regardless of which project each tab belonged to.
    expect(restoredTexts).toContain("p1:claude:p1-claude-restored:renamed-p1");
    expect(restoredTexts).toContain("p2:claude:p2-claude-restored:renamed-p2");
  });
});
