// ⌘N -> "Session": the same dialog as New Workspace, scoped to the project
// you're already in. Mocks `@tauri-apps/plugin-dialog`'s `open()` the same
// way `NewWorkspaceModal.test.tsx` does.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo } from "../state/sessions";

const { openMock } = vi.hoisted(() => ({ openMock: vi.fn() }));

vi.mock("@tauri-apps/plugin-dialog", () => ({ open: openMock }));

const { default: NewSessionModal } = await import("./NewSessionModal");

const PROJECT: ProjectInfo = { id: "ade", label: "OmniAgent ADE", path: "/Users/bruno/code/ade" };

function setup(project: ProjectInfo = PROJECT) {
  const onCreate = vi.fn();
  const onClose = vi.fn();
  render(<NewSessionModal project={project} onCreate={onCreate} onClose={onClose} />);
  return { onCreate, onClose, dialog: screen.getByRole("dialog", { name: "New Session" }) };
}

beforeEach(() => {
  openMock.mockReset();
});

describe("NewSessionModal — rendering", () => {
  it("keeps New Workspace's LAYOUT and AI AGENTS sections, and scopes the folder to this project", () => {
    setup();
    expect(screen.getByText("LAYOUT")).toBeInTheDocument();
    expect(screen.getByText("AI AGENTS")).toBeInTheDocument();
    expect(screen.getByText("FOLDER — OMNIAGENT ADE")).toBeInTheDocument();
    // No project-name field and no "choose a folder first" state: a session
    // always already has somewhere to run.
    expect(screen.queryByLabelText(/project name/i)).not.toBeInTheDocument();
  });

  it("starts in the project's own folder", () => {
    setup();
    expect(screen.getByText("/Users/bruno/code/ade")).toBeInTheDocument();
    expect(screen.getByText(/Runs in the project folder/)).toBeInTheDocument();
  });

  it("offers all four layout presets, side-by-side selected by default", () => {
    setup();
    for (const preset of [2, 4, 6, 8]) {
      expect(screen.getByRole("button", { name: new RegExp(`^${preset}$`) })).toBeInTheDocument();
    }
    expect(screen.getByText("Side-by-side split")).toBeInTheDocument();
  });

  it("checks only Claude by default, and can create immediately", () => {
    setup();
    expect(screen.getByRole("checkbox", { name: /Claude Code/ })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: /Codex/ })).not.toBeChecked();
    expect(screen.getByRole("button", { name: "Create Session" })).toBeEnabled();
  });
});

describe("NewSessionModal — the folder stays inside the project", () => {
  it("accepts a subfolder and shows it relative to the project", async () => {
    openMock.mockResolvedValue("/Users/bruno/code/ade/ui/src");
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Browse" }));
    await waitFor(() => expect(screen.getByText("ui/src")).toBeInTheDocument());
    expect(screen.getByText(/Runs in this subfolder/)).toBeInTheDocument();
  });

  it("opens the picker inside the project rather than anywhere on disk", async () => {
    openMock.mockResolvedValue(null);
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Browse" }));
    await waitFor(() =>
      expect(openMock).toHaveBeenCalledWith(expect.objectContaining({ defaultPath: "/Users/bruno/code/ade" })),
    );
  });

  it("refuses a folder outside the project, and says why", async () => {
    openMock.mockResolvedValue("/etc");
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Browse" }));
    expect(await screen.findByText(/outside this project/)).toBeInTheDocument();
    expect(screen.getByText("/Users/bruno/code/ade")).toBeInTheDocument(); // unchanged
  });

  it("refuses a sibling folder whose path merely starts the same way", async () => {
    openMock.mockResolvedValue("/Users/bruno/code/ade-scratch");
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Browse" }));
    expect(await screen.findByText(/outside this project/)).toBeInTheDocument();
  });

  it("goes back to the project folder in one click", async () => {
    openMock.mockResolvedValue("/Users/bruno/code/ade/ui");
    setup();
    fireEvent.click(screen.getByRole("button", { name: "Browse" }));
    await waitFor(() => expect(screen.getByText("ui")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "Use the project folder" }));
    expect(screen.getByText("/Users/bruno/code/ade")).toBeInTheDocument();
  });

  it("falls back to the project id when it has no path on disk", () => {
    setup({ id: "/Users/bruno/code/other", label: "Other", path: null });
    expect(screen.getByText("/Users/bruno/code/other")).toBeInTheDocument();
  });
});

describe("NewSessionModal — creating", () => {
  it("hands back the project, the cwd, the checked engines in ENGINES order, and the layout", () => {
    const { onCreate } = setup();
    fireEvent.click(screen.getByRole("checkbox", { name: /Shell/ }));
    fireEvent.click(screen.getByRole("button", { name: "6" }));
    fireEvent.click(screen.getByRole("button", { name: "Create Session" }));
    expect(onCreate).toHaveBeenCalledWith(PROJECT, "/Users/bruno/code/ade", ["claude", "shell"], 6);
  });

  it("creates in the chosen subfolder", async () => {
    openMock.mockResolvedValue("/Users/bruno/code/ade/crates");
    const { onCreate } = setup();
    fireEvent.click(screen.getByRole("button", { name: "Browse" }));
    await waitFor(() => expect(screen.getByText("crates")).toBeInTheDocument());
    fireEvent.click(screen.getByRole("button", { name: "Create Session" }));
    expect(onCreate).toHaveBeenCalledWith(PROJECT, "/Users/bruno/code/ade/crates", ["claude"], 2);
  });

  it("cannot create with no agent checked", () => {
    const { onCreate } = setup();
    fireEvent.click(screen.getByRole("checkbox", { name: /Claude Code/ }));
    expect(screen.getByRole("button", { name: "Create Session" })).toBeDisabled();
    expect(onCreate).not.toHaveBeenCalled();
  });
});

describe("NewSessionModal — keyboard", () => {
  it("focuses itself and creates on Enter", () => {
    const { onCreate, dialog } = setup();
    expect(dialog).toHaveFocus();
    fireEvent.keyDown(dialog, { key: "Enter" });
    expect(onCreate).toHaveBeenCalledWith(PROJECT, "/Users/bruno/code/ade", ["claude"], 2);
  });

  it("picks a layout by number", () => {
    const { onCreate, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "3" }); // the third preset — 6
    expect(screen.getByText("2×3 grid layout")).toBeInTheDocument();
    fireEvent.keyDown(dialog, { key: "Enter" });
    expect(onCreate).toHaveBeenCalledWith(PROJECT, "/Users/bruno/code/ade", ["claude"], 6);
  });

  it("Escape cancels", () => {
    const { onClose, onCreate, dialog } = setup();
    fireEvent.keyDown(dialog, { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(onCreate).not.toHaveBeenCalled();
  });

  it("still creates on Enter after an agent checkbox has been clicked", () => {
    // Caught in a real browser: focus sits on the checkbox after clicking
    // it, and blanket-ignoring keys from an <input> made Enter a dead key
    // right at the end of the flow.
    const { onCreate } = setup();
    const codex = screen.getByRole("checkbox", { name: /Codex/ });
    fireEvent.click(codex);
    fireEvent.keyDown(codex, { key: "Enter" });
    expect(onCreate).toHaveBeenCalledWith(PROJECT, "/Users/bruno/code/ade", ["claude", "codex"], 2);
  });

  it("leaves Space to the checkbox it belongs to", () => {
    const { onCreate } = setup();
    fireEvent.keyDown(screen.getByRole("checkbox", { name: /Codex/ }), { key: " " });
    expect(onCreate).not.toHaveBeenCalled();
  });
});
