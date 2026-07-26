// Pure, framework-free state for `NewSessionModal.tsx` — the "new session"
// half of ⌘N (founder brief, 2026-07-26, verbatim: *"Each session can be
// created with a new layout, agents, etc... but in the same folder or
// subfolder."*).
//
// Deliberately the same shape as `newWorkspaceState.ts` (flat state, LAYOUT
// preset + per-engine checklist + collapse toggle + submit gating), because
// it IS the same dialog minus one section and plus one constraint:
//
// - LAYOUT and AI AGENTS are identical — a session is created with its own
//   layout and its own agents.
// - The DIRECTORY section is replaced by a *scoped* one: the cwd starts at
//   the already-selected project's folder and can only ever be narrowed to a
//   folder inside it. There is no `add_project`, no project name, and no way
//   to leave the project — that's the difference between a session and a
//   workspace.
//
// `isInsideProjectRoot` below is the guard that makes "or subfolder" real
// rather than aspirational. It mirrors the discipline
// `crates/brain-ingest/src/fileops.rs` established for every path the app
// accepts from a user: compare on **path-component boundaries**, never
// string prefixes (`/repo/app-2` is not inside `/repo/app`), and refuse
// anything that isn't a plain absolute path. One honest difference: the Rust
// side can `std::fs::canonicalize` and so also closes symlink traversal;
// nothing in the webview can resolve a symlink, so this normalizes
// textually and the check is "the path you picked is written as a path
// inside the project". That is a UI guard on a macOS native folder picker
// (the user chose the folder themselves, in their own file system), not a
// security boundary against hostile input — the boundary that matters lives
// in Rust, where the file operations happen.
import { ENGINES, type Engine } from "./sessions";
import { LAYOUT_PRESETS, type LayoutPreset } from "./paneGrid";
import { DEFAULT_ENGINE_SELECTION } from "./newWorkspaceState";

export interface NewSessionState {
  /** The project this session is being created in — its folder is both the
   * default cwd and the boundary every pick is checked against. */
  projectRoot: string;
  /** The session's cwd: `projectRoot`, or a folder inside it. Never null —
   * a session always has somewhere to run, which is exactly why this dialog
   * needs no "choose a folder first" state at all. */
  path: string;
  layout: LayoutPreset;
  engines: Record<Engine, boolean>;
  agentsCollapsed: boolean;
  submitting: boolean;
  error: string | null;
}

export function initialNewSessionState(projectRoot: string): NewSessionState {
  return {
    projectRoot,
    path: projectRoot,
    layout: 2,
    engines: DEFAULT_ENGINE_SELECTION,
    agentsCollapsed: false,
    submitting: false,
    error: null,
  };
}

export type NewSessionAction =
  | { type: "folder_picked"; path: string }
  | { type: "folder_reset" }
  | { type: "layout_selected"; layout: LayoutPreset }
  | { type: "engine_toggled"; engine: Engine }
  | { type: "agents_collapsed_toggled" }
  | { type: "submit_started" }
  | { type: "submit_failed"; error: string };

export function newSessionReducer(state: NewSessionState, action: NewSessionAction): NewSessionState {
  switch (action.type) {
    case "folder_picked":
      // Rejected in the reducer, not at the call site, so the rule holds for
      // every path in (picker, future drag-and-drop, a test) and the user
      // gets told why instead of the pick silently doing nothing.
      if (!isInsideProjectRoot(state.projectRoot, action.path)) {
        return {
          ...state,
          error: `That folder is outside this project. A session runs in ${state.projectRoot} or a folder inside it.`,
        };
      }
      return { ...state, path: normalizePath(action.path), error: null };

    case "folder_reset":
      return { ...state, path: state.projectRoot, error: null };

    case "layout_selected":
      return { ...state, layout: action.layout };

    case "engine_toggled":
      return { ...state, engines: { ...state.engines, [action.engine]: !state.engines[action.engine] } };

    case "agents_collapsed_toggled":
      return { ...state, agentsCollapsed: !state.agentsCollapsed };

    case "submit_started":
      return { ...state, submitting: true, error: null };

    case "submit_failed":
      return { ...state, submitting: false, error: action.error };

    default:
      return state;
  }
}

/** `ENGINES` order, same as `newWorkspaceState.checkedEngines` — so panes
 * land in a stable left-to-right order in the chosen layout every time. */
export function checkedEngines(state: NewSessionState): Engine[] {
  return ENGINES.filter((engine) => state.engines[engine]);
}

/** At least one agent, not already submitting, and a cwd that still passes
 * the boundary check (belt and braces — the reducer already refuses a bad
 * pick, so this can only fail for a state built by hand). */
export function canSubmit(state: NewSessionState): boolean {
  return (
    !state.submitting &&
    checkedEngines(state).length > 0 &&
    isInsideProjectRoot(state.projectRoot, state.path)
  );
}

// --------------------------------------------------------------- paths

/** Collapses `.` segments, resolves `..` against earlier segments, drops
 * duplicate and trailing slashes. Returns `""` for anything that isn't an
 * absolute POSIX path (macOS-only app), which every caller treats as a
 * refusal. */
export function normalizePath(path: string): string {
  if (typeof path !== "string" || !path.startsWith("/")) return "";
  const out: string[] = [];
  for (const segment of path.split("/")) {
    if (segment === "" || segment === ".") continue;
    if (segment === "..") {
      // A `..` that would climb above `/` is a malformed path, not a
      // silently-clamped one.
      if (out.length === 0) return "";
      out.pop();
      continue;
    }
    out.push(segment);
  }
  return "/" + out.join("/");
}

/**
 * Is `candidate` the project root itself, or a folder inside it?
 *
 * Component-wise, never a string prefix: `/repo/app-2` is NOT inside
 * `/repo/app`, and a `startsWith` check would say it is. `/` as a root
 * accepts everything absolute, which is correct and only reachable if a
 * project is literally rooted at `/`.
 */
export function isInsideProjectRoot(root: string, candidate: string): boolean {
  const normalizedRoot = normalizePath(root);
  const normalizedCandidate = normalizePath(candidate);
  if (normalizedRoot === "" || normalizedCandidate === "") return false;
  if (normalizedRoot === normalizedCandidate) return true;
  const rootParts = normalizedRoot.split("/");
  const candidateParts = normalizedCandidate.split("/");
  if (candidateParts.length <= rootParts.length) return false;
  return rootParts.every((part, i) => part === candidateParts[i]);
}

/** How the chosen folder is written in the dialog: the project root shows
 * as itself, a subfolder as the path *relative* to it (`ui/src`) — which is
 * the part the user actually chose, and keeps a deep path readable in a
 * narrow row. */
export function displaySessionPath(state: NewSessionState): string {
  const root = normalizePath(state.projectRoot);
  const path = normalizePath(state.path);
  if (root === path) return root;
  if (!isInsideProjectRoot(root, path)) return path;
  return path.slice(root === "/" ? 1 : root.length + 1);
}

/** True when the session will run somewhere other than the project root —
 * what the dialog's "Use project folder" reset offers to undo. */
export function isSubfolder(state: NewSessionState): boolean {
  return normalizePath(state.projectRoot) !== normalizePath(state.path);
}

export { LAYOUT_PRESETS };
export type { LayoutPreset };
