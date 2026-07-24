// Pure, framework-free UI state for the brain map (Task 6.2) — same split as
// `state/sessions.ts` in the workspace shell: no Tauri/React imports, so
// every transition is trivially unit-testable and `BrainMap.tsx` stays a
// thin binding of this reducer to `useGraphData`/force-graph calls.

/** The 8 `NodeKind` wire-strings `map_feed.rs` emits (`kind_str`) — kept
 * here as the single source of truth for the Lens/Legend's kind list so
 * `Lens.tsx` and `BrainMap.tsx` never hand-copy a second list that can
 * drift from the backend contract. */
export const NODE_KINDS = [
  "project",
  "file",
  "code_entity",
  "doc",
  "memory",
  "decision",
  "session",
  "community",
] as const;
export type NodeKindWire = (typeof NODE_KINDS)[number];

export type MapLayout = "radial" | "hierarchy";

export interface MapUiState {
  /** Community node ids currently expanded (real members shown, hub hidden). */
  expanded: string[];
  /** `map_graph`'s `filter` param verbatim: an ALLOW-list of kinds to show.
   * Empty = no filtering (show everything) — matches `map_feed.rs`'s own
   * "empty filter = no filtering" contract exactly, so the Lens's
   * checkboxes map straight onto the wire param with no inversion. */
  filter: NodeKindWire[];
  layout: MapLayout;
  fullscreen: boolean;
  selectedNodeId: string | null;
  searchQuery: string;
}

export const initialMapUiState: MapUiState = {
  expanded: [],
  filter: [],
  layout: "radial",
  fullscreen: false,
  selectedNodeId: null,
  searchQuery: "",
};

export type MapUiAction =
  | { type: "community/expand"; id: string }
  | { type: "community/collapseAll" }
  | { type: "filter/toggle"; kind: NodeKindWire }
  | { type: "filter/clear" }
  | { type: "layout/set"; layout: MapLayout }
  | { type: "fullscreen/toggle" }
  | { type: "node/select"; id: string | null }
  | { type: "search/set"; query: string };

export function mapUiReducer(state: MapUiState, action: MapUiAction): MapUiState {
  switch (action.type) {
    case "community/expand":
      if (state.expanded.includes(action.id)) return state; // idempotent
      return { ...state, expanded: [...state.expanded, action.id] };

    case "community/collapseAll":
      if (state.expanded.length === 0) return state;
      return { ...state, expanded: [] };

    case "filter/toggle": {
      const has = state.filter.includes(action.kind);
      return {
        ...state,
        filter: has ? state.filter.filter((k) => k !== action.kind) : [...state.filter, action.kind],
      };
    }

    case "filter/clear":
      if (state.filter.length === 0) return state;
      return { ...state, filter: [] };

    case "layout/set":
      if (state.layout === action.layout) return state;
      return { ...state, layout: action.layout };

    case "fullscreen/toggle":
      return { ...state, fullscreen: !state.fullscreen };

    case "node/select":
      return { ...state, selectedNodeId: action.id };

    case "search/set":
      return { ...state, searchQuery: action.query };

    default:
      return state;
  }
}
