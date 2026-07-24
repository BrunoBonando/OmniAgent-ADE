// Pure, framework-free state for the sidebar's "+" Add Project flow —
// founder feedback (Bruno, 2026-07-24, verbatim): "Open one terminal, and
// start from there... the user can add multiple sessions within one project
// or add a new project (item on the left)". Same split as
// `onboarding/onboardingState.ts`: a reducer with zero Tauri/React imports
// so the pick-folder -> edit-name -> submit transitions are unit-testable
// without mounting `AddProjectModal.tsx` or mocking the native dialog /
// `invoke()`. `AddProjectModal.tsx` dispatches `folder_picked` right after
// `@tauri-apps/plugin-dialog`'s `open()` resolves, then `submit_started` /
// `submit_failed` around its `addProject()` call (success just closes the
// modal — there's no "submitted" phase to model here).

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
