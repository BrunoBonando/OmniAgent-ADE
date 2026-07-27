import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import SidebarSessionRow, { SESSION_CARD_DELAY_MS } from "./SidebarSessionRow";
import { groupTabsBySession } from "../state/sessionGroups";
import type { TabInfo } from "../state/sessions";

const { useGitBranchMock } = vi.hoisted(() => ({ useGitBranchMock: vi.fn() }));
vi.mock("../lib/useGitBranch", () => ({ useGitBranch: useGitBranchMock }));

function tab(overrides: Partial<TabInfo> = {}): TabInfo {
  return {
    id: "sess-1",
    project: "p1",
    engine: "claude",
    cwd: "/Users/bonando/code/api",
    createdAt: 0,
    group: "g1",
    ...overrides,
  };
}

function session(tabs: TabInfo[] = [tab()], activeTabId: string | null = null) {
  return groupTabsBySession(tabs, activeTabId)[0].sessions[0];
}

function setup(overrides: Partial<Parameters<typeof SidebarSessionRow>[0]> = {}) {
  const props = {
    session: session(),
    projectLabel: "api",
    isCurrent: false,
    tint: "#78a9ff",
    expanded: false,
    activeTabId: null as string | null,
    onActivate: vi.fn(),
    onToggleExpanded: vi.fn(),
    onActivateTab: vi.fn(),
    onRename: vi.fn(),
    ...overrides,
  };
  const { container } = render(<SidebarSessionRow {...props} />);
  return { container, props, onActivate: props.onActivate, onRename: props.onRename };
}

describe("SidebarSessionRow — the session and its branch, nothing else", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  it("shows the session's name", () => {
    setup({ session: session([tab({ groupLabel: "auth refactor" })]) });
    expect(screen.getByText("auth refactor")).toBeInTheDocument();
  });

  it("names an unnamed session Session 1", () => {
    setup();
    expect(screen.getByText("Session 1")).toBeInTheDocument();
  });

  it("shows the branch of the session's own root", () => {
    setup({ session: session([tab({ cwd: "/Users/bonando/code/api" })]) });
    expect(useGitBranchMock).toHaveBeenCalledWith("/Users/bonando/code/api");
    expect(screen.getByText("main")).toBeInTheDocument();
  });

  it("shows no branch tag at all outside a git repo, rather than an empty one", () => {
    useGitBranchMock.mockReturnValue(null);
    const { container } = setup();
    expect(container.querySelector(".session-row-branch")).toBeNull();
  });

  it("never prints the terminal count or the terminals' names — that is what the founder asked to remove", () => {
    const { container } = setup({
      session: session([tab({ id: "s1", label: "backend fix" }), tab({ id: "s2", engine: "shell" })]),
    });
    expect(container.textContent).not.toContain("backend fix");
    expect(container.textContent).not.toContain("shell");
  });

  it("activates the session when clicked", () => {
    const { onActivate } = setup();
    fireEvent.click(screen.getByRole("button", { name: /Session 1/ }));
    expect(onActivate).toHaveBeenCalled();
  });
});

describe("SidebarSessionRow — accent bar and expand chevron (Task 4 redesign)", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  it("current row has the is-current class and rotated chevron", () => {
    const { container } = setup({ isCurrent: true, expanded: true });
    expect(container.querySelector(".session-row.is-current")).toBeInTheDocument();
    expect(container.querySelector(".session-row-chevron.is-expanded")).toBeInTheDocument();
  });

  it("a row that is neither current nor expanded lacks those markers", () => {
    const { container } = setup({ isCurrent: false, expanded: false });
    expect(container.querySelector(".session-row.is-current")).toBeNull();
    expect(container.querySelector(".session-row-chevron.is-expanded")).toBeNull();
  });

  it("chevron toggles expansion without activating", () => {
    const { container, props } = setup({ expanded: false });
    fireEvent.click(container.querySelector(".session-row-chevron")!);
    expect(props.onToggleExpanded).toHaveBeenCalled();
    expect(props.onActivate).not.toHaveBeenCalled();
  });

  // Was "renders an empty children container when expanded" pre-Task-5, back
  // when `.session-row-children` had nothing to render yet. Now that it
  // lists the session's own terminals (Task 5), a *non-current* expanded
  // session still lists them — expanding any row is meant to be browsable —
  // it just never gets the "New terminal" row, since spawning only ever
  // targets the session on screen. `setup()`'s default session has exactly
  // one tab and `isCurrent: false`.
  it("lists the session's terminals when expanded, even when it isn't the current session", () => {
    const { container } = setup({ expanded: true });
    const children = container.querySelector(".session-row-children");
    expect(children).toBeInTheDocument();
    expect(container.querySelectorAll(".terminal-row")).toHaveLength(1);
    expect(container.querySelector(".terminal-row-new")).toBeNull();
  });

  it("renders no children container at all when collapsed", () => {
    const { container } = setup({ expanded: false });
    expect(container.querySelector(".session-row-children")).toBeNull();
  });

  it("expanded current session lists terminals and the New terminal row", () => {
    const { container } = setup({
      isCurrent: true,
      expanded: true,
      session: session([tab({ id: "a" }), tab({ id: "b" })]),
      onOpenNewTerminal: vi.fn(),
    });
    expect(container.querySelectorAll(".terminal-row")).toHaveLength(2);
    expect(screen.getByText("New terminal")).toBeInTheDocument();
  });

  it("hides the New terminal row at MAX_PANES", () => {
    const { container } = setup({
      isCurrent: true,
      expanded: true,
      session: session(Array.from({ length: 8 }, (_, i) => tab({ id: `t${i}` }))),
      onOpenNewTerminal: vi.fn(),
    });
    expect(container.querySelector(".terminal-row-new")).toBeNull();
  });
});

// Fix-round, 2026-07-27: review found the chevron rendering on its own line
// above the row (a block-level button before a flex sibling starts its own
// line). This ensures they're still kept in one row.
describe("SidebarSessionRow — one-line layout (fix-round, 2026-07-27)", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  it("puts the chevron and the name/branch button in one flex row, not stacked", () => {
    const { container } = setup();
    const body = container.querySelector(".session-row-body")!;
    expect(body).toBeInTheDocument();
    expect(body.querySelector(":scope > .session-row-chevron")).not.toBeNull();
    expect(body.querySelector(":scope > .session-row-main")).not.toBeNull();
  });

  it("puts the rename input in the same flex row as the chevron while renaming", () => {
    const { container } = setup();
    fireEvent.doubleClick(screen.getByText("Session 1"));
    const body = container.querySelector(".session-row-body")!;
    expect(body.querySelector(":scope > .session-row-chevron")).not.toBeNull();
    expect(body.querySelector(":scope > .session-row-rename-input")).not.toBeNull();
  });

  it("does not render the dot cluster or layout badge under the session title", () => {
    const { container } = setup({ session: session([tab({ id: "a" }), tab({ id: "b" })]) });
    expect(container.querySelector(".session-row-meta")).toBeNull();
    expect(container.querySelector(".session-row-dot")).toBeNull();
    expect(screen.queryByText("1×2")).not.toBeInTheDocument();
  });
});

describe("SidebarSessionRow — renaming, the app's double-click gesture", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
  });

  it("commits a new name on Enter", () => {
    const { onRename } = setup();
    fireEvent.doubleClick(screen.getByText("Session 1"));
    const input = screen.getByRole("textbox");
    fireEvent.change(input, { target: { value: "auth refactor" } });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onRename).toHaveBeenCalledWith("auth refactor");
  });

  it("commits on blur, like the pane header and the project menu do", () => {
    const { onRename } = setup();
    fireEvent.doubleClick(screen.getByText("Session 1"));
    const input = screen.getByRole("textbox");
    fireEvent.change(input, { target: { value: "ship it" } });
    fireEvent.blur(input);
    expect(onRename).toHaveBeenCalledWith("ship it");
  });

  it("abandons the edit on Escape", () => {
    const { onRename } = setup();
    fireEvent.doubleClick(screen.getByText("Session 1"));
    const input = screen.getByRole("textbox");
    fireEvent.change(input, { target: { value: "nope" } });
    fireEvent.keyDown(input, { key: "Escape" });
    expect(onRename).not.toHaveBeenCalled();
    expect(screen.getByText("Session 1")).toBeInTheDocument();
  });

  it("starts the edit from the name currently shown", () => {
    setup({ session: session([tab({ groupLabel: "auth refactor" })]) });
    fireEvent.doubleClick(screen.getByText("auth refactor"));
    expect(screen.getByRole("textbox")).toHaveValue("auth refactor");
  });

  it("does not activate the session while renaming it", () => {
    const { onActivate } = setup();
    fireEvent.doubleClick(screen.getByText("Session 1"));
    fireEvent.click(screen.getByRole("textbox"));
    expect(onActivate).not.toHaveBeenCalled();
  });
});

describe("SidebarSessionRow — the hover card (moved here from the pane header)", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue("main");
    vi.useFakeTimers({ shouldAdvanceTime: true });
  });
  afterEach(() => vi.useRealTimers());

  function hoverRow() {
    fireEvent.mouseEnter(document.querySelector(".session-row")!);
    act(() => void vi.advanceTimersByTime(SESSION_CARD_DELAY_MS));
  }

  it("stays closed until the pointer has actually rested on the row", () => {
    setup();
    fireEvent.mouseEnter(document.querySelector(".session-row")!);
    act(() => void vi.advanceTimersByTime(SESSION_CARD_DELAY_MS - 50));
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
    act(() => void vi.advanceTimersByTime(60));
    expect(screen.getByRole("tooltip")).toBeInTheDocument();
  });

  it("closes again as soon as the pointer leaves", () => {
    setup();
    hoverRow();
    fireEvent.mouseLeave(document.querySelector(".session-row")!);
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });

  it("shows the whole session without a status description beneath the badge", () => {
    setup({
      session: session([
        tab({ id: "s1", groupLabel: "auth refactor", status: "tool_execution" }),
        tab({ id: "s2", engine: "shell", status: "ready" }),
      ]),
      projectLabel: "api",
    });
    hoverRow();
    const card = screen.getByRole("tooltip");
    expect(card.textContent).toContain("auth refactor");
    expect(card.textContent).toContain("~/code/api");
    expect(card.textContent).toContain("main");
    expect(card.textContent).toContain("2 terminals");
    expect(card.textContent).toContain("Claude Code");
    expect(card.textContent).toContain("Shell");
    expect(card.textContent).toContain("Running tools");
    expect(card.querySelector(".session-card-explain")).toBeNull();
  });

  it("says so when a terminal in the session was reattached to a still-running engine", () => {
    setup({ session: session([tab({ restored: true })]) });
    hoverRow();
    expect(screen.getByRole("tooltip").textContent).toContain("Restored");
  });

  it("does not say 'Restored' for an ordinary fresh session", () => {
    setup();
    hoverRow();
    expect(screen.getByRole("tooltip").textContent).not.toContain("Restored");
  });

  it("gets out of the way while the session is being renamed", () => {
    setup();
    hoverRow();
    // The card is open, so "Session 1" is on screen twice (row + card) —
    // the row's own name is the one being double-clicked.
    fireEvent.doubleClick(document.querySelector(".session-row-name")!);
    expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
  });
});
