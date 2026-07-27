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
import { LAYOUT_SETTING_KEY, type ProjectInfo, type TabInfo } from "./state/sessions";
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
// "open-new-terminal" button (so the same wiring test can exercise
// `onOpenNewTerminal` — the sidebar's "New terminal" row, Task 5 — alongside
// ⌘T, both landing on the exact same `setNewTerminalOpen`) AND a
// "select-project-<id>" button per project, wired straight to
// `onSelectProject`. That second one exists only for the
// visibleSession-vs-joinTargetSession regression test below: `onSelectProject`
// is the ONE App.tsx call that moves `selectedProjectId` without touching
// `activeTabId` (`onSelectProject={(p) => setSelectedProjectId(p.id)}` — see
// `App.tsx`), which is exactly the real-world sequence ("switch projects via
// the sidebar") that can leave a focused pane in a DIFFERENT project than
// the one selected.
vi.mock("./components/Sidebar", () => ({
  default: function SidebarStub(props: {
    projects: ProjectInfo[];
    onNewTabInProject: (p: ProjectInfo) => void;
    onOpenNewTerminal: () => void;
    onSelectProject: (p: ProjectInfo) => void;
  }) {
    return (
      <div>
        {props.projects.map((p) => (
          <span key={p.id}>
            <button onClick={() => props.onNewTabInProject(p)}>{`new-tab-${p.id}`}</button>
            <button onClick={() => props.onSelectProject(p)}>{`select-project-${p.id}`}</button>
          </span>
        ))}
        <button onClick={() => props.onOpenNewTerminal()}>open-new-terminal-row</button>
      </div>
    );
  },
}));

// `data-group` (never asserted on by App.requestNewTab.test.tsx's own copy
// of this stub) and the "activate-<id>" button both exist for the same
// regression test as `select-project-<id>` above: `data-group` is how the
// test tells apart a pane that landed in the RIGHT session (the actual
// `sessionGroupForNewPane` join target) from one that landed in the
// on-screen-but-wrong session (`visibleSessionGroupId`) without depending on
// an opaque, `Date.now()`-derived generated group id; `onActivateTab` is
// what moves `activeTabId` to a specific tab (the real
// `activateTab={activateTab}` App.tsx wires to `Workspace`), which is the
// other half of setting up "focused pane is in a different project than the
// one selected".
vi.mock("./components/Workspace", () => ({
  default: function WorkspaceStub(props: { tabs: TabInfo[]; onActivateTab: (id: string) => void }) {
    return (
      <ul>
        {props.tabs.map((t) => (
          <li key={t.id} data-testid="tab-info" data-group={t.group ?? ""}>
            {`${t.project}:${t.engine}:${t.label ?? ""}`}
            <button onClick={() => props.onActivateTab(t.id)}>{`activate-${t.id}`}</button>
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
    // `restoreId` (5th arg — only the boot-restore path passes it, see
    // `App.tsx`'s `sessionCreate(t.project, t.engine, t.cwd, briefing, t.id)`)
    // is echoed back as `id` so a seeded layout's tab ids/groups survive
    // restoration exactly as written, instead of being replaced by
    // freshly-generated ones — the divergence regression test below relies
    // on restored tabs keeping the ids/groups its layout fixture assigns.
    tauriMocks.sessionCreateMock.mockImplementation(
      (project: string, engine: string, cwd: string, _briefing: unknown, restoreId?: string) =>
        Promise.resolve({
          id: restoreId ?? `${project}-sess-${++created}`,
          project,
          engine,
          cwd,
          created: 0,
          restored: !!restoreId,
        }),
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

describe("App — ⌘T targets the JOIN session, not just the on-screen one (fix round)", () => {
  // Regression for the bug the first review round caught: `visibleSession`
  // (`visibleSessionGroupId` — "which session is on screen") and
  // `joinTargetSession` (`sessionGroupForNewPane` — "which session does a
  // new pane join", the function `requestNewTab` itself actually calls) can
  // legitimately disagree. Per `state/sessionGroups.ts`'s own docs, both
  // fall back differently when the focused pane isn't in the target
  // project: `visibleSessionGroupId` picks that project's FIRST-SEEN
  // session, `sessionGroupForNewPane` picks its MOST-RECENTLY-CREATED one.
  //
  // Reproduced with an ordinary flow, not a contrived one: project A has
  // two sessions (Session 1, created first, 2 panes; Session 2, created
  // after, 1 pane). The user is focused on a pane in project B, then clicks
  // project A's row in the sidebar — `onSelectProject` (`App.tsx`:
  // `(p) => setSelectedProjectId(p.id)`) moves `selectedProjectId` WITHOUT
  // touching `activeTabId`, so the focused pane stays B's even though A is
  // now the selected/on-screen workspace. `visibleSessionGroupId` then
  // falls back to A's Session 1 (first-seen); `sessionGroupForNewPane`
  // falls back to A's Session 2 (most recent) — the exact divergence.
  const a: ProjectInfo = { id: "A", label: "Project A", path: "/tmp/a" };
  const b: ProjectInfo = { id: "B", label: "Project B", path: "/tmp/b" };

  // A pre-restored layout (rather than clicking "new-tab-A" repeatedly) is
  // the only way to get TWO sessions in one project through this stub
  // harness: `sessionGroupForNewPane` (what every real "add a pane" path
  // goes through) never mints a second session for a project that already
  // has one — only `NewSessionModal`/`EmptyWorkspace`'s `handleSessionCreated`
  // does that, and both render real Tauri-backed dialogs this file doesn't
  // stub out.
  const layout = JSON.stringify({
    tabs: [
      { project: "A", engine: "shell", cwd: "/tmp/a", id: "a1", group: "grp-a1", groupLabel: "Session 1" },
      { project: "A", engine: "shell", cwd: "/tmp/a", id: "a2", group: "grp-a1", groupLabel: "Session 1" },
      { project: "A", engine: "shell", cwd: "/tmp/a", id: "a3", group: "grp-a2", groupLabel: "Session 2" },
      { project: "B", engine: "shell", cwd: "/tmp/b", id: "b1", group: "grp-b1", groupLabel: "Session 1" },
    ],
  });

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
    tauriMocks.listProjectsMock.mockResolvedValue([a, b]);
    tauriMocks.settingsGetMock.mockImplementation((key: string) =>
      Promise.resolve(key === LAYOUT_SETTING_KEY ? layout : null),
    );
    let created = 0;
    tauriMocks.sessionCreateMock.mockImplementation(
      (project: string, engine: string, cwd: string, _briefing: unknown, restoreId?: string) =>
        Promise.resolve({
          id: restoreId ?? `${project}-fresh-${++created}`,
          project,
          engine,
          cwd,
          created: 0,
          restored: !!restoreId,
        }),
    );
  });

  /** Boots the app with the layout above restored, then reproduces the
   * "focused on B, switch to A via the sidebar" sequence: activate b1
   * (`activateTab` — sets BOTH `activeTabId` and `selectedProjectId` to B),
   * then select project A (`onSelectProject` — moves ONLY
   * `selectedProjectId`, per its own doc above). Leaves
   * `selectedProjectId = "A"`, `activeTabId = "b1"`. */
  async function setUpDivergentFocus() {
    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab-info")).toHaveLength(4));
    fireEvent.click(screen.getByRole("button", { name: "activate-b1" }));
    fireEvent.click(screen.getByRole("button", { name: "select-project-A" }));
    tauriMocks.sessionCreateMock.mockClear();
  }

  it("⌘T's modal shows the JOIN session (Session 2, sessionGroupForNewPane's pick), not the on-screen one (Session 1)", async () => {
    await setUpDivergentFocus();

    fireEvent.keyDown(window, { key: "t", metaKey: true });

    // Session 2 (the join target: A's most-recently-created session) — NOT
    // Session 1 (A's first-seen session, what `visibleSessionGroupId` would
    // have shown, and what the pre-fix code actually rendered here).
    expect(await screen.findByText("in Session 2 · 1 of 8 used")).toBeInTheDocument();
    expect(screen.queryByText("in Session 1 · 2 of 8 used")).not.toBeInTheDocument();
  });

  it("confirming joins Session 2 (the real requestNewTab target) — Session 1 stays untouched", async () => {
    await setUpDivergentFocus();

    fireEvent.keyDown(window, { key: "t", metaKey: true });
    await screen.findByText("New terminal");
    fireEvent.click(screen.getByText("Open terminal ⏎"));

    await waitFor(() => expect(tauriMocks.sessionCreateMock).toHaveBeenCalledTimes(1));
    // The new pane's cwd/session both come from project A regardless of
    // which of A's two sessions it joined, so the group is the only thing
    // that can tell them apart — grp-a2 (Session 2) must have gained the
    // pane, grp-a1 (Session 1) must still have exactly its original two.
    await waitFor(() => {
      expect(document.querySelectorAll('[data-group="grp-a2"]')).toHaveLength(2);
    });
    expect(document.querySelectorAll('[data-group="grp-a1"]')).toHaveLength(2);
  });

  it(`refuses ⌘T using the JOIN session's count (Session 2, at ${MAX_PANES}) even while the on-screen session (Session 1) has room — the "false negative" shape`, async () => {
    // Overrides the shared layout: Session 1 (on-screen, first-seen) has 1
    // pane — plenty of room — while Session 2 (the actual join target,
    // most-recently-created) is already full. Pre-fix, the precheck read
    // `visibleSession` (Session 1, not full) and would have let the
    // keystroke through, opening the modal for a session that's actually
    // full — only failing once the user filled in a name/engine and hit
    // confirm, inside `requestNewTab`'s OWN (always-correct)
    // `sessionGroupForNewPane`-based check. Post-fix, the SAME precheck the
    // modal would need is what refuses up front.
    const fullLayout = JSON.stringify({
      tabs: [
        { project: "A", engine: "shell", cwd: "/tmp/a", id: "a1", group: "grp-a1", groupLabel: "Session 1" },
        ...Array.from({ length: MAX_PANES }, (_, i) => ({
          project: "A",
          engine: "shell",
          cwd: "/tmp/a",
          id: `a2-${i}`,
          group: "grp-a2",
          groupLabel: "Session 2",
        })),
        { project: "B", engine: "shell", cwd: "/tmp/b", id: "b1", group: "grp-b1", groupLabel: "Session 1" },
      ],
    });
    tauriMocks.settingsGetMock.mockImplementation((key: string) =>
      Promise.resolve(key === LAYOUT_SETTING_KEY ? fullLayout : null),
    );

    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab-info")).toHaveLength(1 + MAX_PANES + 1));
    fireEvent.click(screen.getByRole("button", { name: "activate-b1" }));
    fireEvent.click(screen.getByRole("button", { name: "select-project-A" }));
    tauriMocks.sessionCreateMock.mockClear();

    fireEvent.keyDown(window, { key: "t", metaKey: true });

    expect(await screen.findByText(new RegExp(`already has ${MAX_PANES} terminals`))).toBeInTheDocument();
    expect(screen.queryByText("New terminal")).not.toBeInTheDocument();
    expect(tauriMocks.sessionCreateMock).not.toHaveBeenCalled();
  });

  it(`still opens ⌘T's modal when the JOIN session (Session 2) has room, even though the on-screen session (Session 1) is at ${MAX_PANES} — the "false positive" shape`, async () => {
    // The mirror image of the previous test: Session 1 (on-screen,
    // first-seen) is already full, Session 2 (the actual join target,
    // most-recently-created) has room. Pre-fix, the precheck read
    // `visibleSession` (Session 1, full) and would have refused the
    // keystroke outright — blocking a perfectly valid ⌘T, since the session
    // it's actually about to join has room.
    const roomyLayout = JSON.stringify({
      tabs: [
        ...Array.from({ length: MAX_PANES }, (_, i) => ({
          project: "A",
          engine: "shell",
          cwd: "/tmp/a",
          id: `a1-${i}`,
          group: "grp-a1",
          groupLabel: "Session 1",
        })),
        { project: "A", engine: "shell", cwd: "/tmp/a", id: "a2", group: "grp-a2", groupLabel: "Session 2" },
        { project: "B", engine: "shell", cwd: "/tmp/b", id: "b1", group: "grp-b1", groupLabel: "Session 1" },
      ],
    });
    tauriMocks.settingsGetMock.mockImplementation((key: string) =>
      Promise.resolve(key === LAYOUT_SETTING_KEY ? roomyLayout : null),
    );

    render(<App />);
    await waitFor(() => expect(screen.getAllByTestId("tab-info")).toHaveLength(MAX_PANES + 1 + 1));
    fireEvent.click(screen.getByRole("button", { name: "activate-b1" }));
    fireEvent.click(screen.getByRole("button", { name: "select-project-A" }));
    tauriMocks.sessionCreateMock.mockClear();

    fireEvent.keyDown(window, { key: "t", metaKey: true });

    expect(await screen.findByText("in Session 2 · 1 of 8 used")).toBeInTheDocument();
    expect(screen.queryByText(new RegExp(`already has ${MAX_PANES} terminals`))).not.toBeInTheDocument();
  });
});
