// Pure logic behind the per-session code review panel (founder ask,
// 2026-07-26: a per-session "Code Review Panel" entry in the pane's 3-dot
// menu carrying the uncommitted-change count, opening a dedicated right-hand
// column). Everything here is a plain function over the backend's wire
// shapes so `CodeReviewPanel.tsx` stays a rendering layer — same split
// `fileTreeState.ts` keeps with `FileTree.tsx`, and the reason the header
// arithmetic, the two render caps, and the revert prompts are unit-testable
// without a browser or a git repo.
import type { ChangedFile, ChangeStatus, DiffHunk, ReviewStatus } from "../lib/tauri";

// ------------------------------------------------------------------ sizing

const CODE_REVIEW_MIN_WIDTH = 280;
const CODE_REVIEW_MAX_WIDTH = 760;

/** Wider than the file tree's 260 default: this column holds a diff, and a
 * diff that wraps every other line is unreadable. */
export const CODE_REVIEW_DEFAULT_WIDTH = 440;

export function clampCodeReviewWidth(width: number): number {
  return Math.min(CODE_REVIEW_MAX_WIDTH, Math.max(CODE_REVIEW_MIN_WIDTH, width));
}

/** Docked on the right edge of `app-body`, so the resize handle is on the
 * panel's LEFT edge — dragging left (pointer X decreasing) widens it.
 * Deliberately the same rule and the same shape as `fileTreeState.ts`'s
 * `widthFromDrag`, so the two right-hand panels resize identically. */
export function codeReviewWidthFromDrag(
  startWidth: number,
  startClientX: number,
  currentClientX: number,
): number {
  return clampCodeReviewWidth(startWidth + (startClientX - currentClientX));
}

// ------------------------------------------------------------ file badges

/** The per-file stat badge model. Three cases rather than one, because a
 * binary file and a zero-line change are genuinely different things and the
 * reference screenshot renders them differently (a plain grey `0` for its
 * empty `.log` files, and nothing countable at all for a binary). */
export type FileStat =
  | { kind: "counts"; added: number; removed: number }
  | { kind: "empty" }
  | { kind: "binary" };

export function formatFileStat(file: ChangedFile): FileStat {
  if (file.binary || file.added === null || file.removed === null) {
    return { kind: "binary" };
  }
  if (file.added === 0 && file.removed === 0) {
    return { kind: "empty" };
  }
  return { kind: "counts", added: file.added, removed: file.removed };
}

/** One-letter marker + accessible name per change kind. Distinct letters
 * matter: this is the only thing distinguishing an untracked file from a
 * modified one at a glance, which the founder's ask calls for implicitly
 * ("number of changes within files that are uncommited" spans both). */
export function statusGlyph(status: ChangeStatus): { letter: string; label: string } {
  switch (status) {
    case "modified":
      return { letter: "M", label: "Modified" };
    case "added":
      return { letter: "A", label: "Added (staged)" };
    case "deleted":
      return { letter: "D", label: "Deleted" };
    case "renamed":
      return { letter: "R", label: "Renamed" };
    case "untracked":
      return { letter: "U", label: "Untracked" };
  }
}

// ----------------------------------------------------------- header stats

export interface HeaderStats {
  pathLabel: string;
  branchLabel: string;
  fileCount: number;
  added: number;
  removed: number;
  isClean: boolean;
  /** Set when binary files are excluded from the aggregate, so the header
   * discloses that `+N -M` doesn't cover everything. */
  binaryNote: string | null;
  /** Set when the backend capped the file list. */
  truncatedNote: string | null;
}

export function deriveHeaderStats(status: ReviewStatus): HeaderStats {
  return {
    pathLabel: homeAbbreviated(status.repo_root),
    branchLabel: branchLabel(status),
    fileCount: status.file_count,
    added: status.added,
    removed: status.removed,
    isClean: status.file_count === 0,
    binaryNote:
      status.binary_count > 0
        ? `${status.binary_count} binary ${status.binary_count === 1 ? "file" : "files"} not counted`
        : null,
    truncatedNote: status.truncated
      ? `showing the first ${status.files.length} of ${status.file_count} files`
      : null,
  };
}

function branchLabel(status: ReviewStatus): string {
  if (status.branch) return status.branch;
  if (!status.has_head) return "no commits yet";
  if (status.detached) return "detached";
  return "unknown";
}

/** `/Users/bonando/Documents/x` -> `~/Documents/x`, the way the reference
 * header writes it. Matches any `/Users/<name>` prefix rather than reading
 * the real home directory, which the webview has no access to anyway. */
export function homeAbbreviated(path: string): string {
  const match = /^\/Users\/[^/]+(\/.*)?$/.exec(path);
  if (!match) return path;
  return match[1] ? `~${match[1]}` : "~";
}

// ------------------------------------------------------- expand / collapse

export function toggleExpandedFile(expanded: ReadonlySet<string>, path: string): Set<string> {
  const next = new Set(expanded);
  if (!next.delete(path)) next.add(path);
  return next;
}

// ------------------------------------------------------------ render caps
//
// Two independent caps, because a change set can be huge in two unrelated
// ways and the reference screenshot shows the first one for real (158 files).
// The backend already caps both at a much higher level (2000 files / 4000
// diff lines) — these are the *render* budgets on top of that, so the panel
// stays responsive rather than laying out thousands of rows at once.

/** Rows rendered per page in the file list; "Show more" adds another page. */
export const FILE_PAGE_SIZE = 80;

/** Diff lines rendered for a single expanded file. */
export const DIFF_RENDER_CAP = 600;

export interface FileListPage {
  shown: ChangedFile[];
  remaining: number;
  hasMore: boolean;
}

export function fileListPage(files: readonly ChangedFile[], visibleCount: number): FileListPage {
  const shown = files.slice(0, visibleCount);
  return {
    shown,
    remaining: files.length - shown.length,
    hasMore: shown.length < files.length,
  };
}

export function nextVisibleCount(current: number, total: number): number {
  return Math.min(total, current + FILE_PAGE_SIZE);
}

export interface RenderableDiff {
  hunks: DiffHunk[];
  shown: number;
  total: number;
  capped: boolean;
}

/** Trims a parsed diff to [`DIFF_RENDER_CAP`] lines, cutting *within* a hunk
 * rather than dropping it whole, and dropping any hunk that would be empty
 * rather than rendering a header with nothing under it. */
export function renderableDiffLines(hunks: readonly DiffHunk[]): RenderableDiff {
  const total = hunks.reduce((sum, h) => sum + h.lines.length, 0);
  if (total <= DIFF_RENDER_CAP) {
    return { hunks: hunks as DiffHunk[], shown: total, total, capped: false };
  }
  const out: DiffHunk[] = [];
  let budget = DIFF_RENDER_CAP;
  for (const hunk of hunks) {
    if (budget <= 0) break;
    const lines = hunk.lines.slice(0, budget);
    budget -= lines.length;
    out.push({ header: hunk.header, lines });
  }
  return { hunks: out, shown: DIFF_RENDER_CAP - Math.max(0, budget), total, capped: true };
}

// ---------------------------------------------------------------- commit

/** Why the Commit button is disabled, or `null` when it isn't. A string
 * rather than a boolean so the UI can *say* why instead of presenting a dead
 * control — an interface should explain what it wants. */
export function commitDisabledReason(
  status: ReviewStatus | null,
  message: string,
  busy: boolean,
): string | null {
  if (busy) return "Committing…";
  if (!status || status.file_count === 0) return "Nothing to commit";
  if (message.trim() === "") return "Write a commit message first";
  return null;
}

// ---------------------------------------------------------------- revert

/** What the in-row confirmation should say before throwing a file's changes
 * away. The wording splits on whether the change is recoverable afterwards,
 * because that is the single fact the user needs to decide — an untracked
 * file goes to the Trash and can be dragged back out, while a modified
 * file's edits are restored over and genuinely gone. */
export interface RevertPrompt {
  /** `true` when the action cannot be undone (restore-over-working-copy). */
  destructive: boolean;
  /** `true` when this file can't be reverted at all (a rename) — the UI
   * shows `detail` and offers no confirm button. */
  blocked: boolean;
  confirmLabel: string;
  detail: string;
}

export function revertPrompt(file: ChangedFile): RevertPrompt {
  if (file.status === "renamed") {
    return {
      destructive: false,
      blocked: true,
      confirmLabel: "",
      detail: `Renamed from ${file.old_path ?? "another path"} — undo a rename with git directly.`,
    };
  }
  if (file.status === "untracked" || file.status === "added") {
    return {
      destructive: false,
      blocked: false,
      confirmLabel: "Move to Trash",
      detail: "This file has never been committed. It goes to the macOS Trash, so you can get it back.",
    };
  }
  return {
    destructive: true,
    blocked: false,
    confirmLabel: "Discard changes",
    detail: "Restores the committed version over your edits. This can't be undone.",
  };
}
