// Pure, framework-free state for the "import projects from other tools"
// flow (`ImportProjectsFlow.tsx`) — same split every other onboarding/modal
// state file in this codebase uses (`onboardingState.ts`/
// `newWorkspaceState.ts`/`addProjectState.ts`/`fileTreeState.ts`): a
// reducer plus small pure helpers, zero Tauri/React imports, so the
// interesting logic (which tools are selectable, how candidates from
// multiple tools merge and dedupe, which rows are already-added projects,
// per-tool select-all/none, live checked count, partial-failure
// summarization) is unit-testable without mounting a component or mocking
// `invoke()`.
//
// Founder ask (Bruno, 2026-07-25, verbatim): "detect other dev tools
// already installed on the user's machine and offer to import their known
// project lists, so a new OmniAgent user doesn't have to manually
// '+ Add Project' one folder at a time." Part A (backend, frozen,
// `crates/brain-ingest/src/import_detect.rs`) built read-only detection for
// three tools; this is Part B — turning a selected candidate into a real
// project via the existing `addProject` (`lib/tauri.ts`), reused exactly as
// `NewWorkspaceModal.tsx` already does, never reimplemented.
//
// Two-phase flow, same "reducer with a `phase` field" shape as
// `onboardingState.ts`/`authGateState.ts`:
// - "tools": `detectImportableTools()` results render as a toggleable list
//   (only `detected: true` tools are selectable — an undetected tool shows
//   as an informative, grayed, non-interactive row, never hidden).
// - "candidates": `listImportCandidates()` for every checked tool, merged
//   into one deduped, existing-project-aware checklist, grouped by source
//   tool.
// - "importing"/"done": the bulk `add_project` loop's own live progress and
//   final summary — the loop itself lives in the component (it's
//   inherently async IO, same as `App.tsx`'s `handleWorkspaceCreated`
//   isn't a reducer case either), dispatching one `row_result` per
//   settled call so the checklist can show live ✓/✗ per row.
import type { DetectedTool, ImportCandidate } from "../lib/tauri";
import type { ProjectInfo } from "./sessions";

// ------------------------------------------------------------- tool colors
// Import-flow-only display metadata, deliberately NOT added to `theme.ts`
// (that file's own doc scopes it to "what an [runnable] engine looks
// like" — an import source isn't one). `claude-code` reuses the exact same
// violet as `ENGINE_COLOR.claude` (it really is the same product); `vscode`
// is VS Code's own brand blue; `cursor` stays neutral (its own mark is
// monochrome, and it's unverified/uninstalled on the reference machine —
// see `import_detect.rs`'s module doc — so it gets no invented brand hue).
export const IMPORT_TOOL_COLOR: Record<string, string> = {
  "claude-code": "#cc96f2",
  vscode: "#3178c6",
  cursor: "#9a9ca6",
};

export type ImportPhase = "tools" | "candidates" | "importing" | "done";

/** One row in the candidates checklist — a merged, deduped view over every
 * checked tool's raw `ImportCandidate`s. */
export interface ImportRow {
  path: string;
  suggestedName: string;
  /** Which tool this row is displayed/grouped under — the FIRST tool (in
   * `tools` order) that reported this path, when more than one did. */
  sourceTool: string;
  /** True when `path` already matches an existing OmniAgent project — the
   * row is still shown (transparency beats silently hiding it) but can
   * never be checked. */
  alreadyAdded: boolean;
}

/** The outcome of one `add_project` call made from the checklist. */
export interface ImportRowResult {
  path: string;
  suggestedName: string;
  success: boolean;
  /** Present when `success` — the real created project, so the caller can
   * e.g. select it or refresh the sidebar. */
  project?: ProjectInfo;
  /** Present when `!success`. */
  error?: string;
}

/** What `ImportProjectsFlow` hands back to its caller (`FirstRun.tsx` /
 * `Sidebar.tsx`, both via `App.tsx`) once a batch finishes — the shape
 * `handleImportCompleted` (App.tsx) reloads the project list and builds an
 * error-banner summary from. */
export interface ImportBatchResult {
  created: ProjectInfo[];
  failed: ImportRowResult[];
}

export interface ImportState {
  phase: ImportPhase;
  /** `null` while the initial `detectImportableTools()` call is in flight;
   * `[]` only if that call itself failed (see `error`). */
  tools: DetectedTool[] | null;
  /** Per-tool checked state, keyed by `DetectedTool.id` — only ever `true`
   * for a tool that was also `detected` (see `tool_toggled`). */
  selectedTools: Record<string, boolean>;
  rows: ImportRow[];
  /** Per-row checked state, keyed by `ImportRow.path`. */
  checked: Record<string, boolean>;
  /** Settles one at a time as the "importing" bulk loop runs; final length
   * equals the checked-row count once `phase === "done"`. */
  results: ImportRowResult[];
  error: string | null;
}

export const initialImportState: ImportState = {
  phase: "tools",
  tools: null,
  selectedTools: {},
  rows: [],
  checked: {},
  results: [],
  error: null,
};

export type ImportAction =
  | { type: "tools_loaded"; tools: DetectedTool[] }
  | { type: "tools_load_failed"; error: string }
  | { type: "tool_toggled"; id: string }
  | { type: "candidates_requested" }
  | { type: "candidates_loaded"; rows: ImportRow[] }
  | { type: "candidates_load_failed"; error: string }
  | { type: "back_to_tools" }
  | { type: "candidate_toggled"; path: string }
  | { type: "tool_group_set"; tool: string; checked: boolean }
  | { type: "import_started" }
  | { type: "row_result"; result: ImportRowResult }
  | { type: "import_finished" };

export function importReducer(state: ImportState, action: ImportAction): ImportState {
  switch (action.type) {
    case "tools_loaded": {
      // Detected tools are checked by default — the common case ("pull
      // from everything this machine has") is zero clicks, same
      // "sensible-default checklist" precedent `newWorkspaceState.ts`'s
      // `DEFAULT_ENGINE_SELECTION` and `AddProjectModal`'s "all checked"
      // convention (this task's own brief) both establish. An undetected
      // tool is never selectable, so it's never `true` here.
      const selectedTools: Record<string, boolean> = {};
      for (const tool of action.tools) selectedTools[tool.id] = tool.detected;
      return { ...state, tools: action.tools, selectedTools, error: null };
    }

    case "tools_load_failed":
      return { ...state, tools: [], error: action.error };

    case "tool_toggled": {
      const tool = state.tools?.find((t) => t.id === action.id);
      if (!tool || !tool.detected) return state; // an unavailable tool can't be toggled
      return { ...state, selectedTools: { ...state.selectedTools, [action.id]: !state.selectedTools[action.id] } };
    }

    case "candidates_requested":
      return { ...state, phase: "candidates", error: null };

    case "candidates_loaded": {
      const checked: Record<string, boolean> = {};
      for (const row of action.rows) checked[row.path] = !row.alreadyAdded;
      return { ...state, rows: action.rows, checked, error: null };
    }

    case "candidates_load_failed":
      return { ...state, error: action.error };

    case "back_to_tools":
      return { ...state, phase: "tools", rows: [], checked: {}, error: null };

    case "candidate_toggled": {
      const row = state.rows.find((r) => r.path === action.path);
      if (!row || row.alreadyAdded) return state; // an already-added row is never selectable
      return { ...state, checked: { ...state.checked, [action.path]: !state.checked[action.path] } };
    }

    case "tool_group_set": {
      const checked = { ...state.checked };
      for (const row of state.rows) {
        if (row.sourceTool !== action.tool || row.alreadyAdded) continue;
        checked[row.path] = action.checked;
      }
      return { ...state, checked };
    }

    case "import_started":
      return { ...state, phase: "importing", results: [] };

    case "row_result":
      return { ...state, results: [...state.results, action.result] };

    case "import_finished":
      return { ...state, phase: "done" };

    default:
      return state;
  }
}

// ------------------------------------------------------------- selectors

/** The tools phase's checkbox list only ever renders `detected` tools as
 * interactive rows — the caller renders the rest of `tools` separately as
 * grayed/informational ("Cursor — not found"). */
export function selectableTools(tools: DetectedTool[] | null): DetectedTool[] {
  return (tools ?? []).filter((t) => t.detected);
}

export function checkedToolIds(state: ImportState): string[] {
  return selectableTools(state.tools)
    .filter((t) => state.selectedTools[t.id])
    .map((t) => t.id);
}

/** Gates the tools phase's "Continue" action — at least one detected tool
 * must be checked. */
export function canProceedToCandidates(state: ImportState): boolean {
  return checkedToolIds(state).length > 0;
}

/** A path, normalized for comparison only (never for display/`add_project`
 * calls) — strips a trailing slash so `/a/b` and `/a/b/` compare equal,
 * mirroring `roots.rs`'s own path-comparison convention. */
function normalizePath(path: string): string {
  return path.replace(/\/+$/, "");
}

/** Merges every checked tool's raw candidates into one deduped,
 * existing-project-aware row list — the input to `candidates_loaded`.
 *
 * Two dedup rules, both silent (never a visible "duplicate" error, just
 * fewer/marked rows):
 * - the SAME path reported by two different tools (e.g. both Claude Code
 *   and VS Code remember the same repo) keeps only its first occurrence,
 *   in `tools` array order — a path is one real folder no matter how many
 *   tools' histories mention it, so it must only ever produce one
 *   `add_project` call;
 * - a path that already matches an existing OmniAgent project's `path`
 *   (or `id`, for the rare project whose `path` is null) is marked
 *   `alreadyAdded: true` rather than dropped — still shown, for
 *   transparency, but the reducer never lets it be checked.
 */
export function mergeCandidates(
  tools: Array<{ id: string }>,
  byTool: Record<string, ImportCandidate[]>,
  existingProjects: ProjectInfo[],
): ImportRow[] {
  const existingPaths = new Set(existingProjects.map((p) => normalizePath(p.path ?? p.id)));
  const seen = new Set<string>();
  const rows: ImportRow[] = [];
  for (const tool of tools) {
    for (const candidate of byTool[tool.id] ?? []) {
      const norm = normalizePath(candidate.path);
      if (seen.has(norm)) continue;
      seen.add(norm);
      rows.push({
        path: candidate.path,
        suggestedName: candidate.suggested_name,
        sourceTool: tool.id,
        alreadyAdded: existingPaths.has(norm),
      });
    }
  }
  return rows;
}

/** Rows grouped by source tool, in first-seen order — what the checklist
 * actually renders (one section per tool). */
export function rowsByTool(rows: ImportRow[]): Array<{ tool: string; rows: ImportRow[] }> {
  const order: string[] = [];
  const map = new Map<string, ImportRow[]>();
  for (const row of rows) {
    if (!map.has(row.sourceTool)) {
      map.set(row.sourceTool, []);
      order.push(row.sourceTool);
    }
    map.get(row.sourceTool)!.push(row);
  }
  return order.map((tool) => ({ tool, rows: map.get(tool)! }));
}

/** The checked, selectable (never already-added) paths, in row order —
 * both what "Import Selected (N)" counts and the exact call order the
 * bulk `add_project` loop uses. */
export function checkedPaths(state: ImportState): string[] {
  return state.rows.filter((r) => !r.alreadyAdded && state.checked[r.path]).map((r) => r.path);
}

export function checkedCount(state: ImportState): number {
  return checkedPaths(state).length;
}

/** One tool group's header checkbox state — "all"/"none"/"some" (tri-state)
 * over that tool's selectable (non-already-added) rows only. */
export function toolGroupState(
  rows: ImportRow[],
  checked: Record<string, boolean>,
  tool: string,
): "all" | "none" | "some" {
  const selectable = rows.filter((r) => r.sourceTool === tool && !r.alreadyAdded);
  if (selectable.length === 0) return "none";
  const checkedInGroup = selectable.filter((r) => checked[r.path]).length;
  if (checkedInGroup === 0) return "none";
  if (checkedInGroup === selectable.length) return "all";
  return "some";
}

/** `results` (settled so far, or final) -> the "done" phase's headline
 * summary text. */
export function summarizeImportResults(results: ImportRowResult[]): {
  createdCount: number;
  failedCount: number;
  message: string;
} {
  const createdCount = results.filter((r) => r.success).length;
  const failedCount = results.length - createdCount;
  let message: string;
  if (failedCount === 0) {
    message = `Imported ${createdCount} project${createdCount === 1 ? "" : "s"}.`;
  } else if (createdCount === 0) {
    message = `Couldn't import ${failedCount} project${failedCount === 1 ? "" : "s"}.`;
  } else {
    message = `Imported ${createdCount} of ${createdCount + failedCount} projects — ${failedCount} failed.`;
  }
  return { createdCount, failedCount, message };
}

/** Turns the flat settle-order `results` list into the `ImportBatchResult`
 * shape `App.tsx`'s `handleImportCompleted` consumes. A result marked
 * `success` without a `project` (shouldn't happen — `addProject` either
 * resolves with one or the call is caught as a failure — but never trust
 * IO blindly) is treated as a failure rather than silently dropped. */
export function toBatchResult(results: ImportRowResult[]): ImportBatchResult {
  const created: ProjectInfo[] = [];
  const failed: ImportRowResult[] = [];
  for (const r of results) {
    if (r.success && r.project) created.push(r.project);
    else failed.push(r.success ? { ...r, success: false, error: "no project returned" } : r);
  }
  return { created, failed };
}

/** `App.tsx`'s error-banner text for a batch with at least one failure —
 * `null` when everything succeeded (no banner needed). Mirrors
 * `handleWorkspaceCreated`'s own "Created X, but couldn't start Y" banner
 * convention: name the failures, don't just say "some failed". */
export function importFailureBanner(result: ImportBatchResult): string | null {
  if (result.failed.length === 0) return null;
  const names = result.failed.map((f) => f.suggestedName).join(", ");
  return result.created.length > 0
    ? `Imported ${result.created.length} project${result.created.length === 1 ? "" : "s"}, but couldn't import ${names}.`
    : `Couldn't import ${names}.`;
}
