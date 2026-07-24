// Pure, framework-free session/tab state for the workspace shell (PLAN.md
// Task 5.2). Deliberately has zero Tauri/React imports so it's trivial to
// unit test (see sessions.test.ts) and so App.tsx stays a thin binding of
// this reducer to `invoke()` calls and DOM events — all the "what happens
// when" logic (tab ordering, which tab becomes active after a close,
// engine-default resolution, layout persistence shape) lives here, once.

export const ENGINES = ["claude", "codex", "shell"] as const;
export type Engine = (typeof ENGINES)[number];

export function isEngine(value: unknown): value is Engine {
  return value === "claude" || value === "codex" || value === "shell";
}

/** Sidebar row — the `brain_query{kind:"list_projects"}` shape. */
export interface ProjectInfo {
  id: string;
  label: string;
  path: string | null;
}

/** A live terminal tab. `id` is the Rust `SessionInfo.id` (real PTY session).
 * `label` is an optional user-set custom name (double-click a tab in
 * `TabBar` to set one) — falls back to `engine` when unset. See
 * `tabDisplayLabel`.
 *
 * `needsAttention` (founder feedback, 2026-07-24 — Bruno, verbatim: "every
 * claude session can notify the app whenever it needs attention[...]
 * generate a badge"): set by the `tab/attention` action when a
 * `session-attention:{id}` Tauri event arrives (`sessions.rs`'s PTY reader
 * thread pattern-matches the raw output stream for Claude's own
 * tool-permission-prompt text — see that file's module docs for the full
 * investigation), cleared by `tab/activated` — the same action every
 * existing tab-focus path (`TabBar`, `Sidebar`'s per-project tab list,
 * `CommandPalette`) already dispatches through `onActivateTab`, so "the
 * user actually looked at this tab" needs no new UI wiring, just this
 * reducer case doing one more thing. */
export interface TabInfo {
  id: string;
  project: string;
  engine: Engine;
  cwd: string;
  createdAt: number;
  label?: string;
  needsAttention: boolean;
}

export interface SessionsState {
  projects: ProjectInfo[];
  tabs: TabInfo[];
  activeTabId: string | null;
}

export const initialSessionsState: SessionsState = {
  projects: [],
  tabs: [],
  activeTabId: null,
};

export type SessionsAction =
  | { type: "projects/loaded"; projects: ProjectInfo[] }
  | { type: "tab/opened"; tab: TabInfo }
  | { type: "tab/closed"; id: string }
  | { type: "tab/activated"; id: string }
  | { type: "tab/renamed"; id: string; label: string }
  | { type: "tab/attention"; id: string }
  | { type: "layout/restored"; tabs: TabInfo[] };

/**
 * When the active tab closes, focus falls to its left neighbor (matches the
 * mental model of every tabbed editor/browser: closing a tab keeps you in
 * the same neighborhood, not e.g. jumping back to tab 1). Falls back to the
 * tab that slid into the closed slot, then null if the closed tab was the
 * only one.
 */
function nextActiveAfterClose(closedIndex: number, remaining: TabInfo[]): string | null {
  if (remaining.length === 0) return null;
  const left = remaining[closedIndex - 1];
  if (left) return left.id;
  const sameSlot = remaining[closedIndex];
  if (sameSlot) return sameSlot.id;
  return remaining[0].id;
}

export function sessionsReducer(state: SessionsState, action: SessionsAction): SessionsState {
  switch (action.type) {
    case "projects/loaded":
      return { ...state, projects: action.projects };

    case "tab/opened":
      return {
        ...state,
        tabs: [...state.tabs, action.tab],
        activeTabId: action.tab.id,
      };

    case "tab/closed": {
      const idx = state.tabs.findIndex((t) => t.id === action.id);
      if (idx === -1) return state;
      const tabs = state.tabs.filter((t) => t.id !== action.id);
      const activeTabId =
        state.activeTabId === action.id ? nextActiveAfterClose(idx, tabs) : state.activeTabId;
      return { ...state, tabs, activeTabId };
    }

    case "tab/activated": {
      const target = state.tabs.find((t) => t.id === action.id);
      if (!target) return state;
      // Activating a tab is the one place "the user actually looked at
      // this" gets observed — clear its badge here rather than adding a
      // second action every activation call site would need to remember to
      // also dispatch. Skips the tabs-array rebuild when there was nothing
      // to clear, so repeatedly clicking an already-active, already-quiet
      // tab doesn't churn a new array on every render.
      if (!target.needsAttention) return { ...state, activeTabId: action.id };
      return {
        ...state,
        activeTabId: action.id,
        tabs: state.tabs.map((t) => (t.id === action.id ? { ...t, needsAttention: false } : t)),
      };
    }

    case "tab/attention": {
      if (!state.tabs.some((t) => t.id === action.id)) return state;
      return {
        ...state,
        tabs: state.tabs.map((t) => (t.id === action.id ? { ...t, needsAttention: true } : t)),
      };
    }

    case "tab/renamed": {
      if (!state.tabs.some((t) => t.id === action.id)) return state;
      const trimmed = action.label.trim();
      return {
        ...state,
        tabs: state.tabs.map((t) =>
          t.id === action.id ? { ...t, label: trimmed.length > 0 ? trimmed : undefined } : t,
        ),
      };
    }

    case "layout/restored":
      return {
        ...state,
        tabs: action.tabs,
        activeTabId: action.tabs[0]?.id ?? null,
      };

    default:
      return state;
  }
}

/** What a tab's chrome (`TabBar`, `Sidebar`, `CommandPalette`) should
 * actually print: the custom rename if the user set one, else the engine
 * name — the pre-rename default every tab already displayed. */
export function tabDisplayLabel(tab: TabInfo): string {
  return tab.label && tab.label.length > 0 ? tab.label : tab.engine;
}

/** Tabs grouped per project, project order = first-seen order (stable, no re-sort on new tabs within a known project). */
export function tabsByProject(tabs: TabInfo[]): Array<{ project: string; tabs: TabInfo[] }> {
  const order: string[] = [];
  const map = new Map<string, TabInfo[]>();
  for (const tab of tabs) {
    if (!map.has(tab.project)) {
      map.set(tab.project, []);
      order.push(tab.project);
    }
    map.get(tab.project)!.push(tab);
  }
  return order.map((project) => ({ project, tabs: map.get(project)! }));
}

/** DESIGN 3.2 / PLAN.md Task 5.2: machine-pressure badge past 6 live sessions. */
export const PRESSURE_THRESHOLD = 6;
export function isUnderPressure(tabs: TabInfo[]): boolean {
  return tabs.length > PRESSURE_THRESHOLD;
}

/** Settings-table keys (Task 5.2's "your call on key scheme"). */
export function defaultEngineSettingKey(project: string): string {
  return `default_engine:${project}`;
}
export const GLOBAL_DEFAULT_ENGINE_KEY = "default_engine:__global__";
export const LAYOUT_SETTING_KEY = "layout";

/**
 * Per-project default engine, falling back to a global default, falling
 * back to "claude" (DESIGN principle 5 / Bruno's own words in DESIGN.md:
 * "if the default is Claude, it basically runs Claude"). `settings` is the
 * flat key/value map read from the `settings` table via `settings_get`.
 */
export function resolveDefaultEngine(project: string, settings: Record<string, string | undefined>): Engine {
  const perProject = settings[defaultEngineSettingKey(project)];
  if (isEngine(perProject)) return perProject;
  const global = settings[GLOBAL_DEFAULT_ENGINE_KEY];
  if (isEngine(global)) return global;
  return "claude";
}

export function cycleEngine(current: Engine, direction: 1 | -1): Engine {
  const idx = ENGINES.indexOf(current);
  const next = (idx + direction + ENGINES.length) % ENGINES.length;
  return ENGINES[next];
}

/** The shape persisted under `LAYOUT_SETTING_KEY` — engines are restarted
 * fresh on restore (DESIGN 3.1: no PTY resurrection), so only the inputs to
 * a fresh `session_create` call are kept, never the old session id. `label`
 * is the one piece of pure UI state worth carrying across a restart (a
 * rename with no other effect on the session), so it rides along here too. */
export interface PersistedTab {
  project: string;
  engine: Engine;
  cwd: string;
  label?: string;
}
export interface Layout {
  tabs: PersistedTab[];
}

export function serializeLayout(tabs: TabInfo[]): string {
  const layout: Layout = {
    tabs: tabs.map(({ project, engine, cwd, label }) => ({
      project,
      engine,
      cwd,
      ...(label ? { label } : {}),
    })),
  };
  return JSON.stringify(layout);
}

/** Never throws — a corrupt/missing layout restores to "no tabs" rather than crashing the app on launch. */
export function deserializeLayout(raw: string | null | undefined): PersistedTab[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as Partial<Layout>;
    if (!Array.isArray(parsed.tabs)) return [];
    return parsed.tabs.filter(
      (t): t is PersistedTab =>
        !!t &&
        typeof t.project === "string" &&
        typeof t.cwd === "string" &&
        isEngine(t.engine) &&
        (t.label === undefined || typeof t.label === "string"),
    );
  } catch {
    return [];
  }
}
