// Sessions are named things, and the name survives everything (founder
// brief, 2026-07-26, verbatim: "Each session has a name and can be renamed.
// It starts with session #1").
//
// Drives the real wiring rather than a hand-authored fixture, the same way
// `App.sessionRestore.test.tsx` does: open real sessions through `App.tsx`,
// read the names off the real `groupTabsBySession` derivation the sidebar
// renders from, capture EXACTLY what the real persist effect wrote to the
// settings table, and feed that payload back into a fresh mount to stand in
// for a relaunch.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { groupTabsBySession } from "./state/sessionGroups";
import { LAYOUT_SETTING_KEY, type ProjectInfo, type TabInfo } from "./state/sessions";

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

vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));

// The sidebar, reduced to what this test is about: the session names it
// would print, and the two triggers that create/rename sessions.
vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    projects: ProjectInfo[];
    tabs: TabInfo[];
    activeTabId: string | null;
    onNewTabInProject: (p: ProjectInfo) => void;
    onNewSessionInProject?: (p: ProjectInfo) => void;
    onRenameSession?: (p: ProjectInfo, group: string, name: string) => void;
  }) {
    const sessions = groupTabsBySession(props.tabs, props.activeTabId).flatMap((g) => g.sessions);
    return (
      <div>
        {props.projects.map((p) => (
          <div key={p.id}>
            <button onClick={() => props.onNewTabInProject(p)}>{`new-tab-${p.id}`}</button>
            <button onClick={() => props.onNewSessionInProject?.(p)}>{`new-session-${p.id}`}</button>
          </div>
        ))}
        <ul>
          {sessions.map((s) => (
            <li key={s.id} data-testid="session-row">
              {s.label}
              <button
                onClick={() =>
                  props.onRenameSession?.(
                    props.projects.find((p) => p.id === s.project)!,
                    s.id,
                    "auth refactor",
                  )
                }
              >
                {`rename-${s.label}`}
              </button>
            </li>
          ))}
        </ul>
      </div>
    );
  },
}));

vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: { tabs: TabInfo[]; onCloseTab: (id: string) => void }) {
    return (
      <ul>
        {props.tabs.map((t) => (
          <li key={t.id} data-testid="tab">
            {`${t.id}:${t.groupLabel ?? "-"}`}
            <button onClick={() => props.onCloseTab(t.id)}>{`close-${t.id}`}</button>
          </li>
        ))}
      </ul>
    );
  },
}));

// ⌘N -> "Session" without the dialog: one click creates a session with one
// claude terminal in the project folder.
vi.mock("./components/NewSessionModal", () => ({
  default: function NewSessionModalStub(props: {
    project: ProjectInfo;
    onCreate: (p: ProjectInfo, cwd: string, engines: string[], layout: string) => void;
  }) {
    return (
      <button onClick={() => props.onCreate(props.project, props.project.path!, ["claude"], "single")}>
        create-session
      </button>
    );
  },
}));

vi.mock("./components/CommandPalette", () => ({ default: () => null }));
vi.mock("./components/FileTree", () => ({ default: () => null }));
vi.mock("./map/BrainMap", () => ({ default: () => null }));
vi.mock("./onboarding/FirstRun", () => ({ default: () => null }));
vi.mock("./onboarding/AuthGate", () => ({ default: () => null }));

const { default: App } = await import("./App");

const p1: ProjectInfo = { id: "p1", label: "Project One", path: "/tmp/p1" };

let sessionCounter = 0;

function resetMocks() {
  for (const mock of Object.values(tauriMocks)) mock.mockReset();
  sessionCounter = 0;
  tauriMocks.ingestionStatusMock.mockResolvedValue({
    running: false,
    projects_total: 0,
    projects_done: 0,
    total_nodes: 0,
  });
  tauriMocks.rootsListMock.mockResolvedValue(["/tmp/root"]);
  tauriMocks.listProjectsMock.mockResolvedValue([p1]);
  tauriMocks.getBriefingMock.mockResolvedValue(undefined);
  tauriMocks.settingsSetMock.mockResolvedValue(undefined);
  tauriMocks.settingsGetMock.mockResolvedValue(null);
  tauriMocks.sessionStatusMock.mockResolvedValue(null);
  tauriMocks.sessionKillMock.mockResolvedValue(undefined);
  tauriMocks.sessionCreateMock.mockImplementation(
    (project: string, engine: string, cwd: string, _briefing: unknown, restoreId?: string) => {
      sessionCounter += 1;
      return Promise.resolve({
        id: restoreId ?? `sess-${sessionCounter}`,
        project,
        engine,
        cwd,
        created: 0,
        restored: restoreId !== undefined,
      });
    },
  );
}

function sessionNames(): string[] {
  return screen.getAllByTestId("session-row").map((li) => li.textContent!.replace(/rename-.*$/, ""));
}

function lastLayout(): { tabs: Array<Record<string, unknown>> } {
  const calls = tauriMocks.settingsSetMock.mock.calls.filter(([key]) => key === LAYOUT_SETTING_KEY);
  expect(calls.length).toBeGreaterThan(0);
  return JSON.parse(calls[calls.length - 1][1] as string);
}

async function openTerminal() {
  const before = screen.queryAllByTestId("tab").length;
  fireEvent.click(await screen.findByRole("button", { name: "new-tab-p1" }));
  await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(before + 1));
}

async function openSession() {
  const before = screen.queryAllByTestId("tab").length;
  fireEvent.click(await screen.findByRole("button", { name: "new-session-p1" }));
  fireEvent.click(await screen.findByRole("button", { name: "create-session" }));
  await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(before + 1));
}

describe("App — a session is born with a name", () => {
  beforeEach(resetMocks);

  it("starts at Session 1 and counts up per workspace", async () => {
    render(<App />);
    await openTerminal();
    expect(sessionNames()).toEqual(["Session 1"]);

    await openSession();
    expect(sessionNames()).toEqual(["Session 1", "Session 2"]);
  });

  it("stores the name on every terminal in the session, so it survives a relaunch", async () => {
    render(<App />);
    await openTerminal();
    // A second terminal opened with ⌘T joins the session you're in — and
    // therefore its name, not a new one.
    await openTerminal();
    expect(sessionNames()).toEqual(["Session 1"]);
    await waitFor(() => {
      const tabs = lastLayout().tabs;
      expect(tabs).toHaveLength(2);
      expect(tabs.map((t) => t.groupLabel)).toEqual(["Session 1", "Session 1"]);
      expect(new Set(tabs.map((t) => t.group)).size).toBe(1);
    });
  });

  it("reuses the lowest free number when a session is closed out of order", async () => {
    render(<App />);
    await openTerminal(); // Session 1
    await openSession(); // Session 2
    await openSession(); // Session 3
    expect(sessionNames()).toEqual(["Session 1", "Session 2", "Session 3"]);

    // Close Session 2's only terminal…
    fireEvent.click(screen.getByRole("button", { name: "close-sess-2" }));
    await waitFor(() => expect(sessionNames()).toEqual(["Session 1", "Session 3"]));

    // …and the next session takes the free number rather than colliding
    // with Session 3 or climbing to 4.
    await openSession();
    expect(sessionNames()).toEqual(["Session 1", "Session 3", "Session 2"]);
  });
});

describe("App — renaming a session", () => {
  beforeEach(resetMocks);

  it("renames every terminal's session at once and persists it", async () => {
    render(<App />);
    await openTerminal();
    await openTerminal();

    fireEvent.click(screen.getByRole("button", { name: "rename-Session 1" }));
    await waitFor(() => expect(sessionNames()).toEqual(["auth refactor"]));

    await waitFor(() => {
      expect(lastLayout().tabs.map((t) => t.groupLabel)).toEqual(["auth refactor", "auth refactor"]);
    });
  });

  it("keeps a renamed session's name out of the way of the next session's numbering", async () => {
    render(<App />);
    await openTerminal();
    fireEvent.click(screen.getByRole("button", { name: "rename-Session 1" }));
    await waitFor(() => expect(sessionNames()).toEqual(["auth refactor"]));

    await openSession();
    // Session 1's number is free again — nothing on screen is called that.
    expect(sessionNames()).toEqual(["auth refactor", "Session 1"]);
  });
});

describe("App — names come back with the sessions after a relaunch", () => {
  beforeEach(resetMocks);

  it("restores each pane into its own named session, with its restoreId", async () => {
    const first = render(<App />);
    await openTerminal();
    await openSession();
    fireEvent.click(screen.getByRole("button", { name: "rename-Session 1" }));
    await waitFor(() => expect(sessionNames()).toEqual(["auth refactor", "Session 2"]));

    const calls = tauriMocks.settingsSetMock.mock.calls.filter(([key]) => key === LAYOUT_SETTING_KEY);
    const payload = calls[calls.length - 1][1] as string;
    first.unmount();

    // -- the relaunch: a fresh mount reading back EXACTLY that payload ----
    resetMocks();
    tauriMocks.settingsGetMock.mockImplementation((key: string) =>
      Promise.resolve(key === LAYOUT_SETTING_KEY ? payload : null),
    );

    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(2));

    // The names are back, on the same sessions, in the same order…
    expect(sessionNames()).toEqual(["auth refactor", "Session 2"]);
    // …and every pane reattached to its own live engine.
    expect(tauriMocks.sessionCreateMock).toHaveBeenCalledWith("p1", "claude", "/tmp/p1", undefined, "sess-1");
    expect(tauriMocks.sessionCreateMock).toHaveBeenCalledWith("p1", "claude", "/tmp/p1", undefined, "sess-2");
    expect(screen.getAllByTestId("tab").map((li) => li.textContent)).toEqual([
      "sess-1:auth refactorclose-sess-1",
      "sess-2:Session 2close-sess-2",
    ]);
  });

  it("numbers a new session against the restored ones, never colliding with them", async () => {
    resetMocks();
    tauriMocks.settingsGetMock.mockImplementation((key: string) =>
      Promise.resolve(
        key === LAYOUT_SETTING_KEY
          ? JSON.stringify({
              tabs: [
                {
                  id: "sess-old-2",
                  project: "p1",
                  engine: "claude",
                  cwd: "/tmp/p1",
                  group: "sess-grp-old-2",
                  groupLabel: "Session 2",
                },
              ],
            })
          : null,
      ),
    );

    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab")).toHaveLength(1));
    await openSession();
    expect(sessionNames()).toEqual(["Session 2", "Session 1"]);
  });
});
