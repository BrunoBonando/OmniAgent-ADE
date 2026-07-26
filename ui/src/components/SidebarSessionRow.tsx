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
// and — under both, since 2026-07-26 — a **mini map of its panes**: one
// OmniAgent mark per terminal, in the same approved grid shape the real pane
// grid uses, each tinted and animated by that terminal's own live status.
// The "2 panes · Claude Code, Shell" meta line and the nested list of every
// terminal in the session are still gone from here — both moved into the
// hover card, which is the surface that asked for detail. The mini map is
// not that list coming back: it is a picture of the layout with no names in
// it, which is the one thing the hover card can't answer at a glance.
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
import { useCallback, useEffect, useRef, useState, type CSSProperties } from "react";
import { deriveSessionCard } from "../state/sessionHoverCard";
import type { SessionGroup } from "../state/sessionGroups";
import { gridShape } from "../state/paneGrid";
import { useGitBranch } from "../lib/useGitBranch";
import SessionHoverCard from "./SessionHoverCard";
import SessionStatusLight from "./SessionStatusLight";
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
  /** Bring this session on screen — `App.tsx` activates one of its
   * terminals, which also selects its workspace. */
  onActivate: () => void;
  /** Commit a new name for the session. Called with the raw draft; the
   * reducer trims it and treats empty as "back to the default name". */
  onRename: (name: string) => void;
  /** The hover-revealed session close (founder ask: "I must be able to
   * close a session") — `Sidebar` confirms before anything is killed.
   * Absent = no close control, same convention as `onCloseWorkspace`. */
  onClose?: () => void;
}

export default function SidebarSessionRow({
  session,
  projectLabel,
  isCurrent,
  tint,
  onActivate,
  onRename,
  onClose,
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

  // The row's mini pane-map (founder ask, 2026-07-26): one OmniAgent mark
  // per terminal, "in their order in the layout and their current status,
  // with the same effect, meaning it also stays in 1, 1x2, 2x2, 2x3, 2x4
  // layout". So the shape comes from `gridShape` — the SAME function the
  // real grid derives its arrangement from — and the leftover cells are
  // drawn as holes exactly like `buildGrid` pads them, which is what keeps
  // this a map of the layout rather than a row of dots that happens to have
  // the right count. It also replaces the row's single aggregate light:
  // eight marks that each say their own state say strictly more than one
  // that says the most significant of them.
  const shape = gridShape(session.tabs.length);

  return (
    <li
      ref={rowRef}
      className={`session-row${isCurrent ? " is-current" : ""}`}
      style={{ "--session-tint": tint } as CSSProperties}
      onMouseEnter={scheduleCard}
      onMouseLeave={closeCard}
    >
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
        <button className="session-row-main" onClick={onActivate}>
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
          <span
            className="session-row-panes"
            style={{ "--pane-cols": shape.cols } as CSSProperties}
          >
            {Array.from({ length: shape.cols * shape.rows }, (_, i) => {
              const pane = session.tabs[i];
              return pane ? (
                <SessionStatusLight key={pane.id} status={pane.status} size={13} />
              ) : (
                <span key={`hole-${i}`} className="session-row-pane-hole" aria-hidden="true" />
              );
            })}
          </span>
        </button>
      )}
      {/* A sibling of `.session-row-main`, not a child — a button can't nest
          inside a button — revealed on the row's hover like the workspace
          row's own close. */}
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
    </li>
  );
}
