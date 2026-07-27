// One session in the sidebar (founder brief, 2026-07-26, verbatim):
//
// > "Workspace is the main part: Inside it we have a session that contains
// > multiple terminals. Each session has a name and can be renamed. It
// > starts with session #1"
// > "The menu on the left should not show the amount of tabs and their
// > names. Just the session, so it's cleaner. Session and current github
// > branch. On hover, it shows full details."
//
// So the row is the session's **name**, the **branch** its root folder is on,
// and nothing else. The
// "2 panes · Claude Code, Shell" meta line and the nested list of every
// terminal in the session are still gone from here — both moved into the
// hover card, which is the surface that asked for detail.
//
// Its own component (rather than more JSX inside `Sidebar.tsx`) for one
// concrete reason: the branch comes from `useGitBranch`, a hook, and a
// sidebar with N sessions needs N of them. Everything else follows from
// living here — the rename edit state and the hover-card timer are per-row
// too.
//
// **Which path the branch reflects:** the session's own root
// (`SessionGroup.cwd`, the cwd its first terminal was created in — see that
// field's doc). A session is created with one cwd (the project folder or a
// validated subfolder), so its terminals normally agree; when they drift, the
// row answers for the session, not for whichever terminal happens to be
// focused.
//
// The row also gained a left accent bar and an expand/collapse chevron for
// the session that's on screen, since the redesign now lets a session's
// terminals be listed and reached inline (Task 5) instead of only through the
// hover card.
import { useCallback, useEffect, useRef, useState, type CSSProperties } from "react";
import { deriveSessionCard } from "../state/sessionHoverCard";
import { type SessionGroup } from "../state/sessionGroups";
import { useGitBranch } from "../lib/useGitBranch";
import { MAX_PANES } from "../state/paneGrid";
import SessionHoverCard from "./SessionHoverCard";
import { SidebarTerminalRow } from "./SidebarTerminalRow";
import Icon from "./Icon";

/** How long the pointer must rest on a session row before its card appears.
 * Long enough that running the pointer down the sidebar never summons a
 * trail of cards, short enough that deliberately pointing at a session feels
 * answered. Closing is immediate — a card that lingers is in the way.
 * (Inherited unchanged from the pane header this card used to open from.) */
export const SESSION_CARD_DELAY_MS = 320;

/**
 * The rect the card is placed from: this row's vertical position, but the
 * **sidebar's** right edge.
 *
 * A session row is inset from the panel it lives in (the workspace chip's
 * padding, the session list's own indent), so a card placed a gap to the
 * right of the *row* lands a few pixels on top of the sidebar — verified in
 * a real browser: 237px against a 240px panel. Anchoring to the panel edge
 * means the card always clears the sidebar, whatever a row's indent is.
 * Falls back to the row itself if the panel can't be found.
 */
function measureCardAnchor(row: HTMLElement | null): DOMRect | null {
  if (!row) return null;
  const rowRect = row.getBoundingClientRect();
  const panel = row.closest(".sidebar")?.getBoundingClientRect();
  if (!panel) return rowRect;
  return new DOMRect(rowRect.x, rowRect.y, Math.max(0, panel.right - rowRect.x), rowRect.height);
}

interface SidebarSessionRowProps {
  session: SessionGroup;
  projectLabel: string;
  /** Whether this is the session **on screen** in the pane grid — the accent
   * rail.
   *
   * Passed in rather than read off `session.isCurrent` (which only knows
   * about the focused pane) because since 2026-07-26 the grid shows exactly
   * one session, and which one is a slightly richer question: selecting a
   * workspace in the sidebar does not move focus, so a project whose panes
   * nobody is focused on still has a session on screen. `Sidebar` answers
   * with `visibleSessionGroupId` — the same function `Workspace.tsx` uses to
   * decide what to paint — so the rail and the grid cannot disagree. */
  isCurrent: boolean;
  /** This session's own colour, for its rail. Computed by `Sidebar` (same
   * hash/palette the workspace avatars use) rather than here, so both
   * columns of the sidebar cycle one palette and this file doesn't need a
   * second copy of the hash. */
  tint: string;
  /** Whether the terminal list under this row is open — either the user
   * toggled it open, or (`Sidebar`'s default) it's the session the founder
   * brief's mock always shows expanded. Renders one `SidebarTerminalRow` per
   * `session.tabs` entry, plus the "New terminal" row (Task 5). */
  expanded: boolean;
  /** The pane currently focused, app-wide — each `SidebarTerminalRow` below
   * compares its own tab id against this to mark itself active. */
  activeTabId: string | null;
  /** Bring this session on screen — `App.tsx` activates one of its
   * terminals, which also selects its workspace. */
  onActivate: () => void;
  /** Toggles `expanded` for this session — the chevron's own click, kept
   * from bubbling into `onActivate` so opening/closing the terminal list
   * never also switches the grid to this session. */
  onToggleExpanded: () => void;
  /** Activates one specific terminal — each `SidebarTerminalRow` calls this
   * with its own tab id. The same function `Sidebar` already has as
   * `onActivateTab` (there is only ever one "activate this pane" function in
   * the app), passed straight through. */
  onActivateTab: (tabId: string) => void;
  /** Commit a new name for the session. Called with the raw draft; the
   * reducer trims it and treats empty as "back to the default name". */
  onRename: (name: string) => void;
  /** The hover-revealed session close (founder ask: "I must be able to
   * close a session") — `Sidebar` confirms before anything is killed.
   * Absent = no close control, same convention as `onCloseWorkspace`. */
  onClose?: () => void;
  /** Renders as the "New terminal" row inside the expanded children, when
   * this is the current session and it hasn't hit `MAX_PANES` (Task 5).
   * Absent = no control shown, same convention as `onClose`. */
  onOpenNewTerminal?: () => void;
}

export default function SidebarSessionRow({
  session,
  projectLabel,
  isCurrent,
  tint,
  expanded,
  activeTabId,
  onActivate,
  onToggleExpanded,
  onActivateTab,
  onRename,
  onClose,
  onOpenNewTerminal,
}: SidebarSessionRowProps) {
  const branch = useGitBranch(session.cwd);
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState("");

  // `cardAnchor` doubles as "is the card open": it holds the row rect
  // measured at open time, which the fixed-position card is placed from.
  const rowRef = useRef<HTMLLIElement>(null);
  const [cardAnchor, setCardAnchor] = useState<DOMRect | null>(null);
  const openTimer = useRef<number | null>(null);

  const closeCard = useCallback(() => {
    if (openTimer.current !== null) {
      window.clearTimeout(openTimer.current);
      openTimer.current = null;
    }
    setCardAnchor(null);
  }, []);

  // Clears a pending open timer if the session goes away mid-hover, so a
  // card never appears for a session that no longer exists.
  useEffect(() => () => closeCard(), [closeCard]);

  function scheduleCard() {
    if (openTimer.current !== null) return;
    openTimer.current = window.setTimeout(() => {
      openTimer.current = null;
      setCardAnchor(measureCardAnchor(rowRef.current));
    }, SESSION_CARD_DELAY_MS);
  }

  function startRename() {
    closeCard();
    setDraft(session.label);
    setRenaming(true);
  }

  function commitRename() {
    setRenaming(false);
    if (draft.trim() !== session.label) onRename(draft);
  }

  return (
    <li
      ref={rowRef}
      className={`session-row${isCurrent ? " is-current" : ""}`}
      style={{ "--session-tint": tint } as CSSProperties}
      onMouseEnter={scheduleCard}
      onMouseLeave={closeCard}
    >
      {/* The chevron and whichever of `.session-row-main`/the rename input is
          showing share one flex row (fix-round, 2026-07-27): `.session-row`
          itself is plain block layout, so without this wrapper the chevron
          — a block-level button — started its own line above the row
          instead of sitting beside the name. */}
      <div className="session-row-body">
        <button
          type="button"
          className={`session-row-chevron${expanded ? " is-expanded" : ""}`}
          aria-label={expanded ? "Collapse session" : "Expand session"}
          onClick={(e) => {
            e.stopPropagation();
            onToggleExpanded();
          }}
        >
          ›
        </button>
        {renaming ? (
          <input
            className="session-row-rename-input"
            value={draft}
            autoFocus
            aria-label={`Rename ${session.label}`}
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commitRename}
            onKeyDown={(e) => {
              e.stopPropagation();
              if (e.key === "Enter") {
                e.preventDefault();
                commitRename();
              } else if (e.key === "Escape") {
                e.preventDefault();
                setRenaming(false);
              }
            }}
          />
        ) : (
          <button
            className="session-row-main"
            onClick={onActivate}
            // Explicit, so the button's accessible name is the same short
            // phrase shown visually: the session name + branch (when present).
            aria-label={branch ? `${session.label} Branch ${branch}` : session.label}
          >
            <span className="session-row-top">
              <span className="session-row-name" onDoubleClick={startRename} title="Double-click to rename">
                {session.label}
              </span>
              {branch && (
                <span className="session-row-branch" aria-label={`Branch ${branch}`}>
                  <Icon name="branch" size={11} className="session-row-branch-glyph" />
                  {/* Its own element so a long branch ellipsizes: an anonymous
                      text node inside a flex container can't take
                      `text-overflow`, and `feature/sidebar-sessions` was being
                      cut mid-word against the panel edge. */}
                  <span className="session-row-branch-name">{branch}</span>
                </span>
              )}
            </span>
          </button>
        )}
      </div>
      {/* A sibling of `.session-row-body`, not a child of `.session-row-main`
          — a button can't nest inside a button — revealed on the row's
          hover like the workspace row's own close. */}
      {onClose && !renaming && (
        <button
          className="session-row-close"
          onClick={(e) => {
            e.stopPropagation();
            closeCard();
            onClose();
          }}
          aria-label={`Close session ${session.label}`}
          title="Close session"
        >
          <Icon name="x" size={12} />
        </button>
      )}
      {cardAnchor !== null && !renaming && (
        <SessionHoverCard
          model={deriveSessionCard({ session, projectLabel, branch })}
          anchor={cardAnchor}
        />
      )}
      {expanded && (
        <div className="session-row-children">
          {session.tabs.map((t) => (
            <SidebarTerminalRow
              key={t.id}
              tab={t}
              isActive={t.id === activeTabId}
              onActivate={() => onActivateTab(t.id)}
            />
          ))}
          {/* Spawning only ever happens into the session on screen — a
              background session's expanded list is browsable (click a
              terminal to bring it forward) but isn't where ⌘T lands.
              `onOpenNewTerminal` is absent for the same reason `onClose`
              can be: no handler wired, no control shown. `MAX_PANES` mirrors
              the cap `App.tsx`'s own spawn path already enforces, so this
              row never promises a terminal the grid would refuse. */}
          {isCurrent && onOpenNewTerminal && session.tabs.length < MAX_PANES && (
            <button
              type="button"
              className="terminal-row-new"
              onClick={onOpenNewTerminal}
              aria-label="New terminal"
              title="New terminal (⌘T)"
            >
              <Icon name="plus" size={13} />
              <span className="terminal-row-new-label" aria-hidden>
                New terminal
              </span>
              <span className="terminal-row-new-key" aria-hidden>
                ⌘T
              </span>
            </button>
          )}
        </div>
      )}
    </li>
  );
}
