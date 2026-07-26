// Pure, framework-free state for `NewWorkspaceModal.tsx` — the sidebar's
// "+" flow, rebuilt from the BridgeSpace "New Workspace" dialog reference
// (a founder screenshot, described precisely in the task rather than
// checked into `docs/reference/` as an image — see `NewWorkspaceModal.tsx`'s
// own module doc). Unlike `addProjectState.ts`'s two-screen pick -> name
// flow (deliberately terse — that modal has nothing else to configure),
// the reference is a single dialog with every section (LAYOUT, DIRECTORY,
// AI AGENTS) visible at once, so this is a flat state shape rather than a
// `phase` enum: nothing here gates *which section renders*, only whether
// the whole thing can be submitted (`canSubmit`) and the AI AGENTS list's
// own collapse toggle.
//
// This REPLACES `AddProjectModal.tsx` as the sidebar's "+" trigger (see
// `Sidebar.tsx`'s own doc comment for why — this flow is a strict superset:
// pick a folder, optionally rename it, AND choose which engines to boot and
// how to arrange them, in one dialog) but deliberately reuses
// `addProjectState.ts`'s `basenameOf` rather than duplicating that pure
// folder-picking logic — that file and its tests stay exactly as they were,
// just as a library function now instead of backing its own top-level
// modal.
import { basenameOf } from "./addProjectState";
import { ENGINES, type Engine } from "./sessions";
import { getDefaultAgentSelection, type AgentsState } from "./agents";
import { LAYOUT_PRESETS, type LayoutPreset } from "./paneGrid";

export interface NewWorkspaceState {
  path: string | null;
  /** Editable project display name — the dialog now asks for this BEFORE a
   * folder, so it only defaults from the folder's basename (same precedent
   * `addProjectState.ts` established) when still blank at the moment a
   * folder is picked; a name the user already typed, before or after that,
   * is never overwritten. */
  name: string;
  layout: LayoutPreset;
  /** Per-engine checked state for the AI AGENTS checklist — a plain record
   * rather than a `Set<Engine>` so `initialNewWorkspaceState`/test
   * fixtures can express it as a literal object matching `ENGINES`. */
  engines: Record<Engine, boolean>;
  agentsCollapsed: boolean;
  submitting: boolean;
  error: string | null;
}

/** The checklist a dialog falls back to when nothing is known about which
 * agents exist yet — only Claude, the same "if the default is Claude, it
 * basically runs Claude" precedent `sessions.ts`'s `resolveDefaultEngine`
 * and `EnginePicker.tsx` establish for the single-tab flow.
 *
 * Prefer {@link initialNewWorkspaceStateFor}, which picks from the agents
 * actually installed on this machine. This constant is the zero-knowledge
 * case (and what the pre-agent-registry tests pin). */
export const DEFAULT_ENGINE_SELECTION: Record<Engine, boolean> = {
  claude: true,
  codex: false,
  shell: false,
  copilot: false,
  antigravity: false,
};

export const initialNewWorkspaceState: NewWorkspaceState = {
  path: null,
  name: "",
  layout: 4,
  engines: DEFAULT_ENGINE_SELECTION,
  agentsCollapsed: false,
  submitting: false,
  error: null,
};

/** The state a New Workspace dialog opens with, given what is installed.
 *
 * Founder brief (2026-07-26, verbatim): *"the last one that they created,
 * should be pre-selected. if it's a brand new installation, it should be
 * shell selected or if it's only one agent installed, let's say: claude is
 * the only agent installed, then you pre-select claude."*
 *
 * The rule itself is `getDefaultAgentSelection` (`agents.ts`) — this only
 * turns its answer into the `Record<Engine, boolean>` the checklist renders,
 * so there is one definition of "which agents should start checked" rather
 * than one here and one there.
 *
 * Filtered against `installed` on the way out: a row for a missing agent is
 * rendered *disabled*, so a checked-and-disabled box would be one the user
 * cannot clear and cannot submit with. Pre-selecting only what can actually
 * run keeps the dialog always submittable. */
export function initialNewWorkspaceStateFor(agents: AgentsState): NewWorkspaceState {
  const selected = new Set(
    getDefaultAgentSelection(agents).filter((a) => agents.installed.has(a)),
  );
  return {
    ...initialNewWorkspaceState,
    engines: Object.fromEntries(ENGINES.map((e) => [e, selected.has(e)])) as Record<
      Engine,
      boolean
    >,
  };
}

export type NewWorkspaceAction =
  | { type: "folder_picked"; path: string }
  | { type: "name_changed"; name: string }
  | { type: "layout_selected"; layout: LayoutPreset }
  | { type: "engine_toggled"; engine: Engine }
  | { type: "agents_collapsed_toggled" }
  | { type: "submit_started" }
  | { type: "submit_failed"; error: string };

export function newWorkspaceReducer(state: NewWorkspaceState, action: NewWorkspaceAction): NewWorkspaceState {
  switch (action.type) {
    case "folder_picked":
      // The dialog now asks for a name BEFORE a folder — don't clobber
      // something the user already typed; only default from the folder's
      // basename when the name field is still blank.
      return {
        ...state,
        path: action.path,
        name: state.name.trim().length > 0 ? state.name : basenameOf(action.path),
        error: null,
      };

    case "name_changed":
      return { ...state, name: action.name };

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

/** The checked engines, always in `ENGINES` order regardless of click
 * order — this is also the exact order NewWorkspaceModal's bulk-create
 * spawns sessions in and `buildGrid` (paneGrid.ts) fills the grid in, so panes
 * land in a stable, predictable left-to-right/top-to-bottom order every
 * time. */
export function checkedEngines(state: NewWorkspaceState): Engine[] {
  return ENGINES.filter((engine) => state.engines[engine]);
}

/** Gates the "Create Workspace" button: a folder must be picked, the
 * (possibly user-edited) name must be non-blank, at least one engine must
 * be checked (the reference's own constraint — an empty workspace makes no
 * sense), and a submit can't already be in flight. */
export function canSubmit(state: NewWorkspaceState): boolean {
  return (
    state.path !== null &&
    state.name.trim().length > 0 &&
    !state.submitting &&
    checkedEngines(state).length > 0
  );
}

// Re-exported so components only need to import this one module for both
// the state shape and the preset list it's built from.
export { LAYOUT_PRESETS };
export type { LayoutPreset };
