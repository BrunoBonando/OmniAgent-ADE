// The sidebar's top control: which workspace am I in, and how do I leave it.
import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { WorkspaceSwitcher } from "./WorkspaceSwitcher";

describe("WorkspaceSwitcher", () => {
  it("shows active workspace name, path and WORKSPACE microlabel", () => {
    render(
      <WorkspaceSwitcher
        project={{ id: "omni", label: "OmniAgent", path: "/u/b/OmniAgent-ADE" }}
        open={false}
        onToggle={vi.fn()}
      />,
    );
    expect(screen.getByText("OmniAgent")).toBeInTheDocument();
    expect(screen.getByText("/u/b/OmniAgent-ADE")).toBeInTheDocument();
    expect(screen.getByText("WORKSPACE")).toBeInTheDocument();
  });

  it("falls back when no workspace is open", () => {
    render(<WorkspaceSwitcher project={null} open={false} onToggle={vi.fn()} />);
    expect(screen.getByText("No workspace")).toBeInTheDocument();
    expect(screen.getByText("choose or add one")).toBeInTheDocument();
  });

  it("toggles the menu on click", () => {
    const onToggle = vi.fn();
    render(
      <WorkspaceSwitcher
        project={{ id: "omni", label: "OmniAgent", path: null }}
        open={false}
        onToggle={onToggle}
      />,
    );
    fireEvent.click(screen.getByRole("button"));
    expect(onToggle).toHaveBeenCalled();
  });
});
