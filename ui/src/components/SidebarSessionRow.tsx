// One session in the sidebar (founder brief, 2026-07-26, verbatim):
//
// > "Workspace is the main part: Inside it we have a session that contains
// > multiple terminals. Each session has a name and can be renamed. It
// > starts with session #1"
// > "The menu on the left should not show the amount of tabs and their
// > names. Just the session, so it's cleaner. Session and current github
// > branch. On hover, it shows full details."
//
// So the row is exactly three things: the session's live light, its **name**,
// and the **branch** its root folder is on. The "2 panes · Claude Code,
// Shell" meta line and the nested list of every terminal in the session are
// gone from here — both moved into the hover card, which is the surface that
// asked for detail.
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
import { useCallback, useEffect, useRef, useState } from "react";
import { deriveSessionCard } from "../state/sessionHoverCard";
import { mostSignificantStatus } from "../state/sessionStatus";
import type { SessionGroup } from "../state/sessionGroups";
import { useGitBranch } from "../lib/useGitBranch";
import SessionHoverCard from "./SessionHoverCard";
import SessionStatusLight from "./SessionStatusLight";

/** How long the pointer must rest on a session row before its card appears.
 * Long enough that running the pointer down the sidebar never summons a
 * trail of cards, short enough that deliberately pointing at a session feels
 * answered. Closing is immediate — a card that lingers is in the way.
 * (Inherited unchanged from the pane header this card used to open from.) */
export const SESSION_CARD_DELAY_MS = 320;

interface SidebarSessionRowProps {
  session: SessionGroup;
  projectLabel: string;
  /** Bring this session on screen — `App.tsx` activates one of its
   * terminals, which also selects its workspace. */
  onActivate: () => void;
  /** Commit a new name for the session. Called with the raw draft; the
   * reducer trims it and treats empty as "back to the default name". */
  onRename: (name: string) => void;
}

export default function SidebarSessionRow({
  session,
  projectLabel,
  onActivate,
  onRename,
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
      setCardAnchor(rowRef.current?.getBoundingClientRect() ?? null);
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

  const status = mostSignificantStatus(session.tabs.map((t) => t.status));

  return (
    <li
      ref={rowRef}
      className={`session-row${session.isCurrent ? " is-current" : ""}`}
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
          {/* The session's aggregate light — its most significant terminal's
              state. Keeps its own "on hover, it explains" tooltip (Bruno's
              words), which is why the light carries the sentence rather than
              the row. */}
          <SessionStatusLight status={status} size={11} />
          <span className="session-row-name" onDoubleClick={startRename} title="Double-click to rename">
            {session.label}
          </span>
          {branch && (
            <span className="session-row-branch" aria-label={`Branch ${branch}`}>
              <span className="session-row-branch-glyph" aria-hidden="true">
                ⑂
              </span>
              {branch}
            </span>
          )}
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
