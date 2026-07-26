import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
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

  it("renders the title + agent label, not the project (same in every pane)", () => {
    setup();
    expect(screen.getByText("claude")).toBeInTheDocument();
    expect(screen.getByText("Claude Code", { exact: false })).toBeInTheDocument();
    expect(screen.queryByText("bridgemind-api", { exact: false })).not.toBeInTheDocument();
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

  it("shows the git branch as a session tag when useGitBranch resolves one", () => {
    useGitBranchMock.mockReturnValue("main");
    setup();
    const tag = screen.getByLabelText("Branch main");
    expect(tag).toHaveClass("pane-header-tag");
    expect(tag.textContent).toContain("main");
  });

  it("renders no branch tag when there is none", () => {
    useGitBranchMock.mockReturnValue(null);
    setup();
    expect(screen.queryByLabelText(/^Branch /)).not.toBeInTheDocument();
  });

  describe("the branch is a tag on the session, not a dropdown", () => {
    // Founder ask, verbatim: "terminal title has a dropdown with main,
    // remove it. This must be connected to the session as a tag, that must
    // be tied to the current git branch."
    beforeEach(() => useGitBranchMock.mockReturnValue("main"));

    it("is not a control: no button, no menu semantics, no click affordance", () => {
      setup();
      const tag = screen.getByLabelText("Branch main");
      expect(tag.tagName).toBe("SPAN");
      expect(tag).not.toHaveAttribute("aria-haspopup");
      expect(tag).not.toHaveAttribute("role");
      // The old pill's `title="git branch: main"` promised something on
      // click; the hover card explains instead.
      expect(tag).not.toHaveAttribute("title");
    });

    it("carries the session's engine so the tag is tinted with the engine colour the status light gave up", () => {
      setup({ tab: tab({ engine: "codex" }) });
      expect(screen.getByLabelText("Branch main")).toHaveAttribute("data-engine", "codex");
    });
  });

  it("says a session needs attention through its light, not a second red dot", () => {
    // 2026-07-26: the latched `needsAttention` badge folded into the
    // five-state status (see state/sessions.ts's TabInfo doc). The header
    // must carry that meaning exactly once — the light — with no separate
    // attention marker beside it.
    const { rerender } = render(
      <PaneHeader
        tab={tab({ status: "thinking" })}
        projectLabel="p"
        isFocused={false}
        onFocus={() => {}}
        onClose={() => {}}
        onSplit={() => {}}
        onRename={() => {}}
      />,
    );
    expect(screen.queryByRole("status")).not.toBeInTheDocument();
    expect(document.querySelector(".pane-header-attention-dot")).toBeNull();

    rerender(
      <PaneHeader
        tab={tab({ status: "awaiting_approval" })}
        projectLabel="p"
        isFocused={false}
        onFocus={() => {}}
        onClose={() => {}}
        onSplit={() => {}}
        onRename={() => {}}
      />,
    );
    expect(document.querySelector(".pane-header-attention-dot")).toBeNull();
    expect(document.querySelector('.session-light[data-status="awaiting_approval"]')).not.toBeNull();
    expect(document.querySelector(".pane-header.has-attention")).toBeNull();
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

  describe("the five-state status light (the OmniAgent mark)", () => {
    function light() {
      return document.querySelector(".session-light")!;
    }

    it("replaces the old engine-coloured dot", () => {
      setup();
      expect(document.querySelector(".pane-header-dot")).toBeNull();
      expect(light()).toBeInTheDocument();
    });

    it("renders the mark and the animated fill the mask needs", () => {
      setup();
      expect(light().querySelector(".session-light-mark .session-light-fill")).not.toBeNull();
    });

    it.each([
      ["ready", "steady"],
      ["thinking", "sweep"],
      ["tool_execution", "chase"],
      ["awaiting_approval", "breathe"],
      ["error", "flash"],
    ] as const)("renders %s with its own colour state and its own motion (%s)", (status, motion) => {
      setup({ tab: tab({ status }) });
      expect(light()).toHaveAttribute("data-status", status);
      expect(light()).toHaveAttribute("data-motion", motion);
    });

    it("shows the neutral pre-signal mark — never green — before any status arrives", () => {
      setup({ tab: tab({ status: undefined }) });
      expect(light()).toHaveAttribute("data-status", "unknown");
      expect(light()).toHaveAttribute("data-motion", "steady");
    });

    it("explains itself to a screen reader as well as on hover", () => {
      setup({ tab: tab({ status: "awaiting_approval" }) });
      const img = screen.getByRole("img", { name: /needs approval/i });
      expect(img.getAttribute("aria-label")).toContain("approve");
    });
  });

  describe("no hover card here any more — it belongs to the sidebar's session row", () => {
    // Founder, 2026-07-26: "The hover part is currently wrong: it's not on
    // the terminal itself, but on session menu on the left." What survived
    // on this header is the status light's own explanation, which is a
    // different affordance ("on hover, it explains, of course").
    beforeEach(() => {
      vi.useFakeTimers({ shouldAdvanceTime: true });
      useGitBranchMock.mockReturnValue("main");
    });
    afterEach(() => vi.useRealTimers());

    it("opens nothing when the pointer rests on the header", () => {
      setup();
      const header = document.querySelector(".pane-header")!;
      fireEvent.mouseEnter(header);
      act(() => void vi.advanceTimersByTime(2000));
      expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
    });

    it("still explains the session's state on the light itself", () => {
      setup({ tab: tab({ status: "tool_execution" }) });
      const light = document.querySelector(".session-light")!;
      expect(light.getAttribute("title")).toContain("Running a command or writing files right now.");
    });
  });

  describe("3-dot menu (change engine / terminal theme)", () => {
    it("renders no menu trigger when neither onChangeEngine nor onChangeTheme is provided", () => {
      setup();
      expect(screen.queryByRole("button", { name: /options/i })).not.toBeInTheDocument();
    });

    it("renders the trigger and opens the menu on click", () => {
      const onChangeEngine = vi.fn();
      setup({ onChangeEngine });
      const trigger = screen.getByRole("button", { name: /options/i });
      expect(screen.queryByRole("menu")).not.toBeInTheDocument();
      fireEvent.click(trigger);
      expect(screen.getByRole("menu")).toBeInTheDocument();
      expect(trigger).toHaveAttribute("aria-expanded", "true");
    });

    it("closes the menu on a second click of the trigger", () => {
      const onChangeEngine = vi.fn();
      setup({ onChangeEngine });
      const trigger = screen.getByRole("button", { name: /options/i });
      fireEvent.click(trigger);
      fireEvent.click(trigger);
      expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    });

    it("forwards the tab's current engine/theme into the menu and calls onChangeEngine, closing the menu", () => {
      const onChangeEngine = vi.fn();
      const onChangeTheme = vi.fn();
      setup({
        tab: tab({ engine: "codex", themeId: "matrix" }),
        onChangeEngine,
        onChangeTheme,
      });
      fireEvent.click(screen.getByRole("button", { name: /options/i }));
      expect(screen.getByText("Codex (current)")).toBeInTheDocument();
      expect(screen.getByRole("button", { name: /Matrix/ })).toHaveAttribute("aria-pressed", "true");

      fireEvent.click(screen.getByText(/Restart with Claude Code/));
      expect(onChangeEngine).toHaveBeenCalledWith("claude");
      expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    });

    it("defaults an unset themeId to the standard preset when opening the menu", () => {
      setup({ tab: tab({ themeId: undefined }), onChangeTheme: vi.fn() });
      fireEvent.click(screen.getByRole("button", { name: /options/i }));
      expect(screen.getByRole("button", { name: /Standard/ })).toHaveAttribute("aria-pressed", "true");
    });

    it("clicking a theme calls onChangeTheme and closes the menu", () => {
      const onChangeTheme = vi.fn();
      setup({ onChangeTheme });
      fireEvent.click(screen.getByRole("button", { name: /options/i }));
      fireEvent.click(screen.getByText("Amber CRT"));
      expect(onChangeTheme).toHaveBeenCalledWith("amber");
      expect(screen.queryByRole("menu")).not.toBeInTheDocument();
    });
  });
});
