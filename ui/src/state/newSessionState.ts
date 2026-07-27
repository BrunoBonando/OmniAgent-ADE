// Pure, framework-free state for `NewSessionModal.tsx` — the "new session"
// half of ⌘N.
//
// **Redesign (Task 10, 2026-07-27).** The dialog no longer asks for a name,
// a set of checkboxes and a layout that only previewed itself. It asks one
// question — *what are you doing?* — and the answer does double duty: it
// becomes the session's name (`sessionNameFromPrompt`) and the first prompt
// typed into the session's lead terminal. The rest is one decision per
// terminal:
//
// - `layout` is the number of terminals, and `slots` is exactly that many
//   engines, one per pane. They are kept in lockstep by `resizeSlots`, so
//   there is no state where the grid shows four terminals and the caller
//   receives three engines.
// - The DIRECTORY section stays *scoped*: the cwd starts at the already-
//   selected project's folder and can only ever be narrowed to a folder
//   inside it. There is no `add_project`, no project name, and no way to
//   leave the project — that's the difference between a session and a
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
import { getDefaultAgentSelection, type AgentsState } from "./agents";
import type { Engine, ProjectInfo } from "./sessions";
import type { LayoutPreset } from "./paneGrid";

/** A session name long enough to read as a sentence fragment in the sidebar
 * and short enough that the row never has to decide what to drop. */
const MAX_SESSION_NAME = 60;

export interface NewSessionState {
  /** The project this session is being created in — its folder is both the
   * default cwd and the boundary every pick is checked against. */
  projectRoot: string;
  /** The session's cwd: `projectRoot`, or a folder inside it. Never null —
   * a session always has somewhere to run, which is exactly why this dialog
   * needs no "choose a folder first" state at all. */
  path: string;
  /** *What are you doing?* — the session's name and its first prompt. Held
   * verbatim (untrimmed): trimming is what `sessionNameFromPrompt` does to
   * the *name*, and doing it here would fight the user's caret mid-word. */
  prompt: string;
  layout: LayoutPreset;
  /** One engine per pane, `slots.length === layout` always. */
  slots: Engine[];
  submitting: boolean;
  error: string | null;
}

/** Layout 2 (a side-by-side split — the shape a session is most often born
 * in), every slot pre-filled with the project's default engine, so Enter
 * alone is a complete decision. */
export function initialNewSessionStateFor(project: ProjectInfo, agents: AgentsState): NewSessionState {
  const projectRoot = project.path ?? project.id;
  const fallback = defaultSlotEngine(agents);
  return {
    projectRoot,
    path: projectRoot,
    prompt: "",
    layout: 2,
    slots: resizeSlots([], 2, fallback),
    submitting: false,
    error: null,
  };
}

/** The engine every unpicked slot starts as — the same
 * "last-selected-else-the-only-one-installed-else-shell" chain
 * `NewWorkspaceModal` pre-fills from, so the two dialogs can't disagree
 * about what this machine's default agent is. */
export function defaultSlotEngine(agents: AgentsState): Engine {
  return getDefaultAgentSelection(agents)[0] ?? "shell";
}

/** `slots` re-cut to `layout` panes: the engines already picked keep their
 * slot, new panes get `fallback`, removed panes are dropped from the end.
 * Growing back after shrinking deliberately does NOT restore what was
 * there — a slot the user can no longer see is not a decision they still
 * hold. */
export function resizeSlots(slots: Engine[], layout: LayoutPreset, fallback: Engine): Engine[] {
  return Array.from({ length: layout }, (_, i) => slots[i] ?? fallback);
}

/** The session's name, from what the user said they're doing: trimmed,
 * whitespace collapsed (a pasted paragraph is one line in the sidebar), and
 * capped. `undefined` for an empty prompt — the caller's cue to fall back to
 * the workspace's own numbering rather than name a session "". */
export function sessionNameFromPrompt(prompt: string): string | undefined {
  const clean = prompt.trim().replace(/\s+/g, " ");
  return clean.length === 0 ? undefined : clean.slice(0, MAX_SESSION_NAME);
}

export type NewSessionAction =
  | { type: "prompt"; value: string }
  | { type: "layout"; layout: LayoutPreset }
  | { type: "slot"; index: number; engine: Engine }
  | { type: "path"; path: string }
  | { type: "submit_started" }
  | { type: "submit_failed"; error: string };

export function newSessionReducer(state: NewSessionState, action: NewSessionAction): NewSessionState {
  switch (action.type) {
    case "prompt":
      return { ...state, prompt: action.value };

    case "layout":
      // The grid and the engine list are the same decision seen twice, so
      // they move together — never "pick 4, then remember to add engines".
      return {
        ...state,
        layout: action.layout,
        slots: resizeSlots(state.slots, action.layout, state.slots[0] ?? "shell"),
      };

    case "slot":
      if (action.index < 0 || action.index >= state.slots.length) return state;
      return {
        ...state,
        slots: state.slots.map((engine, i) => (i === action.index ? action.engine : engine)),
      };

    case "path":
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

    case "submit_started":
      return { ...state, submitting: true, error: null };

    case "submit_failed":
      return { ...state, submitting: false, error: action.error };

    default:
      return state;
  }
}

/** At least one terminal, not already submitting, and a cwd that still
 * passes the boundary check (belt and braces — the reducer already refuses
 * a bad pick, so this can only fail for a state built by hand). */
export function canSubmit(state: NewSessionState): boolean {
  return (
    !state.submitting &&
    state.slots.length > 0 &&
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
