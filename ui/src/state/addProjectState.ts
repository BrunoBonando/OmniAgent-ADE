// Pure, framework-free state originally built for the sidebar's "+" Add
// Project flow — founder feedback (Bruno, 2026-07-24, verbatim): "Open one
// terminal, and start from there... the user can add multiple sessions
// within one project or add a new project (item on the left)". Same split
// as `onboarding/onboardingState.ts`: a reducer with zero Tauri/React
// imports so the pick-folder -> edit-name -> submit transitions are
// unit-testable without mounting a modal component or mocking the native
// dialog / `invoke()`.
//
// 2026-07-25: the modal this originally backed (`AddProjectModal.tsx`) was
// replaced by `NewWorkspaceModal.tsx` (a strict superset — see that
// component's own module doc), and deleted. This file and its test were
// deliberately kept — `basenameOf` is genuinely reusable, working, tested
// logic, not something worth deleting just because its original caller is
// gone — `newWorkspaceState.ts` now imports `basenameOf` from here instead
// of re-deriving it. The rest of this module (the `AddProjectState`
// reducer/phase machine) is unused dead code at this point, kept only
// because `basenameOf` lives in the same file; if this file ever needs a
// real edit, consider splitting `basenameOf` out on its own rather than
// carrying the rest forward.

export type AddProjectPhase = "pick" | "name" | "submitting";

export interface AddProjectState {
  phase: AddProjectPhase;
  path: string | null;
  name: string;
  error: string | null;
}

export const initialAddProjectState: AddProjectState = {
  phase: "pick",
  path: null,
  name: "",
  error: null,
};

export type AddProjectAction =
  | { type: "folder_picked"; path: string }
  | { type: "name_changed"; name: string }
  | { type: "choose_different_folder" }
  | { type: "submit_started" }
  | { type: "submit_failed"; error: string };

/** The native folder picker returns a POSIX path; the editable name field
 * defaults to its last path segment so the common case ("just add this
 * folder") is a single click with nothing to type. */
export function basenameOf(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  const idx = trimmed.lastIndexOf("/");
  return idx === -1 ? trimmed : trimmed.slice(idx + 1);
}

export function addProjectReducer(state: AddProjectState, action: AddProjectAction): AddProjectState {
  switch (action.type) {
    case "folder_picked":
      return { phase: "name", path: action.path, name: basenameOf(action.path), error: null };

    case "name_changed":
      return { ...state, name: action.name };

    case "choose_different_folder":
      return { ...state, phase: "pick", path: null, error: null };

    case "submit_started":
      return { ...state, phase: "submitting", error: null };

    case "submit_failed":
      return { ...state, phase: "name", error: action.error };

    default:
      return state;
  }
}

/** Gates the confirm button: a folder must be picked and the (possibly
 * user-edited) name must be non-blank, and a submit can't already be
 * in flight. */
export function canSubmit(state: AddProjectState): boolean {
  return state.phase === "name" && state.path !== null && state.name.trim().length > 0;
}
