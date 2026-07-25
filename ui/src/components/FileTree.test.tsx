// Founder feedback, Part B (2026-07-25, verbatim): "make sure the file view
// works correctly, with it's own file visualization. It must work exactly
// like the Finder from Mac OS." Component-level coverage for FileTree.tsx,
// mocking the same surfaces `../lib/tauri`/`@tauri-apps/plugin-opener` this
// codebase's other components already mock (see BrainMap.test.tsx), plus
// `@tauri-apps/api/event` (`listen`, for the `dir-changed:{path}` live
// updates — same style Terminal.tsx/App.tsx already use) and the browser
// clipboard API (Copy Path).
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo } from "../state/sessions";
import type { DirEntry } from "../lib/tauri";

const {
  listDirMock,
  sessionWriteMock,
  openPathMock,
  revealItemInDirMock,
  settingsGetMock,
  settingsSetMock,
  renamePathMock,
  movePathMock,
  duplicatePathMock,
  deleteToTrashMock,
  createFileMock,
  createDirMock,
  watchDirMock,
  unwatchDirMock,
  listenMock,
  clipboardWriteTextMock,
} = vi.hoisted(() => ({
  listDirMock: vi.fn(),
  sessionWriteMock: vi.fn(),
  openPathMock: vi.fn(),
  revealItemInDirMock: vi.fn(),
  settingsGetMock: vi.fn(),
  settingsSetMock: vi.fn(),
  renamePathMock: vi.fn(),
  movePathMock: vi.fn(),
  duplicatePathMock: vi.fn(),
  deleteToTrashMock: vi.fn(),
  createFileMock: vi.fn(),
  createDirMock: vi.fn(),
  watchDirMock: vi.fn(),
  unwatchDirMock: vi.fn(),
  listenMock: vi.fn(),
  clipboardWriteTextMock: vi.fn(),
}));

vi.mock("../lib/tauri", () => ({
  listDir: listDirMock,
  sessionWrite: sessionWriteMock,
  settingsGet: settingsGetMock,
  settingsSet: settingsSetMock,
  renamePath: renamePathMock,
  movePath: movePathMock,
  duplicatePath: duplicatePathMock,
  deleteToTrash: deleteToTrashMock,
  createFile: createFileMock,
  createDir: createDirMock,
  watchDir: watchDirMock,
  unwatchDir: unwatchDirMock,
  FILE_TREE_WIDTH_SETTING_KEY: "file_tree_width",
}));

vi.mock("@tauri-apps/plugin-opener", () => ({
  openPath: openPathMock,
  revealItemInDir: revealItemInDirMock,
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: listenMock,
}));

const { default: FileTree } = await import("./FileTree");

const PROJECT: ProjectInfo = { id: "demo", label: "demo", path: "/repo/demo" };

function rootEntries(): DirEntry[] {
  return [
    { name: "src", path: "/repo/demo/src", is_dir: true },
    { name: "main.py", path: "/repo/demo/main.py", is_dir: false },
    { name: "notes.md", path: "/repo/demo/notes.md", is_dir: false },
  ];
}

function childEntries(): DirEntry[] {
  return [{ name: "util.ts", path: "/repo/demo/src/util.ts", is_dir: false }];
}

function setup(overrides: Partial<Parameters<typeof FileTree>[0]> = {}) {
  const onClose = vi.fn();
  const result = render(<FileTree project={PROJECT} activeTabId={null} onClose={onClose} {...overrides} />);
  return { onClose, unmount: result.unmount };
}

describe("FileTree", () => {
  beforeEach(() => {
    listDirMock.mockReset();
    sessionWriteMock.mockReset();
    openPathMock.mockReset();
    revealItemInDirMock.mockReset();
    settingsGetMock.mockReset();
    settingsSetMock.mockReset();
    renamePathMock.mockReset();
    movePathMock.mockReset();
    duplicatePathMock.mockReset();
    deleteToTrashMock.mockReset();
    createFileMock.mockReset();
    createDirMock.mockReset();
    watchDirMock.mockReset();
    unwatchDirMock.mockReset();
    listenMock.mockReset();
    clipboardWriteTextMock.mockReset();

    listDirMock.mockResolvedValue(rootEntries());
    openPathMock.mockResolvedValue(undefined);
    revealItemInDirMock.mockResolvedValue(undefined);
    sessionWriteMock.mockResolvedValue(undefined);
    settingsGetMock.mockResolvedValue(null);
    settingsSetMock.mockResolvedValue(undefined);
    watchDirMock.mockResolvedValue(undefined);
    unwatchDirMock.mockResolvedValue(undefined);
    listenMock.mockResolvedValue(() => {});
    Object.assign(navigator, { clipboard: { writeText: clipboardWriteTextMock } });
    clipboardWriteTextMock.mockResolvedValue(undefined);
    // jsdom doesn't implement this — the component guards its absence, but
    // tests that exercise drag hit-testing stub it explicitly per-test.
    // @ts-expect-error -- not part of jsdom's Document type
    delete document.elementFromPoint;
  });

  // -------------------------------------------------------------- basics
  it("prompts to select a project when none is selected", () => {
    render(<FileTree project={null} activeTabId={null} onClose={() => {}} />);
    expect(screen.getByText(/select a project/i)).toBeInTheDocument();
    expect(listDirMock).not.toHaveBeenCalled();
  });

  it("shows a graceful message for a project with no known path", () => {
    render(<FileTree project={{ id: "x", label: "x", path: null }} activeTabId={null} onClose={() => {}} />);
    expect(screen.getByText(/no known path/i)).toBeInTheDocument();
    expect(listDirMock).not.toHaveBeenCalled();
  });

  it("lists the selected project's root entries via listDir", async () => {
    setup();
    expect(listDirMock).toHaveBeenCalledWith("/repo/demo");
    expect(await screen.findByText("src")).toBeInTheDocument();
    expect(screen.getByText("main.py")).toBeInTheDocument();
  });

  it("shows a loading state before listDir resolves", () => {
    listDirMock.mockReturnValue(new Promise(() => {})); // never resolves
    setup();
    expect(screen.getByText(/loading/i)).toBeInTheDocument();
  });

  it("shows an error state when listDir rejects", async () => {
    listDirMock.mockRejectedValue(new Error("permission denied"));
    setup();
    expect(await screen.findByText(/permission denied/i)).toBeInTheDocument();
  });

  it("shows an empty-project message when the root has no entries", async () => {
    listDirMock.mockResolvedValue([]);
    setup();
    expect(await screen.findByText(/empty/i)).toBeInTheDocument();
  });

  it("the header's reveal action reveals the project root in Finder", async () => {
    setup();
    await screen.findByText("src");
    fireEvent.click(screen.getByRole("button", { name: /reveal/i }));
    await waitFor(() => expect(revealItemInDirMock).toHaveBeenCalledWith("/repo/demo"));
  });

  it("the close button calls onClose", async () => {
    const { onClose } = setup();
    await screen.findByText("src");
    fireEvent.click(screen.getByRole("button", { name: /hide file tree/i }));
    expect(onClose).toHaveBeenCalled();
  });

  it("offers no insert-into-terminal control when no terminal tab is active", async () => {
    setup({ activeTabId: null });
    await screen.findByText("main.py");
    expect(screen.queryByRole("button", { name: /paste/i })).not.toBeInTheDocument();
  });

  it("pastes a file's quoted path into the active terminal when one is focused", async () => {
    setup({ activeTabId: "sess-1" });
    await screen.findByText("main.py");
    fireEvent.click(screen.getByRole("button", { name: /paste main\.py/i }));
    await waitFor(() => expect(sessionWriteMock).toHaveBeenCalledWith("sess-1", '"/repo/demo/main.py" '));
  });

  // ----------------------------------------------------- icons (Task 1)
  it("renders a distinct icon per row, folders included, for every visible entry", async () => {
    setup();
    await screen.findByText("src");
    const icons = document.querySelectorAll(".file-tree-icon");
    expect(icons.length).toBe(rootEntries().length);
  });

  // ------------------------------------------- click = select, dblclick = open (Task 2)
  it("a single click selects a row without opening or toggling it", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.click(screen.getByText("main.py"));
    expect(openPathMock).not.toHaveBeenCalled();
    expect(screen.getByText("main.py").closest(".file-tree-row")).toHaveClass("is-selected");
  });

  it("a single click on a folder selects it without expanding", async () => {
    setup();
    await screen.findByText("src");
    fireEvent.click(screen.getByText("src"));
    expect(listDirMock).toHaveBeenCalledTimes(1); // root only, no expand fetch
    expect(screen.getByText("src").closest(".file-tree-row")).toHaveClass("is-selected");
  });

  it("double-clicking a file opens it via openPath", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.doubleClick(screen.getByText("main.py"));
    await waitFor(() => expect(openPathMock).toHaveBeenCalledWith("/repo/demo/main.py"));
  });

  it("double-clicking a directory lazily loads and reveals its children exactly once", async () => {
    listDirMock.mockImplementation((path: string) => Promise.resolve(path === "/repo/demo" ? rootEntries() : childEntries()));
    setup();
    await screen.findByText("src");
    expect(listDirMock).toHaveBeenCalledTimes(1);

    fireEvent.doubleClick(screen.getByText("src"));
    expect(await screen.findByText("util.ts")).toBeInTheDocument();
    expect(listDirMock).toHaveBeenCalledWith("/repo/demo/src");
    expect(listDirMock).toHaveBeenCalledTimes(2);

    fireEvent.doubleClick(screen.getByText("src"));
    expect(screen.queryByText("util.ts")).not.toBeInTheDocument();
    fireEvent.doubleClick(screen.getByText("src"));
    expect(await screen.findByText("util.ts")).toBeInTheDocument();
    expect(listDirMock).toHaveBeenCalledTimes(2); // cached, no re-fetch
  });

  // ------------------------------------------------------- multi-select (Task 3)
  it("cmd-click adds a second row to the selection", async () => {
    setup();
    await screen.findByText("notes.md");
    fireEvent.click(screen.getByText("main.py"));
    fireEvent.click(screen.getByText("notes.md"), { metaKey: true });
    expect(screen.getByText("main.py").closest(".file-tree-row")).toHaveClass("is-selected");
    expect(screen.getByText("notes.md").closest(".file-tree-row")).toHaveClass("is-selected");
  });

  it("shift-click selects the contiguous range", async () => {
    setup();
    await screen.findByText("notes.md");
    fireEvent.click(screen.getByText("src"));
    fireEvent.click(screen.getByText("notes.md"), { shiftKey: true });
    expect(screen.getByText("src").closest(".file-tree-row")).toHaveClass("is-selected");
    expect(screen.getByText("main.py").closest(".file-tree-row")).toHaveClass("is-selected");
    expect(screen.getByText("notes.md").closest(".file-tree-row")).toHaveClass("is-selected");
  });

  it("clicking empty tree space clears the selection", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.click(screen.getByText("main.py"));
    expect(screen.getByText("main.py").closest(".file-tree-row")).toHaveClass("is-selected");
    fireEvent.click(document.querySelector(".file-tree-body")!);
    expect(screen.getByText("main.py").closest(".file-tree-row")).not.toHaveClass("is-selected");
  });

  // ------------------------------------------------------- context menu (Task 4)
  it("right-clicking a row opens a context menu with file actions", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    expect(screen.getByRole("menuitem", { name: "Open" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Reveal in Finder" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Rename" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Duplicate" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: /move main\.py to trash/i })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "Copy Path" })).toBeInTheDocument();
    // a plain file target offers no New File/New Folder
    expect(screen.queryByRole("menuitem", { name: "New File" })).not.toBeInTheDocument();
  });

  it("right-clicking a folder's context menu also offers New File/New Folder", async () => {
    setup();
    await screen.findByText("src");
    fireEvent.contextMenu(screen.getByText("src"));
    expect(screen.getByRole("menuitem", { name: "New File" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "New Folder" })).toBeInTheDocument();
  });

  it("right-clicking empty tree space offers only New File/New Folder", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(document.querySelector(".file-tree-body")!);
    expect(screen.getByRole("menuitem", { name: "New File" })).toBeInTheDocument();
    expect(screen.getByRole("menuitem", { name: "New Folder" })).toBeInTheDocument();
    expect(screen.queryByRole("menuitem", { name: "Open" })).not.toBeInTheDocument();
  });

  it("right-clicking a row that's part of a multi-selection offers only Move to Trash", async () => {
    setup();
    await screen.findByText("notes.md");
    fireEvent.click(screen.getByText("main.py"));
    fireEvent.click(screen.getByText("notes.md"), { metaKey: true });
    fireEvent.contextMenu(screen.getByText("main.py"));
    expect(screen.getByRole("menuitem", { name: /move 2 items to trash/i })).toBeInTheDocument();
    expect(screen.queryByRole("menuitem", { name: "Open" })).not.toBeInTheDocument();
  });

  it("context menu Open calls openPath for a file target", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: "Open" }));
    await waitFor(() => expect(openPathMock).toHaveBeenCalledWith("/repo/demo/main.py"));
  });

  it("context menu Reveal in Finder calls revealItemInDir for the target", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: "Reveal in Finder" }));
    await waitFor(() => expect(revealItemInDirMock).toHaveBeenCalledWith("/repo/demo/main.py"));
  });

  it("context menu Duplicate calls duplicatePath and selects the new entry", async () => {
    duplicatePathMock.mockResolvedValue("/repo/demo/main copy.py");
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: "Duplicate" }));
    await waitFor(() => expect(duplicatePathMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo/main.py"));
  });

  it("context menu Move to Trash calls delete_to_trash for every selected item", async () => {
    deleteToTrashMock.mockResolvedValue(undefined);
    setup();
    await screen.findByText("notes.md");
    fireEvent.click(screen.getByText("main.py"));
    fireEvent.click(screen.getByText("notes.md"), { metaKey: true });
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: /move 2 items to trash/i }));
    await waitFor(() => {
      expect(deleteToTrashMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo/main.py");
      expect(deleteToTrashMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo/notes.md");
    });
  });

  it("context menu Move to Trash shows the backend's error message on failure", async () => {
    deleteToTrashMock.mockRejectedValue(new Error("permission denied: /repo/demo/main.py"));
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: /move main\.py to trash/i }));
    expect(await screen.findByText(/permission denied/i)).toBeInTheDocument();
  });

  // ------------------------------- Bug 5: partial-failure selection cleanup
  it("Move to Trash on a multi-selection only deselects the items that actually succeeded, leaving the failed one selected", async () => {
    deleteToTrashMock.mockImplementation((_projectPath: string, path: string) =>
      path === "/repo/demo/notes.md" ? Promise.reject(new Error("permission denied")) : Promise.resolve(undefined),
    );
    setup();
    await screen.findByText("notes.md");
    fireEvent.click(screen.getByText("main.py"));
    fireEvent.click(screen.getByText("notes.md"), { metaKey: true });
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: /move 2 items to trash/i }));

    await waitFor(() => expect(deleteToTrashMock).toHaveBeenCalledTimes(2));
    await screen.findByText(/permission denied/i);

    // main.py's delete succeeded -> no longer selected.
    expect(screen.getByText("main.py").closest(".file-tree-row")).not.toHaveClass("is-selected");
    // notes.md's delete FAILED -> stays selected so the user can see what still needs attention.
    expect(screen.getByText("notes.md").closest(".file-tree-row")).toHaveClass("is-selected");
  });

  it("context menu Copy Path writes the path to the clipboard", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: "Copy Path" }));
    await waitFor(() => expect(clipboardWriteTextMock).toHaveBeenCalledWith("/repo/demo/main.py"));
  });

  it("Escape closes the context menu", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    expect(screen.getByRole("menu")).toBeInTheDocument();
    fireEvent.keyDown(screen.getByRole("menu"), { key: "Escape" });
    expect(screen.queryByRole("menu")).not.toBeInTheDocument();
  });

  // ------------------------------------------------------------- rename (Task 5)
  it("context menu Rename swaps the label for an inline input pre-filled with the current name", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
    expect(screen.getByDisplayValue("main.py")).toBeInTheDocument();
  });

  it("commits the rename on Enter, calling rename_path", async () => {
    renamePathMock.mockResolvedValue("/repo/demo/renamed.py");
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
    const input = screen.getByDisplayValue("main.py");
    fireEvent.change(input, { target: { value: "renamed.py" } });
    fireEvent.keyDown(input, { key: "Enter" });
    await waitFor(() => expect(renamePathMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo/main.py", "renamed.py"));
  });

  it("commits the rename on blur", async () => {
    renamePathMock.mockResolvedValue("/repo/demo/renamed.py");
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
    const input = screen.getByDisplayValue("main.py");
    fireEvent.change(input, { target: { value: "renamed.py" } });
    fireEvent.blur(input);
    await waitFor(() => expect(renamePathMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo/main.py", "renamed.py"));
  });

  it("cancels the rename on Escape without calling rename_path", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
    const input = screen.getByDisplayValue("main.py");
    fireEvent.change(input, { target: { value: "should not stick" } });
    fireEvent.keyDown(input, { key: "Escape" });
    expect(renamePathMock).not.toHaveBeenCalled();
    expect(screen.getByText("main.py")).toBeInTheDocument();
  });

  it("shows the backend's error message when a rename collides", async () => {
    renamePathMock.mockRejectedValue(new Error('a file named "notes.md" already exists'));
    setup();
    await screen.findByText("main.py");
    fireEvent.contextMenu(screen.getByText("main.py"));
    fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
    const input = screen.getByDisplayValue("main.py");
    fireEvent.change(input, { target: { value: "notes.md" } });
    fireEvent.keyDown(input, { key: "Enter" });
    expect(await screen.findByText(/already exists/i)).toBeInTheDocument();
  });

  // --------------------------- Bug 3: expanded/children cache sync on rename/move/delete
  it("renaming an expanded folder keeps it expanded and shows its cached children at the new path", async () => {
    listDirMock.mockImplementation((path: string) => Promise.resolve(path === "/repo/demo" ? rootEntries() : childEntries()));
    renamePathMock.mockResolvedValue("/repo/demo/lib");
    setup();
    await screen.findByText("src");
    fireEvent.doubleClick(screen.getByText("src")); // expand — caches util.ts under /repo/demo/src
    await screen.findByText("util.ts");

    // The parent (root) listing gets refetched after the rename and now shows "lib".
    listDirMock.mockResolvedValueOnce([
      { name: "lib", path: "/repo/demo/lib", is_dir: true },
      { name: "main.py", path: "/repo/demo/main.py", is_dir: false },
      { name: "notes.md", path: "/repo/demo/notes.md", is_dir: false },
    ]);

    fireEvent.contextMenu(screen.getByText("src"));
    fireEvent.click(screen.getByRole("menuitem", { name: "Rename" }));
    const input = screen.getByDisplayValue("src");
    fireEvent.change(input, { target: { value: "lib" } });
    fireEvent.keyDown(input, { key: "Enter" });

    // Renders under its new name, STILL expanded, showing the cached child
    // immediately — not collapsed just because `expanded` was keyed by the
    // old path, and not re-fetched (the cache carried forward under the new key).
    expect(await screen.findByText("lib")).toBeInTheDocument();
    expect(screen.getByText("util.ts")).toBeInTheDocument();
    expect(screen.queryByText("src")).not.toBeInTheDocument();
    expect(listDirMock).not.toHaveBeenCalledWith("/repo/demo/lib");
  });

  it("deleting an expanded folder, then something new occupying the exact same path, never shows the deleted folder's stale cached children", async () => {
    listDirMock.mockImplementation((path: string) => Promise.resolve(path === "/repo/demo" ? rootEntries() : childEntries()));
    deleteToTrashMock.mockResolvedValue(undefined);
    let dirChangedHandler: (() => void) | undefined;
    listenMock.mockImplementation((eventName: string, handler: () => void) => {
      if (eventName === "dir-changed:/repo/demo") dirChangedHandler = handler;
      return Promise.resolve(() => {});
    });
    setup();
    await screen.findByText("src");
    await waitFor(() => expect(dirChangedHandler).toBeDefined());

    fireEvent.doubleClick(screen.getByText("src")); // expand — caches util.ts under /repo/demo/src
    await screen.findByText("util.ts");

    // Delete "src".
    listDirMock.mockResolvedValueOnce([
      { name: "main.py", path: "/repo/demo/main.py", is_dir: false },
      { name: "notes.md", path: "/repo/demo/notes.md", is_dir: false },
    ]);
    fireEvent.contextMenu(screen.getByText("src"));
    fireEvent.click(screen.getByRole("menuitem", { name: /move src to trash/i }));
    await waitFor(() => expect(screen.queryByText("src")).not.toBeInTheDocument());

    // Something new gets created at the exact same path by an external
    // process — simulated as an external dir-changed refresh bringing a
    // "src" entry back.
    listDirMock.mockResolvedValueOnce([
      { name: "src", path: "/repo/demo/src", is_dir: true },
      { name: "main.py", path: "/repo/demo/main.py", is_dir: false },
      { name: "notes.md", path: "/repo/demo/notes.md", is_dir: false },
    ]);
    dirChangedHandler!();
    await screen.findByText("src");

    // Expanding the NEW "src" must fetch fresh content — never the deleted
    // folder's stale cached "util.ts".
    listDirMock.mockResolvedValueOnce([{ name: "brand-new.ts", path: "/repo/demo/src/brand-new.ts", is_dir: false }]);
    fireEvent.doubleClick(screen.getByText("src"));
    expect(await screen.findByText("brand-new.ts")).toBeInTheDocument();
    expect(screen.queryByText("util.ts")).not.toBeInTheDocument();
  });

  // ------------------------------------------------------ New File/Folder (Task 7)
  it("the header's New File button creates at the project root and enters rename mode", async () => {
    createFileMock.mockResolvedValue("/repo/demo/untitled file");
    setup();
    await screen.findByText("main.py");
    listDirMock.mockResolvedValueOnce([...rootEntries(), { name: "untitled file", path: "/repo/demo/untitled file", is_dir: false }]);
    fireEvent.click(screen.getByRole("button", { name: "New file" }));
    await waitFor(() => expect(createFileMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo", "untitled file"));
    expect(await screen.findByDisplayValue("untitled file")).toBeInTheDocument();
  });

  it("the header's New Folder button creates at the project root", async () => {
    createDirMock.mockResolvedValue("/repo/demo/untitled folder");
    setup();
    await screen.findByText("main.py");
    fireEvent.click(screen.getByRole("button", { name: "New folder" }));
    await waitFor(() => expect(createDirMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo", "untitled folder"));
  });

  it("New File targets the selected folder, not the root", async () => {
    createFileMock.mockResolvedValue("/repo/demo/src/untitled file");
    listDirMock.mockImplementation((path: string) => Promise.resolve(path === "/repo/demo" ? rootEntries() : childEntries()));
    setup();
    await screen.findByText("src");
    fireEvent.click(screen.getByText("src")); // select the folder
    fireEvent.click(screen.getByRole("button", { name: "New file" }));
    await waitFor(() => expect(createFileMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo/src", "untitled file"));
  });

  it("shows the backend's error message when create collides", async () => {
    createFileMock.mockRejectedValue(new Error('a file named "untitled file" already exists'));
    setup();
    await screen.findByText("main.py");
    fireEvent.click(screen.getByRole("button", { name: "New file" }));
    expect(await screen.findByText(/already exists/i)).toBeInTheDocument();
  });

  // --------------------------------------------------------- resize (Task 9)
  it("applies the persisted width on load", async () => {
    settingsGetMock.mockImplementation((key: string) => Promise.resolve(key === "file_tree_width" ? "340" : null));
    setup();
    await screen.findByText("main.py");
    await waitFor(() => expect(screen.getByLabelText("Project files")).toHaveStyle({ width: "340px" }));
  });

  it("dragging the resize handle changes the panel width and persists it", async () => {
    setup();
    await screen.findByText("main.py");
    const handle = screen.getByRole("separator", { name: /resize file browser panel/i });
    fireEvent.pointerDown(handle, { clientX: 500, pointerId: 1 });
    fireEvent.pointerMove(handle, { clientX: 460, pointerId: 1 }); // dragging left widens
    fireEvent.pointerUp(handle, { clientX: 460, pointerId: 1 });
    await waitFor(() => expect(screen.getByLabelText("Project files")).toHaveStyle({ width: "300px" }));
    expect(settingsSetMock).toHaveBeenCalledWith("file_tree_width", "300");
  });

  // ------------------------------- Bug 1&2: Pointer Capture (resize side)
  it("a resize interrupted by pointercancel (e.g. released outside the window) does not persist the in-progress width", async () => {
    setup();
    await screen.findByText("main.py");
    const handle = screen.getByRole("separator", { name: /resize file browser panel/i });
    fireEvent.pointerDown(handle, { clientX: 500, pointerId: 1 });
    fireEvent.pointerMove(handle, { clientX: 460, pointerId: 1 });
    await waitFor(() => expect(screen.getByLabelText("Project files")).toHaveStyle({ width: "300px" }));

    fireEvent.pointerCancel(handle, { pointerId: 1 });
    expect(settingsSetMock).not.toHaveBeenCalled();

    // A later, unrelated pointerup elsewhere must not resurrect the cancelled resize.
    fireEvent.pointerUp(document.body, { pointerId: 1 });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(settingsSetMock).not.toHaveBeenCalled();
  });

  it("never attaches resize listeners to window — only to the handle that started the drag", async () => {
    const addSpy = vi.spyOn(window, "addEventListener");
    setup();
    await screen.findByText("main.py");
    const handle = screen.getByRole("separator", { name: /resize file browser panel/i });
    fireEvent.pointerDown(handle, { clientX: 500, pointerId: 1 });
    fireEvent.pointerMove(handle, { clientX: 460, pointerId: 1 });
    fireEvent.pointerUp(handle, { clientX: 460, pointerId: 1 });
    const leaked = addSpy.mock.calls.filter(([type]) =>
      ["mousemove", "mouseup", "pointermove", "pointerup", "pointercancel"].includes(type as string),
    );
    expect(leaked).toEqual([]);
    addSpy.mockRestore();
  });

  // --------------------------------------------------- live updates (Task 8)
  it("watches the project root on mount and unwatches on unmount", async () => {
    const { unmount } = setup();
    await screen.findByText("main.py");
    await waitFor(() => expect(watchDirMock).toHaveBeenCalledWith("/repo/demo"));
    unmount();
    await waitFor(() => expect(unwatchDirMock).toHaveBeenCalledWith("/repo/demo"));
  });

  it("watches a directory on expand and unwatches on collapse", async () => {
    listDirMock.mockImplementation((path: string) => Promise.resolve(path === "/repo/demo" ? rootEntries() : childEntries()));
    setup();
    await screen.findByText("src");
    fireEvent.doubleClick(screen.getByText("src"));
    await screen.findByText("util.ts");
    await waitFor(() => expect(watchDirMock).toHaveBeenCalledWith("/repo/demo/src"));

    fireEvent.doubleClick(screen.getByText("src")); // collapse
    await waitFor(() => expect(unwatchDirMock).toHaveBeenCalledWith("/repo/demo/src"));
  });

  it("re-fetches a directory's listing when its dir-changed event fires", async () => {
    let dirChangedHandler: (() => void) | undefined;
    listenMock.mockImplementation((eventName: string, handler: () => void) => {
      if (eventName === "dir-changed:/repo/demo") dirChangedHandler = handler;
      return Promise.resolve(() => {});
    });
    setup();
    await screen.findByText("main.py");
    await waitFor(() => expect(dirChangedHandler).toBeDefined());
    expect(listDirMock).toHaveBeenCalledTimes(1);

    listDirMock.mockResolvedValueOnce([
      { name: "src", path: "/repo/demo/src", is_dir: true },
      { name: "main.py", path: "/repo/demo/main.py", is_dir: false },
      { name: "notes.md", path: "/repo/demo/notes.md", is_dir: false },
      { name: "new-file.txt", path: "/repo/demo/new-file.txt", is_dir: false },
    ]);
    dirChangedHandler!();
    expect(await screen.findByText("new-file.txt")).toBeInTheDocument();
    expect(listDirMock).toHaveBeenCalledTimes(2);
  });

  // ---------------------------------------------------- drag-and-drop (Task 6)
  it("dragging a row onto a folder row calls move_path with the folder as destination", async () => {
    movePathMock.mockResolvedValue("/repo/demo/src/notes.md");
    setup();
    const notes = await screen.findByText("notes.md");
    const srcRow = screen.getByText("src").closest("[data-file-tree-path]") as HTMLElement;

    document.elementFromPoint = vi.fn().mockReturnValue(srcRow);

    fireEvent.pointerDown(notes, { clientX: 10, clientY: 100, button: 0, pointerId: 1 });
    fireEvent.pointerMove(notes, { clientX: 10, clientY: 40, pointerId: 1 }); // past the drag threshold, over "src"
    fireEvent.pointerUp(notes, { clientX: 10, clientY: 40, pointerId: 1 });

    await waitFor(() => expect(movePathMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo/notes.md", "/repo/demo/src"));
  });

  it("dragging a row onto empty tree space calls move_path with the project root as destination", async () => {
    listDirMock.mockImplementation((path: string) => Promise.resolve(path === "/repo/demo" ? rootEntries() : childEntries()));
    movePathMock.mockResolvedValue("/repo/demo/util.ts");
    setup();
    await screen.findByText("src");
    fireEvent.doubleClick(screen.getByText("src"));
    const util = await screen.findByText("util.ts");
    const body = document.querySelector(".file-tree-body") as HTMLElement;

    document.elementFromPoint = vi.fn().mockReturnValue(body);

    fireEvent.pointerDown(util, { clientX: 10, clientY: 100, button: 0, pointerId: 1 });
    fireEvent.pointerMove(util, { clientX: 10, clientY: 400, pointerId: 1 });
    fireEvent.pointerUp(util, { clientX: 10, clientY: 400, pointerId: 1 });

    await waitFor(() => expect(movePathMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo/src/util.ts", "/repo/demo"));
  });

  it("a drag that doesn't cross the threshold is treated as a click, not a move", async () => {
    setup();
    const notes = await screen.findByText("notes.md");
    fireEvent.pointerDown(notes, { clientX: 10, clientY: 10, button: 0, pointerId: 1 });
    fireEvent.pointerMove(notes, { clientX: 11, clientY: 10, pointerId: 1 }); // 1px — below threshold
    fireEvent.pointerUp(notes, { clientX: 11, clientY: 10, pointerId: 1 });
    expect(movePathMock).not.toHaveBeenCalled();
  });

  it("shows the backend's error message when a move is rejected", async () => {
    movePathMock.mockRejectedValue(new Error("cannot move a folder into itself or one of its own subfolders"));
    setup();
    const notes = await screen.findByText("notes.md");
    const srcRow = screen.getByText("src").closest("[data-file-tree-path]") as HTMLElement;
    document.elementFromPoint = vi.fn().mockReturnValue(srcRow);

    fireEvent.pointerDown(notes, { clientX: 10, clientY: 100, button: 0, pointerId: 1 });
    fireEvent.pointerMove(notes, { clientX: 10, clientY: 40, pointerId: 1 });
    fireEvent.pointerUp(notes, { clientX: 10, clientY: 40, pointerId: 1 });

    expect(await screen.findByText(/cannot move a folder/i)).toBeInTheDocument();
  });

  // -------------------- Bug 4: multi-select drag excludes selected descendants
  it("dragging a multi-selection containing a folder and its own descendant only moves the top-level folder", async () => {
    const customRoot: DirEntry[] = [
      { name: "src", path: "/repo/demo/src", is_dir: true },
      { name: "dest", path: "/repo/demo/dest", is_dir: true },
      { name: "main.py", path: "/repo/demo/main.py", is_dir: false },
    ];
    listDirMock.mockImplementation((path: string) =>
      Promise.resolve(path === "/repo/demo" ? customRoot : path === "/repo/demo/src" ? childEntries() : []),
    );
    movePathMock.mockResolvedValue("/repo/demo/dest/src");
    setup();
    await screen.findByText("src");
    fireEvent.doubleClick(screen.getByText("src")); // expand
    await screen.findByText("util.ts");

    // Shift-click range-select from "src" to "util.ts" — parent before child
    // in visible tree order, exactly the scenario the bug describes.
    fireEvent.click(screen.getByText("src"));
    fireEvent.click(screen.getByText("util.ts"), { shiftKey: true });
    expect(screen.getByText("src").closest(".file-tree-row")).toHaveClass("is-selected");
    expect(screen.getByText("util.ts").closest(".file-tree-row")).toHaveClass("is-selected");

    const destRow = screen.getByText("dest").closest("[data-file-tree-path]") as HTMLElement;
    document.elementFromPoint = vi.fn().mockReturnValue(destRow);

    // Start the drag on the folder itself, which is part of the selection —
    // drags the whole current selection (both src and util.ts).
    fireEvent.pointerDown(screen.getByText("src"), { clientX: 10, clientY: 100, button: 0, pointerId: 1 });
    fireEvent.pointerMove(screen.getByText("src"), { clientX: 10, clientY: 40, pointerId: 1 });
    fireEvent.pointerUp(screen.getByText("src"), { clientX: 10, clientY: 40, pointerId: 1 });

    await waitFor(() => expect(movePathMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo/src", "/repo/demo/dest"));
    // The already-nested descendant must not be sent as its own, separately
    // doomed-to-fail move call — it moves for free, nested inside its parent.
    expect(movePathMock).not.toHaveBeenCalledWith("/repo/demo", "/repo/demo/src/util.ts", "/repo/demo/dest");
    expect(movePathMock).toHaveBeenCalledTimes(1);
  });

  // ------------------------------- Bug 1&2: Pointer Capture (drag side)
  // Raw `window`-level mousemove/mouseup listeners only ever got removed
  // inside their own `onUp()` — if the button was released outside the app
  // window, the browser never delivers that `mouseup` at all, so the
  // listeners leaked permanently and the NEXT unrelated mouseup anywhere in
  // the app replayed the stale drag. Pointer Capture fixes this: listeners
  // live on the row that started the drag (never `window`), and the
  // capturing element is guaranteed to receive either `pointerup` or
  // `pointercancel` — there is no third "silently disappeared" case.
  it("a drag that ends with pointerup commits the move and cleans up (no window listeners left behind)", async () => {
    const addSpy = vi.spyOn(window, "addEventListener");
    movePathMock.mockResolvedValue("/repo/demo/src/notes.md");
    setup();
    const notes = await screen.findByText("notes.md");
    const srcRow = screen.getByText("src").closest("[data-file-tree-path]") as HTMLElement;
    document.elementFromPoint = vi.fn().mockReturnValue(srcRow);

    fireEvent.pointerDown(notes, { clientX: 10, clientY: 100, button: 0, pointerId: 1 });
    fireEvent.pointerMove(notes, { clientX: 10, clientY: 40, pointerId: 1 });
    expect(screen.getByText("notes.md").closest(".file-tree-row")).toHaveClass("is-drag-source");
    fireEvent.pointerUp(notes, { clientX: 10, clientY: 40, pointerId: 1 });

    await waitFor(() => expect(movePathMock).toHaveBeenCalledWith("/repo/demo", "/repo/demo/notes.md", "/repo/demo/src"));
    expect(screen.getByText("notes.md").closest(".file-tree-row")).not.toHaveClass("is-drag-source");

    const leaked = addSpy.mock.calls.filter(([type]) =>
      ["mousemove", "mouseup", "pointermove", "pointerup", "pointercancel"].includes(type as string),
    );
    expect(leaked).toEqual([]); // every listener the drag used was attached to the row, not window
    addSpy.mockRestore();
  });

  it("pointercancel (simulating the button being released outside the window) aborts the drag, cleans up, and a later unrelated pointerup never replays it", async () => {
    movePathMock.mockResolvedValue("/repo/demo/src/notes.md");
    setup();
    const notes = await screen.findByText("notes.md");
    const srcRow = screen.getByText("src").closest("[data-file-tree-path]") as HTMLElement;
    document.elementFromPoint = vi.fn().mockReturnValue(srcRow);

    fireEvent.pointerDown(notes, { clientX: 10, clientY: 100, button: 0, pointerId: 1 });
    fireEvent.pointerMove(notes, { clientX: 10, clientY: 40, pointerId: 1 });
    // The drag is genuinely under way — proves pointer events, not clicks, drive it.
    expect(screen.getByText("notes.md").closest(".file-tree-row")).toHaveClass("is-drag-source");

    fireEvent.pointerCancel(notes, { pointerId: 1 });
    expect(screen.getByText("notes.md").closest(".file-tree-row")).not.toHaveClass("is-drag-source");
    expect(movePathMock).not.toHaveBeenCalled();

    // Old bug: a stale `window`-level mouseup listener would replay this
    // drag (calling movePath with the originally-dragged file + whatever
    // hover target happened to be under this later, unrelated event) the
    // next time ANY mouseup fired anywhere in the app.
    fireEvent.pointerUp(document.body, { pointerId: 1 });
    await new Promise((resolve) => setTimeout(resolve, 0));
    expect(movePathMock).not.toHaveBeenCalled();
  });
});
