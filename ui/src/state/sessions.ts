// Pure, framework-free session/tab state for the workspace shell (PLAN.md
// Task 5.2). Deliberately has zero Tauri/React imports so it's trivial to
// unit test (see sessions.test.ts) and so App.tsx stays a thin binding of
// this reducer to `invoke()` calls and DOM events — all the "what happens
// when" logic (tab ordering, which tab becomes active after a close,
// engine-default resolution, layout persistence shape) lives here, once.

import { isTerminalThemeId, type TerminalThemeId } from "../lib/terminalThemes";
import type { SessionStatus } from "./sessionStatus";

export const ENGINES = ["claude", "codex", "shell"] as const;
export type Engine = (typeof ENGINES)[number];

/** The implicit session every pane with no `group` belongs to, per project.
 * Two kinds of pane land here: layouts persisted before groups existed
 * (which must keep restoring exactly as they did), and any future code path
 * that opens a pane without saying which session it's for. Never generated
 * as a real group id — `newSessionGroupId` only ever mints `sess-grp-…`.
 *
 * Lives here rather than in `sessionGroups.ts` (which re-exports it, so
 * every existing import still resolves) because the reducer below needs it
 * to address a session by `project + group`, and `sessionGroups.ts` already
 * imports from this module — pointing a value import back the other way
 * would close the cycle. */
export const UNGROUPED_SESSION_ID = "__ungrouped__";

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
 * ## `needsAttention` is gone (2026-07-26), folded into `status`
 *
 * This used to carry a latched `needsAttention: boolean`, set by a
 * `tab/attention` action fed from the `session-attention:{id}` event and
 * cleared by `tab/activated`, rendered as a red dot in three places (pane
 * header, sidebar project row, sidebar tab row). The five-state light
 * (`status` below) is driven by the *same* underlying detection in
 * `sessions.rs` and now says the same thing in a richer language:
 * `awaiting_approval` is exactly "this session is waiting on you" and
 * `error` is exactly "this one is stuck". Keeping both meant the UI
 * claimed the same fact twice, in two colours, with two different
 * lifetimes (one latched-until-clicked, one live) — which is worse than
 * either alone, because they disagree the moment a session resolves
 * itself without the user ever looking.
 *
 * So attention is now *derived*, never stored: `statusNeedsAttention`
 * (`sessionStatus.ts`) is the one definition, the sidebar tints its dot
 * with the same status colour the pane's light uses, and the notifications
 * panel (`state/notifications.ts`) owns the "you were somewhere else when
 * this happened" job the latched badge was really being used for.
 *
 * `themeId` (founder ask, verbatim: "you can add some themes for each
 * terminal already ... The theme is applied to the terminal only and it
 * should be always saved automatically"): this pane's terminal-color-theme
 * OVERRIDE, unset by default — every pane with no override renders
 * `terminalThemes.ts`'s `DEFAULT_TERMINAL_THEME` ("global default, new
 * sessions use it"; there's no separate "set the app-wide default" action
 * in v1, see that module's own doc). Set via `PaneHeader`'s 3-dot "Terminal
 * theme" picker (`tab/themeChanged`), and — same "one piece of pure UI
 * state worth carrying across a restart" treatment `label` already gets —
 * persisted per-pane through `PersistedTab`/`serializeLayout` below, so a
 * pane's chosen theme survives a relaunch if its project's layout is
 * restored. */
export interface TabInfo {
  id: string;
  project: string;
  engine: Engine;
  cwd: string;
  createdAt: number;
  label?: string;
  /** Which *session* (pane group) inside its project this pane belongs to
   * — founder brief, 2026-07-26, verbatim: "Each session can be created
   * with a new layout, agents, etc... but in the same folder or subfolder"
   * and "Inside each workspace (first column) it must show the session
   * it's currently on the screen".
   *
   * A **workspace** is a project (a sidebar row, its own folder); a
   * **session** is the set of one-or-more agent panes created together
   * inside it, with their own layout preset, their own engines and their
   * own cwd (the project folder or a subfolder of it). This id is what
   * makes that grouping real — see `state/sessionGroups.ts` for the
   * derivations built on it and `components/Sidebar.tsx` for the
   * project -> session -> pane tree it renders.
   *
   * Optional on purpose: layouts persisted before this existed have no
   * group, and every one of those panes still has to restore and render
   * exactly as it did (they're collected under a single implicit group per
   * project — `UNGROUPED_SESSION_ID`). Carried across a relaunch through
   * `PersistedTab`, and across an engine restart by the caller, for the
   * same reason `label`/`themeId` are: it describes the PANE, not the
   * process underneath it. */
  group?: string;
  /** The **name of the session this pane belongs to** — founder brief,
   * 2026-07-26, verbatim: *"Each session has a name and can be renamed. It
   * starts with session #1"*.
   *
   * Stored, not derived. The sidebar used to label sessions positionally
   * ("the 2nd session in this project is Session 2"), which silently
   * renames every session below one that closes — the opposite of a name.
   * So a session's name is materialized when it is created (`Session 1`,
   * `Session 2`, … — see `sessionGroups.ts`'s `nextSessionName` for the
   * numbering rule) and thereafter only changes when the user renames it.
   *
   * Carried by *every* pane of the session rather than by a second
   * collection keyed by group id, for the reason `sessionGroups.ts`'s doc
   * gives: the tabs array is the only thing that survives a relaunch, so a
   * side table of names would need its own persistence, its own restore and
   * its own garbage collection, and could disagree with the panes it
   * describes. Renaming writes the name onto every pane in the group
   * (`session/renamed`), and reading takes the first pane that has one.
   *
   * Undefined for pre-naming layouts and for the implicit ungrouped
   * session, which fall back to a derived default. */
  groupLabel?: string;
  themeId?: TerminalThemeId;
  /** This pane's five-state light (`sessionStatus.ts`), set by the
   * `tab/status` action from the `session-status:{id}` event stream and the
   * one-shot `session_status` pull `App.tsx` does per new session.
   * `undefined` = nothing has reported in yet, which renders as the neutral
   * "Starting" mark rather than a guess (see `statusPresentation`).
   *
   * Lives on the tab (rather than in a `PaneHeader`-local hook) for exactly
   * the reason `needsAttention` does: the status of a session the user isn't
   * looking at is the interesting case, and the notifications panel a later
   * dispatch builds needs one central place holding every session's current
   * light. Deliberately NOT persisted — see `PersistedTab`. */
  status?: SessionStatus;
  /** `SessionInfo.restored`: this tab reattached to an engine that survived
   * the app closing (tmux), rather than starting a fresh one. A fact about
   * *this run* only, so — like `status` — it is never persisted. Surfaced as
   * one line in the hover card; nothing branches on it, because a restore
   * that silently fell back to a fresh session must look and behave
   * identically to any other session. */
  restored?: boolean;
}

export interface SessionsState {
  projects: ProjectInfo[];
  tabs: TabInfo[];
  /** Before the BridgeSpace pane-grid rebuild this was "which tab is the
   * *only* one currently displayed" (the old `TabBar`/single-terminal-area
   * shell). Now that `Workspace.tsx` shows every session in the selected
   * project as a simultaneously-visible pane, this means "which pane last
   * had focus" instead — still cleared-on-activate (below), still what
   * clears a pane's attention badge, still what `PaneHeader` highlights.
   * `App.tsx`'s `activateTab` also keeps `selectedProjectId` (its own,
   * separate piece of state) in sync with this tab's project, so "activate"
   * always brings the right grid on screen too — that part lives outside
   * this reducer since `selectedProjectId` isn't part of `SessionsState`. */
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
  | { type: "tabs/opened_bulk"; tabs: TabInfo[] }
  | { type: "tab/closed"; id: string }
  | { type: "tab/activated"; id: string }
  | { type: "tab/renamed"; id: string; label: string }
  // Renaming a whole SESSION (the sidebar's double-click-to-rename, same
  // gesture `PaneHeader`/`ProjectMenu` use for a pane and a project). A
  // session is addressed by `project + group` because a group id is only
  // unique within its project, and the implicit `UNGROUPED_SESSION_ID`
  // exists once per project. An empty/whitespace name clears the stored
  // name, exactly like `tab/renamed` does for a pane.
  | { type: "session/renamed"; project: string; group: string; name: string }
  // The five-state light — one `session-status:{id}` transition, or the
  // one-shot `session_status` pull for a pane that just appeared.
  | { type: "tab/status"; id: string; status: SessionStatus }
  | { type: "layout/restored"; tabs: TabInfo[] }
  // Auto-title from the first prompt (`autoTitle.ts`'s capture, fed from
  // `Terminal.tsx`'s real onData stream) — unlike `tab/renamed`, only ever
  // applies when the tab has no label yet (see the reducer case's own
  // doc): a manual rename or an already-set auto-title always wins.
  | { type: "tab/autoTitled"; id: string; label: string }
  // PaneHeader's 3-dot "Change engine": the old session (`oldId`) was
  // killed and a brand-new one spawned with a different engine, same
  // pane/slot — swaps the whole `TabInfo` in place (see the reducer case's
  // own doc for why this is a dedicated action rather than close-then-open).
  | { type: "tab/engineRestarted"; oldId: string; tab: TabInfo }
  // PaneHeader's 3-dot "Terminal theme" picker — `themeId: undefined`
  // clears the pane's override back to the global default.
  | { type: "tab/themeChanged"; id: string; themeId: TerminalThemeId | undefined };

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

    // NewWorkspaceModal's bulk-create: every session in the newly-created
    // workspace lands in a single dispatch (never a `tab/opened` per
    // session) so a brand-new project's `ProjectPaneGrid` (Workspace.tsx)
    // mounts directly with its whole final tab set already present in one
    // render — see `paneGrid.ts`'s `buildLayoutTree` doc for why an
    // incremental, one-at-a-time reveal would both defeat the chosen
    // LAYOUT preset's arrangement and risk remounting already-open panes
    // mid-batch. Same "newest tab becomes active" rule as `tab/opened`,
    // generalized to the last tab in the batch. A no-op for an empty batch
    // (every session in the batch failed to create — the caller still has
    // something to show via the error banner, just no new tabs to add).
    case "tabs/opened_bulk": {
      if (action.tabs.length === 0) return state;
      return {
        ...state,
        tabs: [...state.tabs, ...action.tabs],
        activeTabId: action.tabs[action.tabs.length - 1].id,
      };
    }

    case "tab/closed": {
      const idx = state.tabs.findIndex((t) => t.id === action.id);
      if (idx === -1) return state;
      const tabs = state.tabs.filter((t) => t.id !== action.id);
      const activeTabId =
        state.activeTabId === action.id ? nextActiveAfterClose(idx, tabs) : state.activeTabId;
      return { ...state, tabs, activeTabId };
    }

    case "tab/activated": {
      // Pure focus now: this used to ALSO clear the activated tab's latched
      // `needsAttention` badge, which no longer exists (see `TabInfo`'s doc
      // for why attention folded into `status`). Nothing about looking at a
      // pane changes what its session is actually doing, so activation
      // touches only `activeTabId` and never rebuilds the tabs array.
      if (!state.tabs.some((t) => t.id === action.id)) return state;
      return { ...state, activeTabId: action.id };
    }

    case "tab/status": {
      const target = state.tabs.find((t) => t.id === action.id);
      // Skips the tabs-array rebuild when the light didn't actually change.
      // The backend already only emits on a genuine transition, but the
      // one-shot `session_status` pull on mount usually reports the state a
      // just-arrived event already set — without this guard that pull would
      // churn a new `tabs` array (and re-render every pane) for nothing.
      if (!target || target.status === action.status) return state;
      return {
        ...state,
        tabs: state.tabs.map((t) => (t.id === action.id ? { ...t, status: action.status } : t)),
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

    case "session/renamed": {
      const inSession = (t: TabInfo) =>
        t.project === action.project && (t.group ?? UNGROUPED_SESSION_ID) === action.group;
      if (!state.tabs.some(inSession)) return state;
      const trimmed = action.name.trim();
      return {
        ...state,
        tabs: state.tabs.map((t) =>
          inSession(t) ? { ...t, groupLabel: trimmed.length > 0 ? trimmed : undefined } : t,
        ),
      };
    }

    case "tab/autoTitled": {
      const target = state.tabs.find((t) => t.id === action.id);
      // Never overwrites an existing label — a manual rename, a label
      // carried over from an engine restart, or a duplicate/late-arriving
      // auto-title fire (shouldn't happen given `autoTitle.ts`'s own
      // "capture once" guarantee, but the reducer stays defensive) all win.
      if (!target || (target.label && target.label.length > 0)) return state;
      return {
        ...state,
        tabs: state.tabs.map((t) => (t.id === action.id ? { ...t, label: action.label } : t)),
      };
    }

    case "tab/engineRestarted": {
      const idx = state.tabs.findIndex((t) => t.id === action.oldId);
      if (idx === -1) return state;
      const tabs = state.tabs.slice();
      tabs[idx] = action.tab;
      const activeTabId = state.activeTabId === action.oldId ? action.tab.id : state.activeTabId;
      return { ...state, tabs, activeTabId };
    }

    case "tab/themeChanged": {
      if (!state.tabs.some((t) => t.id === action.id)) return state;
      return {
        ...state,
        tabs: state.tabs.map((t) => (t.id === action.id ? { ...t, themeId: action.themeId } : t)),
      };
    }

    case "layout/restored":
      // MERGE, never wholesale-replace: `App.tsx`'s boot effect sequentially
      // `await`s `sessionCreate` for every persisted tab before firing this
      // action once, and nothing disables the Sidebar's new-tab affordances
      // while that loop is in flight. If the user opens a tab mid-restore,
      // `tab/opened` already appended it to `state.tabs` — a wholesale
      // replace here would silently drop it from the UI while its
      // already-spawned backend PTY session keeps running orphaned forever
      // (nothing left in state to ever call `sessionKill` on it). Restored
      // tabs always get fresh ids from a fresh `sessionCreate` call, so they
      // can never collide with an id already in `state.tabs` — a plain
      // concat is a safe merge, no dedup needed. Focus: only default to the
      // first restored tab if nothing opened during the race has already
      // claimed it — never steal focus away from a tab the user is already
      // looking at.
      return {
        ...state,
        tabs: [...action.tabs, ...state.tabs],
        activeTabId: state.activeTabId ?? action.tabs[0]?.id ?? null,
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

/** Upper bound on a session id the backend will accept as a `restore_id`,
 * mirroring `sessions.rs`'s `MAX_SESSION_ID_LEN`. */
export const MAX_SESSION_ID_LEN = 96;

/** The backend's `is_valid_session_id`, mirrored (`[A-Za-z0-9_-]`, 1..=96).
 * That id becomes both a filename (`<id>.log`) and a tmux target, so the
 * Rust side *validates* rather than sanitizes and rejects anything else —
 * checking here as well means a hand-edited or corrupted settings row costs
 * one tab its live-session restore, not the whole `session_create` call.
 * Generated ids are `sess-<nanos>-<counter>`, comfortably inside this. */
export function isValidSessionId(value: unknown): value is string {
  return (
    typeof value === "string" &&
    value.length > 0 &&
    value.length <= MAX_SESSION_ID_LEN &&
    /^[A-Za-z0-9_-]+$/.test(value)
  );
}

/** The shape persisted under `LAYOUT_SETTING_KEY`.
 *
 * **`id` (2026-07-26) is what makes session restore real.** This used to
 * deliberately drop it — DESIGN 3.1's "engines are restarted fresh on
 * restore, no PTY resurrection", so only the inputs to a fresh
 * `session_create` were worth keeping. Two backend dispatches then made
 * sessions genuinely survive the app closing (tmux-backed, see
 * `src-tauri/src/sessions.rs`'s "Session persistence via tmux"), and that
 * machinery keys entirely off the session keeping the *same id* across a
 * relaunch: `session_create({ …, restoreId })` reattaches to the still-live
 * `claude`/`codex`/shell process instead of spawning a new one. With no
 * persisted id there is no `restoreId` to send, every relaunch mints a fresh
 * id, and the whole feature is inert. So the id rides along now — and
 * `App.tsx`'s boot restore passes it as `restoreId`.
 *
 * It stays *optional* in the type on purpose: layouts written before this
 * change have no `id`, and they must keep restoring exactly as they did
 * (fresh session, no `restoreId` sent). `label` and `themeId` are the two
 * pieces of pure UI state worth carrying across a restart (a rename, a
 * pane's terminal-theme override) and are unchanged.
 *
 * `status` and `restored` (see `TabInfo`) are deliberately absent: both
 * describe a live process in *this* run, and persisting either would mean
 * restoring a pane with a stale light claiming a state nothing has
 * verified. */
export interface PersistedTab {
  project: string;
  engine: Engine;
  cwd: string;
  id?: string;
  label?: string;
  themeId?: TerminalThemeId;
  /** The pane's session (pane-group) id — see `TabInfo.group`. Persisted
   * for the same reason `label`/`themeId` are: it's pure UI state
   * describing the pane, and a relaunch that scattered every pane back
   * into one anonymous pile would lose the grouping the user built. Kept
   * optional so pre-grouping layouts restore unchanged, and validated on
   * the way back in — a corrupt group id costs that pane its grouping, not
   * its terminal. */
  group?: string;
  /** The session's **name** (see `TabInfo.groupLabel`). Persisted for the
   * same reason the group id is: a relaunch that came back with sessions
   * called something else — or renumbered — would make the name a lie. Kept
   * even when `group` itself was rejected above: the pane then joins its
   * project's implicit session, and that session is still the one the user
   * named. */
  groupLabel?: string;
}
export interface Layout {
  tabs: PersistedTab[];
}

export function serializeLayout(tabs: TabInfo[]): string {
  const layout: Layout = {
    tabs: tabs.map(({ id, project, engine, cwd, label, themeId, group, groupLabel }) => ({
      project,
      engine,
      cwd,
      // An id the backend would reject as a `restoreId` is not worth
      // storing — it can only produce a failed restore next launch.
      ...(isValidSessionId(id) ? { id } : {}),
      ...(label ? { label } : {}),
      ...(themeId ? { themeId } : {}),
      ...(isValidSessionId(group) ? { group } : {}),
      ...(groupLabel && groupLabel.trim().length > 0 ? { groupLabel: groupLabel.trim() } : {}),
    })),
  };
  return JSON.stringify(layout);
}

/** Never throws — a corrupt/missing layout restores to "no tabs" rather
 * than crashing the app on launch. Two fields are individually repaired
 * rather than costing the whole entry:
 *
 * - an invalid `themeId` (e.g. a preset removed in a later version) drops
 *   just that field — a stale theme preference losing the session/project it
 *   was attached to would be a much worse failure mode than silently falling
 *   back to the global default theme for that one pane;
 * - an invalid *or duplicated* `id` drops just that field, so the tab
 *   restores as a fresh session instead of disappearing. Duplicates matter
 *   because the backend rejects a `restoreId` naming a session already live
 *   in this app ("restore_id must name a session from a previous run"), and
 *   one corrupt row must not be able to cost the user a whole pane.
 */
export function deserializeLayout(raw: string | null | undefined): PersistedTab[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as Partial<Layout>;
    if (!Array.isArray(parsed.tabs)) return [];
    const seenIds = new Set<string>();
    return parsed.tabs
      .filter(
        (t): t is PersistedTab =>
          !!t &&
          typeof t.project === "string" &&
          typeof t.cwd === "string" &&
          isEngine(t.engine) &&
          (t.label === undefined || typeof t.label === "string"),
      )
      .map((t) => (t.themeId !== undefined && !isTerminalThemeId(t.themeId) ? { ...t, themeId: undefined } : t))
      // A group id is a plain opaque token (same `[A-Za-z0-9_-]{1,96}`
      // shape as a session id, generated by `newSessionGroupId`), so an
      // invalid one drops just that field: the pane restores, ungrouped,
      // instead of vanishing.
      .map((t) => {
        if (t.group === undefined) return t;
        if (isValidSessionId(t.group)) return t;
        const { group: _dropped, ...rest } = t;
        return rest;
      })
      // A session name is free text the user typed, so it is only checked
      // for being a non-empty string — a corrupt one costs the session its
      // name (it falls back to a derived default) rather than the pane.
      .map((t) => {
        if (t.groupLabel === undefined) return t;
        const trimmed = typeof t.groupLabel === "string" ? t.groupLabel.trim() : "";
        if (trimmed.length > 0) return { ...t, groupLabel: trimmed };
        const { groupLabel: _dropped, ...rest } = t;
        return rest;
      })
      .map((t) => {
        if (t.id === undefined) return t;
        if (!isValidSessionId(t.id) || seenIds.has(t.id)) {
          const { id: _dropped, ...rest } = t;
          return rest;
        }
        seenIds.add(t.id);
        return t;
      });
  } catch {
    return [];
  }
}
