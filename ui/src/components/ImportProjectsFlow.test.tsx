// Component-level coverage for ImportProjectsFlow.tsx — mocks `../lib/tauri`'s
// `detectImportableTools`/`listImportCandidates`/`addProject` the same way
// `NewWorkspaceModal.test.tsx` mocks `addProject` (vi.hoisted + vi.mock).
// Pure selection/merge/summarization logic already has its own dedicated
// coverage in `../state/importState.test.ts` — these tests exercise the
// component wiring (phase transitions, live counts, per-row rendering,
// bulk-import orchestration, duplicate/partial-failure surfacing) on top of
// it.
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { ProjectInfo } from "../state/sessions";
import type { DetectedTool, ImportCandidate } from "../lib/tauri";
import type { ImportBatchResult } from "../state/importState";

const { detectMock, listMock, addProjectMock } = vi.hoisted(() => ({
  detectMock: vi.fn(),
  listMock: vi.fn(),
  addProjectMock: vi.fn(),
}));

vi.mock("../lib/tauri", () => ({
  detectImportableTools: detectMock,
  listImportCandidates: listMock,
  addProject: addProjectMock,
}));

const { default: ImportProjectsFlow } = await import("./ImportProjectsFlow");

const CLAUDE_CODE: DetectedTool = { id: "claude-code", name: "Claude Code", detected: true, candidate_count: 2 };
const VSCODE: DetectedTool = { id: "vscode", name: "VS Code", detected: true, candidate_count: 1 };
const CURSOR: DetectedTool = { id: "cursor", name: "Cursor", detected: false, candidate_count: 0 };

const CLAUDE_CANDIDATES: ImportCandidate[] = [
  { path: "/Users/bruno/code/alpha", suggested_name: "alpha" },
  { path: "/Users/bruno/code/beta", suggested_name: "beta" },
];
const VSCODE_CANDIDATES: ImportCandidate[] = [{ path: "/Users/bruno/code/gamma", suggested_name: "gamma" }];

function setup(existingProjects: ProjectInfo[] = []) {
  const onImported = vi.fn();
  const onClose = vi.fn();
  render(<ImportProjectsFlow existingProjects={existingProjects} onImported={onImported} onClose={onClose} />);
  return { onImported, onClose };
}

async function goToCandidates() {
  await screen.findByText(/claude code/i);
  fireEvent.click(screen.getByRole("button", { name: /continue/i }));
  await screen.findByText("/Users/bruno/code/alpha");
}

beforeEach(() => {
  detectMock.mockReset();
  listMock.mockReset();
  addProjectMock.mockReset();
  detectMock.mockResolvedValue([CLAUDE_CODE, VSCODE, CURSOR]);
  listMock.mockImplementation((tool: string) =>
    Promise.resolve(tool === "claude-code" ? CLAUDE_CANDIDATES : tool === "vscode" ? VSCODE_CANDIDATES : []),
  );
});

describe("ImportProjectsFlow — tools phase", () => {
  it("shows a loading state, then detected tools with real counts and undetected tools grayed with 'not found'", async () => {
    setup();
    expect(screen.getByText(/checking installed tools/i)).toBeInTheDocument();

    await screen.findByText(/claude code/i);
    expect(screen.getByText("2 projects found")).toBeInTheDocument();
    expect(screen.getByText("1 project found")).toBeInTheDocument();
    expect(screen.getByText(/cursor/i)).toBeInTheDocument();
    expect(screen.getByText("not found")).toBeInTheDocument();
    // Cursor has no checkbox — it's not selectable, only shown for signal.
    expect(screen.getAllByRole("checkbox")).toHaveLength(2);
  });

  it("checks every detected tool by default", async () => {
    setup();
    await screen.findByText(/claude code/i);
    for (const checkbox of screen.getAllByRole("checkbox")) expect(checkbox).toBeChecked();
  });

  it("Continue is disabled once every tool is unchecked", async () => {
    setup();
    await screen.findByText(/claude code/i);
    for (const checkbox of screen.getAllByRole("checkbox")) fireEvent.click(checkbox);
    expect(screen.getByRole("button", { name: /continue/i })).toBeDisabled();
  });

  it("Cancel calls onClose without ever calling listImportCandidates", async () => {
    const { onClose } = setup();
    await screen.findByText(/claude code/i);
    fireEvent.click(screen.getByRole("button", { name: /^cancel$/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
    expect(listMock).not.toHaveBeenCalled();
  });

  it("the × close button calls onClose", async () => {
    const { onClose } = setup();
    await screen.findByText(/claude code/i);
    fireEvent.click(screen.getByRole("button", { name: /close/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
  });

  it("a detect_importable_tools failure shows an inline error instead of crashing", async () => {
    detectMock.mockReset();
    detectMock.mockRejectedValue(new Error("permission denied"));
    setup();
    await screen.findByText(/permission denied/i);
  });
});

describe("ImportProjectsFlow — candidates phase", () => {
  it("fetches candidates only for checked tools and merges them, grouped by tool", async () => {
    setup();
    await goToCandidates();

    expect(listMock).toHaveBeenCalledWith("claude-code");
    expect(listMock).toHaveBeenCalledWith("vscode");
    expect(listMock).not.toHaveBeenCalledWith("cursor");

    expect(screen.getByText("alpha")).toBeInTheDocument();
    expect(screen.getByText("beta")).toBeInTheDocument();
    expect(screen.getByText("gamma")).toBeInTheDocument();
  });

  it("does not fetch candidates for a tool the user unchecked", async () => {
    setup();
    await screen.findByText(/claude code/i);
    fireEvent.click(screen.getByRole("checkbox", { name: /vs code/i }));
    fireEvent.click(screen.getByRole("button", { name: /continue/i }));
    await screen.findByText("alpha");

    expect(listMock).toHaveBeenCalledWith("claude-code");
    expect(listMock).not.toHaveBeenCalledWith("vscode");
    expect(screen.queryByText("gamma")).not.toBeInTheDocument();
  });

  it("defaults every row checked, and the Import Selected count matches", async () => {
    setup();
    await goToCandidates();
    expect(screen.getByRole("button", { name: /import selected \(3\)/i })).toBeInTheDocument();
  });

  it("unchecking one row updates the live count", async () => {
    setup();
    await goToCandidates();
    fireEvent.click(screen.getByRole("checkbox", { name: /alpha/i }));
    expect(screen.getByRole("button", { name: /import selected \(2\)/i })).toBeInTheDocument();
  });

  it("a per-tool select-all/none toggle checks/unchecks only that tool's rows", async () => {
    setup();
    await goToCandidates();
    const claudeGroup = screen.getByText("Claude Code").closest<HTMLElement>(".import-tool-group")!;
    const groupToggle = within(claudeGroup).getByRole("checkbox", { name: /claude code/i });

    fireEvent.click(groupToggle); // uncheck the whole claude-code group
    expect(screen.getByRole("button", { name: /import selected \(1\)/i })).toBeInTheDocument(); // only gamma left
    expect(screen.getByRole("checkbox", { name: /alpha/i })).not.toBeChecked();
    expect(screen.getByRole("checkbox", { name: /gamma/i })).toBeChecked();

    fireEvent.click(groupToggle); // re-check it
    expect(screen.getByRole("button", { name: /import selected \(3\)/i })).toBeInTheDocument();
  });

  it("Back returns to the tools phase without losing tool selection", async () => {
    setup();
    await goToCandidates();
    fireEvent.click(screen.getByRole("button", { name: /^back$/i }));
    await screen.findByText(/claude code/i);
    expect(screen.getByRole("checkbox", { name: /claude code/i })).toBeChecked();
    expect(screen.queryByText("alpha")).not.toBeInTheDocument();
  });

  it("a path already reported by two tools appears only once", async () => {
    listMock.mockImplementation((tool: string) =>
      Promise.resolve(
        tool === "claude-code"
          ? [{ path: "/Users/bruno/code/shared", suggested_name: "shared" }]
          : [{ path: "/Users/bruno/code/shared", suggested_name: "shared" }],
      ),
    );
    setup();
    await screen.findByText(/claude code/i);
    fireEvent.click(screen.getByRole("button", { name: /continue/i }));
    await screen.findByText("shared");
    expect(screen.getAllByText("shared")).toHaveLength(1);
    expect(screen.getByRole("button", { name: /import selected \(1\)/i })).toBeInTheDocument();
  });

  it("a candidate matching an existing project is shown disabled, unchecked, tagged, and excluded from the count", async () => {
    const existing: ProjectInfo[] = [{ id: "beta", label: "beta", path: "/Users/bruno/code/beta" }];
    setup(existing);
    await goToCandidates();

    const betaCheckbox = screen.getByRole("checkbox", { name: /beta/i });
    expect(betaCheckbox).toBeDisabled();
    expect(betaCheckbox).not.toBeChecked();
    expect(screen.getByText("Already added")).toBeInTheDocument();
    expect(screen.getByRole("button", { name: /import selected \(2\)/i })).toBeInTheDocument(); // alpha + gamma only

    // Clicking it does nothing — still disabled/unchecked.
    fireEvent.click(betaCheckbox);
    expect(betaCheckbox).not.toBeChecked();
  });
});

describe("ImportProjectsFlow — bulk import + partial failure", () => {
  it("calls add_project once per checked candidate, in checklist order, then shows a Done summary", async () => {
    addProjectMock.mockImplementation((path: string, name: string) =>
      Promise.resolve({ id: name, label: name, path }),
    );
    const { onImported, onClose } = setup();
    await goToCandidates();

    fireEvent.click(screen.getByRole("button", { name: /import selected \(3\)/i }));

    await waitFor(() => expect(screen.getByRole("button", { name: /^done$/i })).toBeInTheDocument());
    expect(addProjectMock).toHaveBeenCalledTimes(3);
    expect(addProjectMock).toHaveBeenNthCalledWith(1, "/Users/bruno/code/alpha", "alpha");
    expect(addProjectMock).toHaveBeenNthCalledWith(2, "/Users/bruno/code/beta", "beta");
    expect(addProjectMock).toHaveBeenNthCalledWith(3, "/Users/bruno/code/gamma", "gamma");
    expect(screen.getByText("Imported 3 projects.")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /^done$/i }));
    expect(onClose).toHaveBeenCalledTimes(1);
    const result = onImported.mock.calls[0][0] as ImportBatchResult;
    expect(result.created).toHaveLength(3);
    expect(result.failed).toHaveLength(0);
  });

  it("only imports checked candidates, skipping unchecked ones entirely", async () => {
    addProjectMock.mockImplementation((path: string, name: string) =>
      Promise.resolve({ id: name, label: name, path }),
    );
    setup();
    await goToCandidates();
    fireEvent.click(screen.getByRole("checkbox", { name: /beta/i })); // uncheck beta

    fireEvent.click(screen.getByRole("button", { name: /import selected \(2\)/i }));

    await waitFor(() => expect(screen.getByRole("button", { name: /^done$/i })).toBeInTheDocument());
    expect(addProjectMock).toHaveBeenCalledTimes(2);
    expect(addProjectMock).not.toHaveBeenCalledWith("/Users/bruno/code/beta", "beta");
  });

  it("one add_project rejecting doesn't abort the batch — the rest still import, and both outcomes show", async () => {
    addProjectMock.mockImplementation((path: string, name: string) => {
      if (name === "beta") return Promise.reject(new Error("already added"));
      return Promise.resolve({ id: name, label: name, path });
    });
    const { onImported } = setup();
    await goToCandidates();

    fireEvent.click(screen.getByRole("button", { name: /import selected \(3\)/i }));

    await waitFor(() => expect(screen.getByRole("button", { name: /^done$/i })).toBeInTheDocument());
    expect(addProjectMock).toHaveBeenCalledTimes(3); // beta's rejection never stopped alpha/gamma
    expect(screen.getByText("Imported 2 of 3 projects — 1 failed.")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /^done$/i }));
    const result = onImported.mock.calls[0][0] as ImportBatchResult;
    expect(result.created).toHaveLength(2);
    expect(result.failed).toEqual([
      { path: "/Users/bruno/code/beta", suggestedName: "beta", success: false, error: "Error: already added" },
    ]);
  });

  it("every add_project failing still lets the user close via Done, never traps them", async () => {
    addProjectMock.mockRejectedValue(new Error("disk full"));
    const { onImported } = setup();
    await goToCandidates();

    fireEvent.click(screen.getByRole("button", { name: /import selected \(3\)/i }));

    await waitFor(() => expect(screen.getByRole("button", { name: /^done$/i })).toBeInTheDocument());
    expect(screen.getByText("Couldn't import 3 projects.")).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /^done$/i }));
    const result = onImported.mock.calls[0][0] as ImportBatchResult;
    expect(result.created).toHaveLength(0);
    expect(result.failed).toHaveLength(3);
  });

  it("disables the checklist and shows a live progress count while importing", async () => {
    let resolveFirst!: (v: { id: string; label: string; path: string }) => void;
    addProjectMock.mockImplementation(
      (path: string, name: string) =>
        new Promise((resolve) => {
          if (name === "alpha") resolveFirst = resolve;
          else resolve({ id: name, label: name, path });
        }),
    );
    setup();
    await goToCandidates();

    fireEvent.click(screen.getByRole("button", { name: /import selected \(3\)/i }));
    await screen.findByText(/importing…/i);
    expect(screen.getByRole("checkbox", { name: /gamma/i })).toBeDisabled();

    resolveFirst({ id: "alpha", label: "alpha", path: "/Users/bruno/code/alpha" });
    await waitFor(() => expect(screen.getByRole("button", { name: /^done$/i })).toBeInTheDocument());
  });
});
