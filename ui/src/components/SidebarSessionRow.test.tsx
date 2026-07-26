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
  const onActivate = vi.fn();
  const onRename = vi.fn();
  render(
    <SidebarSessionRow
      session={session()}
      projectLabel="api"
      isCurrent={false}
      tint="#78a9ff"
      onActivate={onActivate}
      onRename={onRename}
      {...overrides}
    />,
  );
  return { onActivate, onRename };
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
    const { container } = render(
      <SidebarSessionRow session={session()} projectLabel="api" isCurrent={false} tint="#78a9ff" onActivate={() => {}} onRename={() => {}} />,
    );
    expect(container.querySelector(".session-row-branch")).toBeNull();
  });

  it("never prints the terminal count or the terminals' names — that is what the founder asked to remove", () => {
    const { container } = render(
      <SidebarSessionRow
        session={session([tab({ id: "s1", label: "backend fix" }), tab({ id: "s2", engine: "shell" })])}
        projectLabel="api"
        isCurrent={false}
        tint="#78a9ff"
        onActivate={() => {}}
        onRename={() => {}}
      />,
    );
    expect(container.textContent).not.toContain("backend fix");
    expect(container.textContent).not.toContain("shell");
    expect(container.textContent).not.toContain("2");
  });

  it("activates the session when clicked", () => {
    const { onActivate } = setup();
    fireEvent.click(screen.getByRole("button", { name: /Session 1/ }));
    expect(onActivate).toHaveBeenCalled();
  });

  it("carries the session's aggregate status light, explained on hover", () => {
    const { container } = render(
      <SidebarSessionRow
        session={session([tab({ id: "s1", status: "ready" }), tab({ id: "s2", status: "awaiting_approval" })])}
        projectLabel="api"
        isCurrent={false}
        tint="#78a9ff"
        onActivate={() => {}}
        onRename={() => {}}
      />,
    );
    const light = container.querySelector(".session-light")!;
    expect(light).toHaveAttribute("data-status", "awaiting_approval");
    expect(light.getAttribute("title")).toContain("approve");
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

  it("describes the whole session: name, folder, branch, terminals, engines and status", () => {
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
    expect(card.textContent).toContain("Running a command or writing files right now.");
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
