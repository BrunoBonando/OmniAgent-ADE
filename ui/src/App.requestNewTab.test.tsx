// Regression coverage for the instant-default-engine new-tab flow (founder
// ask, verbatim: "When a new terminal is created, it should automatically
// open the default one"). `App.tsx`'s `requestNewTab` resolves the
// per-project/global default-engine settings via `Promise.all`, then
// creates the session directly — no `EnginePicker` modal in between
// anymore.
//
// Before that change, this file guarded against a UI-only bug: two
// overlapping `requestNewTab` calls (different projects) resolving their
// `settingsGet` calls out of order could clobber a single shared "which
// project is the picker showing" state slot. That shared slot no longer
// exists — each call now creates its own session directly, with no
// intermediate UI state to race over — so this file instead locks in the
// simpler invariant the new flow actually needs: two concurrent new-tab
// requests for different projects each land with the CORRECT,
// independently-resolved engine for THEIR OWN project, regardless of which
// project's `settingsGet` promises happen to resolve first.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { NOTIFICATIONS_SETTING_KEY } from "./state/notifications";
import { CLOSED_WORKSPACES_SETTING_KEY } from "./state/closedWorkspaces";
import { LAYOUT_SETTING_KEY, type ProjectInfo, type TabInfo } from "./state/sessions";
import { MAX_PANES } from "./state/paneGrid";
import {
  AUTH_GATE_RESOLVED_SETTING_KEY,
  AUTH_PERSONA_SETTING_KEY,
  AUTH_SIGNED_IN_SETTING_KEY,
} from "./onboarding/authGateState";

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
          <li key={t.id} data-testid="tab-info">
            {`${t.project}:${t.engine}`}
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

describe("App — instant-default-engine new tab", () => {
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
  });

  it("opens the session immediately with no blocking modal in between", async () => {
    const a: ProjectInfo = { id: "A", label: "Project A", path: "/tmp/a" };
    tauriMocks.listProjectsMock.mockResolvedValue([a]);
    tauriMocks.settingsGetMock.mockResolvedValue(null); // no overrides -> falls back to claude
    tauriMocks.sessionCreateMock.mockResolvedValue({
      id: "A-sess",
      project: "A",
      engine: "claude",
      cwd: "/tmp/a",
      created: 0,
    });

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "new-tab-A" }));

    await waitFor(() => {
      expect(screen.getByText("A:claude")).toBeInTheDocument();
    });
  });

  it(`refuses the ${MAX_PANES + 1}th terminal in one session — the approved shapes stop at 2x4`, async () => {
    // Founder, 2026-07-26: "...2x3, 2x4. And no more terminals are
    // available." The ceiling is per SESSION (the unit a grid renders), and it
    // refuses BEFORE spawning — a live PTY the grid has no approved shape for
    // would be worse than the refusal.
    const a: ProjectInfo = { id: "A", label: "Project A", path: "/tmp/a" };
    tauriMocks.listProjectsMock.mockResolvedValue([a]);
    tauriMocks.settingsGetMock.mockResolvedValue(null);
    let created = 0;
    tauriMocks.sessionCreateMock.mockImplementation(() =>
      Promise.resolve({ id: `A-sess-${++created}`, project: "A", engine: "claude", cwd: "/tmp/a", created: 0 }),
    );

    render(<App />);
    const newTab = await screen.findByRole("button", { name: "new-tab-A" });
    for (let i = 1; i <= MAX_PANES; i++) {
      fireEvent.click(newTab);
      await waitFor(() => expect(screen.getAllByTestId("tab-info")).toHaveLength(i));
    }

    fireEvent.click(newTab);
    expect(await screen.findByText(new RegExp(`already has ${MAX_PANES} terminals`))).toBeInTheDocument();
    expect(tauriMocks.sessionCreateMock).toHaveBeenCalledTimes(MAX_PANES);
  });

  it("resolves the per-project override over the global default, same chain EnginePicker's old default used", async () => {
    const a: ProjectInfo = { id: "A", label: "Project A", path: "/tmp/a" };
    tauriMocks.listProjectsMock.mockResolvedValue([a]);
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (
        key === LAYOUT_SETTING_KEY ||
        key === "file_tree_visible" ||
        key === AUTH_GATE_RESOLVED_SETTING_KEY ||
        key === AUTH_SIGNED_IN_SETTING_KEY ||
        key === AUTH_PERSONA_SETTING_KEY ||
        key === NOTIFICATIONS_SETTING_KEY ||
        key === CLOSED_WORKSPACES_SETTING_KEY
      ) {
        return Promise.resolve(null);
      }
      if (key === "default_engine:A") return Promise.resolve("codex");
      if (key === "default_engine:__global__") return Promise.resolve("shell");
      return Promise.resolve(null);
    });
    tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) =>
      Promise.resolve({ id: `${project}-sess`, project, engine, cwd, created: 0 }),
    );

    render(<App />);
    fireEvent.click(await screen.findByRole("button", { name: "new-tab-A" }));

    await waitFor(() => {
      expect(screen.getByText("A:codex")).toBeInTheDocument();
    });
  });

  it("each concurrent request lands its OWN project's correctly-resolved engine, regardless of settingsGet resolution order", async () => {
    const a: ProjectInfo = { id: "A", label: "Project A", path: "/tmp/a" };
    const b: ProjectInfo = { id: "B", label: "Project B", path: "/tmp/b" };
    tauriMocks.listProjectsMock.mockResolvedValue([a, b]);
    tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) =>
      Promise.resolve({ id: `${project}-sess`, project, engine, cwd, created: 0 }),
    );

    const calls: Array<(v: string | null) => void> = [];
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (
        key === LAYOUT_SETTING_KEY ||
        key === "file_tree_visible" ||
        key === AUTH_GATE_RESOLVED_SETTING_KEY ||
        key === AUTH_SIGNED_IN_SETTING_KEY ||
        key === AUTH_PERSONA_SETTING_KEY ||
        key === NOTIFICATIONS_SETTING_KEY ||
        key === CLOSED_WORKSPACES_SETTING_KEY
      ) {
        return Promise.resolve(null);
      }
      return new Promise<string | null>((resolve) => {
        calls.push(resolve);
      });
    });

    render(<App />);
    const buttonA = await screen.findByRole("button", { name: "new-tab-A" });
    const buttonB = await screen.findByRole("button", { name: "new-tab-B" });

    // Click order: A initiated first, B initiated second (while A's own
    // settingsGet calls are still pending).
    fireEvent.click(buttonA);
    fireEvent.click(buttonB);

    // Each requestNewTab call fires settingsGet twice (per-project key,
    // then the global key) via Promise.all — by now all 4 are pending in
    // click order: [A-perProject, A-global, B-perProject, B-global].
    expect(calls.length).toBe(4);

    // B (the later-initiated call) resolves FIRST.
    calls[2]("codex");
    calls[3](null);

    await waitFor(() => {
      expect(screen.getByText("B:codex")).toBeInTheDocument();
    });

    // A (the earlier-initiated call) resolves LAST — must land its own
    // ("shell") engine and must not disturb B's already-created tab (no
    // shared "picker" state left to clobber).
    calls[0]("shell");
    calls[1](null);

    await waitFor(() => {
      expect(screen.getByText("A:shell")).toBeInTheDocument();
    });
    expect(screen.getByText("B:codex")).toBeInTheDocument();
  });
});
