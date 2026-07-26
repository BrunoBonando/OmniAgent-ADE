// The session hover card (founder ask, 2026-07-26, verbatim: "for each
// session, have a hover with more info, like warp does" — his reference
// screenshot is docs/reference/warp-session-hover-card.png).
//
// ## It hangs off the sidebar now, not off a terminal
//
// Same day, after seeing it: *"The hover part is currently wrong: it's not on
// the terminal itself, but on session menu on the left. […] On hover, it
// shows full details."* So `SidebarSessionRow` opens it and the pane header
// no longer has one — there is exactly one hover surface for a session, in
// the place the sessions are listed. The pane header kept the one thing that
// is genuinely about a single terminal: its status light, with its own
// explanation on hover.
//
// The contents moved with it, from one pane to the whole session
// (`state/sessionHoverCard.ts`): the session's name, its root folder, its
// branch, how many terminals and which engines are in it, and the one status
// that speaks for all of them.
//
// Warp's card also carries a diff stat; that one is **absent, not invented**
// — the git review data behind its `+12891` is a later dispatch, and
// `SessionCardModel.diff` is the seam.
//
// Positioned `fixed` from a measured anchor rect and placed to the *right* of
// the row: the sidebar is against the left edge of the window, so a card
// dropped below the row would sit on top of the very list the pointer is
// travelling through. High z-index because the sidebar is its own stacking
// context.
//
// Type is split on purpose: machine facts (path, branch, name, engines) in
// the app's mono face, the human sentence in the sans face. It's the same
// split the terminal itself makes — what the computer says vs what we say.
import { ENGINE_COLOR } from "../theme";
import type { SessionCardModel } from "../state/sessionHoverCard";
import SessionStatusLight from "./SessionStatusLight";

/** Kept in sync with `.session-card { width }` in App.css — only used to
 * keep the card from hanging off the right edge of the window. */
export const HOVER_CARD_WIDTH = 300;
/** Ditto for the vertical clamp: the tallest the card gets (status line,
 * sentence, three facts, engine row). Over-estimating only pushes the card
 * up a few pixels; under-estimating would let it run off the bottom. */
const HOVER_CARD_MAX_HEIGHT = 200;
const VIEWPORT_MARGIN = 10;
const ANCHOR_GAP = 8;

interface SessionHoverCardProps {
  model: SessionCardModel;
  /** The hovered session row's rect (`getBoundingClientRect()`), captured
   * when the card opened. */
  anchor: DOMRect | null;
}

export default function SessionHoverCard({ model, anchor }: SessionHoverCardProps) {
  const viewportWidth = typeof window === "undefined" ? HOVER_CARD_WIDTH : window.innerWidth;
  const viewportHeight = typeof window === "undefined" ? HOVER_CARD_MAX_HEIGHT : window.innerHeight;
  const left = anchor
    ? Math.max(
        VIEWPORT_MARGIN,
        Math.min(anchor.right + ANCHOR_GAP, viewportWidth - HOVER_CARD_WIDTH - VIEWPORT_MARGIN),
      )
    : VIEWPORT_MARGIN;
  const top = anchor
    ? Math.max(
        VIEWPORT_MARGIN,
        Math.min(anchor.top, viewportHeight - HOVER_CARD_MAX_HEIGHT - VIEWPORT_MARGIN),
      )
    : VIEWPORT_MARGIN;

  return (
    <div className="session-card" role="tooltip" style={{ left, top }}>
      <div className="session-card-head">
        <span className="session-card-badge" data-status={model.status.key}>
          <SessionStatusLight status={model.status.status} size={13} decorative />
          {model.status.label}
        </span>
        {model.restored && (
          <span className="session-card-chip" title="Reattached to a session that outlived the app closing">
            Restored
          </span>
        )}
      </div>

      <p className="session-card-explain">{model.status.explanation}</p>

      {/* Unlabelled rows, like the reference: a `~/` path, a `⑂` branch and
          a session name each say what they are, and field labels would eat
          the width a long path needs. */}
      <div className="session-card-facts">
        <div className="session-card-path">{model.path}</div>
        {model.branch !== null && (
          <div className="session-card-branch">
            <span aria-hidden="true">⑂</span> {model.branch}
          </div>
        )}
        <div className="session-card-title">
          {model.name}
          <span className="session-card-project"> · {model.projectLabel}</span>
        </div>
      </div>

      <div className="session-card-foot">
        <span className="session-card-terminals">
          {model.terminals} terminal{model.terminals === 1 ? "" : "s"}
        </span>
        <span className="session-card-engines">
          {model.engines.map((e) => (
            <span className="session-card-engine" key={e.engine}>
              <span
                className="session-card-engine-dot"
                style={{ background: ENGINE_COLOR[e.engine] }}
                aria-hidden="true"
              />
              {e.label}
              {e.count > 1 && <span className="session-card-engine-count">×{e.count}</span>}
            </span>
          ))}
        </span>
        {/* Warp's `+12891` sits here. Left empty until real git-review data
            exists — see `SessionCardModel.diff`. */}
      </div>
    </div>
  );
}
