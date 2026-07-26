// Pure, framework-free session (pane-group) derivations — the "workspace ->
// session -> panes" tree the sidebar renders, and the answers the ⌘N "new
// session" flow needs. Zero React/Tauri imports, same house style as
// `sessions.ts`/`paneGrid.ts`, so all of it is unit-testable without a DOM.
//
// ## The model, stated plainly (founder brief, 2026-07-26)
//
// Bruno, verbatim: *"Each session can be created with a new layout, agents,
// etc... but in the same folder or subfolder"* and *"Inside each workspace
// (first column) it must show the session it's currently on the screen."*
//
// - A **workspace** is a project: a sidebar row, its own folder, its own
//   entry in the brain. Created by `NewWorkspaceModal` (which picks a
//   brand-new folder and calls `add_project`).
// - A **session** is a set of one-or-more agent panes *inside* one project,
//   created together with their own layout preset, their own engines, and
//   their own cwd — the project folder or a subfolder of it. Created by
//   `NewSessionModal`. It is NOT a separate project and never leaves the
//   project's folder.
// - A **pane** is one live PTY (`TabInfo`), belonging to exactly one
//   session.
//
// The grouping is carried by `TabInfo.group` (persisted via
// `PersistedTab.group`), and everything below is derived from the tabs
// array — there is no second collection to keep in sync, which is what
// keeps session restore honest: restore the tabs and the grouping comes
// back with them, for free.
//
// ## Names (same brief: "Each session has a name and can be renamed. It
// ## starts with session #1")
//
// A session's name is **stored**, on its panes (`TabInfo.groupLabel`), for
// exactly the reason the grouping is stored there: one array, one restore.
// It was positional at first — "the 2nd session in this project is Session
// 2" — which quietly renamed every session below one that closed, i.e. the
// opposite of a name.
//
// - A session is created with `nextSessionName`: **the lowest free number**
//   in that workspace, so closing #2 and opening another gives Session 2
//   back rather than climbing forever, and no two rows ever read the same.
// - `groupTabsBySession` shows the stored name when there is one, and hands
//   the rest a derived default that is checked against the stored names, so
//   a legacy session can never collide with a typed one.
// - Renaming is `session/renamed` (sessions.ts), which writes the name onto
//   every pane in the group.
import { UNGROUPED_SESSION_ID, type Engine, type TabInfo } from "./sessions";

/** Re-exported from `sessions.ts`, where it now lives so the reducer can
 * address a session by `project + group` without importing this module (see
 * that constant's own doc). Every existing `from "./sessionGroups"` import
 * keeps working. */
export { UNGROUPED_SESSION_ID };

let groupCounter = 0;

/** A fresh session id, in the same `[A-Za-z0-9_-]{1,96}` shape
 * `isValidSessionId` (sessions.ts) accepts — that validator guards what
 * gets persisted, and a group id that couldn't survive a relaunch would
 * silently un-group its panes on the next launch. Wall clock plus a
 * process-local counter, so two groups created in the same millisecond
 * still differ. */
export function newSessionGroupId(): string {
  groupCounter += 1;
  return `sess-grp-${Date.now()}-${groupCounter}`;
}

export interface SessionGroup {
  /** `TabInfo.group`, or `UNGROUPED_SESSION_ID`. */
  id: string;
  project: string;
  /** The name actually stored on the panes (`TabInfo.groupLabel`), or
   * `undefined` for a session nobody has named — a pre-naming layout, or the
   * implicit ungrouped session. */
  name?: string;
  /** What to print: the stored `name`, else a derived `Session N`. */
  label: string;
  /** The session's own root: the cwd its **first** pane was created in.
   *
   * A session is created with one cwd (`NewSessionModal` validates the
   * project folder or a subfolder of it, and every pane in the batch gets
   * it), so in practice all its panes agree. They can drift afterwards — a
   * "change engine" restart keeps the pane's own cwd, and nothing stops a
   * future feature from moving one — so this picks the first pane rather
   * than pretending the session has no single answer. It is what the
   * sidebar's branch tag and the hover card's path are read from: the
   * session's root, not whichever pane happens to be focused. */
  cwd: string;
  tabs: TabInfo[];
  /** Contains the pane that currently has focus (`activeTabId`) — the
   * "session it's currently on the screen" the sidebar marks. */
  isCurrent: boolean;
}

export interface ProjectSessions {
  project: string;
  sessions: SessionGroup[];
}

/**
 * Tabs grouped project -> session -> panes. Both levels keep first-seen
 * order (stable: a new pane in a known session never re-sorts anything),
 * exactly like `tabsByProject`, which this is the two-level generalization
 * of.
 *
 * `activeTabId` only marks a session current; it never reorders. Exactly
 * one session can be current across the whole tree, because a tab id
 * belongs to exactly one project and one group.
 */
export function groupTabsBySession(tabs: TabInfo[], activeTabId: string | null): ProjectSessions[] {
  const projectOrder: string[] = [];
  const byProject = new Map<string, { order: string[]; groups: Map<string, TabInfo[]> }>();

  for (const tab of tabs) {
    let entry = byProject.get(tab.project);
    if (!entry) {
      entry = { order: [], groups: new Map() };
      byProject.set(tab.project, entry);
      projectOrder.push(tab.project);
    }
    const groupId = tab.group ?? UNGROUPED_SESSION_ID;
    if (!entry.groups.has(groupId)) {
      entry.groups.set(groupId, []);
      entry.order.push(groupId);
    }
    entry.groups.get(groupId)!.push(tab);
  }

  return projectOrder.map((project) => {
    const entry = byProject.get(project)!;
    // Two passes, because a derived default must never collide with a name
    // that is actually stored somewhere in this workspace: collect the real
    // names first, then hand the leftovers the lowest free number.
    const names = entry.order.map((id) => storedSessionName(entry.groups.get(id)!));
    const taken = new Set(names.filter((n): n is string => n !== undefined));
    return {
      project,
      sessions: entry.order.map((id, i) => {
        const groupTabs = entry.groups.get(id)!;
        const name = names[i];
        let label = name;
        if (label === undefined) {
          label = defaultSessionName(lowestFreeSessionNumber(taken));
          taken.add(label);
        }
        return {
          id,
          project,
          name,
          label,
          cwd: groupTabs[0].cwd,
          tabs: groupTabs,
          isCurrent: activeTabId !== null && groupTabs.some((t) => t.id === activeTabId),
        };
      }),
    };
  });
}

/** The name stored on a session's panes: the first one that carries a
 * non-empty `groupLabel`. Renaming writes it onto every pane, so they
 * normally agree; taking the first keeps a half-written group (an engine
 * restart racing a rename) readable instead of blank. */
function storedSessionName(tabs: TabInfo[]): string | undefined {
  for (const tab of tabs) {
    const name = tab.groupLabel?.trim();
    if (name) return name;
  }
  return undefined;
}

/** `Session 1`, `Session 2`, … — the default a session is born with
 * (founder brief: "It starts with session #1"). */
export function defaultSessionName(n: number): string {
  return `Session ${n}`;
}

/** **The numbering rule, stated once:** the lowest positive integer whose
 * default name is not already taken by a live session in that workspace.
 *
 * So sessions created and closed out of order never collide and never grow
 * unbounded: with `Session 1` and `Session 3` open, the next one is
 * `Session 2`; with 1 and 2 open it is `Session 3`. "Taken" means the name
 * a session *shows* — a stored name (including one the user typed as
 * "Session 2") or a derived default — because the collision that matters to
 * the person reading the sidebar is two rows with the same words on them. */
function lowestFreeSessionNumber(taken: ReadonlySet<string>): number {
  let n = 1;
  while (taken.has(defaultSessionName(n))) n += 1;
  return n;
}

/** What to call the session about to be created in `project` — see
 * `lowestFreeSessionNumber` for the rule. Reads the live tabs, so it sees
 * exactly what the sidebar shows. */
export function nextSessionName(tabs: TabInfo[], project: string): string {
  const sessions = groupTabsBySession(tabs, null).find((p) => p.project === project)?.sessions ?? [];
  return defaultSessionName(lowestFreeSessionNumber(new Set(sessions.map((s) => s.label))));
}

/** The session the user is currently on — the group holding the focused
 * pane. `null` when nothing is focused (or the focused id isn't a live
 * tab). Used for the sidebar's "current session" mark and to decide which
 * session a plain ⌘T pane should join. */
export function currentSessionGroupId(tabs: TabInfo[], activeTabId: string | null): string | null {
  if (activeTabId === null) return null;
  const tab = tabs.find((t) => t.id === activeTabId);
  if (!tab) return null;
  return tab.group ?? UNGROUPED_SESSION_ID;
}

/**
 * Which session's panes the grid actually puts **on screen** for `project`
 * — the founder's *"Inside each workspace (first column) it must show the
 * session it's currently on the screen"*, in its second half.
 *
 * The sidebar half of that brief shipped first; the grid stayed unfiltered
 * ("sessions are an organizing layer; all of a project's panes stay
 * visible"). This is the answer that closes it: `Workspace.tsx` renders one
 * grid per *session*, and shows the one this names.
 *
 * The rule, and why it isn't just `currentSessionGroupId`:
 *
 * - **The focused pane's session**, when the focused pane is in this
 *   project. This is the case that matters, and it agrees with
 *   `groupTabsBySession`'s `isCurrent` by construction — the sidebar's
 *   accent rail and the grid can never point at different sessions.
 * - **Otherwise the project's first session** (first-seen order = the
 *   topmost row in the sidebar). Selecting a workspace in the sidebar
 *   deliberately does *not* move focus, so `activeTabId` routinely belongs
 *   to a different project than the one being rendered; `currentSessionGroupId`
 *   answers `null` there, and a grid showing nothing at all would be a
 *   worse answer than showing the session the eye lands on anyway.
 * - **`null`** only when the project genuinely has no panes — the caller
 *   then renders its empty state.
 *
 * A stale `activeTabId` (its pane closed underneath) falls through to the
 * same first-session fallback rather than blanking the grid.
 */
export function visibleSessionGroupId(
  tabs: TabInfo[],
  project: string,
  activeTabId: string | null,
): string | null {
  const focused = activeTabId === null ? undefined : tabs.find((t) => t.id === activeTabId);
  if (focused && focused.project === project) return focused.group ?? UNGROUPED_SESSION_ID;
  const first = tabs.find((t) => t.project === project);
  return first === undefined ? null : (first.group ?? UNGROUPED_SESSION_ID);
}

/**
 * Which session a *newly opened single pane* in `project` should join —
 * the ⌘T / "+" / pane-split path, which says nothing about sessions.
 *
 * The answer is "whichever session you're already looking at in that
 * project": the focused pane's group when the focused pane is in this
 * project, else the project's most recently created session, else `null`
 * (the project has no panes at all — the caller mints a new group).
 * `undefined` is never returned for a real group; `null` means "start a new
 * one", which keeps the caller's branch trivial.
 */
export function sessionGroupForNewPane(
  tabs: TabInfo[],
  project: string,
  activeTabId: string | null,
): string | null {
  const focused = activeTabId === null ? undefined : tabs.find((t) => t.id === activeTabId);
  if (focused && focused.project === project) return focused.group ?? UNGROUPED_SESSION_ID;
  const inProject = tabs.filter((t) => t.project === project);
  if (inProject.length === 0) return null;
  return inProject[inProject.length - 1].group ?? UNGROUPED_SESSION_ID;
}

/** Every pane in one session, in tab order — what "close this session"
 * and "focus this session" operate on. */
export function tabsInSession(tabs: TabInfo[], project: string, groupId: string): TabInfo[] {
  return tabs.filter((t) => t.project === project && (t.group ?? UNGROUPED_SESSION_ID) === groupId);
}

/** Which engines are running in this session and how many terminals of
 * each, first-seen order — the hover card's "how many terminals and which
 * engines" row.
 *
 * Replaced `describeSession`, which rendered the same facts as one string
 * ("2 panes · Claude Code, Shell") for a sidebar line that no longer exists:
 * the sidebar now shows a session's name and branch and nothing else
 * (founder: "The menu on the left should not show the amount of tabs and
 * their names… Just the session, so it's cleaner"), and the card that
 * inherited the detail draws an engine-coloured dot per engine, which needs
 * the engines as data rather than as prose.
 *
 * Built from the live tabs, never from what the create dialog chose — a
 * terminal closed afterwards must not leave the card claiming it's there. */
export function sessionEngineBreakdown(session: SessionGroup): Array<{ engine: Engine; count: number }> {
  const counts: Array<{ engine: Engine; count: number }> = [];
  for (const tab of session.tabs) {
    const seen = counts.find((c) => c.engine === tab.engine);
    if (seen) seen.count += 1;
    else counts.push({ engine: tab.engine, count: 1 });
  }
  return counts;
}
