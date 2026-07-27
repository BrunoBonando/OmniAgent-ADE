// Pure, framework-free state for the notifications badge + panel (founder
// ask, 2026-07-26, verbatim: *"notification badge (each agent, terminal,
// whatever... whenever it requires attention or finalizes a run, it should
// notify there)"*). Zero React/Tauri imports, same house style as
// `sessionStatus.ts`/`sessionGroups.ts` — `components/NotificationsPanel.tsx`
// is a thin renderer over this.
//
// ## Which events notify: the backend's flag, not a second copy of the rule
//
// Bruno also said, precisely: *"only green, yellow or red generate a
// notification (in case the user is somewhere else (maybe not in that
// terminal) or in another session or even workspace)"*. That rule is
// already implemented once, authoritatively, in Rust
// (`SessionStatus::notifies` — true for `ready`/`awaiting_approval`/`error`,
// never for `thinking`/`tool_execution`) and rides along on every
// `session-status:{id}` payload as `notify`. This module reads that flag and
// never re-derives it; `sessionStatus.ts`'s own header says the same thing
// from the other side. One rule, one place, no drift.
//
// ## …and the second half of his sentence: the focus rule
//
// The parenthetical is the actual product requirement, not an aside: a
// notification exists for the case where *the user is somewhere else*. A
// green light appearing on the pane he is looking at, right now, is not
// news — he watched it happen. So `deriveNotification` suppresses an event
// only when every one of these is true at once:
//
//   1. it's the focused pane           (`event.id === focusedTabId`)
//   2. …in the project on screen       (`tab.project === selectedProjectId`)
//   3. …in the workspace view          (`view === "workspace"`, not the map)
//   4. …in a visible window            (`windowVisible`, i.e.
//                                       document.visibilityState)
//
// Any one of those failing means he genuinely could have missed it — a
// background pane, another project's grid, the map view, or a hidden/
// backgrounded app window — and the notification is recorded. That is the
// most conservative reading of "in case the user is somewhere else": when in
// doubt, notify. The one deliberately-accepted false negative is the pane
// he's focused on but isn't watching (window visible, eyes elsewhere) —
// unknowable from here, and the pane's own light still shows the state.
import type { SessionStatus, SessionStatusEvent } from "./sessionStatus";
import type { TabInfo } from "./sessions";

/** Settings-table key, same "one string constant + JSON string value"
 * convention `LAYOUT_SETTING_KEY` uses, read/written through the generic
 * `settingsGet`/`settingsSet`. */
export const NOTIFICATIONS_SETTING_KEY = "notifications";

/** How many entries are kept (and persisted). Warp's own panel is a short
 * recent list, not an archive, and this is a local settings row that gets
 * rewritten on every notification — a few dozen keeps it small enough that
 * the write cost never matters. */
export const MAX_NOTIFICATIONS = 40;

/** The statuses that can ever produce an entry — `notify`'s Rust-side
 * definition, mirrored here ONLY as a validation guard for restoring
 * persisted entries (a settings row hand-edited to say `thinking` must not
 * resurrect a notification the rule never allows). It is never used to
 * decide whether a live event notifies; `event.notify` is. */
const NOTIFIABLE: readonly SessionStatus[] = ["ready", "awaiting_approval", "error"];

export interface NotificationEntry {
  /** Stable id for dismissal/keying: session id + the moment it fired. */
  id: string;
  sessionId: string;
  project: string;
  projectLabel: string;
  /** The pane's cwd — the panel resolves the branch tag from it (the same
   * `useGitBranch` hook the pane header uses), and it's what makes a row
   * still meaningful for a session that has since closed. */
  cwd: string;
  engine: string;
  status: SessionStatus;
  /** The session's own title — its rename/auto-title, else the engine name
   * (`tabDisplayLabel`), captured at notification time so a later rename
   * never rewrites history. */
  title: string;
  createdAt: number;
  /** False until the panel has been opened since this arrived — what the
   * badge counts. */
  read: boolean;
}

export interface NotificationsState {
  entries: NotificationEntry[];
}

export const initialNotificationsState: NotificationsState = { entries: [] };

/** Everything `deriveNotification` needs to answer "does this event become
 * a notification, and what does it say" — passed in whole rather than read
 * from anywhere, which is what keeps this module pure and the suppression
 * rule testable without mounting the app. */
export interface NotificationContext {
  event: SessionStatusEvent;
  /** The tab this event belongs to. `undefined` (an event for a session
   * this app doesn't have a pane for) produces nothing — a notification
   * that can't name its session, or navigate to it, is noise. */
  tab: TabInfo | undefined;
  projectLabel: string;
  /** The pane that currently has focus (`SessionsState.activeTabId`). */
  focusedTabId: string | null;
  /** The project whose grid is on screen (`App.tsx`'s selectedProjectId). */
  selectedProjectId: string | null;
  view: "workspace" | "map";
  /** `document.visibilityState === "visible"` — a minimised or
   * behind-another-app window means the user is, definitionally, somewhere
   * else. */
  windowVisible: boolean;
  now: number;
}

/** One plain sentence for what happened, written for the person reading the
 * panel rather than for whoever wrote the state machine — the same voice
 * `STATUS_PRESENTATION`'s explanations use, but past tense: the panel is a
 * log of things that already happened, the light is a live state. */
export function notificationSubtitle(status: SessionStatus): string {
  switch (status) {
    case "ready":
      return "Task completed.";
    case "awaiting_approval":
      return "Needs your approval.";
    case "error":
      return "Error occurred.";
    default:
      // Unreachable via `notify` (thinking/tool_execution never notify) —
      // total anyway so a future sixth state can't crash the panel.
      return "Status changed.";
  }
}

/** The keystroke that answers an engine's pending permission prompt with
 * "yes", written straight into its PTY (`sessionWrite`) — the same input
 * path typing in the pane uses, which also clears the Rust-side attention
 * latch (`sessions.rs`'s `mark_user_input`). Claude Code's dialog is a
 * numbered select where the digit picks the option outright, so `"1"` is
 * "Yes" without trusting where the highlight currently sits.
 *
 * ponytail: version-coupled to Claude Code's own dialog, exactly like the
 * `ATTENTION_MARKERS` scrape that detects the prompt in the first place —
 * one assumption, both sides of it. Other engines return `null` (no known
 * gesture) and their rows offer "Open pane" only; add an entry here when an
 * engine's prompt gesture is verified against a real session. The write
 * itself has an inherent race window too, being frontend-only (App.tsx's
 * in-flight guard narrows it, but doesn't close it): the durable fix is a
 * Rust-side `session_approve(id)` that re-checks the prompt scrape inside
 * the same lock before writing, rather than trusting the last status event
 * the frontend saw. */
const APPROVE_KEYSTROKES: Record<string, string> = { claude: "1" };

export function approveKeystroke(engine: string): string | null {
  return APPROVE_KEYSTROKES[engine] ?? null;
}

/** Actionable = this row froze an `awaiting_approval` AND that session is
 * still awaiting right now (`awaiting` = live status, passed in by the
 * caller). Both halves matter: without the live check, Approve would type
 * into whatever replaced the prompt since. */
export function isActionable(entry: NotificationEntry, awaiting: ReadonlySet<string>): boolean {
  return entry.status === "awaiting_approval" && awaiting.has(entry.sessionId);
}

/** The reference panel's three bands: NEEDS YOU (actionable, whatever their
 * age — a blocked session doesn't stop being blocked at midnight), then
 * EARLIER TODAY / OLDER by local calendar day.
 *
 * A session can carry more than one still-awaiting entry: the reducer only
 * collapses an *immediate* repeat (same session, same status, nothing else
 * in between), and a restored persisted entry reuses a session id from a
 * previous run, so two `awaiting_approval` rows for one session is reachable
 * without either of those catching it. Two rows means two Approve buttons
 * for a single prompt, so before banding, only the newest actionable entry
 * per session id is allowed into NEEDS YOU — the rest are not actionable for
 * banding purposes and fall through to the ordinary day-band logic below,
 * same as any other non-actionable row. */
export function groupNotifications(
  entries: NotificationEntry[],
  awaiting: ReadonlySet<string>,
  now: number,
): { needsYou: NotificationEntry[]; earlierToday: NotificationEntry[]; older: NotificationEntry[] } {
  const startOfToday = new Date(now).setHours(0, 0, 0, 0);

  const newestActionableBySession = new Map<string, NotificationEntry>();
  for (const entry of entries) {
    if (!isActionable(entry, awaiting)) continue;
    const current = newestActionableBySession.get(entry.sessionId);
    if (!current || entry.createdAt > current.createdAt) {
      newestActionableBySession.set(entry.sessionId, entry);
    }
  }

  const needsYou: NotificationEntry[] = [];
  const earlierToday: NotificationEntry[] = [];
  const older: NotificationEntry[] = [];
  for (const entry of entries) {
    const isNeedsYouWinner = newestActionableBySession.get(entry.sessionId) === entry;
    if (isNeedsYouWinner) needsYou.push(entry);
    else if (entry.createdAt >= startOfToday) earlierToday.push(entry);
    else older.push(entry);
  }
  return { needsYou, earlierToday, older };
}

/** Whether the user is demonstrably looking at this session right now — the
 * four-part rule in this module's header. Exported for its own test and so
 * the rule is nameable in a review, rather than buried in a conditional. */
export function isSessionOnScreen(ctx: NotificationContext): boolean {
  return (
    ctx.tab !== undefined &&
    ctx.event.id === ctx.focusedTabId &&
    ctx.tab.project === ctx.selectedProjectId &&
    ctx.view === "workspace" &&
    ctx.windowVisible
  );
}

/** `null` = no notification (not notifiable, unknown session, or the user
 * is already looking at it). */
export function deriveNotification(ctx: NotificationContext): NotificationEntry | null {
  if (!ctx.event.notify) return null;
  if (!ctx.tab) return null;
  if (isSessionOnScreen(ctx)) return null;

  const tab = ctx.tab;
  const title = tab.label && tab.label.length > 0 ? tab.label : tab.engine;
  return {
    id: `${ctx.event.id}:${ctx.now}`,
    sessionId: ctx.event.id,
    project: tab.project,
    projectLabel: ctx.projectLabel,
    cwd: tab.cwd,
    engine: ctx.event.engine || tab.engine,
    status: ctx.event.status,
    title,
    createdAt: ctx.now,
    read: false,
  };
}

export type NotificationsAction =
  | { type: "notification/added"; entry: NotificationEntry }
  | { type: "notification/dismissed"; id: string }
  | { type: "notifications/cleared" }
  /** The panel was opened — everything in it has now been seen. */
  | { type: "notifications/read" }
  | { type: "notifications/restored"; entries: NotificationEntry[] };

export function notificationsReducer(
  state: NotificationsState,
  action: NotificationsAction,
): NotificationsState {
  switch (action.type) {
    case "notification/added": {
      const newest = state.entries[0];
      // Collapse an immediate repeat of the same state for the same session
      // (ready -> thinking -> ready with nothing else in between) into one
      // row, refreshed to the newer time. Anything else since — even another
      // session's notification — keeps both, because then the older row
      // carries information the newer one doesn't.
      const rest =
        newest && newest.sessionId === action.entry.sessionId && newest.status === action.entry.status
          ? state.entries.slice(1)
          : state.entries;
      return { entries: [action.entry, ...rest].slice(0, MAX_NOTIFICATIONS) };
    }

    case "notification/dismissed":
      return { entries: state.entries.filter((e) => e.id !== action.id) };

    case "notifications/cleared":
      return { entries: [] };

    case "notifications/read": {
      if (state.entries.every((e) => e.read)) return state; // no churn
      return { entries: state.entries.map((e) => (e.read ? e : { ...e, read: true })) };
    }

    case "notifications/restored":
      return { entries: action.entries.slice(0, MAX_NOTIFICATIONS) };

    default:
      return state;
  }
}

export function unreadCount(state: NotificationsState): number {
  return state.entries.filter((e) => !e.read).length;
}

// ---------------------------------------------------------------- filter
// The reference panel leads with a filter chip carrying a count ("All tabs
// (3)"). Ours is a real two-state filter rather than a decorative count,
// because a control that looks like a filter and filters nothing is the
// same dead-UI problem the account menu's omitted rows avoid — and with
// several projects open, "just this workspace" is the question actually
// worth asking.

export type NotificationFilter = "all" | "project" | "needs_you";

export function filterNotifications(
  entries: NotificationEntry[],
  filter: NotificationFilter,
  projectId: string | null,
  awaiting: ReadonlySet<string>,
): NotificationEntry[] {
  if (filter === "all") return entries;
  if (filter === "needs_you") return entries.filter((e) => isActionable(e, awaiting));
  if (projectId === null) return [];
  return entries.filter((e) => e.project === projectId);
}

/** Chip text, count included — "All 3". The chip copy is fixed per the
 * design file ("All" / "This workspace" / "Needs you") regardless of the
 * actual project name; `_projectLabel` is vestigial — kept only so the
 * signature doesn't need to change at every call site — and unused. */
export function filterChipLabel(
  filter: NotificationFilter,
  count: number,
  _projectLabel: string | null,
): string {
  const name = filter === "all" ? "All" : filter === "needs_you" ? "Needs you" : "This workspace";
  return `${name} ${count}`;
}

/** Relative timestamps, in the reference panel's own vocabulary ("Just
 * now", "2 days"). Coarse on purpose: a notification list is scanned,
 * not read, and second-level precision would make every row twitch. */
export function relativeTime(createdAt: number, now: number): string {
  const seconds = Math.max(0, Math.round((now - createdAt) / 1000));
  if (seconds < 60) return "Just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  const days = Math.floor(hours / 24);
  return days === 1 ? "1 day" : `${days} days`;
}

// ------------------------------------------------------------ persistence
// Kept across relaunches (Bruno's own framing is "the user is somewhere
// else" — quitting for the night is the extreme case of somewhere else, and
// the reference panel's own rows read "2 days ago"/"3 days ago", so it
// clearly outlives a window). Cheap: one settings row written through the
// same generic `settingsGet`/`settingsSet` pattern `LAYOUT_SETTING_KEY`
// already uses, no new command, no new table.
//
// What restore deliberately does NOT do is claim the sessions are still
// there: a restored entry names a session id from a previous run, which may
// or may not exist now. `NotificationsPanel` resolves that at click time
// against the live tabs (jump to the pane if it's live, else select the
// project, else say so) rather than pre-filtering the list — a completed
// task is still worth reading about after the pane that ran it is gone.

export function serializeNotifications(entries: NotificationEntry[]): string {
  return JSON.stringify({ entries: entries.slice(0, MAX_NOTIFICATIONS) });
}

/** Never throws: a corrupt row restores as "no notifications" rather than
 * breaking the app on launch, and one malformed entry costs only itself —
 * same defensive shape as `deserializeLayout`. */
export function deserializeNotifications(raw: string | null | undefined): NotificationEntry[] {
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw) as { entries?: unknown };
    if (!Array.isArray(parsed.entries)) return [];
    return parsed.entries
      .filter((e): e is NotificationEntry => {
        if (!e || typeof e !== "object") return false;
        const entry = e as Partial<NotificationEntry>;
        return (
          typeof entry.id === "string" &&
          typeof entry.sessionId === "string" &&
          typeof entry.project === "string" &&
          typeof entry.projectLabel === "string" &&
          typeof entry.cwd === "string" &&
          typeof entry.engine === "string" &&
          typeof entry.title === "string" &&
          typeof entry.createdAt === "number" &&
          Number.isFinite(entry.createdAt) &&
          typeof entry.status === "string" &&
          NOTIFIABLE.includes(entry.status as SessionStatus)
        );
      })
      .map((e) => ({ ...e, read: e.read === true }))
      .slice(0, MAX_NOTIFICATIONS);
  } catch {
    return [];
  }
}
