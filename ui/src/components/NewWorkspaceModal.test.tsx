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
import type { AgentsState } from "../state/agents";

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

const DEFAULT_AGENT_STATE: AgentsState = {
  installed: new Set(["claude", "shell"]),
  lastSelected: [],
  installing: new Map(),
};

function setup(agents: Partial<AgentsState> = {}) {
  const onCreate = vi.fn();
  const onClose = vi.fn();
  const onInstallAgent = vi.fn();
  const agentState = { ...DEFAULT_AGENT_STATE, ...agents };
  render(
    <NewWorkspaceModal
      onCreate={onCreate}
      onClose={onClose}
      agentState={agentState}
      onInstallAgent={onInstallAgent}
    />
  );
  return { onCreate, onClose, onInstallAgent };
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

  // The pre-fill rule itself (last-selected -> single-installed -> shell) is
  // unit-tested in `state/agents.test.ts`. These two prove the MODAL actually
  // consults it — it previously hardcoded "Claude checked", which made
  // `getDefaultAgentSelection` dead code that every unit test passed against
  // while the dialog ignored it.

  it("with no history, defaults to shell — not to whichever agent is listed first", () => {
    setup();
    // Founder rule, verbatim: "if it's a brand new installation, it should be
    // shell selected". Two agents installed and nothing used before, so
    // neither the last-selected nor the only-one-installed branch applies.
    expect(screen.getByRole("checkbox", { name: /shell/i })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: /claude code/i })).not.toBeChecked();
    // Exactly 5 agent checkboxes — claude, codex, shell, copilot, antigravity
    expect(screen.getAllByRole("checkbox")).toHaveLength(5);
  });

  it("pre-selects the agents used for the last workspace", () => {
    // "the last one that they created, should be pre-selected."
    setup({ installed: new Set(["claude", "shell"]), lastSelected: ["claude"] });
    expect(screen.getByRole("checkbox", { name: /claude code/i })).toBeChecked();
    expect(screen.getByRole("checkbox", { name: /shell/i })).not.toBeChecked();
  });

  it("never pre-checks an agent that is no longer installed", () => {
    // Its row renders disabled, so a checked box would be one the user can
    // neither clear nor submit with.
    setup({ installed: new Set(["shell"]), lastSelected: ["codex"] });
    expect(screen.getByRole("checkbox", { name: /codex/i })).not.toBeChecked();
    expect(screen.getByRole("checkbox", { name: /codex/i })).toBeDisabled();
    expect(screen.getByRole("checkbox", { name: /shell/i })).toBeChecked();
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
    expect(submit).toBeEnabled(); // shell checked by default

    fireEvent.click(screen.getByRole("checkbox", { name: /shell/i }));
    expect(submit).toBeDisabled(); // nothing checked now

    // Claude rather than Codex: only installed agents have an enabled
    // checkbox, and this fixture installs claude + shell.
    fireEvent.click(screen.getByRole("checkbox", { name: /claude code/i }));
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
    // Shell starts checked (the default), so this ticks claude as well —
    // clicked second, but it must still come back FIRST, in ENGINES order.
    fireEvent.click(screen.getByRole("checkbox", { name: /claude code/i }));
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
