// Regression coverage for bug 2: `App.tsx`'s `requestNewTab` reads
// per-project/global default-engine settings via `Promise.all`, then calls
// `setPickerDefault`/`setPickerProject` with no protection against two
// overlapping calls (e.g. clicking "+" for project A then quickly for
// project B) resolving out of order — whichever `Promise.all` settles LAST
// wins the final picker state regardless of *click* order.
// `useGraphData.ts`'s `map_graph` fetch already guards this exact bug class
// with a monotonic request id (`requestIdRef`, checked before applying a
// result); `requestNewTab` needs the same guard.
//
// Same stubbing approach as `App.bootRestore.test.tsx`: heavy children
// stubbed to `null`/minimal probes, `Sidebar` reduced to one "new tab"
// button per project and a readout of the current tabs, `EnginePicker`
// reduced to a readout of which project/engine it's showing.
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
  default: function EnginePickerStub(props: { project: ProjectInfo; defaultEngine: string }) {
    return (
      <div data-testid="engine-picker">
        <span data-testid="picker-project">{props.project.id}</span>
        <span data-testid="picker-default">{props.defaultEngine}</span>
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({ default: () => null }));
vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({ default: () => null }));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));

const { default: App } = await import("./App");

describe("App — requestNewTab out-of-order settingsGet resolution", () => {
  beforeEach(() => {
    for (const mock of Object.values(tauriMocks)) mock.mockReset();
    tauriMocks.ingestionStatusMock.mockResolvedValue({
      running: false,
      projects_total: 0,
      projects_done: 0,
      total_nodes: 0,
    });
    tauriMocks.rootsListMock.mockResolvedValue(["/tmp/root"]);
    tauriMocks.settingsSetMock.mockResolvedValue(undefined);
    tauriMocks.getBriefingMock.mockResolvedValue(undefined);
  });

  it("applies the most-recently-initiated request's result even when an earlier request's settingsGet resolves later", async () => {
    const a: ProjectInfo = { id: "A", label: "Project A", path: "/tmp/a" };
    const b: ProjectInfo = { id: "B", label: "Project B", path: "/tmp/b" };
    tauriMocks.listProjectsMock.mockResolvedValue([a, b]);

    const calls: Array<(v: string | null) => void> = [];
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      // Boot-effect settings reads (layout restore, file-tree visibility)
      // resolve immediately — only the two per-`requestNewTab`-call reads
      // (per-project default engine, global default engine) are deferred
      // under the test's control below.
      if (key === LAYOUT_SETTING_KEY || key === "file_tree_visible") return Promise.resolve(null);
      return new Promise<string | null>((resolve) => {
        calls.push(resolve);
      });
    });

    render(<App />);

    const buttonA = await screen.findByRole("button", { name: "new-tab-A" });
    const buttonB = await screen.findByRole("button", { name: "new-tab-B" });

    // Click order: A initiated first, B initiated second (while A's own
    // settingsGet calls are still pending) -- the user's most recent
    // action is "open a tab in B".
    fireEvent.click(buttonA);
    fireEvent.click(buttonB);

    // Each requestNewTab call fires settingsGet twice (per-project key,
    // then the global key) via Promise.all -- both calls happen
    // synchronously before either yields, so by now all 4 are pending in
    // click order: [A-perProject, A-global, B-perProject, B-global].
    expect(calls.length).toBe(4);

    // B (the later-initiated call) resolves FIRST.
    calls[2]("codex");
    calls[3](null);

    await waitFor(() => {
      expect(screen.getByTestId("picker-project").textContent).toBe("B");
    });
    expect(screen.getByTestId("picker-default").textContent).toBe("codex");

    // A (the earlier-initiated call) resolves LAST -- it must not clobber
    // B's already-applied, more-recent result.
    calls[0]("shell");
    calls[1](null);
    await new Promise((resolve) => setTimeout(resolve, 0));

    expect(screen.getByTestId("picker-project").textContent).toBe("B");
    expect(screen.getByTestId("picker-default").textContent).toBe("codex");
  });
});
