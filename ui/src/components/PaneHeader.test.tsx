import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import PaneHeader, { HOVER_CARD_DELAY_MS } from "./PaneHeader";
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

  describe("session hover card", () => {
    // Founder ask: "for each session, have a hover with more info, like warp
    // does" + "on hover, it explains, of course" — one surface for both.
    beforeEach(() => {
      vi.useFakeTimers({ shouldAdvanceTime: true });
      useGitBranchMock.mockReturnValue("main");
    });
    afterEach(() => vi.useRealTimers());

    function hoverHeader() {
      const header = document.querySelector(".pane-header")!;
      fireEvent.mouseEnter(header);
      act(() => void vi.advanceTimersByTime(HOVER_CARD_DELAY_MS));
      return header;
    }

    it("stays closed until the pointer has actually rested on the header", () => {
      setup();
      fireEvent.mouseEnter(document.querySelector(".pane-header")!);
      act(() => void vi.advanceTimersByTime(HOVER_CARD_DELAY_MS - 50));
      expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
      act(() => void vi.advanceTimersByTime(60));
      expect(screen.getByRole("tooltip")).toBeInTheDocument();
    });

    it("explains the current status in plain language", () => {
      setup({ tab: tab({ status: "tool_execution" }) });
      hoverHeader();
      const card = screen.getByRole("tooltip");
      expect(card.textContent).toContain("Running tools");
      expect(card.textContent).toContain("Running a command or writing files right now.");
    });

    it("shows the session's folder, branch, title and engine", () => {
      setup({
        tab: tab({ label: "backend fix", cwd: "/Users/bonando/Documents/Bruno.Digital/My-Brain" }),
        projectLabel: "My-Brain",
      });
      hoverHeader();
      const card = screen.getByRole("tooltip");
      expect(card.textContent).toContain("~/Documents/Bruno.Digital/My-Brain");
      expect(card.textContent).toContain("main");
      expect(card.textContent).toContain("backend fix");
      expect(card.textContent).toContain("Claude Code");
    });

    it("says so when the session was reattached to a still-running engine", () => {
      setup({ tab: tab({ restored: true }) });
      hoverHeader();
      expect(screen.getByRole("tooltip").textContent).toContain("Restored");
    });

    it("does not say 'Restored' for an ordinary fresh session", () => {
      setup();
      hoverHeader();
      expect(screen.getByRole("tooltip").textContent).not.toContain("Restored");
    });

    it("invents no diff stat — Warp's `+12891` has no data behind it here yet", () => {
      setup();
      hoverHeader();
      expect(screen.getByRole("tooltip").textContent).not.toMatch(/[+-]\d/);
    });

    it("closes as soon as the pointer leaves", () => {
      setup();
      const header = hoverHeader();
      fireEvent.mouseLeave(header);
      expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
    });

    it("gets out of the way the moment the header is pressed (that press may start a pane drag)", () => {
      setup();
      const header = hoverHeader();
      fireEvent.mouseDown(header);
      expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
    });

    it("does not hover over its own rename input", () => {
      setup();
      hoverHeader();
      // The card is open and echoes the session title, so target the
      // header's own label element rather than the text.
      fireEvent.doubleClick(document.querySelector(".pane-header-label")!);
      expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
    });

    it("does not fight the 3-dot menu for the same space", () => {
      setup({ onChangeEngine: vi.fn() });
      hoverHeader();
      fireEvent.click(screen.getByRole("button", { name: /options/i }));
      expect(screen.queryByRole("tooltip")).not.toBeInTheDocument();
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
