import { fireEvent, render, screen } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import ProjectMenu from "./ProjectMenu";
import type { ProjectInfo } from "../state/sessions";

const PROJECT: ProjectInfo = { id: "OmniAgent-ADE", label: "OmniAgent-ADE", path: "/tmp/OmniAgent-ADE" };

function setup(overrides: Partial<Parameters<typeof ProjectMenu>[0]> = {}) {
  const onTogglePause = vi.fn();
  const onReingest = vi.fn();
  const onRename = vi.fn();
  const onClose = vi.fn();
  render(
    <ProjectMenu
      project={PROJECT}
      paused={false}
      busy={false}
      onTogglePause={onTogglePause}
      onReingest={onReingest}
      onRename={onRename}
      onClose={onClose}
      {...overrides}
    />,
  );
  return { onTogglePause, onReingest, onRename, onClose };
}

describe("ProjectMenu — rename (closes the root cause of a stale project label)", () => {
  it("double-clicking the title opens an inline rename input pre-filled with the current label", () => {
    setup();
    fireEvent.doubleClick(screen.getByText("OmniAgent-ADE"));
    expect(screen.getByDisplayValue("OmniAgent-ADE")).toBeInTheDocument();
  });

  it("commits a new label on Enter, trimmed, and closes the whole menu", () => {
    const { onRename, onClose } = setup();
    fireEvent.doubleClick(screen.getByText("OmniAgent-ADE"));
    const input = screen.getByDisplayValue("OmniAgent-ADE");
    fireEvent.change(input, { target: { value: "  OmniAgent  " } });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onRename).toHaveBeenCalledWith("OmniAgent");
    expect(onClose).toHaveBeenCalled();
  });

  it("commits on blur too", () => {
    const { onRename } = setup();
    fireEvent.doubleClick(screen.getByText("OmniAgent-ADE"));
    fireEvent.change(screen.getByDisplayValue("OmniAgent-ADE"), { target: { value: "New Name" } });
    fireEvent.blur(screen.getByDisplayValue("New Name"));
    expect(onRename).toHaveBeenCalledWith("New Name");
  });

  it("cancels on Escape without calling onRename", () => {
    const { onRename } = setup();
    fireEvent.doubleClick(screen.getByText("OmniAgent-ADE"));
    const input = screen.getByDisplayValue("OmniAgent-ADE");
    fireEvent.change(input, { target: { value: "should not stick" } });
    fireEvent.keyDown(input, { key: "Escape" });
    expect(onRename).not.toHaveBeenCalled();
    expect(screen.getByText("OmniAgent-ADE")).toBeInTheDocument();
  });

  it("does not call onRename for a blank name — reverts to showing the title", () => {
    const { onRename, onClose } = setup();
    fireEvent.doubleClick(screen.getByText("OmniAgent-ADE"));
    const input = screen.getByDisplayValue("OmniAgent-ADE");
    fireEvent.change(input, { target: { value: "   " } });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(onRename).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByText("OmniAgent-ADE")).toBeInTheDocument();
  });

  it("does not call onRename when the value is unchanged", () => {
    const { onRename } = setup();
    fireEvent.doubleClick(screen.getByText("OmniAgent-ADE"));
    fireEvent.keyDown(screen.getByDisplayValue("OmniAgent-ADE"), { key: "Enter" });
    expect(onRename).not.toHaveBeenCalled();
  });
});

describe("ProjectMenu — existing pause/reingest behavior stays intact", () => {
  it("still renders the stale banner, pause checkbox, and re-check button", () => {
    setup({
      staleness: { project: "OmniAgent-ADE", last_ingested: Math.floor(Date.now() / 1000) - 999999, stale: true },
    });
    expect(screen.getByText(/Stale/)).toBeInTheDocument();
    expect(screen.getByRole("checkbox")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /Re-check now/ })).toBeInTheDocument();
  });

  it("toggling pause and clicking re-check still fire their own callbacks", () => {
    const { onTogglePause, onReingest } = setup();
    fireEvent.click(screen.getByRole("checkbox"));
    expect(onTogglePause).toHaveBeenCalled();
    fireEvent.click(screen.getByRole("button", { name: /Re-check now/ }));
    expect(onReingest).toHaveBeenCalled();
  });
});
