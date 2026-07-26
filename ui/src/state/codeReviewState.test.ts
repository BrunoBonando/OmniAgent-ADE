// Pure logic behind the per-session code review panel — the derived header
// stats, the per-file stat badge, expand/collapse, the resize math, and the
// two render caps that keep a 158-file working tree (the reference
// screenshot's own number) from janking the panel.
import { describe, expect, it } from "vitest";
import type { ChangedFile, DiffHunk, ReviewStatus } from "../lib/tauri";
import {
  CODE_REVIEW_DEFAULT_WIDTH,
  clampCodeReviewWidth,
  codeReviewWidthFromDrag,
  commitDisabledReason,
  DIFF_RENDER_CAP,
  deriveHeaderStats,
  fileListPage,
  FILE_PAGE_SIZE,
  formatFileStat,
  homeAbbreviated,
  nextVisibleCount,
  renderableDiffLines,
  revertPrompt,
  statusGlyph,
  toggleExpandedFile,
} from "./codeReviewState";

function file(over: Partial<ChangedFile> = {}): ChangedFile {
  return {
    path: "src/main.rs",
    status: "modified",
    old_path: null,
    added: 3,
    removed: 1,
    binary: false,
    ...over,
  };
}

function status(over: Partial<ReviewStatus> = {}): ReviewStatus {
  return {
    repo_root: "/Users/bonando/Documents/Bruno.Digital/My-Brain",
    branch: "main",
    detached: false,
    has_head: true,
    files: [file()],
    file_count: 1,
    added: 3,
    removed: 1,
    binary_count: 0,
    truncated: false,
    ...over,
  };
}

describe("formatFileStat", () => {
  it("reports added and removed counts for a normal text file", () => {
    expect(formatFileStat(file({ added: 21, removed: 0 }))).toEqual({
      kind: "counts",
      added: 21,
      removed: 0,
    });
  });

  it("reports a binary file as binary rather than as +0 -0", () => {
    // The backend sends null counts for a binary file precisely so the UI
    // never renders a truthful-looking zero — this is where that pays off.
    expect(formatFileStat(file({ binary: true, added: null, removed: null }))).toEqual({
      kind: "binary",
    });
  });

  it("collapses a zero-line change to the reference's plain 0 badge", () => {
    // The reference screenshot shows a bare grey `0` for its empty .log
    // files rather than `+0 · -0`.
    expect(formatFileStat(file({ added: 0, removed: 0 }))).toEqual({ kind: "empty" });
  });
});

describe("deriveHeaderStats", () => {
  it("derives the file count and aggregate the panel header shows", () => {
    const stats = deriveHeaderStats(
      status({ file_count: 158, added: 12910, removed: 0, files: [] }),
    );
    expect(stats.fileCount).toBe(158);
    expect(stats.added).toBe(12910);
    expect(stats.removed).toBe(0);
    expect(stats.branchLabel).toBe("main");
    expect(stats.pathLabel).toBe("~/Documents/Bruno.Digital/My-Brain");
  });

  it("names a detached HEAD instead of inventing a branch", () => {
    expect(deriveHeaderStats(status({ branch: null, detached: true })).branchLabel).toBe("detached");
  });

  it("says so when the repo has no commits yet", () => {
    expect(deriveHeaderStats(status({ branch: null, has_head: false })).branchLabel).toBe("no commits yet");
  });

  it("discloses that binary files are excluded from the aggregate", () => {
    const stats = deriveHeaderStats(status({ file_count: 5, binary_count: 2 }));
    expect(stats.binaryNote).toBe("2 binary files not counted");
  });

  it("has no binary note when nothing is binary", () => {
    expect(deriveHeaderStats(status({ binary_count: 0 })).binaryNote).toBeNull();
  });

  it("discloses a truncated file list rather than silently showing fewer files", () => {
    const stats = deriveHeaderStats(status({ file_count: 5000, files: new Array(2000).fill(file()), truncated: true }));
    expect(stats.truncatedNote).toBe("showing the first 2000 of 5000 files");
  });

  it("returns a clean empty state for a clean working tree", () => {
    const stats = deriveHeaderStats(status({ files: [], file_count: 0, added: 0, removed: 0 }));
    expect(stats.fileCount).toBe(0);
    expect(stats.isClean).toBe(true);
  });
});

describe("homeAbbreviated", () => {
  it("shortens a home-directory path the way the reference header does", () => {
    expect(homeAbbreviated("/Users/bonando/Documents/Bruno.Digital/My-Brain")).toBe(
      "~/Documents/Bruno.Digital/My-Brain",
    );
  });

  it("leaves a path outside any home directory alone", () => {
    expect(homeAbbreviated("/opt/src/thing")).toBe("/opt/src/thing");
  });

  it("handles the home directory itself", () => {
    expect(homeAbbreviated("/Users/bonando")).toBe("~");
  });
});

describe("toggleExpandedFile", () => {
  it("expands a collapsed row and collapses an expanded one", () => {
    const once = toggleExpandedFile(new Set<string>(), "a.txt");
    expect(once.has("a.txt")).toBe(true);
    expect(toggleExpandedFile(once, "a.txt").has("a.txt")).toBe(false);
  });

  it("never mutates the set it was handed", () => {
    const before = new Set<string>(["a.txt"]);
    toggleExpandedFile(before, "b.txt");
    expect(before.has("b.txt")).toBe(false);
  });

  it("keeps other expanded rows open", () => {
    const next = toggleExpandedFile(new Set(["a.txt"]), "b.txt");
    expect(next.has("a.txt")).toBe(true);
    expect(next.has("b.txt")).toBe(true);
  });
});

describe("file list paging", () => {
  const many = new Array(500).fill(null).map((_, i) => file({ path: `f${i}.txt` }));

  it("renders only the first page of a very large change set", () => {
    const page = fileListPage(many, FILE_PAGE_SIZE);
    expect(page.shown).toHaveLength(FILE_PAGE_SIZE);
    expect(page.remaining).toBe(500 - FILE_PAGE_SIZE);
    expect(page.hasMore).toBe(true);
  });

  it("shows everything once the visible count covers the list", () => {
    const page = fileListPage(many, 1000);
    expect(page.shown).toHaveLength(500);
    expect(page.remaining).toBe(0);
    expect(page.hasMore).toBe(false);
  });

  it("grows the visible count by one page at a time, never past the total", () => {
    expect(nextVisibleCount(FILE_PAGE_SIZE, 500)).toBe(FILE_PAGE_SIZE * 2);
    expect(nextVisibleCount(480, 500)).toBe(500);
  });
});

describe("renderableDiffLines", () => {
  function hunk(n: number): DiffHunk {
    return {
      header: `@@ -1,${n} +1,${n} @@`,
      lines: new Array(n).fill(null).map((_, i) => ({
        kind: "added" as const,
        old_line: null,
        new_line: i + 1,
        text: `line ${i}`,
      })),
    };
  }

  it("passes a small diff through untouched", () => {
    const out = renderableDiffLines([hunk(10)]);
    expect(out.capped).toBe(false);
    expect(out.shown).toBe(10);
    expect(out.hunks[0].lines).toHaveLength(10);
  });

  it("caps a huge diff and reports how much it cut", () => {
    const out = renderableDiffLines([hunk(DIFF_RENDER_CAP + 200)]);
    expect(out.capped).toBe(true);
    expect(out.shown).toBe(DIFF_RENDER_CAP);
    expect(out.total).toBe(DIFF_RENDER_CAP + 200);
  });

  it("cuts across hunk boundaries without dropping a whole hunk's header", () => {
    const out = renderableDiffLines([hunk(DIFF_RENDER_CAP - 1), hunk(50)]);
    expect(out.shown).toBe(DIFF_RENDER_CAP);
    expect(out.hunks).toHaveLength(2);
    expect(out.hunks[1].lines).toHaveLength(1);
  });

  it("drops hunks entirely past the cap rather than rendering empty shells", () => {
    const out = renderableDiffLines([hunk(DIFF_RENDER_CAP), hunk(50)]);
    expect(out.hunks).toHaveLength(1);
  });
});

describe("commitDisabledReason", () => {
  it("blocks a commit with no message", () => {
    expect(commitDisabledReason(status(), "   ", false)).toBe("Write a commit message first");
  });

  it("blocks a commit with nothing to commit", () => {
    expect(commitDisabledReason(status({ file_count: 0, files: [] }), "msg", false)).toBe(
      "Nothing to commit",
    );
  });

  it("blocks a second commit while one is already running", () => {
    expect(commitDisabledReason(status(), "msg", true)).toBe("Committing…");
  });

  it("allows a real commit", () => {
    expect(commitDisabledReason(status(), "feat: real", false)).toBeNull();
  });
});

describe("revertPrompt", () => {
  it("warns that a modified file's edits are gone for good", () => {
    const prompt = revertPrompt(file({ status: "modified" }));
    expect(prompt.destructive).toBe(true);
    expect(prompt.confirmLabel).toBe("Discard changes");
    expect(prompt.detail).toContain("can't be undone");
  });

  it("offers the Trash for an untracked file, which is recoverable", () => {
    const prompt = revertPrompt(file({ status: "untracked" }));
    expect(prompt.confirmLabel).toBe("Move to Trash");
    expect(prompt.detail).toContain("Trash");
  });

  it("offers the Trash for a staged-new file too", () => {
    expect(revertPrompt(file({ status: "added" })).confirmLabel).toBe("Move to Trash");
  });

  it("refuses a rename up front rather than letting the call fail", () => {
    const prompt = revertPrompt(file({ status: "renamed", old_path: "old.txt" }));
    expect(prompt.blocked).toBe(true);
    expect(prompt.detail).toContain("old.txt");
  });
});

describe("statusGlyph", () => {
  it("gives every change kind its own single-letter marker", () => {
    const glyphs = (["modified", "added", "deleted", "renamed", "untracked"] as const).map(
      (s) => statusGlyph(s).letter,
    );
    expect(new Set(glyphs).size).toBe(5);
    expect(statusGlyph("modified").letter).toBe("M");
    expect(statusGlyph("untracked").letter).toBe("U");
  });
});

describe("resize math", () => {
  it("clamps to the panel's bounds", () => {
    expect(clampCodeReviewWidth(10)).toBeGreaterThanOrEqual(280);
    expect(clampCodeReviewWidth(99999)).toBeLessThanOrEqual(760);
    expect(clampCodeReviewWidth(CODE_REVIEW_DEFAULT_WIDTH)).toBe(CODE_REVIEW_DEFAULT_WIDTH);
  });

  it("widens the panel when the left-edge handle is dragged left", () => {
    // Docked right, so the handle is on the LEFT edge: pointer X decreasing
    // must widen it — same rule as the file tree's own handle.
    expect(codeReviewWidthFromDrag(400, 800, 700)).toBe(500);
    expect(codeReviewWidthFromDrag(400, 800, 900)).toBe(300);
  });
});
