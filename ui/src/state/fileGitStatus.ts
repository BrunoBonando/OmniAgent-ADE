// Sidebar git decoration (Task 7, left-pane redesign): fold `review_status`'s
// flat `ChangedFile` list into per-file letters and per-ancestor-dir counts,
// keyed by ABSOLUTE path so `FileTree` rows (which carry `entry.path` as an
// absolute path — see `lib/tauri.ts`'s `DirEntry`) can look themselves up
// directly with no path math at render time.
import type { ChangeStatus, ReviewStatus } from "../lib/tauri";

export type DirTone = "add" | "mod";

export interface GitBadges {
  /** Absolute file path -> its change status. */
  byFile: Map<string, ChangeStatus>;
  /** Absolute dir path -> how many changed descendants it has, and whether
   * every one of them is purely additive (`"add"`, only added/untracked
   * files) or at least one is a modification/deletion/rename (`"mod"`). */
  byDir: Map<string, { count: number; tone: DirTone }>;
  /** True total (`ReviewStatus.file_count`, not just `byFile.size`) — the
   * header chip never undercounts if the backend ever caps `files`. */
  total: number;
}

const EMPTY: GitBadges = { byFile: new Map(), byDir: new Map(), total: 0 };

export function buildGitBadges(status: ReviewStatus | null): GitBadges {
  if (!status || status.files.length === 0) return EMPTY;
  const byFile = new Map<string, ChangeStatus>();
  const byDir = new Map<string, { count: number; tone: DirTone }>();
  const root = status.repo_root.endsWith("/") ? status.repo_root.slice(0, -1) : status.repo_root;
  for (const f of status.files) {
    const abs = `${root}/${f.path}`;
    byFile.set(abs, f.status);
    const isAdd = f.status === "added" || f.status === "untracked";
    const parts = f.path.split("/").slice(0, -1);
    let dir = root;
    for (const part of parts) {
      dir = `${dir}/${part}`;
      const prev = byDir.get(dir);
      byDir.set(dir, {
        count: (prev?.count ?? 0) + 1,
        tone: prev == null ? (isAdd ? "add" : "mod") : prev.tone === "add" && isAdd ? "add" : "mod",
      });
    }
  }
  return { byFile, byDir, total: status.file_count };
}
