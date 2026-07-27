// Pure, framework-free state for `NewWorkspaceModal.tsx` — the sidebar's
// "+" flow.
//
// ## Rewritten for the left-pane redesign (Task 12)
//
// The BridgeSpace-derived dialog this file used to back asked for four
// things at once: a name, a folder, a LAYOUT preset and a set of AI AGENTS
// to boot. The redesign drops three of them:
//
// - **name** — derived from the folder's basename now
//   ({@link workspaceNameFromPath}); renaming moved to the workspace menu's
//   ⋯ → ProjectMenu, where it belongs (you rename a workspace far more
//   often than you create one).
// - **layout** / **engines** — creating a workspace no longer creates
//   terminals. `App` opens the New Session modal immediately after
//   "Add workspace", and *that* dialog owns which engines run in which
//   panes. One place decides, instead of two dialogs that could disagree.
//
// What replaces them is information rather than configuration: a
// {@link FolderStats} strip describing what is actually in the folder
// (see `folder_stats` in `src-tauri/src/commands/mod.rs`) plus the two
// decisions that genuinely belong to *adding a folder* — whether to ingest
// it now, and whether memory notes need review before they commit.
import type { FolderStats } from "../lib/tauri";

export interface NewWorkspaceState {
  path: string | null;
  /** `null` before a folder is picked (and after a failed lookup — the
   * strip simply shows placeholders rather than an error surface of its
   * own), `"loading"` while `folder_stats` is in flight. */
  stats: FolderStats | "loading" | null;
  /** Default on: the whole point of adding a folder is for the brain to
   * know about it. Off pauses the root instead (`rootsSetPaused`). */
  ingestNow: boolean;
  /** Default off, mirroring `REVIEW_MEMORY_SETTING_KEY`'s own default —
   * session notes auto-commit unless you ask to vet them first. */
  reviewNotes: boolean;
  submitting: boolean;
  error: string | null;
}

/** The workspace's display name: the folder's basename, trailing slashes
 * ignored (`/x/y/` -> `y`). Falls back to the raw input for a path with no
 * separator at all, so this never returns `""` for a non-empty path. */
export function workspaceNameFromPath(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  const idx = trimmed.lastIndexOf("/");
  const base = idx === -1 ? trimmed : trimmed.slice(idx + 1);
  return base.length > 0 ? base : path;
}

export function initialNewWorkspaceState(): NewWorkspaceState {
  return {
    path: null,
    stats: null,
    ingestNow: true,
    reviewNotes: false,
    submitting: false,
    error: null,
  };
}

export type NewWorkspaceAction =
  | { type: "path"; path: string }
  | { type: "stats"; stats: FolderStats | null }
  | { type: "ingestNow" }
  | { type: "reviewNotes" }
  | { type: "submit_started" }
  | { type: "submit_failed"; error: string };

export function newWorkspaceReducer(
  state: NewWorkspaceState,
  action: NewWorkspaceAction,
): NewWorkspaceState {
  switch (action.type) {
    case "path":
      // The stats for the *previous* folder must not linger while the new
      // folder's are fetched — picking a path is what puts the strip into
      // its loading state, not a separate action the caller could forget.
      return { ...state, path: action.path, stats: "loading", error: null };

    case "stats":
      return { ...state, stats: action.stats };

    case "ingestNow":
      return { ...state, ingestNow: !state.ingestNow };

    case "reviewNotes":
      return { ...state, reviewNotes: !state.reviewNotes };

    case "submit_started":
      return { ...state, submitting: true, error: null };

    case "submit_failed":
      return { ...state, submitting: false, error: action.error };

    default:
      return state;
  }
}

/** Gates "Add workspace": a folder must be picked and no submit already in
 * flight. Deliberately does NOT wait on `stats` — the strip is information,
 * not validation, and a slow walk of a huge folder must never block the
 * button. */
export function canSubmit(state: NewWorkspaceState): boolean {
  return state.path !== null && !state.submitting;
}
