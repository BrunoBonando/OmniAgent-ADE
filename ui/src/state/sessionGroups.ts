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
import type { TabInfo } from "./sessions";

/** The implicit session every pane with no `group` belongs to, per project.
 * Two kinds of pane land here: layouts persisted before groups existed
 * (which must keep restoring exactly as they did), and any future code path
 * that opens a pane without saying which session it's for. Never generated
 * as a real group id — `newSessionGroupId` only ever mints `sess-grp-…`. */
export const UNGROUPED_SESSION_ID = "__ungrouped__";

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
  /** Display name: "Session 1", "Session 2", … by first-seen order within
   * the project. Positional rather than stored, so nothing has to be
   * migrated, renamed or persisted — and the numbering always reads in the
   * order the sessions appear in the sidebar. */
  label: string;
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
    return {
      project,
      sessions: entry.order.map((id, i) => {
        const groupTabs = entry.groups.get(id)!;
        return {
          id,
          project,
          label: `Session ${i + 1}`,
          tabs: groupTabs,
          isCurrent: activeTabId !== null && groupTabs.some((t) => t.id === activeTabId),
        };
      }),
    };
  });
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

/** One line under a session row: how many panes and which engines, e.g.
 * "2 panes · Claude Code, Shell". Deliberately built from the live tabs
 * rather than remembering what the create dialog chose — a pane closed
 * afterwards must not leave the row claiming it's still there. */
export function describeSession(session: SessionGroup, engineLabel: (engine: string) => string): string {
  const count = session.tabs.length;
  const engines: string[] = [];
  for (const tab of session.tabs) {
    const label = engineLabel(tab.engine);
    if (!engines.includes(label)) engines.push(label);
  }
  return `${count} pane${count === 1 ? "" : "s"} · ${engines.join(", ")}`;
}
