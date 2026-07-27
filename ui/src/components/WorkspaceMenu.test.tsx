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

// Since Task 3 retired the sidebar's per-project rows, this dropdown is the
// ONLY direct path to switching, adding or importing a workspace — so rows
// that were `<div role="menuitem" onClick>` with no `tabIndex` and no key
// handler made the app's primary navigation surface reachable by mouse only.
describe("WorkspaceMenu — keyboard reachability", () => {
  function rows(container: HTMLElement) {
    return [...container.querySelectorAll<HTMLElement>('[role="menuitem"]')];
  }

  it("every menuitem is in the tab order", () => {
    const { container } = setup();
    // Two workspaces + New workspace + Import projects….
    expect(rows(container)).toHaveLength(4);
    for (const row of rows(container)) expect(row).toHaveAttribute("tabindex", "0");
  });

  it("Enter on a focused workspace row selects it, exactly like a click", () => {
    const { container, props } = setup();
    const voice = rows(container).find((r) => r.textContent?.includes("Voice"))!;
    voice.focus();
    fireEvent.keyDown(voice, { key: "Enter" });

    expect(props.onSelect).toHaveBeenCalledWith(projects[1]);
    expect(props.onClose).toHaveBeenCalled();
  });

  it("Space activates too, and stops the page scrolling under the menu", () => {
    const { container, props } = setup();
    const voice = rows(container).find((r) => r.textContent?.includes("Voice"))!;
    voice.focus();
    const notCancelled = fireEvent.keyDown(voice, { key: " " });

    expect(props.onSelect).toHaveBeenCalledWith(projects[1]);
    expect(notCancelled).toBe(false); // preventDefault() was called
  });

  it("Enter on the active row closes without re-selecting, exactly like its click", () => {
    const { container, props } = setup();
    const active = container.querySelector<HTMLElement>(".workspace-menu-row.is-active")!;
    active.focus();
    fireEvent.keyDown(active, { key: "Enter" });

    expect(props.onSelect).not.toHaveBeenCalled();
    expect(props.onClose).toHaveBeenCalled();
  });

  it("Enter and Space fire New workspace and Import projects…", () => {
    const { container, props } = setup();
    const [, , newWorkspace, importRow] = rows(container);
    newWorkspace.focus();
    fireEvent.keyDown(newWorkspace, { key: "Enter" });
    expect(props.onNewWorkspace).toHaveBeenCalled();

    importRow.focus();
    fireEvent.keyDown(importRow, { key: " " });
    expect(props.onImport).toHaveBeenCalled();
  });

  it("other keys are left alone — typing in a menu never selects a workspace", () => {
    const { container, props } = setup();
    const voice = rows(container).find((r) => r.textContent?.includes("Voice"))!;
    voice.focus();
    fireEvent.keyDown(voice, { key: "v" });
    fireEvent.keyDown(voice, { key: "ArrowDown" });

    expect(props.onSelect).not.toHaveBeenCalled();
    expect(props.onClose).not.toHaveBeenCalled();
  });

  it("a key aimed at the nested ⋯ button doesn't also fire its row", () => {
    // The manage button is a real <button>: Enter on it becomes a click,
    // which would bubble straight back into the row's own handler and
    // switch workspace behind the settings sheet the user just asked for.
    const { container, props } = setup();
    const manage = container.querySelector<HTMLElement>(".workspace-menu-manage")!;
    fireEvent.keyDown(manage, { key: "Enter" });

    expect(props.onSelect).not.toHaveBeenCalled();
    expect(props.onClose).not.toHaveBeenCalled();
  });
});
