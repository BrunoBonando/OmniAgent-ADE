// Task 11: the New Session dialog's "what are you doing?" answer becomes
// the first thing typed into the session's lead terminal, once that
// terminal reports its first `session-status:{id}` event — written without
// a trailing newline so nothing auto-executes.
//
// Real end-to-end wiring, same approach as `App.newSession.test.tsx`
// (⌘N -> `NewSessionModal` -> `handleSessionCreated`, direct since Task 13
// retired the intermediate chooser), combined with
// `App.notifications.test.tsx`'s real `session-status:{id}` listener
// registry — needed here because these cases must deliver a genuine event
// to whichever session id the dialog actually spawned, not a fixed one.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LAYOUT_SETTING_KEY, type ProjectInfo, type TabInfo } from "./state/sessions";
import { NOTIFICATIONS_SETTING_KEY } from "./state/notifications";
import type { SessionStatusEvent } from "./state/sessionStatus";

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
}));

/** A real listener registry (`App.notifications.test.tsx`'s pattern), so a
 * test can deliver a genuine `session-status:{id}` payload to whatever
 * `App.tsx` subscribed for the session the dialog just spawned. */
const listeners = vi.hoisted(() => new Map<string, Array<(e: { payload: unknown }) => void>>());

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(async (event: string, handler: (e: { payload: unknown }) => void) => {
    const list = listeners.get(event) ?? [];
    list.push(handler);
    listeners.set(event, list);
    return () => {
      const current = listeners.get(event) ?? [];
      listeners.set(
        event,
        current.filter((h) => h !== handler),
      );
    };
  }),
}));

const { openMock } = vi.hoisted(() => ({ openMock: vi.fn() }));
vi.mock("@tauri-apps/plugin-dialog", () => ({ open: openMock }));

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
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: { tabs: TabInfo[]; activeTabId: string | null }) {
    return (
      <ul data-testid="workspace-stub" data-active-tab-id={props.activeTabId ?? ""}>
        {props.tabs.map((t) => (
          <li key={t.id} data-testid="tab" data-engine={t.engine}>
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

function emitSessionStatus(id: string, event: SessionStatusEvent) {
  for (const handler of listeners.get(`session-status:${id}`) ?? []) {
    handler({ payload: event });
  }
}

beforeEach(() => {
  listeners.clear();
  openMock.mockReset();
  tauriMocks.agentCheckInstalledMock.mockReset().mockResolvedValue(["claude", "codex"]);
  tauriMocks.getBriefingMock.mockReset().mockResolvedValue("briefing");
  tauriMocks.gitBranchMock.mockReset().mockResolvedValue(null);
  tauriMocks.ingestionStatusMock.mockReset().mockResolvedValue({ running: false, total_nodes: 41208 });
  tauriMocks.listProjectsMock.mockReset().mockResolvedValue([P1]);
  tauriMocks.rootsListMock.mockReset().mockResolvedValue(["/tmp"]);
  tauriMocks.sessionKillMock.mockReset().mockResolvedValue(undefined);
  tauriMocks.sessionStatusMock.mockReset().mockResolvedValue(null);
  tauriMocks.sessionWriteMock.mockReset().mockResolvedValue(undefined);
  tauriMocks.settingsSetMock.mockReset().mockResolvedValue(undefined);
  let counter = 0;
  tauriMocks.sessionCreateMock
    .mockReset()
    .mockImplementation((project: string, engine: string, cwd: string) => {
      counter += 1;
      return Promise.resolve({ id: `sess-${counter}`, project, engine, cwd, created: 0 });
    });
  tauriMocks.settingsGetMock.mockReset().mockImplementation((key: string) => {
    if (key === "last_selected_agents") return Promise.resolve(JSON.stringify(["claude"]));
    if (key === LAYOUT_SETTING_KEY || key === NOTIFICATIONS_SETTING_KEY) return Promise.resolve(null);
    return Promise.resolve(null);
  });
});

async function boot() {
  render(<App />);
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

/** The single spawned tab's id, read back off the workspace stub. */
function soleTabId(): string {
  return screen.getByTestId("tab").textContent!.split(":")[0];
}

describe("Task 11 — the session prompt reaches the first agent pane", () => {
  it("writes the prompt into the first agent pane once it reports status", async () => {
    await boot();
    const dialog = await openSessionDialog();
    fireEvent.click(screen.getByRole("button", { name: "1" })); // one terminal, default engine (claude)
    fireEvent.change(screen.getByLabelText("What are you doing?"), {
      target: { value: "rotate tokens" },
    });
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(screen.getByTestId("tab").dataset.engine).toBe("claude");
    const tabId = soleTabId();

    expect(tauriMocks.sessionWriteMock).not.toHaveBeenCalled();
    emitSessionStatus(tabId, { id: tabId, status: "ready", notify: false, engine: "claude" });
    await waitFor(() => expect(tauriMocks.sessionWriteMock).toHaveBeenCalledWith(tabId, "rotate tokens"));
  });

  it("writes exactly once, even if the pane reports status twice", async () => {
    await boot();
    const dialog = await openSessionDialog();
    fireEvent.click(screen.getByRole("button", { name: "1" }));
    fireEvent.change(screen.getByLabelText("What are you doing?"), {
      target: { value: "rotate tokens" },
    });
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    const tabId = soleTabId();

    emitSessionStatus(tabId, { id: tabId, status: "thinking", notify: false, engine: "claude" });
    emitSessionStatus(tabId, { id: tabId, status: "ready", notify: false, engine: "claude" });
    await waitFor(() => expect(tauriMocks.sessionWriteMock).toHaveBeenCalledTimes(1));
    expect(tauriMocks.sessionWriteMock).toHaveBeenCalledWith(tabId, "rotate tokens");
  });

  it("an all-shell session gets no prompt write", async () => {
    await boot();
    const dialog = await openSessionDialog();
    fireEvent.click(screen.getByRole("button", { name: "1" })); // one terminal
    fireEvent.click(slotTriggers()[0]);
    fireEvent.click(screen.getByRole("option", { name: "Shell" }));
    fireEvent.change(screen.getByLabelText("What are you doing?"), {
      target: { value: "rotate tokens" },
    });
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(screen.getByTestId("tab").dataset.engine).toBe("shell");
    const tabId = soleTabId();

    emitSessionStatus(tabId, { id: tabId, status: "ready", notify: false, engine: "shell" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(tauriMocks.sessionWriteMock).not.toHaveBeenCalled();
  });

  it("targets the first non-shell tab in SLOT order, not the first tab overall", async () => {
    // Default layout is 2 (side by side), both slots pre-filled with the
    // default engine (claude) — leave slot 1 alone and switch only slot 0
    // to Shell, so the spawn order is [shell, claude]. A bug that grabbed
    // `created[0]` unconditionally, or searched in the wrong order, would
    // target the shell tab (sess-1) instead of the claude tab (sess-2).
    await boot();
    const dialog = await openSessionDialog();
    fireEvent.click(slotTriggers()[0]);
    fireEvent.click(screen.getByRole("option", { name: "Shell" }));
    fireEvent.change(screen.getByLabelText("What are you doing?"), {
      target: { value: "rotate tokens" },
    });
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(2));
    const tabs = screen.getAllByTestId("tab");
    expect(tabs.map((t) => t.dataset.engine)).toEqual(["shell", "claude"]);
    const shellTabId = tabs[0].textContent!.split(":")[0];
    const claudeTabId = tabs[1].textContent!.split(":")[0];

    // Status on the shell tab first — it must never receive the prompt.
    emitSessionStatus(shellTabId, { id: shellTabId, status: "ready", notify: false, engine: "shell" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(tauriMocks.sessionWriteMock).not.toHaveBeenCalled();

    emitSessionStatus(claudeTabId, { id: claudeTabId, status: "ready", notify: false, engine: "claude" });
    await waitFor(() =>
      expect(tauriMocks.sessionWriteMock).toHaveBeenCalledWith(claudeTabId, "rotate tokens"),
    );
    expect(tauriMocks.sessionWriteMock).not.toHaveBeenCalledWith(shellTabId, expect.anything());
  });

  it("an empty prompt writes nothing", async () => {
    await boot();
    const dialog = await openSessionDialog();
    fireEvent.click(screen.getByRole("button", { name: "1" })); // one terminal, prompt left empty
    fireEvent.keyDown(dialog, { key: "Enter" });

    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    expect(screen.getByTestId("tab").dataset.engine).toBe("claude");
    const tabId = soleTabId();

    emitSessionStatus(tabId, { id: tabId, status: "ready", notify: false, engine: "claude" });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(tauriMocks.sessionWriteMock).not.toHaveBeenCalled();
  });
});
