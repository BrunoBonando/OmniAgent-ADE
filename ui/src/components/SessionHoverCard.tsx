// The per-session hover card (founder ask, 2026-07-26, verbatim: "for each
// session, have a hover with more info, like warp does" — his reference
// screenshot is docs/reference/warp-session-hover-card.png).
//
// Warp's card carries a status badge, the `~`-collapsed working path, the
// branch, the session title, the agent name with its avatar, and a diff
// stat. This one carries the same information in the same reading order,
// with two deliberate differences:
//
// - it opens with the status **explained in a sentence**, which is also
//   Bruno's "on hover, it explains" for the five-state light — one hover
//   surface for the whole pane rather than a tooltip on the light nested
//   inside a card on the header, which would fight each other on the way to
//   the close button;
// - the diff stat is **absent, not invented**. The git review data behind
//   Warp's `+12891` is a later dispatch; `HoverCardModel.diff` is the seam,
//   and the footer already leaves it the room.
//
// Positioned `fixed` from a measured anchor rect rather than absolutely
// inside the header: the header lives inside react-mosaic's toolbar, which
// clips, and every pane is its own stacking context — a fixed layer sidesteps
// both without touching the library's CSS.
//
// Type is split on purpose: machine facts (path, branch, title, engine) in
// the app's mono face, the human sentence in the sans face. It's the same
// split the terminal itself makes — what the computer says vs what we say.
import { ENGINE_COLOR } from "../theme";
import type { HoverCardModel } from "../state/sessionHoverCard";
import SessionStatusLight from "./SessionStatusLight";

/** Kept in sync with `.session-card { width }` in App.css — only used to
 * keep the card from hanging off the right edge of the window. */
export const HOVER_CARD_WIDTH = 300;
const VIEWPORT_MARGIN = 10;
const ANCHOR_GAP = 6;

interface SessionHoverCardProps {
  model: HoverCardModel;
  /** The hovered pane header's rect (`getBoundingClientRect()`), captured
   * when the card opened. */
  anchor: DOMRect | null;
}

export default function SessionHoverCard({ model, anchor }: SessionHoverCardProps) {
  const viewportWidth = typeof window === "undefined" ? HOVER_CARD_WIDTH : window.innerWidth;
  const left = anchor
    ? Math.max(VIEWPORT_MARGIN, Math.min(anchor.left, viewportWidth - HOVER_CARD_WIDTH - VIEWPORT_MARGIN))
    : VIEWPORT_MARGIN;
  const top = anchor ? anchor.bottom + ANCHOR_GAP : VIEWPORT_MARGIN;

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
          {model.title}
          <span className="session-card-project"> · {model.projectLabel}</span>
        </div>
      </div>

      <div className="session-card-foot">
        <span className="session-card-engine">
          <span
            className="session-card-engine-dot"
            style={{ background: ENGINE_COLOR[model.engine] }}
            aria-hidden="true"
          />
          {model.engineLabel}
        </span>
        {/* Warp's `+12891` sits here. Left empty until real git-review data
            exists — see `HoverCardModel.diff`. */}
      </div>
    </div>
  );
}
