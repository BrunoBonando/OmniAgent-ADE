// The sidebar after the 2026-07-26 founder round: what a workspace row and
// a session row are allowed to show, and the hover-revealed workspace close.
import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import Sidebar from "./Sidebar";
import type { ProjectInfo, TabInfo } from "../state/sessions";

const { useGitBranchMock } = vi.hoisted(() => ({ useGitBranchMock: vi.fn() }));
vi.mock("../lib/useGitBranch", () => ({ useGitBranch: useGitBranchMock }));

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
}));

const p1: ProjectInfo = { id: "p1", label: "api", path: "/tmp/p1" };
const p2: ProjectInfo = { id: "p2", label: "web", path: "/tmp/p2" };

function tab(overrides: Partial<TabInfo> = {}): TabInfo {
  return { id: "s1", project: "p1", engine: "claude", cwd: "/tmp/p1", createdAt: 0, group: "g1", ...overrides };
}

function setup(overrides: Partial<Parameters<typeof Sidebar>[0]> = {}) {
  const onCloseWorkspace = vi.fn();
  const onActivateTab = vi.fn();
  const utils = render(
    <Sidebar
      projects={[p1, p2]}
      tabs={[tab(), tab({ id: "s2", engine: "shell", label: "shell scratch" })]}
      activeTabId="s1"
      selectedProjectId="p1"
      onSelectProject={() => {}}
      onNewTabInProject={() => {}}
      onActivateTab={onActivateTab}
      onWorkspaceCreated={() => {}}
      newWorkspaceOpen={false}
      onOpenNewWorkspace={() => {}}
      onCloseNewWorkspace={() => {}}
      onRenameProject={() => {}}
      onImportCompleted={() => {}}
      onCloseWorkspace={onCloseWorkspace}
      {...overrides}
    />,
  );
  return { ...utils, onCloseWorkspace, onActivateTab };
}

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
    expect(container.querySelector(".project-row-count")).toBeNull();
  });

  it("no longer lists the terminals inside a session", () => {
    const { container } = setup();
    expect(container.querySelector(".project-row-tabs")).toBeNull();
    expect(screen.queryByText("shell scratch")).not.toBeInTheDocument();
  });

  it("no longer prints the '2 panes · Claude Code, Shell' meta line", () => {
    const { container } = setup();
    expect(container.textContent).not.toContain("panes");
    expect(container.querySelector(".project-row-session-meta")).toBeNull();
  });

  it("marks the session on screen with the accent rail rather than a text tag", () => {
    const { container } = setup();
    expect(container.querySelector(".session-row.is-current")).not.toBeNull();
    expect(container.textContent).not.toContain("on screen");
  });

  it("activates the session's first terminal when its row is clicked", () => {
    const { onActivateTab } = setup();
    fireEvent.click(screen.getByRole("button", { name: /Session 1/ }));
    expect(onActivateTab).toHaveBeenCalledWith("s1");
  });
});

describe("Sidebar — closing a workspace", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  it("offers a close control on every workspace row", () => {
    setup();
    expect(screen.getByRole("button", { name: "Close workspace api" })).toBeInTheDocument();
    expect(screen.getByRole("button", { name: "Close workspace web" })).toBeInTheDocument();
  });

  it("asks before killing anything, and says exactly what stops", () => {
    const { onCloseWorkspace } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));

    const dialog = screen.getByRole("dialog", { name: "Close workspace" });
    expect(dialog.textContent).toContain("2 terminals in 1 session");
    expect(onCloseWorkspace).not.toHaveBeenCalled();
  });

  it("is unambiguous that nothing is deleted", () => {
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));
    const dialog = screen.getByRole("dialog", { name: "Close workspace" });
    expect(dialog.textContent).toContain("Nothing is deleted");
    expect(dialog.textContent).toContain("Add the folder again to reopen it");
  });

  it("says nothing is running when the workspace has no terminals", () => {
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Close workspace web" }));
    expect(screen.getByRole("dialog", { name: "Close workspace" }).textContent).toContain(
      "Nothing is running in it",
    );
  });

  it("closes the workspace only once the user confirms", () => {
    const { onCloseWorkspace } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));
    fireEvent.click(screen.getByRole("button", { name: "Close workspace" }));
    expect(onCloseWorkspace).toHaveBeenCalledWith(p1);
  });

  it("cancels without touching a thing", () => {
    const { onCloseWorkspace } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(onCloseWorkspace).not.toHaveBeenCalled();
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
  });

  it("takes Escape as cancel and Enter as confirm, like every other dialog here", () => {
    const { onCloseWorkspace } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));
    fireEvent.keyDown(screen.getByRole("dialog", { name: "Close workspace" }), { key: "Escape" });
    expect(onCloseWorkspace).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole("button", { name: "Close workspace api" }));
    fireEvent.keyDown(screen.getByRole("dialog", { name: "Close workspace" }), { key: "Enter" });
    expect(onCloseWorkspace).toHaveBeenCalledWith(p1);
  });

  it("shows no close control at all when the app does not pass a handler", () => {
    setup({ onCloseWorkspace: undefined });
    expect(screen.queryByRole("button", { name: /^Close workspace/ })).not.toBeInTheDocument();
  });
});
