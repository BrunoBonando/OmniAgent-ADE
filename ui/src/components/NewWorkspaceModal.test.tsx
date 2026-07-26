// Component-level coverage for NewWorkspaceModal.tsx — the BridgeSpace
// "New Workspace" dialog rebuild (see this component's own module doc for
// the available agents). Mocks `@tauri-apps/plugin-dialog`'s `open()` and
// `../lib/tauri`'s `addProject` the same way `FileTree.test.tsx` mocks its
// own Tauri surfaces.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { Engine } from "../state/sessions";
import type { LayoutPreset } from "../state/paneGrid";
import type { ProjectInfo } from "../state/sessions";

const { openMock, addProjectMock } = vi.hoisted(() => ({
  openMock: vi.fn(),
  addProjectMock: vi.fn(),
}));

vi.mock("@tauri-apps/plugin-dialog", () => ({
  open: openMock,
}));

vi.mock("../lib/tauri", () => ({
  addProject: addProjectMock,
}));

const { default: NewWorkspaceModal } = await import("./NewWorkspaceModal");

const PROJECT: ProjectInfo = { id: "demo-workspace", label: "demo-workspace", path: "/tmp/demo-workspace" };

function setup() {
  const onCreate = vi.fn();
  const onClose = vi.fn();
  render(<NewWorkspaceModal onCreate={onCreate} onClose={onClose} />);
  return { onCreate, onClose };
}

beforeEach(() => {
  openMock.mockReset();
  addProjectMock.mockReset();
});

describe("NewWorkspaceModal — rendering", () => {
  it("shows the title and all three sections", () => {
    setup();
    expect(screen.getByRole("dialog", { name: /new workspace/i })).toBeInTheDocument();
    expect(screen.getByText("LAYOUT")).toBeInTheDocument();
    expect(screen.getByText("DIRECTORY")).toBeInTheDocument();
    expect(screen.getByText("AI AGENTS")).toBeInTheDocument();
  });

  it("shows all four layout presets, 4 selected by default with its caption", () => {
    setup();
    for (const preset of [2, 4, 6, 9]) {
      expect(screen.getByRole("button", { name: new RegExp(`^${preset}\\b`) })).toBeInTheDocument();
    }
    expect(screen.getByText("2×2 grid layout")).toBeInTheDocument();
  });

  it("checks only Claude by default among all available agents", () => {
    setup();
    const claude = screen.getByRole("checkbox", { name: /claude code/i });
    const codex = screen.getByRole("checkbox", { name: /codex/i });
    const shell = screen.getByRole("checkbox", { name: /shell/i });
    expect(claude).toBeChecked();
    expect(codex).not.toBeChecked();
    expect(shell).not.toBeChecked();
    // Exactly 5 agent checkboxes — claude, codex, shell, copilot, antigravity
    expect(screen.getAllByRole("checkbox")).toHaveLength(5);
  });

  it("Create Workspace starts disabled — no folder chosen yet", () => {
    setup();
    expect(screen.getByRole("button", { name: /create workspace/i })).toBeDisabled();
  });
});

describe("NewWorkspaceModal — layout preset selection", () => {
  it("clicking a different preset updates the selection and caption", () => {
    setup();
    fireEvent.click(screen.getByRole("button", { name: /^6\b/ }));
    expect(screen.getByText("2×3 grid layout")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /^6\b/ })).toHaveClass("is-selected");
    expect(screen.getByRole("button", { name: /^4\b/ })).not.toHaveClass("is-selected");
  });
});

describe("NewWorkspaceModal — AI Agents checklist", () => {
  it("toggling engines updates checked state and re-disables submit once none are checked", async () => {
    setup();
    openMock.mockResolvedValue("/tmp/demo-workspace");
    fireEvent.click(screen.getByRole("button", { name: /browse/i }));
    await waitFor(() => expect(screen.getByDisplayValue("demo-workspace")).toBeInTheDocument());

    const submit = screen.getByRole("button", { name: /create workspace/i });
    expect(submit).toBeEnabled(); // claude still checked

    fireEvent.click(screen.getByRole("checkbox", { name: /claude code/i }));
    expect(submit).toBeDisabled(); // nothing checked now

    fireEvent.click(screen.getByRole("checkbox", { name: /codex/i }));
    expect(submit).toBeEnabled();
  });

  it("collapsing the AI AGENTS section hides the checklist and the toggle label flips", () => {
    setup();
    expect(screen.getByRole("checkbox", { name: /claude code/i })).toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /collapse/i }));
    expect(screen.queryByRole("checkbox", { name: /claude code/i })).not.toBeInTheDocument();
    fireEvent.click(screen.getByRole("button", { name: /expand/i }));
    expect(screen.getByRole("checkbox", { name: /claude code/i })).toBeInTheDocument();
  });

  it("shows a checked/total count badge", () => {
    setup();
    expect(screen.getByText("1/5")).toBeInTheDocument();
    fireEvent.click(screen.getByRole("checkbox", { name: /codex/i }));
    expect(screen.getByText("2/5")).toBeInTheDocument();
  });
});

describe("NewWorkspaceModal — directory picking", () => {
  it("Browse opens the native folder picker and fills the path + name fields", async () => {
    setup();
    openMock.mockResolvedValue("/Users/bruno/code/my-workspace");
    fireEvent.click(screen.getByRole("button", { name: /browse/i }));
    expect(openMock).toHaveBeenCalledWith(expect.objectContaining({ directory: true, multiple: false }));
    await waitFor(() => expect(screen.getByDisplayValue("my-workspace")).toBeInTheDocument());
    expect(screen.getByText("/Users/bruno/code/my-workspace")).toBeInTheDocument();
  });

  it("lets the user override the auto-filled project name", async () => {
    setup();
    openMock.mockResolvedValue("/tmp/demo-workspace");
    fireEvent.click(screen.getByRole("button", { name: /browse/i }));
    const nameInput = await screen.findByDisplayValue("demo-workspace");
    fireEvent.change(nameInput, { target: { value: "renamed-workspace" } });
    expect(screen.getByDisplayValue("renamed-workspace")).toBeInTheDocument();
  });

  it("cancelling the native picker (null result) leaves the form untouched", async () => {
    setup();
    openMock.mockResolvedValue(null);
    fireEvent.click(screen.getByRole("button", { name: /browse/i }));
    await waitFor(() => expect(openMock).toHaveBeenCalled());
    expect(screen.getByRole("button", { name: /create workspace/i })).toBeDisabled();
  });
});

describe("NewWorkspaceModal — submit", () => {
  async function pickFolder() {
    openMock.mockResolvedValue("/tmp/demo-workspace");
    fireEvent.click(screen.getByRole("button", { name: /browse/i }));
    await screen.findByDisplayValue("demo-workspace");
  }

  it("calls add_project then onCreate with the project, checked engines (ENGINES order), and chosen layout", async () => {
    const { onCreate } = setup();
    addProjectMock.mockResolvedValue(PROJECT);
    await pickFolder();
    fireEvent.click(screen.getByRole("checkbox", { name: /shell/i })); // claude + shell checked
    fireEvent.click(screen.getByRole("button", { name: /^9\b/ })); // pick the "9" layout

    fireEvent.click(screen.getByRole("button", { name: /create workspace/i }));

    await waitFor(() => expect(onCreate).toHaveBeenCalledTimes(1));
    expect(addProjectMock).toHaveBeenCalledWith("/tmp/demo-workspace", "demo-workspace");
    const [project, engines, layout] = onCreate.mock.calls[0] as [ProjectInfo, Engine[], LayoutPreset];
    expect(project).toEqual(PROJECT);
    expect(engines).toEqual(["claude", "shell"]); // ENGINES order, not click order
    expect(layout).toBe(9);
  });

  it("does not call onClose itself on success — the caller closes the modal (same split as AddProjectModal/Sidebar)", async () => {
    const { onClose } = setup();
    addProjectMock.mockResolvedValue(PROJECT);
    await pickFolder();
    fireEvent.click(screen.getByRole("button", { name: /create workspace/i }));
    await waitFor(() => expect(addProjectMock).toHaveBeenCalled());
    expect(onClose).not.toHaveBeenCalled();
  });

  it("on add_project failure, shows an inline error, stays open, and never calls onCreate", async () => {
    const { onCreate, onClose } = setup();
    addProjectMock.mockRejectedValue(new Error("disk full"));
    await pickFolder();
    fireEvent.click(screen.getByRole("button", { name: /create workspace/i }));

    await waitFor(() => expect(screen.getByText(/disk full/)).toBeInTheDocument());
    expect(onCreate).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: /create workspace/i })).toBeEnabled();
  });
});

describe("NewWorkspaceModal — dismissal", () => {
  it("Escape calls onClose", () => {
    const { onClose } = setup();
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("the × close button calls onClose", () => {
    const { onClose } = setup();
    fireEvent.click(screen.getByRole("button", { name: /close/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("Cancel calls onClose", () => {
    const { onClose } = setup();
    fireEvent.click(screen.getByRole("button", { name: /^cancel$/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });
});
