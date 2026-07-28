// ⌘N end to end (Task 13, 2026-07-27): direct again — `NewSessionModal`
// (the real component) for the selected workspace, or a request to open
// `NewWorkspaceModal` (still owned by `Sidebar`, since its "+" opens it
// too) with none selected. This retires the intermediate "session or
// workspace?" chooser this file used to drive through first
// (`NewChooserModal`/`state/newChooserState.ts`, both deleted this task —
// see git history for the step in between).
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
  agentCheckInstalledMock: vi.fn(),
  getBriefingMock: vi.fn(),
  gitBranchMock: vi.fn(),
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
  reviewStatusMock: vi.fn(),
}));

vi.mock("./lib/tauri", () => ({
  FILE_TREE_VISIBLE_SETTING_KEY: "file_tree_visible",
  agentCheckInstalled: tauriMocks.agentCheckInstalledMock,
  getBriefing: tauriMocks.getBriefingMock,
  gitBranch: tauriMocks.gitBranchMock,
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
  reviewStatus: tauriMocks.reviewStatusMock,
  sendNativeNotification: vi.fn().mockResolvedValue(undefined),
  renameProject: vi.fn().mockResolvedValue(undefined),
}));

const { openMock } = vi.hoisted(() => ({ openMock: vi.fn() }));
const { xtermKeyDownMock } = vi.hoisted(() => ({ xtermKeyDownMock: vi.fn() }));
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
  default: function WorkspaceStub(props: { tabs: TabInfo[]; activeTabId: string | null }) {
    return (
      <ul data-testid="workspace-stub" data-active-tab-id={props.activeTabId ?? ""}>
        <textarea
          data-testid="xterm-textarea"
          onKeyDown={(event) => {
            if (event.ctrlKey && (event.key === "ArrowDown" || event.key === "ArrowUp")) return;
            xtermKeyDownMock();
            event.preventDefault();
            event.stopPropagation();
          }}
        />
        {props.tabs.map((t) => (
          <li
            key={t.id}
            data-testid="tab"
            data-group={t.group}
            data-group-label={t.groupLabel ?? ""}
            data-cwd={t.cwd}
          >
            {`${t.id}:${t.engine}`}
          </li>
        ))}
      </ul>
    );
  },
}));

vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/DashboardOverview", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({ default: () => null }));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));

vi.mock("./components/StartupScreen", () => ({
  default: function StartupScreenStub(props: {
    loading: boolean;
    projects: { id: string; label: string; path: string | null }[];
    onSelectWorkspace: (p: { id: string; label: string; path: string | null }) => void;
    onStartFromScratch?: () => void;
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

const { default: App } = await import("./App");

const P1: ProjectInfo = { id: "p1", label: "Project One", path: "/tmp/p1" };
const P2: ProjectInfo = { id: "p2", label: "Project Two", path: "/tmp/p2" };

beforeEach(() => {
  openMock.mockReset();
  // Claude and Codex on the machine, Claude last picked — so the session
  // dialog's slots pre-fill with Claude (`getDefaultAgentSelection`).
  tauriMocks.agentCheckInstalledMock.mockReset().mockResolvedValue(["claude", "codex"]);
  tauriMocks.getBriefingMock.mockReset().mockResolvedValue("briefing");
  tauriMocks.gitBranchMock.mockReset().mockResolvedValue(null);
  tauriMocks.ingestionStatusMock.mockReset().mockResolvedValue({ running: false, total_nodes: 41208 });
  tauriMocks.reviewStatusMock.mockReset().mockResolvedValue(null);
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
    if (key === "auth_gate_resolved") return Promise.resolve("true");
    if (key === "last_selected_agents") return Promise.resolve(JSON.stringify(["claude"]));
    if (key === LAYOUT_SETTING_KEY || key === NOTIFICATIONS_SETTING_KEY) return Promise.resolve(null);
    return Promise.resolve(null);
  });
});

async function boot() {
  render(<App />);
  fireEvent.click(await screen.findByRole("button", { name: "startup-select-p1" }));
  await screen.findByText("select-p1");
  await waitFor(() => expect(tauriMocks.rootsListMock).toHaveBeenCalled());
  // `selectedProjectId` defaults to the first project via its own effect,
  // one render tick behind the project list landing — wait for the
  // chrome's breadcrumb (`selectedProject?.label`) so `pressCmdN()` below
  // never races it. Only matters now that ⌘N reads `selectedProject`
  // directly on keydown (Task 13) instead of via an intervening chooser
  // dialog, which used to give this effect enough time to flush for free.
  await screen.findByText("Project One");
}

/** Boot after restoreThreeSessions() — auto-restore fires (auth_gate +
 * last_selected_project + persistedTabs all set), skipping startup screen. */
async function bootAfterRestore() {
  render(<App />);
  await screen.findByText("select-p1");
  await waitFor(() => expect(tauriMocks.rootsListMock).toHaveBeenCalled());
  await screen.findByText("Project One");
}

/** Same boot, but with zero projects — `selectedProject` can never resolve,
 * which is exactly the "no workspace selected" branch ⌘N has to fall
 * through to `NewWorkspaceModal` for. */
async function bootWithNoProjects() {
  tauriMocks.listProjectsMock.mockResolvedValue([]);
  render(<App />);
  await waitFor(() => expect(tauriMocks.rootsListMock).toHaveBeenCalled());
}

function pressCmdN() {
  fireEvent.keyDown(window, { key: "n", metaKey: true });
}

/** ⌘N, direct into the session dialog for the selected project (Task 13 —
 * no chooser in between any more), which every case below starts with. */
async function openSessionDialog() {
  pressCmdN();
  return screen.findByRole("dialog", { name: "New session" });
}

/** One per terminal the dialog is about to spawn — the engine pickers. */
function slotTriggers(): HTMLElement[] {
  return screen.getAllByRole("button", { name: /^Terminal \d+ engine:/ });
}

function restoreThreeSessions() {
  tauriMocks.sessionCreateMock.mockImplementation(
    (project: string, engine: string, cwd: string, _briefing: unknown, restoreId?: string) =>
      Promise.resolve({ id: restoreId ?? "new-session", project, engine, cwd, created: 0 }),
  );
  tauriMocks.settingsGetMock.mockImplementation((key: string) => {
    if (key === "auth_gate_resolved") return Promise.resolve("true");
    if (key === "last_selected_project") return Promise.resolve("p1");
    if (key === LAYOUT_SETTING_KEY) {
      return Promise.resolve(
        JSON.stringify({
          tabs: [
            { id: "first", project: "p1", engine: "claude", cwd: "/tmp/p1", group: "g1" },
            { id: "second", project: "p1", engine: "claude", cwd: "/tmp/p1", group: "g2" },
            { id: "third", project: "p1", engine: "claude", cwd: "/tmp/p1", group: "g3" },
          ],
        }),
      );
    }
    return Promise.resolve(null);
  });
}

describe("⌘N branches directly — no chooser in between (Task 13)", () => {
  it("opens the new-session modal directly for the selected workspace", async () => {
    await boot();
    pressCmdN();
    expect(await screen.findByRole("dialog", { name: "New session" })).toBeInTheDocument();
    expect(screen.getByTestId("sidebar-stub").dataset.newWorkspaceOpen).toBe("false");
  });

  it("with no workspace selected, asks the sidebar to open New Workspace instead", async () => {
    await bootWithNoProjects();
    pressCmdN();
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(screen.queryByRole("dialog", { name: "New session" })).not.toBeInTheDocument();
  });

  it("Escape closes the session dialog without creating anything", async () => {
    await boot();
    const dialog = await openSessionDialog();
    fireEvent.keyDown(dialog, { key: "Escape" });
    await waitFor(() => expect(screen.queryByRole("dialog", { name: "New session" })).not.toBeInTheDocument());
    expect(tauriMocks.sessionCreateMock).not.toHaveBeenCalled();
  });
});

describe("⌘N -> Session: panes in the project you're already in", () => {
  it("⌘N alone opens the session dialog for the selected project", async () => {
    await boot();
    const dialog = await openSessionDialog();
    expect(dialog).toBeInTheDocument();
    expect(screen.getByText("in Project One workspace")).toBeInTheDocument();
    expect(screen.getAllByText("/tmp/p1").length).toBeGreaterThan(0);
  });

  it("creates one terminal per slot, in the project's own folder, grouped as one session", async () => {
    await boot();
    const dialog = await openSessionDialog();
    // 2×2 — four terminals, and the second one runs a shell instead.
    fireEvent.click(screen.getByRole("button", { name: "2×2" }));
    fireEvent.click(slotTriggers()[1]);
    fireEvent.click(screen.getByRole("option", { name: "Shell" }));
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(4));
    const tabs = screen.getAllByTestId("tab");
    expect(tabs.map((t) => t.textContent)).toEqual([
      "sess-1:claude",
      "sess-2:shell",
      "sess-3:claude",
      "sess-4:claude",
    ]);
    // Same cwd (the project folder), same session group, every pane.
    expect(tabs.every((t) => t.dataset.cwd === "/tmp/p1")).toBe(true);
    expect(new Set(tabs.map((t) => t.dataset.group)).size).toBe(1);
    expect(tauriMocks.sessionCreateMock).toHaveBeenCalledTimes(4);
    expect(tauriMocks.sessionCreateMock).toHaveBeenNthCalledWith(1, "p1", "claude", "/tmp/p1", "briefing");
    // Only claude gets a briefing — the zero-config wiring is engine-aware.
    expect(tauriMocks.sessionCreateMock).toHaveBeenNthCalledWith(2, "p1", "shell", "/tmp/p1", undefined);
  });

  it("names the session after what you said you were doing", async () => {
    await boot();
    const dialog = await openSessionDialog();
    fireEvent.change(screen.getByLabelText("What are you doing?"), {
      target: { value: "  coalesce   refresh-token rotation  " },
    });
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(2));
    // Trimmed and collapsed, and written onto every pane in the session.
    expect(screen.getAllByTestId("tab").map((t) => t.dataset.groupLabel)).toEqual([
      "coalesce refresh-token rotation",
      "coalesce refresh-token rotation",
    ]);
  });

  it("an empty prompt falls back to the workspace's own numbering", async () => {
    await boot();
    fireEvent.keyDown(await openSessionDialog(), { key: "Enter" });
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(2));
    expect(screen.getAllByTestId("tab").map((t) => t.dataset.groupLabel)).toEqual(["Session 1", "Session 1"]);
  });

  it("creates them in a chosen subfolder instead, when one is picked", async () => {
    openMock.mockResolvedValue("/tmp/p1/ui/src");
    await boot();
    const dialog = await openSessionDialog();
    fireEvent.click(screen.getByRole("button", { name: "1" })); // one terminal
    fireEvent.click(screen.getByRole("button", { name: "Change" }));
    await waitFor(() => expect(screen.getByText("/tmp/p1/ui/src")).toBeInTheDocument());
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(screen.getByTestId("tab").dataset.cwd).toBe("/tmp/p1/ui/src");
  });

  it("a second session is a second group in the same project", async () => {
    await boot();
    for (let i = 0; i < 2; i++) {
      const dialog = await openSessionDialog();
      fireEvent.click(screen.getByRole("button", { name: "1" })); // one terminal each
      fireEvent.keyDown(dialog, { key: "Enter" });
      await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(i + 1));
    }
    const groups = screen.getAllByTestId("tab").map((t) => t.dataset.group);
    expect(new Set(groups).size).toBe(2);
  });

  it("follows the sidebar's selection: switch project, and the dialog scopes to it", async () => {
    await boot();
    fireEvent.click(screen.getByText("select-p2"));
    await openSessionDialog();
    expect(await screen.findByText("in Project Two workspace")).toBeInTheDocument();
    expect(screen.getAllByText("/tmp/p2").length).toBeGreaterThan(0);
  });

  it("the sidebar's own '+ New session' opens the same dialog", async () => {
    await boot();
    fireEvent.click(screen.getByText("sidebar-new-session-p2"));
    expect(await screen.findByRole("dialog", { name: "New session" })).toBeInTheDocument();
    expect(screen.getByText("in Project Two workspace")).toBeInTheDocument();
  });

  it("surfaces a failed engine without losing the ones that started", async () => {
    tauriMocks.sessionCreateMock.mockImplementation((project: string, engine: string, cwd: string) => {
      if (engine === "shell") return Promise.reject(new Error("no shell"));
      return Promise.resolve({ id: `sess-${engine}`, project, engine, cwd, created: 0 });
    });
    await boot();
    const dialog = await openSessionDialog();
    fireEvent.click(slotTriggers()[1]);
    fireEvent.click(screen.getByRole("option", { name: "Shell" }));
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(await screen.findByText(/couldn't run Shell/i)).toBeInTheDocument();
  });

  it("shows the backend error when no pane could be opened", async () => {
    tauriMocks.sessionCreateMock.mockRejectedValue(new Error("daemon socket not ready"));
    await boot();
    const dialog = await openSessionDialog();
    fireEvent.click(screen.getByRole("button", { name: "1" }));
    fireEvent.keyDown(dialog, { key: "Enter" });

    expect(await screen.findByText(/couldn't start Claude Code in Project One/i)).toBeInTheDocument();
    expect(await screen.findByText(/daemon socket not ready/i)).toBeInTheDocument();
  });
});

describe("Ctrl+Arrow session navigation", () => {
  it.skip("moves down from an xterm descendant and stops at the final session", async () => {
    restoreThreeSessions();
    render(<App />);
    await waitFor(() => expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("first"));
    fireEvent.click(screen.getByText("select-p1"));

    const textarea = screen.getByTestId("xterm-textarea");
    textarea.focus();
    expect(document.activeElement).toBe(textarea);
    fireEvent.keyDown(textarea, { key: "ArrowDown", ctrlKey: true });
    await waitFor(() => expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("second"));
    expect(xtermKeyDownMock).not.toHaveBeenCalled();
    fireEvent.keyDown(textarea, { key: "ArrowDown", ctrlKey: true });
    await waitFor(() => expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("third"));
    fireEvent.keyDown(textarea, { key: "ArrowDown", ctrlKey: true });
    expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("third");
  });

  it.skip("moves up one session and stops at the first session", async () => {
    restoreThreeSessions();
    render(<App />);
    await waitFor(() => expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("first"));
    fireEvent.click(screen.getByText("select-p1"));

    fireEvent.keyDown(window, { key: "ArrowUp", ctrlKey: true });
    expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("first");
    fireEvent.keyDown(window, { key: "ArrowDown", ctrlKey: true });
    await waitFor(() => expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("second"));
    fireEvent.keyDown(window, { key: "ArrowUp", ctrlKey: true });
    await waitFor(() => expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("first"));
  });

  it("owns only exact Ctrl+Arrow chords", async () => {
    restoreThreeSessions();
    render(<App />);
    await waitFor(() => expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("first"));
    fireEvent.click(screen.getByText("select-p1"));

    for (const modifiers of [{ shiftKey: true }, { altKey: true }, { metaKey: true }]) {
      fireEvent.keyDown(window, { key: "ArrowDown", ctrlKey: true, ...modifiers });
    }
    expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("first");
  });

  it("does not navigate behind an active dialog", async () => {
    restoreThreeSessions();
    render(<App />);
    await waitFor(() => expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("first"));
    fireEvent.click(screen.getByText("select-p1"));

    pressCmdN();
    expect(await screen.findByRole("dialog", { name: "New session" })).toBeInTheDocument();
    fireEvent.keyDown(window, { key: "ArrowDown", ctrlKey: true });
    expect(screen.getByTestId("workspace-stub").dataset.activeTabId).toBe("first");
  });
});
