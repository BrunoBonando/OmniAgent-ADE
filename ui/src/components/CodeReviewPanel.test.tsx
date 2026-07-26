// Component coverage for the per-session code review column (founder ask,
// 2026-07-26). Mocks `../lib/tauri` and `@tauri-apps/plugin-opener` the same
// way `FileTree.test.tsx` already does.
//
// The fixtures below are REAL captured output from the actual Rust commands
// run against this repository — see the panel's own doc comment and the
// dispatch's verification notes; nothing here is a hand-invented shape.
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { FileDiff, ReviewStatus } from "../lib/tauri";

const {
  reviewStatusMock,
  reviewFileDiffMock,
  reviewCommitMock,
  reviewRevertFileMock,
  settingsGetMock,
  settingsSetMock,
  openPathMock,
} = vi.hoisted(() => ({
  reviewStatusMock: vi.fn(),
  reviewFileDiffMock: vi.fn(),
  reviewCommitMock: vi.fn(),
  reviewRevertFileMock: vi.fn(),
  settingsGetMock: vi.fn(),
  settingsSetMock: vi.fn(),
  openPathMock: vi.fn(),
}));

vi.mock("../lib/tauri", () => ({
  reviewStatus: reviewStatusMock,
  reviewFileDiff: reviewFileDiffMock,
  reviewCommit: reviewCommitMock,
  reviewRevertFile: reviewRevertFileMock,
  settingsGet: settingsGetMock,
  settingsSet: settingsSetMock,
  CODE_REVIEW_WIDTH_SETTING_KEY: "code_review_width",
}));

vi.mock("@tauri-apps/plugin-opener", () => ({ openPath: openPathMock }));

import CodeReviewPanel from "./CodeReviewPanel";

/** Real `review_status` output captured from this repo. */
const REAL_STATUS: ReviewStatus = {
  repo_root: "/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE",
  branch: "main",
  detached: false,
  has_head: true,
  files: [
    { path: "crates/brain-ingest/src/lib.rs", status: "modified", old_path: null, added: 1, removed: 0, binary: false },
    { path: "src-tauri/src/commands.rs", status: "modified", old_path: null, added: 133, removed: 0, binary: false },
    { path: "src-tauri/src/lib.rs", status: "modified", old_path: null, added: 4, removed: 0, binary: false },
    { path: "crates/brain-ingest/src/gitreview.rs", status: "untracked", old_path: null, added: 1321, removed: 0, binary: false },
    { path: "docs/reference/warp-user-menu.png", status: "untracked", old_path: null, added: null, removed: null, binary: true },
  ],
  file_count: 5,
  added: 1459,
  removed: 0,
  binary_count: 1,
  truncated: false,
};

/** Real `review_file_diff` output for src-tauri/src/lib.rs. */
const REAL_DIFF: FileDiff = {
  path: "src-tauri/src/lib.rs",
  binary: false,
  hunks: [
    {
      header: "@@ -272,6 +272,10 @@ pub fn run() {",
      lines: [
        { kind: "context", old_line: 272, new_line: 272, text: "            commands::unwatch_dir," },
        { kind: "context", old_line: 273, new_line: 273, text: "            commands::detect_importable_tools," },
        { kind: "added", old_line: null, new_line: 275, text: "            commands::review_status," },
        { kind: "added", old_line: null, new_line: 276, text: "            commands::review_file_diff," },
      ],
    },
  ],
  truncated: false,
  line_count: 4,
};

beforeEach(() => {
  vi.clearAllMocks();
  settingsGetMock.mockResolvedValue(null);
  settingsSetMock.mockResolvedValue(undefined);
  reviewStatusMock.mockResolvedValue(REAL_STATUS);
  reviewFileDiffMock.mockResolvedValue(REAL_DIFF);
});

function renderPanel(over: Partial<React.ComponentProps<typeof CodeReviewPanel>> = {}) {
  return render(
    <CodeReviewPanel
      repoPath="/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE"
      sessionLabel="claude · ADE"
      onClose={() => {}}
      {...over}
    />,
  );
}

describe("per-session scoping", () => {
  it("asks the backend about the session's own cwd, not some global repo", async () => {
    renderPanel({ repoPath: "/tmp/session-a" });
    await waitFor(() => expect(reviewStatusMock).toHaveBeenCalledWith("/tmp/session-a"));
  });

  it("names the session it is reviewing", async () => {
    renderPanel();
    expect(await screen.findByText("claude · ADE")).toBeInTheDocument();
  });

  it("re-targets when the panel is reopened from a different session's pane", async () => {
    const { rerender } = renderPanel({ repoPath: "/tmp/session-a" });
    await waitFor(() => expect(reviewStatusMock).toHaveBeenCalledWith("/tmp/session-a"));

    reviewStatusMock.mockResolvedValue({ ...REAL_STATUS, repo_root: "/tmp/session-b", file_count: 0, files: [] });
    rerender(
      <CodeReviewPanel repoPath="/tmp/session-b" sessionLabel="shell · other" onClose={() => {}} />,
    );
    await waitFor(() => expect(reviewStatusMock).toHaveBeenCalledWith("/tmp/session-b"));
  });
});

describe("header", () => {
  it("shows the abbreviated repo path, branch, file count and aggregate", async () => {
    renderPanel();
    expect(await screen.findByText("~/Documents/Bruno.Digital/OmniAgent-ADE")).toBeInTheDocument();
    expect(screen.getByText(/main/)).toBeInTheDocument();
    // Scoped to the header's own totals block — `-0` also appears on every
    // per-file badge, so an unscoped query is genuinely ambiguous here.
    const totals = screen.getByText("+1459").parentElement as HTMLElement;
    expect(within(totals).getByText("-0")).toBeInTheDocument();
    expect(screen.getByTitle("5 changed files")).toBeInTheDocument();
  });

  it("discloses that the aggregate excludes binary files", async () => {
    renderPanel();
    expect(await screen.findByText(/1 binary file not counted/)).toBeInTheDocument();
  });

  it("shows a clean-tree message when nothing is uncommitted", async () => {
    reviewStatusMock.mockResolvedValue({ ...REAL_STATUS, files: [], file_count: 0, added: 0, removed: 0, binary_count: 0 });
    renderPanel();
    expect(await screen.findByText(/Nothing uncommitted/)).toBeInTheDocument();
  });

  it("surfaces a not-a-git-repo error instead of rendering an empty panel", async () => {
    reviewStatusMock.mockRejectedValue("/tmp/nope isn't inside a git repository");
    renderPanel();
    expect(await screen.findByText(/isn't inside a git repository/)).toBeInTheDocument();
  });
});

describe("file list", () => {
  it("lists every changed file", async () => {
    renderPanel();
    expect(await screen.findByText("src-tauri/src/commands.rs")).toBeInTheDocument();
    expect(screen.getByText("crates/brain-ingest/src/gitreview.rs")).toBeInTheDocument();
  });

  it("renders a binary file as binary rather than as +0 -0", async () => {
    renderPanel();
    expect(await screen.findByText("binary")).toBeInTheDocument();
  });

  it("shows per-file stats", async () => {
    renderPanel();
    expect(await screen.findByText("+133")).toBeInTheDocument();
  });

  it("marks untracked files apart from modified ones", async () => {
    renderPanel();
    await screen.findByText("src-tauri/src/commands.rs");
    expect(screen.getAllByTitle("Untracked").length).toBe(2);
    expect(screen.getAllByTitle("Modified").length).toBe(3);
  });
});

describe("expand to see the diff", () => {
  it("fetches and renders the diff with real line numbers on expand", async () => {
    renderPanel();
    fireEvent.click(await screen.findByLabelText("Expand src-tauri/src/lib.rs"));

    await waitFor(() =>
      expect(reviewFileDiffMock).toHaveBeenCalledWith(
        "/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE",
        "src-tauri/src/lib.rs",
      ),
    );
    expect(await screen.findByText("@@ -272,6 +272,10 @@ pub fn run() {")).toBeInTheDocument();
    // testing-library normalizes the element's text but not the matcher
    // string, so this is asserted trimmed.
    expect(screen.getByText("commands::review_status,")).toBeInTheDocument();
    // Both gutters are rendered: the context line carries 272 twice, the
    // added line only a new-side 275.
    expect(screen.getAllByText("272").length).toBe(2);
    expect(screen.getByText("275")).toBeInTheDocument();
  });

  it("collapses again without refetching", async () => {
    renderPanel();
    const toggle = await screen.findByLabelText("Expand src-tauri/src/lib.rs");
    fireEvent.click(toggle);
    await screen.findByText("@@ -272,6 +272,10 @@ pub fn run() {");

    fireEvent.click(screen.getByLabelText("Collapse src-tauri/src/lib.rs"));
    await waitFor(() =>
      expect(screen.queryByText("@@ -272,6 +272,10 @@ pub fn run() {")).not.toBeInTheDocument(),
    );

    fireEvent.click(screen.getByLabelText("Expand src-tauri/src/lib.rs"));
    await screen.findByText("@@ -272,6 +272,10 @@ pub fn run() {");
    expect(reviewFileDiffMock).toHaveBeenCalledTimes(1);
  });

  it("says so for a binary file rather than showing an empty diff", async () => {
    reviewFileDiffMock.mockResolvedValue({
      path: "docs/reference/warp-user-menu.png",
      binary: true,
      hunks: [],
      truncated: false,
      line_count: 0,
    });
    renderPanel();
    fireEvent.click(await screen.findByLabelText("Expand docs/reference/warp-user-menu.png"));
    expect(await screen.findByText(/Binary file — no line-by-line diff/)).toBeInTheDocument();
  });
});

describe("commit", () => {
  it("won't commit without a message", async () => {
    renderPanel();
    await screen.findByText("src-tauri/src/commands.rs");
    expect(screen.getByRole("button", { name: /Commit all 5/ })).toBeDisabled();
    expect(screen.getByText("Write a commit message first")).toBeInTheDocument();
  });

  it("commits every listed change with the typed message and refreshes", async () => {
    reviewCommitMock.mockResolvedValue({ sha: "abc1234def", short_sha: "abc1234", files_committed: 5 });
    renderPanel();
    await screen.findByText("src-tauri/src/commands.rs");

    fireEvent.change(screen.getByLabelText("Commit message"), { target: { value: "feat: real work" } });
    fireEvent.click(screen.getByRole("button", { name: /Commit all 5/ }));

    await waitFor(() =>
      expect(reviewCommitMock).toHaveBeenCalledWith(
        "/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE",
        "feat: real work",
      ),
    );
    expect(await screen.findByText(/Committed 5 files as abc1234/)).toBeInTheDocument();
    // Refetched after committing rather than trusting a stale list.
    expect(reviewStatusMock.mock.calls.length).toBeGreaterThan(1);
  });

  it("shows the backend's own error when a commit fails", async () => {
    reviewCommitMock.mockRejectedValue("nothing to commit — the working tree is clean");
    renderPanel();
    await screen.findByText("src-tauri/src/commands.rs");
    fireEvent.change(screen.getByLabelText("Commit message"), { target: { value: "x" } });
    fireEvent.click(screen.getByRole("button", { name: /Commit all 5/ }));
    expect(await screen.findByText(/nothing to commit/)).toBeInTheDocument();
  });
});

describe("revert is never a bare one-click", () => {
  it("asks for confirmation before discarding a modified file", async () => {
    renderPanel();
    fireEvent.click(await screen.findByLabelText("Revert src-tauri/src/lib.rs"));

    // Nothing happened yet — only a prompt appeared.
    expect(reviewRevertFileMock).not.toHaveBeenCalled();
    expect(screen.getByText(/can't be undone/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Discard changes" }));
    await waitFor(() =>
      expect(reviewRevertFileMock).toHaveBeenCalledWith(
        "/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE",
        "src-tauri/src/lib.rs",
      ),
    );
  });

  it("offers the Trash — not a discard — for an untracked file", async () => {
    reviewRevertFileMock.mockResolvedValue("moved_to_trash");
    renderPanel();
    fireEvent.click(await screen.findByLabelText("Revert crates/brain-ingest/src/gitreview.rs"));
    expect(screen.getByText(/goes to the macOS Trash/)).toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: "Move to Trash" }));
    await waitFor(() => expect(reviewRevertFileMock).toHaveBeenCalled());
    expect(await screen.findByText(/Moved .* to the Trash/)).toBeInTheDocument();
  });

  it("cancelling leaves the file alone", async () => {
    renderPanel();
    fireEvent.click(await screen.findByLabelText("Revert src-tauri/src/lib.rs"));
    fireEvent.click(screen.getByRole("button", { name: "Cancel" }));
    expect(reviewRevertFileMock).not.toHaveBeenCalled();
    expect(screen.queryByText(/can't be undone/)).not.toBeInTheDocument();
  });

  it("refuses a rename up front instead of letting the call fail", async () => {
    reviewStatusMock.mockResolvedValue({
      ...REAL_STATUS,
      files: [{ path: "new.txt", status: "renamed", old_path: "old.txt", added: 0, removed: 0, binary: false }],
      file_count: 1,
    });
    renderPanel();
    fireEvent.click(await screen.findByLabelText("Revert new.txt"));
    expect(screen.getByText(/Renamed from old\.txt/)).toBeInTheDocument();
    expect(screen.queryByRole("button", { name: "Discard changes" })).not.toBeInTheDocument();
  });
});

describe("large change sets", () => {
  it("pages a huge file list rather than rendering every row at once", async () => {
    const many = new Array(240).fill(null).map((_, i) => ({
      path: `generated/file-${i}.ts`,
      status: "untracked" as const,
      old_path: null,
      added: 3,
      removed: 0,
      binary: false,
    }));
    reviewStatusMock.mockResolvedValue({ ...REAL_STATUS, files: many, file_count: 240, binary_count: 0 });
    renderPanel();

    expect(await screen.findByText("generated/file-0.ts")).toBeInTheDocument();
    expect(screen.queryByText("generated/file-100.ts")).not.toBeInTheDocument();

    fireEvent.click(screen.getByRole("button", { name: /Show 80 more/ }));
    expect(await screen.findByText("generated/file-100.ts")).toBeInTheDocument();
  });

  it("discloses a backend-truncated file list", async () => {
    reviewStatusMock.mockResolvedValue({ ...REAL_STATUS, file_count: 5000, truncated: true });
    renderPanel();
    expect(await screen.findByText(/showing the first 5 of 5000 files/)).toBeInTheDocument();
  });
});

describe("row actions", () => {
  it("copies a file's path", async () => {
    const writeText = vi.fn().mockResolvedValue(undefined);
    Object.assign(navigator, { clipboard: { writeText } });
    renderPanel();
    fireEvent.click(await screen.findByLabelText("Copy path of src-tauri/src/lib.rs"));
    await waitFor(() => expect(writeText).toHaveBeenCalledWith("src-tauri/src/lib.rs"));
  });

  it("opens a file with the OS default app", async () => {
    openPathMock.mockResolvedValue(undefined);
    renderPanel();
    fireEvent.click(await screen.findByLabelText("Open src-tauri/src/lib.rs"));
    await waitFor(() =>
      expect(openPathMock).toHaveBeenCalledWith(
        "/Users/bonando/Documents/Bruno.Digital/OmniAgent-ADE/src-tauri/src/lib.rs",
      ),
    );
  });

  it("closes on the close button", async () => {
    const onClose = vi.fn();
    renderPanel({ onClose });
    fireEvent.click(await screen.findByLabelText("Close code review"));
    expect(onClose).toHaveBeenCalled();
  });
});
