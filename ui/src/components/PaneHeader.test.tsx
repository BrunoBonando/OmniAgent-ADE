import { fireEvent, render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import PaneHeader from "./PaneHeader";
import type { TabInfo } from "../state/sessions";

const { useGitBranchMock } = vi.hoisted(() => ({ useGitBranchMock: vi.fn() }));
vi.mock("../lib/useGitBranch", () => ({ useGitBranch: useGitBranchMock }));

function tab(overrides: Partial<TabInfo> = {}): TabInfo {
  return {
    id: "sess-1",
    project: "p1",
    engine: "claude",
    cwd: "/tmp/p1",
    createdAt: 0,
    needsAttention: false,
    ...overrides,
  };
}

function setup(overrides: Partial<Parameters<typeof PaneHeader>[0]> = {}) {
  const onFocus = vi.fn();
  const onClose = vi.fn();
  const onSplit = vi.fn();
  const onRename = vi.fn();
  render(
    <PaneHeader
      tab={tab()}
      projectLabel="bridgemind-api"
      isFocused={false}
      onFocus={onFocus}
      onClose={onClose}
      onSplit={onSplit}
      onRename={onRename}
      {...overrides}
    />,
  );
  return { onFocus, onClose, onSplit, onRename };
}

describe("PaneHeader", () => {
  beforeEach(() => {
    useGitBranchMock.mockReset();
    useGitBranchMock.mockReturnValue(null);
  });

  it("renders the engine + project label, BridgeSpace-style", () => {
    setup();
    expect(screen.getByText("claude")).toBeInTheDocument();
    expect(screen.getByText("bridgemind-api", { exact: false })).toBeInTheDocument();
  });

  it("prefers a custom rename label over the engine name", () => {
    useGitBranchMock.mockReturnValue(null);
    render(
      <PaneHeader
        tab={tab({ label: "backend fix" })}
        projectLabel="bridgemind-api"
        isFocused={false}
        onFocus={() => {}}
        onClose={() => {}}
        onSplit={() => {}}
        onRename={() => {}}
      />,
    );
    expect(screen.getByText("backend fix")).toBeInTheDocument();
    expect(screen.queryByText("claude")).not.toBeInTheDocument();
  });

  it("shows the git branch pill when useGitBranch resolves one", () => {
    useGitBranchMock.mockReturnValue("main");
    setup();
    expect(screen.getByText(/main/)).toBeInTheDocument();
  });

  it("renders no branch pill when there is none", () => {
    useGitBranchMock.mockReturnValue(null);
    setup();
    expect(screen.queryByTitle(/git branch/i)).not.toBeInTheDocument();
  });

  it("shows the attention dot only when the tab needs attention", () => {
    const { rerender } = render(
      <PaneHeader
        tab={tab({ needsAttention: false })}
        projectLabel="p"
        isFocused={false}
        onFocus={() => {}}
        onClose={() => {}}
        onSplit={() => {}}
        onRename={() => {}}
      />,
    );
    expect(screen.queryByRole("status")).not.toBeInTheDocument();

    rerender(
      <PaneHeader
        tab={tab({ needsAttention: true })}
        projectLabel="p"
        isFocused={false}
        onFocus={() => {}}
        onClose={() => {}}
        onSplit={() => {}}
        onRename={() => {}}
      />,
    );
    expect(screen.getByRole("status")).toBeInTheDocument();
  });

  it("calls onFocus on mousedown anywhere in the header", () => {
    const { onFocus } = setup();
    fireEvent.mouseDown(screen.getByText("claude").closest(".pane-header")!);
    expect(onFocus).toHaveBeenCalled();
  });

  it("calls onClose when the close button is clicked", () => {
    const { onClose } = setup();
    fireEvent.click(screen.getByRole("button", { name: /close/i }));
    expect(onClose).toHaveBeenCalled();
  });

  it("calls onSplit when the split (+) button is clicked", () => {
    const { onSplit } = setup();
    fireEvent.click(screen.getByRole("button", { name: /new terminal/i }));
    expect(onSplit).toHaveBeenCalled();
  });

  it("double-clicking the label opens an inline rename input pre-filled with the current display label", () => {
    setup();
    fireEvent.doubleClick(screen.getByText("claude"));
    const input = screen.getByDisplayValue("claude");
    expect(input).toBeInTheDocument();
  });

  it("commits the rename on Enter", () => {
    const { onRename } = setup();
    fireEvent.doubleClick(screen.getByText("claude"));
    const input = screen.getByDisplayValue("claude");
    fireEvent.change(input, { target: { value: "db migration" } });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onRename).toHaveBeenCalledWith("db migration");
  });

  it("commits the rename on blur", () => {
    const { onRename } = setup();
    fireEvent.doubleClick(screen.getByText("claude"));
    const input = screen.getByDisplayValue("claude");
    fireEvent.change(input, { target: { value: "db migration" } });
    fireEvent.blur(input);
    expect(onRename).toHaveBeenCalledWith("db migration");
  });

  it("cancels the rename on Escape without calling onRename", () => {
    const { onRename } = setup();
    fireEvent.doubleClick(screen.getByText("claude"));
    const input = screen.getByDisplayValue("claude");
    fireEvent.change(input, { target: { value: "should not stick" } });
    fireEvent.keyDown(input, { key: "Escape" });
    expect(onRename).not.toHaveBeenCalled();
    expect(screen.getByText("claude")).toBeInTheDocument();
  });

  it("applies the focused-pane styling when isFocused is true", () => {
    setup({ isFocused: true });
    expect(screen.getByText("claude").closest(".pane-header")).toHaveClass("is-focused");
  });
});
