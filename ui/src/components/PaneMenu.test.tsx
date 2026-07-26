import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";

// The menu's "Code review" entry counts this pane's uncommitted changes on
// open (founder ask, 2026-07-26), so `../lib/tauri` is mocked here the same
// way the other component suites mock it.
const { reviewStatusMock } = vi.hoisted(() => ({ reviewStatusMock: vi.fn() }));
vi.mock("../lib/tauri", () => ({ reviewStatus: reviewStatusMock }));

import PaneMenu from "./PaneMenu";

function setup(overrides: Partial<Parameters<typeof PaneMenu>[0]> = {}) {
  const onChangeEngine = vi.fn();
  const onChangeTheme = vi.fn();
  const onClose = vi.fn();
  render(
    <PaneMenu
      currentEngine="claude"
      currentThemeId="standard"
      onChangeEngine={onChangeEngine}
      onChangeTheme={onChangeTheme}
      onClose={onClose}
      {...overrides}
    />,
  );
  return { onChangeEngine, onChangeTheme, onClose };
}

describe("PaneMenu", () => {
  it("lists every engine, labeling the current one instead of offering to restart into itself", () => {
    setup({ currentEngine: "codex" });
    expect(screen.getByText("Codex (current)")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Codex \(current\)/ })).toBeDisabled();
    expect(screen.getByText(/Restart with Claude Code/)).toBeInTheDocument();
    expect(screen.getByText(/Restart with Shell/)).toBeInTheDocument();
  });

  it("clicking a different engine calls onChangeEngine with that engine and closes the menu", () => {
    const { onChangeEngine, onClose } = setup({ currentEngine: "claude" });
    fireEvent.click(screen.getByText(/Restart with Codex/));
    expect(onChangeEngine).toHaveBeenCalledWith("codex");
    expect(onClose).toHaveBeenCalled();
  });

  it("the current engine's row is disabled and does not fire onChangeEngine", () => {
    const { onChangeEngine } = setup({ currentEngine: "claude" });
    fireEvent.click(screen.getByText("Claude Code (current)"));
    expect(onChangeEngine).not.toHaveBeenCalled();
  });

  it("lists all three terminal theme presets with a checkmark on the current one", () => {
    setup({ currentThemeId: "matrix" });
    expect(screen.getByText("Standard")).toBeInTheDocument();
    expect(screen.getByText("Matrix")).toBeInTheDocument();
    expect(screen.getByText("Amber CRT")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Matrix/ })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByRole("button", { name: /Standard/ })).toHaveAttribute("aria-pressed", "false");
  });

  it("clicking a theme calls onChangeTheme with that id and closes the menu", () => {
    const { onChangeTheme, onClose } = setup({ currentThemeId: "standard" });
    fireEvent.click(screen.getByText("Amber CRT"));
    expect(onChangeTheme).toHaveBeenCalledWith("amber");
    expect(onClose).toHaveBeenCalled();
  });

  it("clicking the backdrop closes the menu without changing anything", () => {
    const { onChangeEngine, onChangeTheme, onClose } = setup();
    fireEvent.mouseDown(document.querySelector(".pane-menu-backdrop")!);
    expect(onClose).toHaveBeenCalled();
    expect(onChangeEngine).not.toHaveBeenCalled();
    expect(onChangeTheme).not.toHaveBeenCalled();
  });

  it("clicking inside the menu panel does not bubble to the backdrop", () => {
    const { onClose } = setup();
    fireEvent.mouseDown(screen.getByRole("menu"));
    expect(onClose).not.toHaveBeenCalled();
  });
});

describe("PaneMenu — the per-session code review entry", () => {
  it("is absent when the caller doesn't wire it, leaving the menu as it was", () => {
    setup();
    expect(screen.queryByText("Code review")).not.toBeInTheDocument();
    expect(reviewStatusMock).not.toHaveBeenCalled();
  });

  it("counts THIS pane's cwd, not some app-global repo", async () => {
    reviewStatusMock.mockResolvedValue({ file_count: 9 });
    setup({ repoPath: "/tmp/this-pane", onOpenCodeReview: vi.fn() });
    await waitFor(() => expect(reviewStatusMock).toHaveBeenCalledWith("/tmp/this-pane"));
  });

  it("shows the uncommitted-change count as a badge", async () => {
    reviewStatusMock.mockResolvedValue({ file_count: 9 });
    setup({ repoPath: "/tmp/repo", onOpenCodeReview: vi.fn() });
    expect(await screen.findByLabelText("9 uncommitted changes")).toHaveTextContent("9");
    expect(screen.getByText("9 uncommitted changes")).toBeInTheDocument();
  });

  it("says so plainly when there is nothing uncommitted, with no badge", async () => {
    reviewStatusMock.mockResolvedValue({ file_count: 0 });
    setup({ repoPath: "/tmp/repo", onOpenCodeReview: vi.fn() });
    expect(await screen.findByText("no uncommitted changes")).toBeInTheDocument();
    expect(screen.queryByLabelText(/uncommitted changes$/)).not.toBeInTheDocument();
  });

  it("degrades quietly when the pane's cwd isn't a git repo", async () => {
    reviewStatusMock.mockRejectedValue("/tmp/x isn't inside a git repository");
    setup({ repoPath: "/tmp/x", onOpenCodeReview: vi.fn() });
    expect(await screen.findByText("this session isn't in a git repo")).toBeInTheDocument();
  });

  it("opens the panel and closes the menu when clicked", async () => {
    reviewStatusMock.mockResolvedValue({ file_count: 3 });
    const onOpenCodeReview = vi.fn();
    const { onClose } = setup({ repoPath: "/tmp/repo", onOpenCodeReview });
    fireEvent.click(await screen.findByText("Code review"));
    expect(onOpenCodeReview).toHaveBeenCalled();
    expect(onClose).toHaveBeenCalled();
  });
});
