import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { SidebarTerminalRow } from "./SidebarTerminalRow";
import type { TabInfo } from "../state/sessions";

const base: TabInfo = {
  id: "t1", project: "p", engine: "claude", cwd: "/p", createdAt: 1,
  group: "g", status: "thinking",
};

describe("SidebarTerminalRow", () => {
  it("shows engine icon, display label and status mark", () => {
    const { container } = render(
      <SidebarTerminalRow tab={{ ...base, label: "token rotation" }} isActive={false} onActivate={vi.fn()} />,
    );
    expect(screen.getByText("token rotation")).toBeInTheDocument();
    expect(container.querySelector(".terminal-row-engine")).toBeInTheDocument();
    expect(container.querySelector(".session-light[data-status='thinking']")).toBeInTheDocument();
  });

  it("falls back to the engine name when unnamed", () => {
    render(<SidebarTerminalRow tab={base} isActive={false} onActivate={vi.fn()} />);
    expect(screen.getByText("claude")).toBeInTheDocument();
  });

  it("activates on click and marks the active pane", () => {
    const onActivate = vi.fn();
    const { container } = render(
      <SidebarTerminalRow tab={base} isActive={true} onActivate={onActivate} />,
    );
    expect(container.querySelector(".terminal-row.is-active")).toBeInTheDocument();
    fireEvent.click(container.querySelector(".terminal-row")!);
    expect(onActivate).toHaveBeenCalled();
  });
});
