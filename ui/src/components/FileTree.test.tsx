// Founder feedback, 2026-07-25: "nice to have a folder/file navigation on
// the right panel." Component-level coverage for FileTree.tsx, mocking the
// same two surfaces DetailPanel.tsx's real (unmocked, since it has no test
// file yet) usage would need mocked: `../lib/tauri` (here, `listDir` +
// `sessionWrite`) and `@tauri-apps/plugin-opener` (`openPath`/
// `revealItemInDir`) — the established pattern in this codebase for
// components that call these (see BrainMap.test.tsx's `vi.mock("../lib/
// tauri", ...)`).
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo } from "../state/sessions";
import type { DirEntry } from "../lib/tauri";

const { listDirMock, sessionWriteMock, openPathMock, revealItemInDirMock } = vi.hoisted(() => ({
  listDirMock: vi.fn(),
  sessionWriteMock: vi.fn(),
  openPathMock: vi.fn(),
  revealItemInDirMock: vi.fn(),
}));

vi.mock("../lib/tauri", () => ({
  listDir: listDirMock,
  sessionWrite: sessionWriteMock,
}));

vi.mock("@tauri-apps/plugin-opener", () => ({
  openPath: openPathMock,
  revealItemInDir: revealItemInDirMock,
}));

const { default: FileTree } = await import("./FileTree");

const PROJECT: ProjectInfo = { id: "demo", label: "demo", path: "/repo/demo" };

function rootEntries(): DirEntry[] {
  return [
    { name: "src", path: "/repo/demo/src", is_dir: true },
    { name: "main.py", path: "/repo/demo/main.py", is_dir: false },
  ];
}

function childEntries(): DirEntry[] {
  return [{ name: "util.ts", path: "/repo/demo/src/util.ts", is_dir: false }];
}

function setup(overrides: Partial<Parameters<typeof FileTree>[0]> = {}) {
  const onClose = vi.fn();
  render(<FileTree project={PROJECT} activeTabId={null} onClose={onClose} {...overrides} />);
  return { onClose };
}

describe("FileTree", () => {
  beforeEach(() => {
    listDirMock.mockReset();
    sessionWriteMock.mockReset();
    openPathMock.mockReset();
    revealItemInDirMock.mockReset();
    listDirMock.mockResolvedValue(rootEntries());
    openPathMock.mockResolvedValue(undefined);
    revealItemInDirMock.mockResolvedValue(undefined);
    sessionWriteMock.mockResolvedValue(undefined);
  });

  it("prompts to select a project when none is selected", () => {
    render(<FileTree project={null} activeTabId={null} onClose={() => {}} />);
    expect(screen.getByText(/select a project/i)).toBeInTheDocument();
    expect(listDirMock).not.toHaveBeenCalled();
  });

  it("shows a graceful message for a project with no known path", () => {
    render(
      <FileTree project={{ id: "x", label: "x", path: null }} activeTabId={null} onClose={() => {}} />,
    );
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

  it("clicking a directory row lazily loads and reveals its children exactly once", async () => {
    listDirMock.mockImplementation((path: string) =>
      Promise.resolve(path === "/repo/demo" ? rootEntries() : childEntries()),
    );
    setup();
    await screen.findByText("src");
    expect(listDirMock).toHaveBeenCalledTimes(1);

    fireEvent.click(screen.getByText("src"));
    expect(await screen.findByText("util.ts")).toBeInTheDocument();
    expect(listDirMock).toHaveBeenCalledWith("/repo/demo/src");
    expect(listDirMock).toHaveBeenCalledTimes(2);

    // Collapse, then re-expand — the cached children must not be re-fetched.
    fireEvent.click(screen.getByText("src"));
    expect(screen.queryByText("util.ts")).not.toBeInTheDocument();
    fireEvent.click(screen.getByText("src"));
    expect(await screen.findByText("util.ts")).toBeInTheDocument();
    expect(listDirMock).toHaveBeenCalledTimes(2);
  });

  it("clicking a file opens it via openPath, not a toggle", async () => {
    setup();
    await screen.findByText("main.py");
    fireEvent.click(screen.getByText("main.py"));
    await waitFor(() => expect(openPathMock).toHaveBeenCalledWith("/repo/demo/main.py"));
    expect(screen.queryByText("util.ts")).not.toBeInTheDocument();
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
    await waitFor(() =>
      expect(sessionWriteMock).toHaveBeenCalledWith("sess-1", '"/repo/demo/main.py" '),
    );
  });
});
