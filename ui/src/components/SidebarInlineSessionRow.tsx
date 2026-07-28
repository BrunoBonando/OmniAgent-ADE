// Inline session row used by the simplified Working Sessions list.
// Separate component so each row can own its hover-card timer, git-branch
// hook, and DOM ref — none of which can live in the parent map().
import { useCallback, useEffect, useRef, useState } from "react";
import { type SessionGroup } from "../state/sessionGroups";
import { mostSignificantStatus } from "../state/sessionStatus";
import { deriveSessionCard } from "../state/sessionHoverCard";
import { useGitBranch } from "../lib/useGitBranch";
import SessionStatusLight from "./SessionStatusLight";
import SessionHoverCard from "./SessionHoverCard";
import Icon from "./Icon";

const CARD_DELAY_MS = 320;

/** Measures the anchor rect for the hover card — anchored to the sidebar's
 * right edge (same logic as SidebarSessionRow.measureCardAnchor). */
function measureCardAnchor(row: HTMLElement | null) {
  if (!row) return null;
  const rowRect = row.getBoundingClientRect();
  const panel = row.closest(".sidebar")?.getBoundingClientRect();
  if (!panel) return rowRect;
  return new DOMRect(rowRect.x, rowRect.y, Math.max(0, panel.right - rowRect.x), rowRect.height);
}

interface Props {
  session: SessionGroup;
  projectLabel: string;
  isCurrent: boolean;
  onActivate: () => void;
  onClose?: () => void;
}

export default function SidebarInlineSessionRow({
  session,
  projectLabel,
  isCurrent,
  onActivate,
  onClose,
}: Props) {
  const branch = useGitBranch(session.cwd);
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

  useEffect(() => () => closeCard(), [closeCard]);

  function scheduleCard() {
    if (openTimer.current !== null) return;
    openTimer.current = window.setTimeout(() => {
      openTimer.current = null;
      setCardAnchor(measureCardAnchor(rowRef.current));
    }, CARD_DELAY_MS);
  }

  const sessionStatus = mostSignificantStatus(session.tabs.map((t) => t.status));
  const cardModel = deriveSessionCard({ session, projectLabel, branch });

  return (
    <li
      ref={rowRef}
      className={`sidebar-inline-session-row${isCurrent ? " is-current" : ""}`}
      onMouseEnter={scheduleCard}
      onMouseLeave={closeCard}
    >
      <div className="sidebar-inline-session-icon">
        <SessionStatusLight status={sessionStatus} size={14} decorative />
      </div>
      <button
        className="sidebar-inline-session-name-btn"
        onClick={onActivate}
        aria-label={session.label}
        title={session.label}
      >
        {session.label}
      </button>
      {onClose && (
        <button
          className="sidebar-inline-session-close-btn"
          aria-label={`Close session ${session.label}`}
          title="Close session"
          onClick={(e) => {
            e.stopPropagation();
            closeCard();
            onClose();
          }}
        >
          <Icon name="x" size={11} />
        </button>
      )}
      {cardAnchor !== null && (
        <SessionHoverCard model={cardModel} anchor={cardAnchor} />
      )}
    </li>
  );
}
