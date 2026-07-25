// Coverage for App.tsx's bulk-create orchestration behind NewWorkspaceModal
// (`Sidebar`'s "+"): on `onWorkspaceCreated(project, engines, layout)`, App
// creates one session per checked engine — reusing the exact same
// per-engine spawn logic (`getBriefing` for claude only, `sessionCreate`
// with the project's cwd) `confirmNewTab` already used for the single-tab
// ⌘T flow — dispatches them as ONE bulk batch (see `sessions.ts`'s
// `tabs/opened_bulk` and `paneGrid.ts`'s `buildLayoutTree` docs for why:
// a brand-new project's grid must mount with its final tab set already
// present so the chosen LAYOUT preset's arrangement actually lands, and
// panes already opened never remount mid-batch), computes an
// `initialLayouts` entry for the chosen preset, selects the project, and
// switches to the workspace view — surfacing any per-engine failure via
// the existing `errorBanner` without aborting the rest of the batch.
//
// Same stubbing approach as `App.requestNewTab.test.tsx`/
// `App.bootRestore.test.tsx`: heavy children stubbed to minimal probes.
// `Sidebar`'s stub exposes a single button that fires `onWorkspaceCreated`
// with fixture args (the modal's own UI is covered by
// `NewWorkspaceModal.test.tsx`) plus a "go to map" button to exercise the
// view-switch-back assertion. `Workspace`/`BrainMap` stubs expose just
// enough (`hidden`, `tabs`, `initialLayouts`) to assert on.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { buildLayoutTree } from "./state/paneGrid";
import type { Engine, ProjectInfo, TabInfo } from "./state/sessions";
import type { PaneTree, LayoutPreset } from "./state/paneGrid";

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

const NEW_PROJECT: ProjectInfo = { id: "fresh", label: "fresh", path: "/tmp/fresh" };

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    onWorkspaceCreated: (project: ProjectInfo, engines: Engine[], layout: LayoutPreset) => void;
    onSetView?: (view: "workspace" | "map") => void;
  }) {
    return (
      <div>
        <button onClick={() => props.onSetView?.("map")}>go-to-map</button>
        <button
          onClick={() => props.onWorkspaceCreated(NEW_PROJECT, ["claude", "codex"], 4)}
        >
          create-workspace-claude-codex
        </button>
        <button
          onClick={() => props.onWorkspaceCreated(NEW_PROJECT, ["claude", "codex", "shell"], 6)}
        >
          create-workspace-all-three
        </button>
        <button onClick={() => props.onWorkspaceCreated(NEW_PROJECT, ["codex"], 2)}>
          create-workspace-codex-only
        </button>
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: {
    hidden: boolean;
    tabs: TabInfo[];
    initialLayouts?: Map<string, PaneTree>;
  }) {
    return (
      <div data-testid="workspace-stub" data-hidden={String(props.hidden)}>
        <ul>
          {props.tabs.map((t) => (
            <li key={t.id} data-testid="tab">
              {t.id}:{t.engine}
            </li>
          ))}
        </ul>
        <span data-testid="initial-layout-fresh">
          {JSON.stringify(props.initialLayouts?.get("fresh") ?? null)}
        </span>
      </div>
    );
  },
}));

vi.mock("./components/EnginePicker", () => ({ default: () => null }));
vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({
  default: function BrainMapStub(props: { hidden: boolean }) {
    return <div data-testid="brainmap-stub" data-hidden={String(props.hidden)} />;
  },
}));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));

const { default: App } = await import("./App");

function sessionInfoFor(engine: string) {
  return { id: `${engine}-session`, project: "fresh", engine, cwd: "/tmp/fresh", created: 0 };
}

describe("App — NewWorkspaceModal bulk-create orchestration", () => {
  beforeEach(() => {
    for (const mock of Object.values(tauriMocks)) mock.mockReset();
    tauriMocks.ingestionStatusMock.mockResolvedValue({
      running: false,
      projects_total: 0,
      projects_done: 0,
      total_nodes: 0,
    });
    tauriMocks.rootsListMock.mockResolvedValue(["/tmp/root"]);
    tauriMocks.listProjectsMock.mockResolvedValue([NEW_PROJECT]);
    tauriMocks.settingsGetMock.mockResolvedValue(null);
    tauriMocks.settingsSetMock.mockResolvedValue(undefined);
    tauriMocks.getBriefingMock.mockResolvedValue("briefing text");
  });

  it("creates one session per checked engine (claude gets a briefing, others don't), lands all tabs in one batch, and switches back to the workspace view", async () => {
    tauriMocks.sessionCreateMock.mockImplementation((_project: string, engine: string) =>
      Promise.resolve(sessionInfoFor(engine)),
    );

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "go-to-map" }));
    await waitFor(() => expect(screen.getByTestId("brainmap-stub").dataset.hidden).toBe("false"));

    fireEvent.click(screen.getByRole("button", { name: "create-workspace-claude-codex" }));

    await waitFor(() => {
      const ids = screen.getAllByTestId("tab").map((el) => el.textContent);
      expect(ids).toEqual(["claude-session:claude", "codex-session:codex"]);
    });

    expect(tauriMocks.sessionCreateMock).toHaveBeenCalledTimes(2);
    expect(tauriMocks.sessionCreateMock).toHaveBeenNthCalledWith(1, "fresh", "claude", "/tmp/fresh", "briefing text");
    expect(tauriMocks.sessionCreateMock).toHaveBeenNthCalledWith(2, "fresh", "codex", "/tmp/fresh", undefined);
    expect(tauriMocks.getBriefingMock).toHaveBeenCalledTimes(1);
    expect(tauriMocks.getBriefingMock).toHaveBeenCalledWith("fresh");

    // View flips back from map to workspace once the workspace is created.
    expect(screen.getByTestId("workspace-stub").dataset.hidden).toBe("false");
    expect(screen.getByTestId("brainmap-stub").dataset.hidden).toBe("true");
  });

  it("seeds initialLayouts with buildLayoutTree(createdIds, layout) for the new project", async () => {
    tauriMocks.sessionCreateMock.mockImplementation((_project: string, engine: string) =>
      Promise.resolve(sessionInfoFor(engine)),
    );

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "create-workspace-claude-codex" }));

    await waitFor(() => {
      const raw = screen.getByTestId("initial-layout-fresh").textContent;
      expect(raw).not.toBe("null");
    });

    const expected = buildLayoutTree(["claude-session", "codex-session"], 4);
    const actual = JSON.parse(screen.getByTestId("initial-layout-fresh").textContent!);
    expect(actual).toEqual(expected);
  });

  it("partial failure: one engine's session_create rejects — the rest still land, and an error banner names the failure", async () => {
    tauriMocks.sessionCreateMock.mockImplementation((_project: string, engine: string) => {
      if (engine === "codex") return Promise.reject(new Error("codex not installed"));
      return Promise.resolve(sessionInfoFor(engine));
    });

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "create-workspace-all-three" }));

    await waitFor(() => {
      const ids = screen.getAllByTestId("tab").map((el) => el.textContent);
      expect(ids.sort()).toEqual(["claude-session:claude", "shell-session:shell"]);
    });

    // Still lands the user in the workspace view with whatever succeeded.
    expect(screen.getByTestId("workspace-stub").dataset.hidden).toBe("false");
    expect(screen.getByText(/couldn.t start codex/i)).toBeInTheDocument();
  });

  it("every engine fails: no tabs are created, but the project is still shown and an error banner appears", async () => {
    tauriMocks.sessionCreateMock.mockRejectedValue(new Error("codex not installed"));

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "create-workspace-codex-only" }));

    await waitFor(() => {
      expect(screen.getByText(/couldn.t start codex/i)).toBeInTheDocument();
    });
    expect(screen.queryAllByTestId("tab")).toHaveLength(0);
    // Still switched into the workspace view for the (now session-less)
    // project rather than leaving the user stranded on the map.
    expect(screen.getByTestId("workspace-stub").dataset.hidden).toBe("false");
  });
});
