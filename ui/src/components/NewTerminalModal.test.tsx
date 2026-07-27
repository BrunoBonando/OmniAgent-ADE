import { describe, expect, it, vi } from "vitest";
import { render, screen, fireEvent } from "@testing-library/react";
import { NewTerminalModal } from "./NewTerminalModal";
import { initialAgentsState } from "../state/agents";
import type { SessionGroup } from "../state/sessionGroups";

const session: SessionGroup = {
  id: "g", project: "p", label: "session restore", cwd: "/p", isCurrent: true,
  tabs: Array.from({ length: 4 }, (_, i) => ({
    id: `t${i}`, project: "p", engine: "claude" as const, cwd: "/p", createdAt: i, group: "g",
  })),
};

function setup(overrides = {}) {
  const props = {
    session,
    agentState: { ...initialAgentsState, installed: new Set(["claude", "shell"] as const) },
    onCreate: vi.fn(),
    onInstallAgent: vi.fn(),
    onClose: vi.fn(),
    ...overrides,
  };
  return { ...render(<NewTerminalModal {...props} />), props };
}

describe("NewTerminalModal", () => {
  it("shows session context and slot count", () => {
    setup();
    expect(screen.getByText("New terminal")).toBeInTheDocument();
    expect(screen.getByText("in session restore · 4 of 8 used")).toBeInTheDocument();
  });

  it("pre-fills the name with the next slot number", () => {
    setup();
    expect(screen.getByRole("textbox")).toHaveValue("Terminal #5");
  });

  it("uninstalled engines are dimmed and route to install", () => {
    const { container, props } = setup();
    const row = container.querySelector(".engine-row.is-unavailable");
    expect(row).toBeInTheDocument();
    fireEvent.click(row!);
    expect(props.onInstallAgent).toHaveBeenCalled();
    expect(props.onCreate).not.toHaveBeenCalled();
  });

  it("confirms with edited name and selected engine", () => {
    const { props } = setup();
    fireEvent.change(screen.getByRole("textbox"), { target: { value: "token rotation" } });
    fireEvent.click(screen.getByText("Open terminal ⏎"));
    expect(props.onCreate).toHaveBeenCalledWith("token rotation", "claude");
  });

  it("⌘2 selects codex when installed", () => {
    const { container, props } = setup({
      agentState: { ...initialAgentsState, installed: new Set(["claude", "codex"] as const) },
    });
    fireEvent.keyDown(container.querySelector(".modal-panel")!, { key: "2", metaKey: true });
    fireEvent.keyDown(container.querySelector(".modal-panel")!, { key: "Enter" });
    expect(props.onCreate).toHaveBeenCalledWith(expect.any(String), "codex");
  });
});
