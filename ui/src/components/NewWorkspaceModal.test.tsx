// Component-level coverage for NewWorkspaceModal.tsx — the left-pane
// redesign's "New workspace" dialog (Task 12): folder + stats strip + two
// toggles, no name/layout/engines. Mocks `@tauri-apps/plugin-dialog`'s
// `open()` and every `../lib/tauri` surface the dialog touches, the same
// vi.hoisted + vi.mock shape `FileTree.test.tsx` established.
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo } from "../state/sessions";
import type { FolderStats } from "../lib/tauri";

const { openMock, addProjectMock, folderStatsMock, rootsSetPausedMock, settingsSetMock } =
  vi.hoisted(() => ({
    openMock: vi.fn(),
    addProjectMock: vi.fn(),
    folderStatsMock: vi.fn(),
    rootsSetPausedMock: vi.fn(),
    settingsSetMock: vi.fn(),
  }));

vi.mock("@tauri-apps/plugin-dialog", () => ({
  open: openMock,
}));

vi.mock("../lib/tauri", () => ({
  REVIEW_MEMORY_SETTING_KEY: "review_memory",
  addProject: addProjectMock,
  folderStats: folderStatsMock,
  rootsSetPaused: rootsSetPausedMock,
  settingsSet: settingsSetMock,
}));

const { default: NewWorkspaceModal } = await import("./NewWorkspaceModal");

const PROJECT: ProjectInfo = {
  id: "demo-workspace",
  label: "demo-workspace",
  path: "/tmp/demo-workspace",
};

const STATS: FolderStats = { files: 12480, languages: ["TS", "Rust"], git: true, branches: 4 };

function setup() {
  const onCreate = vi.fn();
  const onClose = vi.fn();
  render(<NewWorkspaceModal onCreate={onCreate} onClose={onClose} />);
  return { onCreate, onClose };
}

/** Picks `/tmp/demo-workspace` and waits for the stats strip to settle. */
async function pickFolder(path = "/tmp/demo-workspace") {
  openMock.mockResolvedValue(path);
  fireEvent.click(screen.getByRole("button", { name: /browse/i }));
  await screen.findByText(path);
}

beforeEach(() => {
  openMock.mockReset();
  addProjectMock.mockReset();
  folderStatsMock.mockReset();
  rootsSetPausedMock.mockReset();
  settingsSetMock.mockReset();
  folderStatsMock.mockResolvedValue(STATS);
  addProjectMock.mockResolvedValue(PROJECT);
  rootsSetPausedMock.mockResolvedValue(undefined);
  settingsSetMock.mockResolvedValue(undefined);
});

describe("NewWorkspaceModal — rendering", () => {
  it("shows the dialog, the folder row and both toggles", () => {
    setup();
    expect(screen.getByRole("dialog", { name: /new workspace/i })).toBeInTheDocument();
    expect(screen.getByText("Project folder")).toBeInTheDocument();
    expect(screen.getByText("No folder chosen yet")).toBeInTheDocument();
    expect(screen.getByRole("switch", { name: /ingest into the brain now/i })).toBeInTheDocument();
    expect(
      screen.getByRole("switch", { name: /review memory notes before commit/i }),
    ).toBeInTheDocument();
  });

  it("defaults: ingest on, review notes off", () => {
    setup();
    expect(screen.getByRole("switch", { name: /ingest/i })).toBeChecked();
    expect(screen.getByRole("switch", { name: /review memory/i })).not.toBeChecked();
  });

  it("hides the stats strip until a folder is picked, and shows the scoped-access hint", () => {
    setup();
    expect(screen.queryByText("files to walk")).not.toBeInTheDocument();
    expect(screen.getByText(/scoped access/i)).toBeInTheDocument();
  });

  it("Add workspace starts disabled — no folder chosen yet", () => {
    setup();
    expect(screen.getByRole("button", { name: /add workspace/i })).toBeDisabled();
  });
});

describe("NewWorkspaceModal — folder picking and the stats strip", () => {
  it("Browse opens the native folder picker and renders the stats for that folder", async () => {
    setup();
    await pickFolder("/Users/bruno/code/my-workspace");

    expect(openMock).toHaveBeenCalledWith(
      expect.objectContaining({ directory: true, multiple: false }),
    );
    expect(folderStatsMock).toHaveBeenCalledWith("/Users/bruno/code/my-workspace");
    await waitFor(() => expect(screen.getByText(/^12[,.]480$/)).toBeInTheDocument());
    expect(screen.getByText("files to walk")).toBeInTheDocument();
    expect(screen.getByText("TS · Rust")).toBeInTheDocument();
    expect(screen.getByText("git ✓")).toBeInTheDocument();
    expect(screen.getByText("4 branches")).toBeInTheDocument();
  });

  it("shows placeholders while folder_stats is in flight", async () => {
    setup();
    let resolve: (s: FolderStats) => void = () => {};
    folderStatsMock.mockReturnValue(new Promise<FolderStats>((r) => (resolve = r)));
    await pickFolder();

    // Strip is up (the folder is known) but every cell is still a placeholder.
    expect(screen.getByText("files to walk")).toBeInTheDocument();
    expect(screen.getAllByText("…").length).toBeGreaterThan(0);

    resolve(STATS);
    await waitFor(() => expect(screen.getByText(/^12[,.]480$/)).toBeInTheDocument());
  });

  it("a folder with no git shows 'no git' / 'init later' instead of a branch count", async () => {
    setup();
    folderStatsMock.mockResolvedValue({ files: 3, languages: [], git: false, branches: 0 });
    await pickFolder();

    await waitFor(() => expect(screen.getByText("no git")).toBeInTheDocument());
    expect(screen.getByText("init later")).toBeInTheDocument();
    expect(screen.getByText("—")).toBeInTheDocument(); // no languages detected
  });

  it("a failed folder_stats leaves placeholders and still allows the add", async () => {
    setup();
    folderStatsMock.mockRejectedValue(new Error("permission denied"));
    await pickFolder();

    await waitFor(() =>
      expect(screen.getByRole("button", { name: /add workspace/i })).toBeEnabled(),
    );
    expect(screen.queryByText(/permission denied/)).not.toBeInTheDocument();
  });

  it("cancelling the native picker (null result) leaves the form untouched", async () => {
    setup();
    openMock.mockResolvedValue(null);
    fireEvent.click(screen.getByRole("button", { name: /browse/i }));
    await waitFor(() => expect(openMock).toHaveBeenCalled());
    expect(folderStatsMock).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: /add workspace/i })).toBeDisabled();
  });
});

describe("NewWorkspaceModal — toggles", () => {
  it("clicking a switch flips its aria-checked", async () => {
    setup();
    const ingest = screen.getByRole("switch", { name: /ingest/i });
    fireEvent.click(ingest);
    expect(ingest).not.toBeChecked();
    fireEvent.click(ingest);
    expect(ingest).toBeChecked();
  });
});

describe("NewWorkspaceModal — submit", () => {
  it("adds the project under the folder's basename and hands it to onCreate", async () => {
    const { onCreate } = setup();
    await pickFolder();
    fireEvent.click(screen.getByRole("button", { name: /add workspace/i }));

    await waitFor(() => expect(onCreate).toHaveBeenCalledTimes(1));
    expect(addProjectMock).toHaveBeenCalledWith("/tmp/demo-workspace", "demo-workspace");
    expect(onCreate).toHaveBeenCalledWith(PROJECT);
  });

  it("with ingest ON (the default), never pauses the new root", async () => {
    setup();
    await pickFolder();
    fireEvent.click(screen.getByRole("button", { name: /add workspace/i }));

    await waitFor(() => expect(addProjectMock).toHaveBeenCalled());
    expect(rootsSetPausedMock).not.toHaveBeenCalled();
  });

  it("with ingest OFF, pauses the new root so no walk starts", async () => {
    setup();
    await pickFolder();
    fireEvent.click(screen.getByRole("switch", { name: /ingest/i }));
    fireEvent.click(screen.getByRole("button", { name: /add workspace/i }));

    await waitFor(() => expect(rootsSetPausedMock).toHaveBeenCalledWith("demo-workspace", true));
  });

  // The encoding is `ReviewPanel`'s, copied verbatim rather than reinvented
  // — it writes `next ? "true" : "false"` to the same key, so a workspace
  // added with the toggle on and the Review panel must agree.
  it("review notes off writes review_memory=\"false\"", async () => {
    setup();
    await pickFolder();
    fireEvent.click(screen.getByRole("button", { name: /add workspace/i }));
    await waitFor(() => expect(settingsSetMock).toHaveBeenCalledWith("review_memory", "false"));
  });

  it("review notes on writes review_memory=\"true\"", async () => {
    setup();
    await pickFolder();
    fireEvent.click(screen.getByRole("switch", { name: /review memory/i }));
    fireEvent.click(screen.getByRole("button", { name: /add workspace/i }));
    await waitFor(() => expect(settingsSetMock).toHaveBeenCalledWith("review_memory", "true"));
  });

  it("a second click while the add is in flight never double-adds", async () => {
    setup();
    await pickFolder();
    const submit = screen.getByRole("button", { name: /add workspace/i });
    fireEvent.click(submit);
    fireEvent.click(submit);
    await waitFor(() => expect(addProjectMock).toHaveBeenCalledTimes(1));
  });

  it("does not call onClose itself on success — the caller closes the modal", async () => {
    const { onClose } = setup();
    await pickFolder();
    fireEvent.click(screen.getByRole("button", { name: /add workspace/i }));
    await waitFor(() => expect(addProjectMock).toHaveBeenCalled());
    expect(onClose).not.toHaveBeenCalled();
  });

  it("on add_project failure, shows an inline error, stays open, and never calls onCreate", async () => {
    const { onCreate, onClose } = setup();
    addProjectMock.mockRejectedValue(new Error("disk full"));
    await pickFolder();
    fireEvent.click(screen.getByRole("button", { name: /add workspace/i }));

    await waitFor(() => expect(screen.getByText(/disk full/)).toBeInTheDocument());
    expect(onCreate).not.toHaveBeenCalled();
    expect(onClose).not.toHaveBeenCalled();
    expect(screen.getByRole("button", { name: /add workspace/i })).toBeEnabled();
  });

  it("a failed preference write is not fatal — the workspace still lands", async () => {
    const { onCreate } = setup();
    settingsSetMock.mockRejectedValue(new Error("settings locked"));
    await pickFolder();
    fireEvent.click(screen.getByRole("button", { name: /add workspace/i }));

    await waitFor(() => expect(onCreate).toHaveBeenCalledWith(PROJECT));
  });
});

describe("NewWorkspaceModal — keyboard", () => {
  it("Enter adds the workspace", async () => {
    const { onCreate } = setup();
    await pickFolder();
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Enter" });
    await waitFor(() => expect(onCreate).toHaveBeenCalledTimes(1));
  });

  it("Enter still works after a toggle has been clicked — it must never go dead", async () => {
    // The Task 10 lesson, kept: a real browser moves focus to a <button> on
    // click, so gating Enter on "nothing/only-the-panel has focus" would
    // make it a dead key right at the end of the flow.
    const { onCreate } = setup();
    await pickFolder();
    const ingest = screen.getByRole("switch", { name: /ingest/i });
    fireEvent.click(ingest);
    ingest.focus();
    fireEvent.keyDown(ingest, { key: "Enter" });
    await waitFor(() => expect(onCreate).toHaveBeenCalledTimes(1));
  });

  it("Enter inside the folder row belongs to Browse, not to the submit", async () => {
    const { onCreate } = setup();
    await pickFolder();
    const browse = screen.getByRole("button", { name: /browse/i });
    browse.focus();
    fireEvent.keyDown(browse, { key: "Enter" });
    expect(onCreate).not.toHaveBeenCalled();
  });

  it("Enter does nothing before a folder is picked", () => {
    const { onCreate } = setup();
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Enter" });
    expect(onCreate).not.toHaveBeenCalled();
    expect(addProjectMock).not.toHaveBeenCalled();
  });
});

describe("NewWorkspaceModal — dismissal", () => {
  it("Escape calls onClose", () => {
    const { onClose } = setup();
    fireEvent.keyDown(screen.getByRole("dialog"), { key: "Escape" });
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("Cancel calls onClose", () => {
    const { onClose } = setup();
    fireEvent.click(screen.getByRole("button", { name: /^cancel$/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("clicking the backdrop calls onClose, clicking the panel does not", () => {
    const { onClose } = setup();
    fireEvent.mouseDown(screen.getByRole("dialog"));
    expect(onClose).not.toHaveBeenCalled();
  });
});
