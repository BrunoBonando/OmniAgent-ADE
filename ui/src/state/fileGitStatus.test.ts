// Task 7 (left-pane redesign): pure tests for `buildGitBadges`, the fold from
// `review_status`'s flat `ChangedFile` list into per-file letters and
// per-ancestor-dir counts, keyed by ABSOLUTE path — see `fileGitStatus.ts`'s
// own module doc for why absolute-path keying matters (it's what `FileTree`
// rows carry).
import { describe, expect, it } from "vitest";
import { buildGitBadges } from "./fileGitStatus";
import type { ReviewStatus } from "../lib/tauri";

function status(files: Array<[string, string]>): ReviewStatus {
  return {
    repo_root: "/repo", branch: "main", detached: false, has_head: true,
    files: files.map(([path, s]) => ({
      path, status: s as never, added: 1, removed: 0, binary: false, old_path: null,
    })),
    file_count: files.length, added: files.length, removed: 0,
    binary_count: 0, truncated: false,
  };
}

describe("buildGitBadges", () => {
  it("maps files to absolute paths and totals", () => {
    const b = buildGitBadges(status([["src/auth/token.ts", "modified"]]));
    expect(b.total).toBe(1);
    expect(b.byFile.get("/repo/src/auth/token.ts")).toBe("modified");
  });

  it("accumulates ancestor dir counts", () => {
    const b = buildGitBadges(status([
      ["src/auth/token.ts", "modified"],
      ["src/auth/token.spec.ts", "added"],
      ["src/stripe/pay.ts", "added"],
    ]));
    expect(b.byDir.get("/repo/src")).toEqual({ count: 3, tone: "mod" });
    expect(b.byDir.get("/repo/src/auth")).toEqual({ count: 2, tone: "mod" });
    expect(b.byDir.get("/repo/src/stripe")).toEqual({ count: 1, tone: "add" });
  });

  it("tone is add only when every descendant is added/untracked", () => {
    const b = buildGitBadges(status([["a/x.ts", "untracked"], ["a/y.ts", "added"]]));
    expect(b.byDir.get("/repo/a")?.tone).toBe("add");
  });

  it("null status yields empty badges", () => {
    const b = buildGitBadges(null);
    expect(b.total).toBe(0);
    expect(b.byFile.size).toBe(0);
  });

  it("joins repo_root and file path with exactly one separator, no double slash", () => {
    const b = buildGitBadges(status([["top.ts", "modified"]]));
    expect(Array.from(b.byFile.keys())).toEqual(["/repo/top.ts"]);
  });
});
