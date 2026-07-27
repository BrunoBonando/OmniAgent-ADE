// End-to-end proof of the notification rule through the REAL wiring: real
// `session-status:{id}` payloads delivered through the real
// `usePerSessionEvent` subscription into the real `App.tsx`, with the real
// `AppChrome`/`NotificationsPanel` rendering the result. The pure rule
// itself is covered exhaustively in `state/notifications.test.ts`; what this
// file proves is that the app hands that rule the *right* focus/visibility
// context at the moment an event lands, and that clicking an entry really
// navigates.
//
// Same stubbing approach as the other `App.*.test.tsx` files, with one
// addition: `listen` is a real registry here, so a test can fire an event at
// a specific session.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { LAYOUT_SETTING_KEY, type ProjectInfo, type TabInfo } from "./state/sessions";
import { NOTIFICATIONS_SETTING_KEY } from "./state/notifications";
import type { SessionStatusEvent } from "./state/sessionStatus";

const tauriMocks = vi.hoisted(() => ({
  agentCheckInstalledMock: vi.fn(),
  enrichQueuePendingCountMock: vi.fn(),
  getBriefingMock: vi.fn(),
  gitBranchMock: vi.fn(),
  ingestionStatusMock: vi.fn(),
  listProjectsMock: vi.fn(),
  renameProjectMock: vi.fn(),
  rootsListMock: vi.fn(),
  sessionCreateMock: vi.fn(),
  sessionKillMock: vi.fn(),
  sessionStatusMock: vi.fn(),
  sessionWriteMock: vi.fn(),
  sendNativeNotificationMock: vi.fn(),
  settingsGetMock: vi.fn(),
  settingsSetMock: vi.fn(),
  systemStatsMock: vi.fn(),
}));

vi.mock("./lib/tauri", () => ({
  FILE_TREE_VISIBLE_SETTING_KEY: "file_tree_visible",
  agentCheckInstalled: tauriMocks.agentCheckInstalledMock,
  enrichQueuePendingCount: tauriMocks.enrichQueuePendingCountMock,
  getBriefing: tauriMocks.getBriefingMock,
  gitBranch: tauriMocks.gitBranchMock,
  ingestionStatus: tauriMocks.ingestionStatusMock,
  listProjects: tauriMocks.listProjectsMock,
  renameProject: tauriMocks.renameProjectMock,
  rootsList: tauriMocks.rootsListMock,
  sessionCreate: tauriMocks.sessionCreateMock,
  sessionKill: tauriMocks.sessionKillMock,
  sessionStatus: tauriMocks.sessionStatusMock,
  sessionWrite: tauriMocks.sessionWriteMock,
  sendNativeNotification: tauriMocks.sendNativeNotificationMock,
  settingsGet: tauriMocks.settingsGetMock,
  settingsSet: tauriMocks.settingsSetMock,
  systemStats: tauriMocks.systemStatsMock,
}));

/** A real listener registry, so a test can deliver a genuine
 * `session-status:{id}` payload to whatever `App.tsx` subscribed. */
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

vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    projects: ProjectInfo[];
    onSelectProject: (p: ProjectInfo) => void;
    onSetView?: (view: "workspace" | "map") => void;
  }) {
    return (
      <div>
        {props.projects.map((p) => (
          <button key={p.id} onClick={() => props.onSelectProject(p)}>{`select-${p.id}`}</button>
        ))}
        <button onClick={() => props.onSetView?.("workspace")}>go-to-workspace</button>
        <button onClick={() => props.onSetView?.("map")}>go-to-map</button>
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: { tabs: TabInfo[]; activeTabId: string | null; onActivateTab: (id: string) => void }) {
    return (
      <ul data-testid="workspace-stub" data-active={props.activeTabId ?? ""}>
        {props.tabs.map((t) => (
          <li key={t.id}>
            <button onClick={() => props.onActivateTab(t.id)}>{`activate-${t.id}`}</button>
          </li>
        ))}
      </ul>
    );
  },
}));

vi.mock("./components/StartupScreen", () => ({
  default: function StartupScreenStub(props: {
    loading: boolean;
    projects: ProjectInfo[];
    onSelectWorkspace: (project: ProjectInfo) => void;
  }) {
    if (props.loading) return <p>startup-loading</p>;
    return (
      <div>
        {props.projects.map((p) => (
          <button key={p.id} onClick={() => props.onSelectWorkspace(p)}>
            {`select-workspace-${p.id}`}
          </button>
        ))}
      </div>
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

/** Two live panes in p1 and one in p2, restored from a persisted layout —
 * the realistic shape for "the user is somewhere else". */
const LAYOUT = JSON.stringify({
  tabs: [
    { project: "p1", engine: "claude", cwd: "/tmp/p1", id: "sess-1", label: "front end", group: "grp-a" },
    { project: "p1", engine: "claude", cwd: "/tmp/p1", id: "sess-2", label: "back end", group: "grp-a" },
    { project: "p1", engine: "shell", cwd: "/tmp/p1", id: "sess-3", label: "other work", group: "grp-a" },
  ],
});

function emit(id: string, event: SessionStatusEvent) {
  for (const handler of listeners.get(`session-status:${id}`) ?? []) {
    handler({ payload: event });
  }
}

function statusEvent(id: string, status: SessionStatusEvent["status"], notify: boolean): SessionStatusEvent {
  return { id, status, notify, engine: "claude" };
}

beforeEach(() => {
  listeners.clear();
  tauriMocks.agentCheckInstalledMock.mockReset().mockResolvedValue(["claude", "codex", "shell"]);
  tauriMocks.enrichQueuePendingCountMock.mockReset().mockResolvedValue(0);
  tauriMocks.getBriefingMock.mockReset().mockResolvedValue("briefing");
  tauriMocks.gitBranchMock.mockReset().mockResolvedValue("main");
  tauriMocks.ingestionStatusMock.mockReset().mockResolvedValue({ running: false });
  tauriMocks.listProjectsMock.mockReset().mockResolvedValue([P1, P2]);
  tauriMocks.renameProjectMock.mockReset().mockResolvedValue(undefined);
  tauriMocks.rootsListMock.mockReset().mockResolvedValue(["/tmp"]);
  tauriMocks.sessionKillMock.mockReset().mockResolvedValue(undefined);
  tauriMocks.sessionStatusMock.mockReset().mockResolvedValue(null);
  tauriMocks.sessionWriteMock.mockReset().mockResolvedValue(undefined);
  tauriMocks.sendNativeNotificationMock.mockReset().mockResolvedValue(undefined);
  tauriMocks.settingsSetMock.mockReset().mockResolvedValue(undefined);
  tauriMocks.systemStatsMock.mockReset().mockResolvedValue({
    cpuPercent: null,
    ramUsedBytes: null,
    ramTotalBytes: null,
    mcpWired: false,
  });
  tauriMocks.sessionCreateMock
    .mockReset()
    .mockImplementation((project: string, engine: string, cwd: string, _b: unknown, restoreId?: string) =>
      Promise.resolve({ id: restoreId ?? `${project}-new`, project, engine, cwd, created: 0, restored: true }),
    );
  tauriMocks.settingsGetMock.mockReset().mockImplementation((key: string) => {
    if (key === "auth_gate_resolved") return Promise.resolve("true");
    if (key === LAYOUT_SETTING_KEY) return Promise.resolve(LAYOUT);
    if (key === NOTIFICATIONS_SETTING_KEY) return Promise.resolve(null);
    return Promise.resolve(null);
  });
});

async function bootWithThreeSessions() {
  render(<App />);
  fireEvent.click(await screen.findByRole("button", { name: "select-workspace-p1" }));
  fireEvent.click(await screen.findByText("select-p1"));
  fireEvent.click(await screen.findByText("go-to-workspace"));
  await waitFor(() => expect(screen.getByText("activate-sess-3")).toBeInTheDocument());
  // Wait for the app to have SETTLED into the state every test below starts
  // from — the restore focused sess-1 and its project is the one on screen.
  // The chrome's own breadcrumb is the honest signal for that: it renders
  // "<project> · <session>" only once `selectedProjectId` and `activeTabId`
  // agree, which is exactly the context the suppression rule reads. Waiting
  // on the active-tab attribute alone raced under load (the project
  // selection lands in a later commit than the restore), and a background
  // notification for the focused pane is precisely what that race produced.
  await waitFor(() =>
    expect(document.querySelector(".app-chrome-breadcrumb")?.textContent).toBe("Project One·Session 1"),
  );
}

function badge() {
  return document.querySelector(".notifications-badge");
}

describe("App — a background session's notification", () => {
  it("records one for a notifying event on a pane the user isn't looking at", async () => {
    await bootWithThreeSessions();
    emit("sess-2", statusEvent("sess-2", "awaiting_approval", true));
    await waitFor(() => expect(badge()?.textContent).toBe("1"));
  });

  it("records pending approval and approval outcomes only", async () => {
    await bootWithThreeSessions();
    emit("sess-2", statusEvent("sess-2", "awaiting_approval", true));
    emit("sess-2", statusEvent("sess-2", "ready", true));
    emit("sess-3", statusEvent("sess-3", "error", true)); // ignored: no prior awaiting
    emit("sess-3", statusEvent("sess-3", "awaiting_approval", true));
    emit("sess-3", statusEvent("sess-3", "error", true));
    await waitFor(() => expect(badge()?.textContent).toBe("2"));

    fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
    expect(screen.getByText("Approved.")).toBeInTheDocument();
    expect(screen.getByText("Rejected.")).toBeInTheDocument();
    expect(screen.getByText("back end")).toBeInTheDocument();
    expect(screen.getByText("other work")).toBeInTheDocument();
  });

  it("records nothing for the thinking/tool states the backend says don't notify", async () => {
    await bootWithThreeSessions();
    emit("sess-2", statusEvent("sess-2", "thinking", false));
    emit("sess-3", statusEvent("sess-3", "tool_execution", false));
    await new Promise((r) => setTimeout(r, 0));
    expect(badge()).toBeNull();
  });
});

describe("App — the focused-session suppression rule", () => {
  it("stays quiet for the focused pane of the project on screen", async () => {
    await bootWithThreeSessions();
    emit("sess-1", statusEvent("sess-1", "awaiting_approval", true));
    await new Promise((r) => setTimeout(r, 0));
    expect(badge()).toBeNull();
  });

  it("notifies for a different pane in the same workspace", async () => {
    await bootWithThreeSessions();
    fireEvent.click(screen.getByText("activate-sess-3"));
    emit("sess-2", statusEvent("sess-2", "awaiting_approval", true));
    await waitFor(() => expect(badge()?.textContent).toBe("1"));
  });

  it("notifies for the focused pane while the user is on the brain map", async () => {
    await bootWithThreeSessions();
    fireEvent.click(screen.getByText("go-to-map"));
    emit("sess-1", statusEvent("sess-1", "awaiting_approval", true));
    await waitFor(() => expect(badge()?.textContent).toBe("1"));
  });
});

describe("App — clicking a notification goes to that session", () => {
  it("selects its project and focuses its pane", async () => {
    await bootWithThreeSessions();
    emit("sess-3", statusEvent("sess-3", "awaiting_approval", true));
    await waitFor(() => expect(badge()?.textContent).toBe("1"));

    fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
    fireEvent.click(await screen.findByRole("button", { name: /Go to other work/ }));

    await waitFor(() => expect(screen.getByTestId("workspace-stub").dataset.active).toBe("sess-3"));
  });

  it("opening the panel clears the badge, and the entries stay in the list", async () => {
    await bootWithThreeSessions();
    emit("sess-2", statusEvent("sess-2", "awaiting_approval", true));
    await waitFor(() => expect(badge()?.textContent).toBe("1"));

    fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
    await waitFor(() => expect(badge()).toBeNull());
    expect(screen.getByText("Needs your approval.")).toBeInTheDocument();
  });
});

describe("App — approving a notification from the panel", () => {
  it("Approve writes the engine's yes-keystroke to the session and clears the row", async () => {
    await bootWithThreeSessions();
    // Drive sess-2 (a pane the user isn't focused on — sess-1 is active) to
    // awaiting_approval: a notification is recorded AND the tab's live
    // status is awaiting, which is what makes the row actionable.
    emit("sess-2", statusEvent("sess-2", "awaiting_approval", true));
    await waitFor(() => expect(badge()?.textContent).toBe("1"));

    fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
    fireEvent.click(await screen.findByRole("button", { name: /^Approve / }));

    await waitFor(() => expect(tauriMocks.sessionWriteMock).toHaveBeenCalledWith("sess-2", "1"));
    await waitFor(() =>
      expect(screen.queryByRole("button", { name: /^Approve / })).not.toBeInTheDocument(),
    );
  });

  it("answering in the pane clears the notification too — the next status event resolves it", async () => {
    // Founder ask (2026-07-27): "if I approve using the terminal, it has to
    // update the notification." The pane path never touches the panel — the
    // backend just reports the session's next status once the prompt is
    // answered, and that event is what takes the awaiting row down.
    await bootWithThreeSessions();
    emit("sess-2", statusEvent("sess-2", "awaiting_approval", true));
    await waitFor(() => expect(badge()?.textContent).toBe("1"));

    // The user answers in the terminal: the engine goes back to work and the
    // backend emits the transition (thinking never notifies, so no new row).
    emit("sess-2", statusEvent("sess-2", "thinking", false));

    fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
    await waitFor(() => expect(screen.queryByText("Needs your approval.")).not.toBeInTheDocument());
    expect(screen.queryByRole("button", { name: /^Approve / })).not.toBeInTheDocument();
    expect(tauriMocks.sessionWriteMock).not.toHaveBeenCalled();
  });

  it("a double-click only writes the approval once — the in-flight guard, not the not-yet-updated tab status", async () => {
    // `tab.status` only flips on the backend's NEXT status event, so both
    // clicks of a double-click see the same "still awaiting" status and
    // pass that guard. Without a synchronous in-flight guard, both clicks
    // would each call sessionWrite("sess-2", "1") — and Claude often raises
    // a follow-up permission prompt immediately, so the second "1" can
    // approve a prompt the user never saw.
    await bootWithThreeSessions();
    emit("sess-2", statusEvent("sess-2", "awaiting_approval", true));
    await waitFor(() => expect(badge()?.textContent).toBe("1"));

    fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
    const approveButton = await screen.findByRole("button", { name: /^Approve / });
    // Two rapid clicks before anything is awaited — the same shape a real
    // double-click produces, since `sessionWriteMock` resolves on a later
    // microtask than these two synchronous `fireEvent.click` calls.
    fireEvent.click(approveButton);
    fireEvent.click(approveButton);

    await waitFor(() =>
      expect(screen.queryByRole("button", { name: /^Approve / })).not.toBeInTheDocument(),
    );
    expect(tauriMocks.sessionWriteMock).toHaveBeenCalledTimes(1);
  });
});

describe("App — notifications outlive the app", () => {
  it("persists the list through the same settings table the layout uses", async () => {
    await bootWithThreeSessions();
    emit("sess-2", statusEvent("sess-2", "awaiting_approval", true));
    await waitFor(() =>
      expect(tauriMocks.settingsSetMock).toHaveBeenCalledWith(
        NOTIFICATIONS_SETTING_KEY,
        expect.stringContaining("sess-2"),
      ),
    );
  });

  it("restores what was persisted on the next launch", async () => {
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === "auth_gate_resolved") return Promise.resolve("true");
      if (key === LAYOUT_SETTING_KEY) return Promise.resolve(LAYOUT);
      if (key === NOTIFICATIONS_SETTING_KEY) {
        return Promise.resolve(
          JSON.stringify({
            entries: [
              {
                id: "old-1",
                sessionId: "sess-gone",
                project: "p1",
                projectLabel: "Project One",
                cwd: "/tmp/p1",
                engine: "claude",
                status: "ready",
                title: "yesterday's run",
                createdAt: Date.now() - 3 * 86_400_000,
                read: false,
              },
            ],
          }),
        );
      }
      return Promise.resolve(null);
    });

    await bootWithThreeSessions();
    await waitFor(() => expect(badge()?.textContent).toBe("1"));
    fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
    expect(screen.getByText("yesterday's run")).toBeInTheDocument();
    expect(screen.getByText("Approved.")).toBeInTheDocument();
    expect(screen.getByText("3 days")).toBeInTheDocument();
  });

  it("a restored entry whose session is gone still takes the user to its project", async () => {
    tauriMocks.settingsGetMock.mockImplementation((key: string) => {
      if (key === "auth_gate_resolved") return Promise.resolve("true");
      if (key === LAYOUT_SETTING_KEY) return Promise.resolve(LAYOUT);
      if (key === NOTIFICATIONS_SETTING_KEY) {
        return Promise.resolve(
          JSON.stringify({
            entries: [
              {
                id: "old-1",
                sessionId: "sess-gone",
                project: "p2",
                projectLabel: "Project Two",
                cwd: "/tmp/p2",
                engine: "claude",
                status: "ready",
                title: "yesterday's run",
                createdAt: Date.now(),
                read: true,
              },
            ],
          }),
        );
      }
      return Promise.resolve(null);
    });

    await bootWithThreeSessions();
    fireEvent.click(screen.getByRole("button", { name: /Notifications/ }));
    fireEvent.click(await screen.findByRole("button", { name: /Go to yesterday's run/ }));
    expect(await screen.findByText(/isn't running any more/)).toBeInTheDocument();
  });
});
