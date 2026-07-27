// ⌘N -> "Session" (Task 10): one prompt that becomes the session's name,
// a layout picked as a thumbnail, and one engine per terminal. Mocks
// `@tauri-apps/plugin-dialog`'s `open()` the same way
// `NewWorkspaceModal.test.tsx` does, and `lib/tauri` for the footer's brain
// count.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { AgentsState } from "../state/agents";
import type { ProjectInfo } from "../state/sessions";

const { openMock } = vi.hoisted(() => ({ openMock: vi.fn() }));
const { ingestionStatusMock } = vi.hoisted(() => ({ ingestionStatusMock: vi.fn() }));

vi.mock("@tauri-apps/plugin-dialog", () => ({ open: openMock }));
vi.mock("../lib/tauri", () => ({ ingestionStatus: ingestionStatusMock }));

const { default: NewSessionModal } = await import("./NewSessionModal");

const PROJECT: ProjectInfo = { id: "ade", label: "OmniAgent ADE", path: "/Users/bruno/code/ade" };

const AGENTS: AgentsState = {
  installed: new Set(["claude", "codex"] as const),
  lastSelected: ["claude"],
  installing: new Map(),
};

function setup(project: ProjectInfo = PROJECT, agentState: AgentsState = AGENTS) {
  const onCreate = vi.fn();
  const onClose = vi.fn();
  render(<NewSessionModal project={project} agentState={agentState} onCreate={onCreate} onClose={onClose} />);
  return { onCreate, onClose, dialog: screen.getByRole("dialog", { name: "New session" }) };
}

/** The dialog's terminal count, read off the engine pickers themselves —
 * the thing the layout is actually for. */
function slotTriggers(): HTMLElement[] {
  return screen.getAllByRole("button", { name: /^Terminal \d+ engine:/ });
}

function promptField(): HTMLInputElement {
  return screen.getByLabelText("What are you doing?") as HTMLInputElement;
}

beforeEach(() => {
  openMock.mockReset();
  ingestionStatusMock.mockReset().mockResolvedValue({
    running: false,
    projects_total: 0,
    projects_done: 0,
    total_nodes: 41208,
  });
});

describe("NewSessionModal — the prompt", () => {
  it("asks what you're doing, and says what the answer is used for", () => {
    setup();
    expect(screen.getByText("What are you doing?")).toBeInTheDocument();
    expect(
      screen.getByText("Becomes the session name and the first prompt. Leave empty for a bare terminal."),
    ).toBeInTheDocument();
  });

  it("focuses the prompt, so the dialog opens ready to be typed into", () => {
    setup();
    expect(promptField()).toHaveFocus();
  });

  it("says how many terminals boot, and on how much brain", async () => {
    const { dialog } = setup();
    await waitFor(() => expect(dialog.textContent).toContain("2 terminals boot briefed on 41,208 brain nodes"));
  });
});

describe("NewSessionModal — layout", () => {
  it("offers every preset as a shaped thumbnail", () => {
    setup();
    for (const badge of ["1", "1×2", "2×2", "2×3", "2×4"]) {
      expect(screen.getByRole("button", { name: badge })).toBeInTheDocument();
    }
    expect(screen.getByRole("button", { name: "1×2" })).toHaveAttribute("aria-pressed", "true");
    expect(screen.getByText("max 8 terminals per session")).toBeInTheDocument();
  });

  it("layout picks resize the slot grid", () => {
    setup();
    expect(slotTriggers()).toHaveLength(2);
    fireEvent.click(screen.getByRole("button", { name: "2×2" }));
    expect(slotTriggers()).toHaveLength(4);
    fireEvent.click(screen.getByRole("button", { name: "1" }));
    expect(slotTriggers()).toHaveLength(1);
  });

  it("keeps the engines already picked when the grid grows", () => {
    setup();
    fireEvent.click(slotTriggers()[1]);
    fireEvent.click(screen.getByRole("option", { name: "Codex" }));
    fireEvent.click(screen.getByRole("button", { name: "2×2" }));
    expect(slotTriggers().map((b) => b.getAttribute("aria-label"))).toEqual([
      "Terminal 1 engine: Claude Code",
      "Terminal 2 engine: Codex",
      "Terminal 3 engine: Claude Code",
      "Terminal 4 engine: Claude Code",
    ]);
  });
});

describe("NewSessionModal — engine per terminal", () => {
  it("starts every terminal on the default engine", () => {
    setup();
    expect(slotTriggers().map((b) => b.getAttribute("aria-label"))).toEqual([
      "Terminal 1 engine: Claude Code",
      "Terminal 2 engine: Claude Code",
    ]);
  });

  it("slot picker swaps one terminal's engine", () => {
    setup();
    fireEvent.click(slotTriggers()[1]);
    fireEvent.click(screen.getByRole("option", { name: "Codex" }));
    expect(slotTriggers().map((b) => b.getAttribute("aria-label"))).toEqual([
      "Terminal 1 engine: Claude Code",
      "Terminal 2 engine: Codex",
    ]);
    expect(screen.queryByRole("listbox")).not.toBeInTheDocument(); // picking closes it
  });

  it("only offers engines this machine can actually run, plus shell", () => {
    setup();
    fireEvent.click(slotTriggers()[0]);
    expect(screen.getAllByRole("option").map((o) => o.textContent)).toEqual(["Claude Code", "Codex", "Shell"]);
  });

  it("falls back to shell alone when nothing is installed", () => {
    setup(PROJECT, { installed: new Set(), lastSelected: [], installing: new Map() });
    expect(slotTriggers()[0]).toHaveAttribute("aria-label", "Terminal 1 engine: Shell");
    fireEvent.click(slotTriggers()[0]);
    expect(screen.getAllByRole("option").map((o) => o.textContent)).toEqual(["Shell"]);
  });

  it("Escape closes the open menu without closing the dialog", () => {
    const { onClose } = setup();
    fireEvent.click(slotTriggers()[0]);
    fireEvent.keyDown(screen.getByRole("listbox"), { key: "Escape" });
    expect(screen.queryByRole("listbox")).not.toBeInTheDocument();
    expect(onClose).not.toHaveBeenCalled();
  });

  it("a click elsewhere in the dialog closes the menu", () => {
    setup();
    fireEvent.click(slotTriggers()[0]);
    expect(screen.getByRole("listbox")).toBeInTheDocument();
    fireEvent.mouseDown(promptField());
    expect(screen.queryByRole("listbox")).not.toBeInTheDocument();
  });
});

describe("NewSessionModal — the folder stays inside the project", () => {
  it("starts in the project's own folder", () => {
    setup();
    expect(screen.getByText("/Users/bruno/code/ade")).toBeInTheDocument();
  });

  it("accepts a subfolder", async () => {
    openMock.mockResolvedValue("/Users/bruno/code/ade/ui/src");
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Change" }));
    await waitFor(() => expect(screen.getByText("/Users/bruno/code/ade/ui/src")).toBeInTheDocument());
  });

  it("opens the picker inside the project rather than anywhere on disk", async () => {
    openMock.mockResolvedValue(null);
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Change" }));
    await waitFor(() =>
      expect(openMock).toHaveBeenCalledWith(expect.objectContaining({ defaultPath: "/Users/bruno/code/ade" })),
    );
  });

  it("refuses a folder outside the project, and says why", async () => {
    openMock.mockResolvedValue("/etc");
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Change" }));
    expect(await screen.findByText(/outside this project/)).toBeInTheDocument();
    expect(screen.getByText("/Users/bruno/code/ade")).toBeInTheDocument(); // unchanged
  });

  it("falls back to the project id when it has no path on disk", () => {
    setup({ id: "/Users/bruno/code/other", label: "Other", path: null });
    expect(screen.getByText("/Users/bruno/code/other")).toBeInTheDocument();
  });
});

describe("NewSessionModal — creating", () => {
  it("confirm passes (project, cwd, slots, prompt)", () => {
    const { onCreate } = setup();
    fireEvent.change(promptField(), { target: { value: "coalesce refresh-token rotation" } });
    fireEvent.click(slotTriggers()[1]);
    fireEvent.click(screen.getByRole("option", { name: "Shell" }));
    fireEvent.click(screen.getByRole("button", { name: /Start session/ }));
    expect(onCreate).toHaveBeenCalledWith(
      PROJECT,
      "/Users/bruno/code/ade",
      ["claude", "shell"],
      "coalesce refresh-token rotation",
    );
  });

  it("an empty prompt is still a session — a bare pair of terminals", () => {
    const { onCreate } = setup();
    fireEvent.click(screen.getByRole("button", { name: /Start session/ }));
    expect(onCreate).toHaveBeenCalledWith(PROJECT, "/Users/bruno/code/ade", ["claude", "claude"], "");
  });

  it("creates in the chosen subfolder", async () => {
    openMock.mockResolvedValue("/Users/bruno/code/ade/crates");
    const { onCreate } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Change" }));
    await waitFor(() => expect(screen.getByText("/Users/bruno/code/ade/crates")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: /Start session/ }));
    expect(onCreate).toHaveBeenCalledWith(PROJECT, "/Users/bruno/code/ade/crates", ["claude", "claude"], "");
  });
});

describe("NewSessionModal — keyboard", () => {
  it("Enter from the prompt starts the session", () => {
    const { onCreate } = setup();
    fireEvent.change(promptField(), { target: { value: "ship the thing" } });
    fireEvent.keyDown(promptField(), { key: "Enter" });
    expect(onCreate).toHaveBeenCalledWith(PROJECT, "/Users/bruno/code/ade", ["claude", "claude"], "ship the thing");
  });

  it("typing digits into the prompt does not change layout", () => {
    setup();
    fireEvent.keyDown(promptField(), { key: "3" });
    fireEvent.change(promptField(), { target: { value: "fix issue 2" } });
    fireEvent.keyDown(promptField(), { key: "2" });
    expect(slotTriggers()).toHaveLength(2);
    expect(screen.getByRole("button", { name: "1×2" })).toHaveAttribute("aria-pressed", "true");
    expect(promptField().value).toBe("fix issue 2");
  });

  it("picks a layout by number once the prompt isn't focused", () => {
    const { dialog } = setup();
    promptField().blur();
    fireEvent.keyDown(dialog, { key: "3" }); // the third preset — 4 terminals
    expect(slotTriggers()).toHaveLength(4);
    expect(screen.getByRole("button", { name: "2×2" })).toHaveAttribute("aria-pressed", "true");
  });

  it("Enter on a slot trigger opens its menu instead of submitting", () => {
    const { onCreate } = setup();
    const slot = slotTriggers()[0];
    slot.focus();
    fireEvent.keyDown(slot, { key: "Enter" });
    expect(onCreate).not.toHaveBeenCalled();
  });

  it("Escape cancels", () => {
    const { onClose, onCreate, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onCreate).not.toHaveBeenCalled();
  });
});
