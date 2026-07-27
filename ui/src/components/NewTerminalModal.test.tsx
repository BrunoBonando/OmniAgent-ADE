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

// Same bug class Task 10 fixed in `NewSessionModal`: every keystroke this
// dialog understands hangs off ONE `onKeyDown` on the panel, which only sees
// events raised inside the panel's own subtree. Nothing in here was
// focusable except the name input and the two footer buttons, so a click on
// an engine row (a plain div) dropped focus on <body> and killed
// Enter/Escape/⌘1/⌘2/⌘3/⌘0 for the rest of the dialog's life — with the
// modal's PRIMARY flow, ⌘T -> click an engine -> Enter, being exactly the
// sequence that triggered it.
describe("NewTerminalModal — focus and keyboard reachability", () => {
  it("focuses (not merely selects) the name input on mount", () => {
    setup();
    expect(screen.getByRole("textbox")).toHaveFocus();
  });

  it("gives the panel a focus backstop so a click can never strand focus outside it", () => {
    const { container } = setup();
    expect(container.querySelector(".modal-panel")).toHaveAttribute("tabindex", "-1");
  });

  it("engine rows are focusable and sit in a listbox", () => {
    const { container } = setup();
    expect(container.querySelector(".engine-row-list")).toHaveAttribute("role", "listbox");
    for (const row of container.querySelectorAll(".engine-row")) {
      expect(row).toHaveAttribute("tabindex", "0");
    }
  });

  it("Enter still creates after focus lands on an engine row — the ⌘T -> click engine -> Enter flow", () => {
    const { container, props } = setup();
    // jsdom's `fireEvent.click` doesn't move focus the way a real browser
    // does, so the browser's click-to-focus is simulated explicitly: with
    // `tabIndex={0}` the row itself takes focus, which is where the Enter
    // then has to be handled.
    const row = container.querySelectorAll<HTMLElement>(".engine-row")[0];
    fireEvent.click(row);
    row.focus();
    expect(row).toHaveFocus();

    fireEvent.keyDown(document.activeElement!, { key: "Enter" });

    expect(props.onCreate).toHaveBeenCalledWith("Terminal #5", "claude");
  });

  it("Space on a focused engine row picks that engine without creating anything", () => {
    const { container, props } = setup({
      agentState: { ...initialAgentsState, installed: new Set(["claude", "codex"] as const) },
    });
    const rows = container.querySelectorAll<HTMLElement>(".engine-row");
    const codex = [...rows].find((r) => r.textContent?.includes("Codex"))!;
    codex.focus();
    fireEvent.keyDown(codex, { key: " " });

    expect(props.onCreate).not.toHaveBeenCalled();
    expect(codex).toHaveAttribute("aria-selected", "true");
    // …and the footer button then opens the engine Space just picked.
    fireEvent.click(screen.getByText("Open terminal ⏎"));
    expect(props.onCreate).toHaveBeenCalledWith("Terminal #5", "codex");
  });

  it("Enter on a focused uninstalled engine row routes to install, never to create", () => {
    const { container, props } = setup();
    const row = container.querySelector<HTMLElement>(".engine-row.is-unavailable")!;
    row.focus();
    fireEvent.keyDown(row, { key: "Enter" });

    expect(props.onInstallAgent).toHaveBeenCalled();
    expect(props.onCreate).not.toHaveBeenCalled();
  });
});
