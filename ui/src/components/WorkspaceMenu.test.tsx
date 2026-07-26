import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { WorkspaceMenu, sessionCountLabel } from "./WorkspaceMenu";
import type { ProjectInfo } from "../state/sessions";

const projects: ProjectInfo[] = [
  { id: "omni", label: "OmniAgent", path: "/u/b/OmniAgent-ADE" },
  { id: "voice", label: "Voice", path: "/u/b/voice-latency" },
];

function setup(overrides: Partial<Parameters<typeof WorkspaceMenu>[0]> = {}) {
  const props = {
    projects,
    activeProjectId: "omni",
    sessionCounts: new Map([["omni", 3], ["voice", 1]]),
    onSelect: vi.fn(),
    onNewWorkspace: vi.fn(),
    onImport: vi.fn(),
    onManage: vi.fn(),
    onClose: vi.fn(),
    ...overrides,
  };
  return { ...render(<WorkspaceMenu {...props} />), props };
}

describe("sessionCountLabel", () => {
  it("pluralizes", () => {
    expect(sessionCountLabel(0)).toBe("no sessions");
    expect(sessionCountLabel(1)).toBe("1 session");
    expect(sessionCountLabel(3)).toBe("3 sessions");
  });
});

describe("WorkspaceMenu", () => {
  it("lists workspaces with counts, active row checked", () => {
    const { container } = setup();
    expect(screen.getByText("WORKSPACES")).toBeInTheDocument();
    expect(screen.getByText("3 sessions")).toBeInTheDocument();
    expect(screen.getByText("1 session")).toBeInTheDocument();
    const active = container.querySelector(".workspace-menu-row.is-active");
    expect(active).toHaveTextContent("OmniAgent");
  });

  it("selects an inactive workspace and closes", () => {
    const { props } = setup();
    fireEvent.click(screen.getByText("Voice"));
    expect(props.onSelect).toHaveBeenCalledWith(projects[1]);
    expect(props.onClose).toHaveBeenCalled();
  });

  it("New workspace and Import rows fire and close", () => {
    const { props } = setup();
    fireEvent.click(screen.getByText("New workspace"));
    expect(props.onNewWorkspace).toHaveBeenCalled();
    fireEvent.click(screen.getByText("Import projects…"));
    expect(props.onImport).toHaveBeenCalled();
  });

  it("backdrop click and Escape close without selecting", () => {
    const { container, props } = setup();
    fireEvent.mouseDown(container.querySelector(".workspace-menu-backdrop")!);
    expect(props.onClose).toHaveBeenCalledTimes(1);
    expect(props.onSelect).not.toHaveBeenCalled();
  });
});
