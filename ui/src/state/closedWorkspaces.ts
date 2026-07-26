// Which workspaces the user has closed (founder ask, 2026-07-26, verbatim:
// "add the possibility to close a workspace, on hover"), as pure data.
//
// ## What "close" means here, and what it deliberately does not
//
// Closing a workspace **closes its terminals and takes it out of the
// sidebar's list of open workspaces**. That is all. It is a window-close,
// not a delete:
//
// - every terminal in it is killed (`session_kill`, which also tears down
//   the tmux session behind it) — so it does end live engines, which is why
//   `CloseWorkspaceConfirm` asks first and says how many;
// - the folder on disk is untouched;
// - the project node, everything ingested from it, and every memory note
//   about it stay in the brain — the map still shows it, `search_brain`
//   still finds it, and re-adding the folder (the sidebar's "+", or the
//   import flow) brings the row straight back, because `add_project` is an
//   upsert keyed by the folder (`src-tauri/src/roots.rs`).
//
// There is deliberately NO "remove from OmniAgent" in this dispatch. A
// control that appears on hover, one click from the row you use all day,
// must not be able to destroy a graph that took an hour to ingest — and
// Bruno asked to *close* a workspace, which is what every other app on his
// dock means by the word.
//
// The set is persisted (settings table, `closed_workspaces`) rather than
// held for the session: a workspace that quietly reappeared on the next
// launch would make the close look broken. Anything that *opens* the
// workspace again — adding the folder, importing it, opening a terminal in
// it from the map or the palette — takes it back out of this set (see
// `App.tsx`'s `reopenWorkspace`).
import type { ProjectInfo } from "./sessions";

/** Settings-table key, same flat `settingsGet`/`settingsSet` convention as
 * `LAYOUT_SETTING_KEY` / `FILE_TREE_VISIBLE_SETTING_KEY`. */
export const CLOSED_WORKSPACES_SETTING_KEY = "closed_workspaces";

/** The projects the sidebar lists: everything the brain knows about, minus
 * the ones the user closed. Order is the brain's, untouched. */
export function openWorkspaces(projects: ProjectInfo[], closed: ReadonlySet<string>): ProjectInfo[] {
  if (closed.size === 0) return projects;
  return projects.filter((p) => !closed.has(p.id));
}

/**
 * Which workspace is selected once `closedId` has gone.
 *
 * Untouched when the user was looking at a different workspace. Otherwise
 * focus falls to the left neighbour, then to whatever slid into the closed
 * slot, then to nothing — the same rule `nextActiveAfterClose` (sessions.ts)
 * uses for panes, because it is the same mental model: closing something
 * keeps you in the same neighbourhood.
 */
export function nextSelectedAfterClose(
  projects: ProjectInfo[],
  closed: ReadonlySet<string>,
  closedId: string,
  selectedId: string | null,
): string | null {
  if (selectedId !== closedId) return selectedId;
  const closedIndex = projects.findIndex((p) => p.id === closedId);
  const remaining = openWorkspaces(projects, closed);
  if (remaining.length === 0) return null;
  const left = remaining[closedIndex - 1];
  if (left) return left.id;
  return (remaining[closedIndex] ?? remaining[0]).id;
}

export function serializeClosedWorkspaces(ids: Iterable<string>): string {
  return JSON.stringify([...ids]);
}

/** Never throws: a corrupt row means "nothing is closed", which shows the
 * user more than they asked for rather than hiding work they can't find. */
export function deserializeClosedWorkspaces(raw: string | null | undefined): string[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    const ids: string[] = [];
    for (const value of parsed) {
      if (typeof value !== "string") continue;
      const id = value.trim();
      if (id.length > 0 && !ids.includes(id)) ids.push(id);
    }
    return ids;
  } catch {
    return [];
  }
}
