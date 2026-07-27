// The notifications badge + panel (founder ask, 2026-07-26, verbatim:
// *"notification badge (each agent, terminal, whatever... whenever it
// requires attention or finalizes a run, it should notify there)"*, with the
// rule *"only green, yellow or red generate a notification (in case the user
// is somewhere else (maybe not in that terminal) or in another session or
// even workspace)"*). Structure follows his reference screenshot,
// docs/reference/warp-notifications-panel.png: a title row with a close
// button, a filter chip carrying a count, then rows of
// [agent mark] [branch] [title] [what happened] [when].
//
// Everything about *whether* something becomes a notification lives in
// `state/notifications.ts` (and, for the rule itself, in Rust — see that
// module's doc). This file only renders, and owns three interaction
// decisions:
//
// 1. **Opening marks everything read.** The badge counts what happened
//    while you were away; having looked at the list, you're no longer away.
//    Rows stay in the list afterwards — read is not the same as gone.
// 2. **A row is a jump, not a card.** Clicking navigates to that session
//    (select its project, focus its pane) — the whole point of the feature.
//    A row whose session no longer exists still selects its project when
//    that project is still there, and otherwise says so rather than
//    pretending to navigate.
// 3. **The mark is the session's own light.** `SessionStatusLight` renders
//    the status the notification is *about*, frozen at the moment it fired —
//    the same glyph the pane header shows, so the two read as the same
//    system rather than two vocabularies for one event.
import { useEffect, useMemo, useRef, useState } from "react";
import {
  approveKeystroke,
  filterChipLabel,
  filterNotifications,
  groupNotifications,
  notificationSubtitle,
  relativeTime,
  type NotificationEntry,
  type NotificationFilter,
} from "../state/notifications";
import { useGitBranch } from "../lib/useGitBranch";
import { ENGINE_COLOR, ENGINE_TAG } from "../theme";
import type { Engine } from "../state/sessions";
import SessionStatusLight from "./SessionStatusLight";
import Icon from "./Icon";

/** Relative timestamps go stale while the panel sits open; re-render them
 * on a coarse tick rather than per second — the strings themselves are
 * coarse ("45m ago"), so anything finer would just churn. */
const CLOCK_TICK_MS = 30_000;

interface NotificationsPanelProps {
  entries: NotificationEntry[];
  /** Session ids that are live right now — decides whether a row can jump
   * to its pane or only back to its project. */
  liveSessionIds: string[];
  /** Projects that still exist, for the same reason. */
  knownProjectIds: string[];
  selectedProjectId: string | null;
  selectedProjectLabel: string | null;
  /** Marks everything read — fired the moment the panel opens. */
  onOpened: () => void;
  /** Navigate to this notification's session/project. */
  onSelect: (entry: NotificationEntry) => void;
  onDismiss: (id: string) => void;
  onClearAll: () => void;
  /** Session ids whose **current** status is `awaiting_approval` — decides
   * which rows are actionable right now, independent of what status they
   * froze at notification time (see `isActionable`). */
  awaitingSessionIds: string[];
  /** Answer this notification's pending approval prompt. */
  onApprove: (entry: NotificationEntry) => void;
  /** Injectable clock, for tests; live otherwise. */
  now?: number;
}

/** Small inbox/tray glyph, matching the reference's badge. Inline SVG for
 * the same reason every other glyph in this app is: no asset pipeline, and
 * `currentColor` follows the trigger's own state. */
function InboxGlyph() {
  return (
    <svg width="15" height="15" viewBox="0 0 16 16" fill="none" aria-hidden="true">
      <path
        d="M2 9.2 3.6 3.3A1.4 1.4 0 0 1 5 2.3h6a1.4 1.4 0 0 1 1.4 1L14 9.2v2.4a1.4 1.4 0 0 1-1.4 1.4H3.4A1.4 1.4 0 0 1 2 11.6V9.2Z"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinejoin="round"
      />
      <path d="M2 9.2h3.1l.9 1.6h4l.9-1.6H14" stroke="currentColor" strokeWidth="1.2" strokeLinejoin="round" />
    </svg>
  );
}

function NotificationRow({
  entry,
  now,
  actionable,
  canJump,
  onSelect,
  onApprove,
  onDismiss,
}: {
  entry: NotificationEntry;
  now: number;
  actionable: boolean;
  canJump: boolean;
  onSelect: () => void;
  onApprove: () => void;
  onDismiss: () => void;
}) {
  // Per-row so each notification shows the branch of the folder its session
  // ran in — the same `useGitBranch` the pane header uses, one call per
  // visible row, only while the panel is open.
  const branch = useGitBranch(entry.cwd);

  // Named explicitly rather than left to the row's own text: read aloud,
  // "wire session restore main Just now Task completed." is a pile of
  // fragments; this says what the control does and where it goes, which is
  // what a name is for.
  const rowLabel = canJump
    ? `Go to ${entry.title} in ${entry.projectLabel} — ${notificationSubtitle(entry.status)}`
    : `${entry.title} in ${entry.projectLabel} — session closed`;
  const rowTitle = canJump ? `Go to ${entry.title} in ${entry.projectLabel}` : `${entry.projectLabel} — session closed`;

  return (
    <li
      className={`notification-row${canJump ? "" : " is-stale"}${entry.read ? "" : " is-unread"}${actionable ? " is-actionable" : ""}`}
    >
      <div
        role="button"
        tabIndex={0}
        className="notification-row-main"
        onClick={onSelect}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            onSelect();
          }
        }}
        aria-label={rowLabel}
        title={rowTitle}
      >
        <span className="notification-row-mark">
          <SessionStatusLight status={entry.status} size={17} decorative />
        </span>
        <span className="notification-row-body">
          <span className="notification-row-meta">
            <span className="notification-row-branch">
              {branch ? (
                <>
                  <Icon name="branch" size={13} /> {branch}
                </>
              ) : (
                entry.projectLabel
              )}
            </span>
            <span className="notification-row-time">{relativeTime(entry.createdAt, now)}</span>
          </span>
          <span className="notification-row-title">
            {entry.title}
            <span className="notification-row-engine" style={{ color: ENGINE_COLOR[entry.engine as Engine] }}>
              {ENGINE_TAG[entry.engine as Engine] ?? entry.engine.toUpperCase()}
            </span>
          </span>
          <span className="notification-row-subtitle">{notificationSubtitle(entry.status)}</span>
          {actionable && (
            <span className="notification-row-actions">
              {approveKeystroke(entry.engine) !== null && (
                <button
                  type="button"
                  className="notification-approve"
                  onClick={(e) => {
                    e.stopPropagation();
                    onApprove();
                  }}
                  aria-label={`Approve ${entry.title} in ${entry.projectLabel}`}
                >
                  Approve
                </button>
              )}
              <button
                type="button"
                className="notification-open-pane"
                onClick={(e) => {
                  e.stopPropagation();
                  onSelect();
                }}
              >
                Open pane
              </button>
            </span>
          )}
        </span>
      </div>
      <button
        type="button"
        className="notification-row-dismiss"
        onClick={onDismiss}
        aria-label={`Dismiss notification from ${entry.title}`}
        title="Dismiss"
      >
        &#215;
      </button>
    </li>
  );
}

/** One banded section of the list, rendered only when it has rows — kept as
 * a small local component so the three bands (NEEDS YOU / EARLIER TODAY /
 * OLDER) stay flat markup rather than a nested conditional per band. */
function Band({
  label,
  items,
  clock,
  live,
  projects,
  onSelect,
  onApprove,
  onDismiss,
  setOpen,
}: {
  label: string;
  items: NotificationEntry[];
  clock: number;
  live: Set<string>;
  projects: Set<string>;
  onSelect: (entry: NotificationEntry) => void;
  onApprove: (entry: NotificationEntry) => void;
  onDismiss: (id: string) => void;
  setOpen: (open: boolean) => void;
}) {
  if (items.length === 0) return null;
  return (
    <>
      <h3 className="notifications-band-label">{label}</h3>
      <ul className="notifications-list">
        {items.map((e) => (
          <NotificationRow
            key={e.id}
            entry={e}
            now={clock}
            actionable={label === "NEEDS YOU"}
            canJump={live.has(e.sessionId) || projects.has(e.project)}
            onSelect={() => {
              onSelect(e);
              setOpen(false);
            }}
            onApprove={() => onApprove(e)}
            onDismiss={() => onDismiss(e.id)}
          />
        ))}
      </ul>
    </>
  );
}

export default function NotificationsPanel({
  entries,
  liveSessionIds,
  knownProjectIds,
  selectedProjectId,
  selectedProjectLabel,
  onOpened,
  onSelect,
  onDismiss,
  onClearAll,
  awaitingSessionIds,
  onApprove,
  now,
}: NotificationsPanelProps) {
  const [open, setOpen] = useState(false);
  const [filter, setFilter] = useState<NotificationFilter>("all");
  const [tick, setTick] = useState(() => now ?? Date.now());
  const panelRef = useRef<HTMLDivElement | null>(null);

  const clock = now ?? tick;
  const unread = entries.filter((e) => !e.read).length;
  const live = useMemo(() => new Set(liveSessionIds), [liveSessionIds]);
  const projects = useMemo(() => new Set(knownProjectIds), [knownProjectIds]);
  const awaiting = useMemo(() => new Set(awaitingSessionIds), [awaitingSessionIds]);
  const visible = filterNotifications(entries, filter, selectedProjectId, awaiting);
  const projectCount = filterNotifications(entries, "project", selectedProjectId, awaiting).length;
  const needsYouCount = filterNotifications(entries, "needs_you", null, awaiting).length;
  const groups = groupNotifications(visible, awaiting, clock);

  useEffect(() => {
    if (!open || now !== undefined) return;
    const interval = window.setInterval(() => setTick(Date.now()), CLOCK_TICK_MS);
    return () => window.clearInterval(interval);
  }, [open, now]);

  useEffect(() => {
    if (open) panelRef.current?.focus();
  }, [open]);

  function openPanel() {
    setTick(Date.now());
    setOpen(true);
    onOpened();
  }

  function toggle() {
    if (open) setOpen(false);
    else openPanel();
  }

  return (
    <div className="notifications-anchor">
      <button
        type="button"
        className={`notifications-trigger${unread > 0 ? " has-unread" : ""}`}
        onClick={toggle}
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={
          unread > 0
            ? `Notifications — ${unread} new`
            : entries.length > 0
              ? "Notifications"
              : "Notifications — nothing new"
        }
        title="Notifications"
      >
        <InboxGlyph />
        {unread > 0 && (
          <span className="notifications-badge" aria-hidden="true">
            {unread > 9 ? "9+" : unread}
          </span>
        )}
      </button>

      {open && (
        <>
          <div className="notifications-backdrop" onMouseDown={() => setOpen(false)} />
          <div
            ref={panelRef}
            className="notifications-panel"
            role="dialog"
            aria-label="Notifications"
            tabIndex={-1}
            onMouseDown={(e) => e.stopPropagation()}
            onKeyDown={(e) => {
              if (e.key === "Escape") {
                e.preventDefault();
                setOpen(false);
              }
            }}
          >
            <div className="notifications-header">
              <h2 className="notifications-title">Notifications</h2>
              <button
                className="notifications-close"
                onClick={() => setOpen(false)}
                aria-label="Close notifications"
              >
                &#215;
              </button>
            </div>

            <div className="notifications-filters">
              <button
                type="button"
                className={`notifications-chip${filter === "all" ? " is-active" : ""}`}
                aria-pressed={filter === "all"}
                onClick={() => setFilter("all")}
              >
                {filterChipLabel("all", entries.length, null)}
              </button>
              <button
                type="button"
                className={`notifications-chip${filter === "project" ? " is-active" : ""}`}
                aria-pressed={filter === "project"}
                disabled={selectedProjectId === null}
                onClick={() => setFilter("project")}
              >
                {filterChipLabel("project", projectCount, selectedProjectLabel)}
              </button>
              <button
                type="button"
                className={`notifications-chip${filter === "needs_you" ? " is-active" : ""}`}
                aria-pressed={filter === "needs_you"}
                onClick={() => setFilter("needs_you")}
              >
                {filterChipLabel("needs_you", needsYouCount, null)}
              </button>
              {entries.length > 0 && (
                <button type="button" className="notifications-clear" onClick={onClearAll}>
                  Clear all
                </button>
              )}
            </div>

            {visible.length === 0 ? (
              <p className="notifications-empty">
                {entries.length === 0
                  ? "Nothing yet. Sessions tell you here when they finish, need approval, or fail."
                  : "Nothing from this project."}
              </p>
            ) : (
              <>
                <Band
                  label="NEEDS YOU"
                  items={groups.needsYou}
                  clock={clock}
                  live={live}
                  projects={projects}
                  onSelect={onSelect}
                  onApprove={onApprove}
                  onDismiss={onDismiss}
                  setOpen={setOpen}
                />
                <Band
                  label="EARLIER TODAY"
                  items={groups.earlierToday}
                  clock={clock}
                  live={live}
                  projects={projects}
                  onSelect={onSelect}
                  onApprove={onApprove}
                  onDismiss={onDismiss}
                  setOpen={setOpen}
                />
                <Band
                  label="OLDER"
                  items={groups.older}
                  clock={clock}
                  live={live}
                  projects={projects}
                  onSelect={onSelect}
                  onApprove={onApprove}
                  onDismiss={onDismiss}
                  setOpen={setOpen}
                />
              </>
            )}
          </div>
        </>
      )}
    </div>
  );
}
