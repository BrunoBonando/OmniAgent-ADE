import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
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
