// The sidebar after the 2026-07-27 left-pane redesign: ONE workspace at a
// time (the switcher + its dropdown), that workspace's sessions under a
// SESSIONS header, and what a session row is allowed to show. The workspace
// close still exists and still confirms — it moved from the project row's
// hover "×" into `ProjectMenu`, reached through the dropdown's per-row "⋯".
import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import Sidebar from "./Sidebar";
import type { ProjectInfo, TabInfo } from "../state/sessions";
import { initialAgentsState } from "../state/agents";

const { useGitBranchMock } = vi.hoisted(() => ({ useGitBranchMock: vi.fn() }));
vi.mock("../lib/useGitBranch", () => ({ useGitBranch: useGitBranchMock }));

// Task 6 (left-pane redesign): Sidebar now renders the real `FileTree` as
// its embedded FILES section, so its own `../lib/tauri` mock has to cover
// FileTree's dependencies too (same module, same resolved path, whichever
// relative specifier each file uses to import it) — `listDir`/`watchDir`/
// `unwatchDir`/etc., not just the roots/ingestion/import surface Sidebar
// itself calls. Defaults are the quiet, empty-tree case; tests that care
// about actual file rows exercise that directly in `FileTree.test.tsx`.
const { listDirMock } = vi.hoisted(() => ({ listDirMock: vi.fn().mockResolvedValue([]) }));

vi.mock("../lib/tauri", () => ({
  rootsPausedProjects: vi.fn().mockResolvedValue([]),
  rootsStaleness: vi.fn().mockResolvedValue([]),
  rootsSetPaused: vi.fn().mockResolvedValue(undefined),
  rootsReingestProject: vi.fn().mockResolvedValue(undefined),
  addProject: vi.fn(),
  settingsGet: vi.fn().mockResolvedValue(null),
  settingsSet: vi.fn().mockResolvedValue(undefined),
  detectImportableTools: vi.fn().mockResolvedValue([]),
  listImportCandidates: vi.fn().mockResolvedValue([]),
  pendingNotesList: vi.fn().mockResolvedValue([]),
  pendingNotesApprove: vi.fn().mockResolvedValue(undefined),
  pendingNotesDiscard: vi.fn().mockResolvedValue(undefined),
  enrichQueuePendingCount: vi.fn().mockResolvedValue(0),
  ingestionStatus: vi.fn().mockResolvedValue({ running: false }),
  REVIEW_MEMORY_SETTING_KEY: "review_memory",
  FILE_TREE_VISIBLE_SETTING_KEY: "file_tree_visible",
  FILE_TREE_WIDTH_SETTING_KEY: "file_tree_width",
  listDir: listDirMock,
  watchDir: vi.fn().mockResolvedValue(undefined),
  unwatchDir: vi.fn().mockResolvedValue(undefined),
  sessionWrite: vi.fn().mockResolvedValue(undefined),
  renamePath: vi.fn(),
  movePath: vi.fn(),
  duplicatePath: vi.fn(),
  deleteToTrash: vi.fn(),
  createFile: vi.fn(),
  createDir: vi.fn(),
}));

vi.mock("@tauri-apps/api/event", () => ({ listen: vi.fn().mockResolvedValue(() => {}) }));
vi.mock("@tauri-apps/plugin-opener", () => ({ openPath: vi.fn(), revealItemInDir: vi.fn() }));

const p1: ProjectInfo = { id: "p1", label: "api", path: "/tmp/p1" };
const p2: ProjectInfo = { id: "p2", label: "web", path: "/tmp/p2" };

function tab(overrides: Partial<TabInfo> = {}): TabInfo {
  return { id: "s1", project: "p1", engine: "claude", cwd: "/tmp/p1", createdAt: 0, group: "g1", ...overrides };
}

/** Open the workspace dropdown, then that workspace's "⋯" (`ProjectMenu`) —
 * the path every per-workspace action takes now that there are no project
 * rows. Anchored by the row's name, since the menu row is what carries it. */
function openWorkspaceMenu(container: HTMLElement, label: string) {
  fireEvent.click(container.querySelector(".workspace-switcher")!);
  // By row, not by text: the selected workspace's name is also on the
  // switcher itself, so a bare `getByText` matches two nodes.
  const row = Array.from(container.querySelectorAll(".workspace-menu-row")).find(
    (candidate) => candidate.querySelector(".workspace-menu-name")?.textContent === label,
  )!;
  fireEvent.click(row.querySelector(".workspace-menu-manage")!);
}

function setup(overrides: Partial<Parameters<typeof Sidebar>[0]> = {}) {
  const onCloseWorkspace = vi.fn();
  const onCloseSession = vi.fn();
  const onActivateTab = vi.fn();
  const onSelectProject = vi.fn();
  const onOpenNewTerminal = vi.fn();
  const utils = render(
    <Sidebar
      projects={[p1, p2]}
      tabs={[tab(), tab({ id: "s2", engine: "shell", label: "shell scratch" })]}
      activeTabId="s1"
      selectedProjectId="p1"
      onSelectProject={onSelectProject}
      onNewTabInProject={() => {}}
      onOpenNewTerminal={onOpenNewTerminal}
      onActivateTab={onActivateTab}
      onWorkspaceCreated={() => {}}
      newWorkspaceOpen={false}
      onOpenNewWorkspace={() => {}}
      onCloseNewWorkspace={() => {}}
      onRenameProject={() => {}}
      onImportCompleted={() => {}}
      onCloseWorkspace={onCloseWorkspace}
      onCloseSession={onCloseSession}
      authSignedIn={null}
      authPersona={null}
      onResetAuthGate={() => {}}
      agentState={initialAgentsState}
      onInstallAgent={() => {}}
      {...overrides}
    />,
  );
  return { ...utils, onCloseWorkspace, onCloseSession, onActivateTab, onSelectProject, onOpenNewTerminal };
}

describe("Sidebar — one workspace at a time", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  it("shows the active workspace in the switcher, not a project list", () => {
    const { container } = setup();
    expect(container.querySelector(".workspace-switcher")).toBeInTheDocument();
    expect(container.querySelector(".project-list")).toBeNull();
    expect(container.querySelector(".project-row")).toBeNull();
    expect(screen.getByText("api")).toBeInTheDocument();
    expect(screen.getByText("/tmp/p1")).toBeInTheDocument();
  });

  it("opens the workspace menu and switches project", () => {
    const { container, onSelectProject } = setup();
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    fireEvent.click(container.querySelector(".workspace-switcher")!);
    fireEvent.click(screen.getByText("web"));
    expect(onSelectProject).toHaveBeenCalledWith(p2);
  });

  it("counts every workspace's sessions in the menu, not just the open one", () => {
    const { container } = setup();
    fireEvent.click(container.querySelector(".workspace-switcher")!);
    expect(screen.getByText("1 session")).toBeInTheDocument();
    expect(screen.getByText("no sessions")).toBeInTheDocument();
  });

  it("keeps New workspace and Import reachable, now from the menu", () => {
    const onOpenNewWorkspace = vi.fn();
    const { container } = setup({ onOpenNewWorkspace });
    expect(container.querySelector(".sidebar-add-project-trigger")).toBeNull();
    fireEvent.click(container.querySelector(".workspace-switcher")!);
    expect(screen.getByText("Import projects…")).toBeInTheDocument();
    fireEvent.click(screen.getByText("New workspace"));
    expect(onOpenNewWorkspace).toHaveBeenCalled();
  });

  it("heads the list with SESSIONS and shows only the selected workspace's sessions", () => {
    const { container } = setup({
      tabs: [tab(), tab({ id: "s3", project: "p2", cwd: "/tmp/p2", group: "g2", groupLabel: "web work" })],
    });
    expect(screen.getByText("SESSIONS")).toBeInTheDocument();
    expect(container.querySelectorAll(".sidebar-session-list .session-row")).toHaveLength(1);
    expect(screen.getByText("Session 1")).toBeInTheDocument();
    expect(screen.queryByText("web work")).not.toBeInTheDocument();
  });

  it("says 'No workspace' when there is nothing open, and still offers a way in", () => {
    const { container } = setup({ projects: [], tabs: [], selectedProjectId: null });
    expect(screen.getByText("No workspace")).toBeInTheDocument();
    expect(screen.getByText("choose or add one")).toBeInTheDocument();
    fireEvent.click(container.querySelector(".workspace-switcher")!);
    expect(screen.getByText("New workspace")).toBeInTheDocument();
  });

  it("opens a new session in the selected workspace from the SESSIONS header", () => {
    const onNewSessionInProject = vi.fn();
    setup({ onNewSessionInProject });
    fireEvent.click(screen.getByRole("button", { name: "New session" }));
    expect(onNewSessionInProject).toHaveBeenCalledWith(p1);
  });
});

describe("Sidebar — session and branch, nothing else", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  it("shows each session's name and branch", () => {
    setup();
    expect(screen.getByText("Session 1")).toBeInTheDocument();
    expect(screen.getByText("main")).toBeInTheDocument();
  });

  it("no longer badges a workspace with how many terminals it has", () => {
    const { container } = setup();
    // Nor with the session-pressure meter the old header carried: the
    // switcher is identity only, and session counts live in the dropdown.
    expect(container.querySelector(".workspace-switcher")!.textContent).not.toMatch(
      /\d\s*(terminal|tab|pane|session)/i,
    );
    expect(container.querySelector(".pressure-badge")).toBeNull();
  });

  // Was "no longer lists the terminals inside a session" pre-Task-5, back
  // when there was no expand/collapse list to have an opinion about. Now
  // that `SidebarSessionRow` renders one (Task 5), the invariant that
  // survives is narrower: a session only lists its terminals once it's
  // expanded — never unconditionally, the way the old always-on "N panes ·
  // engine, engine" meta line did. `setup()`'s default tabs share one group
  // (the on-screen session, auto-expanded), so this moves "s2" into its own,
  // non-current group to keep it collapsed.
  it("does not list a session's terminals unless that session is expanded", () => {
    setup({
      tabs: [tab(), tab({ id: "s2", group: "g2", engine: "shell", label: "shell scratch" })],
    });
    expect(screen.queryByText("shell scratch")).not.toBeInTheDocument();
  });

  it("no longer prints the '2 panes · Claude Code, Shell' meta line", () => {
    const { container } = setup();
    expect(container.textContent).not.toContain("panes");
  });

  it("marks the session on screen with the accent rail rather than a text tag", () => {
    const { container } = setup();
    expect(container.querySelector(".session-row.is-current")).not.toBeNull();
    expect(container.textContent).not.toContain("on screen");
  });

  it("activates the session's first terminal when its row is clicked", () => {
    const { onActivateTab } = setup();
    // Anchored: "Close session Session 1" (the row's hover close) also
    // contains the session name.
    fireEvent.click(screen.getByRole("button", { name: /^Session 1/ }));
    expect(onActivateTab).toHaveBeenCalledWith("s1");
  });
});

describe("Sidebar — auto-expanding the on-screen session (fix-round, 2026-07-27)", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  // Review found `expanded` defaulting off `SessionGroup.isCurrent` (holds
  // the focused pane) instead of the row's own `isCurrent` PROP (the
  // session the accent rail marks — `visibleSessionGroupId`, same function
  // the grid paints from). Those two can disagree: selecting a workspace
  // doesn't move focus, so a project can have a session on screen (rail lit,
  // `isCurrent` prop true) while nothing in that project holds the focused
  // pane at all (every `SessionGroup.isCurrent` in it false). Confirmed with
  // the founder: the row should auto-expand exactly the session its own
  // accent bar marks.
  it("auto-expands the session the accent rail marks, even when the focused pane is in a different project", () => {
    const { container } = setup({
      tabs: [
        tab({ id: "s1", project: "p1", group: "g1" }),
        tab({ id: "s2", project: "p1", group: "g2", groupLabel: "second session" }),
        tab({ id: "s3", project: "p2", cwd: "/tmp/p2", group: "g3" }),
      ],
      // Focus is in p2 — no session in p1 (the selected workspace) holds
      // the focused pane, so `SessionGroup.isCurrent` is false for both g1
      // and g2. `visibleSessionGroupId` still falls back to p1's first
      // session (g1) as the one on screen, which is what `isCurrent` (the
      // prop) and the accent rail mark.
      activeTabId: "s3",
    });
    const currentRow = container.querySelector(".session-row.is-current")!;
    expect(currentRow).not.toBeNull();
    expect(currentRow.querySelector(".session-row-children")).not.toBeNull();
    // The other session in the same project holds no accent and stays
    // collapsed — this isn't "every session in the project auto-expands".
    const rows = [...container.querySelectorAll(".session-row")];
    const otherRow = rows.find((row) => row !== currentRow)!;
    expect(otherRow.querySelector(".session-row-children")).toBeNull();
  });
});

describe("Sidebar — account menu", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  it("shows the mocked user at the bottom without the old footer controls", () => {
    const { container } = setup();
    expect(screen.getByRole("button", { name: "Bruno Bonando — account menu" })).toHaveTextContent(
      "Bruno Bonando",
    );
    expect(screen.queryByText(/⌘K search/)).not.toBeInTheDocument();
    expect(container.querySelector(".sidebar-about-trigger")).toBeNull();
  });

  it("opens session review from the account submenu", () => {
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Bruno Bonando — account menu" }));
    fireEvent.click(screen.getByRole("menuitem", { name: "Review session summaries" }));
    expect(screen.getByRole("dialog", { name: "Session summary review" })).toBeInTheDocument();
  });

  it("opens About from the account submenu", () => {
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Bruno Bonando — account menu" }));
    fireEvent.click(screen.getByRole("menuitem", { name: "About OmniAgent ADE" }));
    expect(screen.getByRole("dialog", { name: "About OmniAgent ADE" })).toBeInTheDocument();
  });
});

describe("Sidebar — closing a workspace", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  it("offers a close control for any workspace, through its dropdown menu", () => {
    const { container } = setup();
    openWorkspaceMenu(container, "api");
    expect(screen.getByRole("button", { name: "Close workspace api" })).toBeInTheDocument();

    openWorkspaceMenu(container, "web");
    expect(screen.getByRole("button", { name: "Close workspace web" })).toBeInTheDocument();
  });

  it("asks before killing anything, and says exactly what stops", () => {
    const { container, onCloseWorkspace } = setup();
    openWorkspaceMenu(container, "api");
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));

    const dialog = screen.getByRole("dialog", { name: "Close workspace" });
    expect(dialog.textContent).toContain("2 terminals in 1 session");
    expect(onCloseWorkspace).not.toHaveBeenCalled();
  });

  it("is unambiguous that nothing is deleted", () => {
    const { container } = setup();
    openWorkspaceMenu(container, "api");
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));
    const dialog = screen.getByRole("dialog", { name: "Close workspace" });
    expect(dialog.textContent).toContain("Nothing is deleted");
    expect(dialog.textContent).toContain("Add the folder again to reopen it");
  });

  it("says nothing is running when the workspace has no terminals", () => {
    const { container } = setup();
    openWorkspaceMenu(container, "web");
    fireEvent.click(screen.getByRole("button", { name: "Close workspace web" }));
    expect(screen.getByRole("dialog", { name: "Close workspace" }).textContent).toContain(
      "Nothing is running in it",
    );
  });

  it("closes the workspace only once the user confirms", () => {
    const { container, onCloseWorkspace } = setup();
    openWorkspaceMenu(container, "api");
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));
    fireEvent.click(screen.getByRole("button", { name: "Close workspace" }));
    expect(onCloseWorkspace).toHaveBeenCalledWith(p1);
  });

  it("cancels without touching a thing", () => {
    const { container, onCloseWorkspace } = setup();
    openWorkspaceMenu(container, "api");
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(onCloseWorkspace).not.toHaveBeenCalled();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("takes Escape as cancel and Enter as confirm, like every other dialog here", () => {
    const { container, onCloseWorkspace } = setup();
    openWorkspaceMenu(container, "api");
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));
    fireEvent.keyDown(screen.getByRole("dialog", { name: "Close workspace" }), { key: "Escape" });
    expect(onCloseWorkspace).not.toHaveBeenCalled();

    openWorkspaceMenu(container, "api");
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));
    fireEvent.keyDown(screen.getByRole("dialog", { name: "Close workspace" }), { key: "Enter" });
    expect(onCloseWorkspace).toHaveBeenCalledWith(p1);
  });

  it("shows no close control at all when the app does not pass a handler", () => {
    const { container } = setup({ onCloseWorkspace: undefined });
    openWorkspaceMenu(container, "api");
    // The rest of the workspace menu is still there — only the close is gone.
    expect(screen.getByRole("button", { name: /Re-check now/ })).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /^Close workspace/ })).not.toBeInTheDocument();
  });
});

describe("Sidebar — closing a session (founder ask: 'I must be able to close a session')", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  it("offers a close control on the session row", () => {
    setup();
    expect(screen.getByRole("button", { name: "Close session Session 1" })).toBeInTheDocument();
  });

  it("asks before killing anything, and says how many terminals stop", () => {
    const { onCloseSession } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Close session Session 1" }));

    const dialog = screen.getByRole("dialog", { name: "Close session" });
    expect(dialog.textContent).toContain("2 terminals");
    expect(onCloseSession).not.toHaveBeenCalled();
  });

  it("closes the session only once the user confirms", () => {
    const { onCloseSession } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Close session Session 1" }));
    fireEvent.click(screen.getByRole("button", { name: "Close session" }));
    expect(onCloseSession).toHaveBeenCalledWith(p1, "g1");
  });

  it("cancels without touching a thing", () => {
    const { onCloseSession } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Close session Session 1" }));
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(onCloseSession).not.toHaveBeenCalled();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("shows no session close control when the app does not pass a handler", () => {
    setup({ onCloseSession: undefined });
    expect(screen.queryByRole("button", { name: /^Close session/ })).not.toBeInTheDocument();
  });
});

describe("Sidebar — FILES section (Task 6, left-pane redesign: the tree embedded below the sessions)", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
    listDirMock.mockReset();
    listDirMock.mockResolvedValue([
      { name: "src", path: "/tmp/p1/src", is_dir: true },
      { name: "main.py", path: "/tmp/p1/main.py", is_dir: false },
      { name: "notes.md", path: "/tmp/p1/notes.md", is_dir: false },
    ]);
  });

  it("renders the FILES header, a filter input, and the tree embedded (no standalone dock chrome)", async () => {
    const { container } = setup();
    expect(screen.getByText("FILES")).toBeInTheDocument();
    expect(container.querySelector(".sidebar-files-filter")).toBeInTheDocument();
    expect(await screen.findByText("main.py")).toBeInTheDocument();
    expect(container.querySelector(".file-tree.is-embedded")).toBeInTheDocument();
    expect(container.querySelector(".file-tree-resize-handle")).toBeNull();
    expect(container.querySelector(".file-tree-header")).toBeNull();
  });

  it("typing into the filter narrows the embedded tree to matching rows — filter state stays local to Sidebar", async () => {
    const { container } = setup();
    await screen.findByText("main.py");
    fireEvent.change(container.querySelector(".sidebar-files-filter")!, { target: { value: "main" } });
    expect(await screen.findByText("main.py")).toBeInTheDocument();
    expect(screen.queryByText("notes.md")).not.toBeInTheDocument();
    expect(screen.queryByText("src")).not.toBeInTheDocument();
  });
});
