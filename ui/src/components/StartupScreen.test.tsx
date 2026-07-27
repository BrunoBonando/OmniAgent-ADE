import { act, fireEvent, render, screen } from "@testing-library/react";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo } from "../state/sessions";
import StartupScreen from "./StartupScreen";

const projects: ProjectInfo[] = [
  { id: "alpha", label: "Alpha", path: "/work/alpha" },
  { id: "beta", label: "Beta", path: "/work/beta" },
];

describe("StartupScreen", () => {
  afterEach(() => {
    vi.useRealTimers();
  });

  it("shows only the OmniAgent loading state while metadata is pending", () => {
    render(
      <StartupScreen loading projects={[]} onSelectWorkspace={vi.fn()} onStartFromScratch={vi.fn()} />,
    );

    expect(screen.getByText("Loading...")).toBeInTheDocument();
    expect(screen.queryByRole("button")).not.toBeInTheDocument();
  });

  it("offers creation first and selects an existing workspace", () => {
    const onSelectWorkspace = vi.fn();
    const onStartFromScratch = vi.fn();
    render(
      <StartupScreen
        loading={false}
        projects={projects}
        onSelectWorkspace={onSelectWorkspace}
        onStartFromScratch={onStartFromScratch}
      />,
    );

    const buttons = screen.getAllByRole("button");
    expect(buttons.map((button) => button.textContent)).toEqual([
      expect.stringContaining("Start from scratch"),
      expect.stringContaining("Alpha"),
      expect.stringContaining("Beta"),
    ]);

    fireEvent.click(screen.getByRole("button", { name: /Alpha/ }));
    expect(onSelectWorkspace).toHaveBeenCalledWith(projects[0]);

    fireEvent.click(screen.getByRole("button", { name: /Start from scratch/ }));
    expect(onStartFromScratch).toHaveBeenCalledOnce();
  });

  it("moves focus through workspace choices with arrow keys", () => {
    render(
      <StartupScreen loading={false} projects={projects} onSelectWorkspace={vi.fn()} onStartFromScratch={vi.fn()} />,
    );
    const start = screen.getByRole("button", { name: /Start from scratch/ });
    const alpha = screen.getByRole("button", { name: /Alpha/ });

    start.focus();
    fireEvent.keyDown(start, { key: "ArrowRight" });
    expect(alpha).toHaveFocus();
  });

  it("keeps the loading overlay visible for at least 3 seconds", () => {
    vi.useFakeTimers();
    const { rerender } = render(
      <StartupScreen loading projects={[]} onSelectWorkspace={vi.fn()} onStartFromScratch={vi.fn()} />,
    );

    rerender(
      <StartupScreen
        loading={false}
        projects={projects}
        onSelectWorkspace={vi.fn()}
        onStartFromScratch={vi.fn()}
      />,
    );

    expect(screen.getByText("Loading...")).toBeInTheDocument();
    act(() => vi.advanceTimersByTime(2999));
    expect(screen.getByText("Loading...")).toBeInTheDocument();
    act(() => vi.advanceTimersByTime(1));
    expect(screen.queryByText("Loading...")).not.toBeInTheDocument();
  });
});
