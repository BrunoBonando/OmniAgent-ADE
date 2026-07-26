// The OmniAgent mark, alive, as one session's status light (founder ask,
// 2026-07-26, verbatim: "Can you make the logo of OmniAgent instead of the
// simple dot but in the colors above? This would be amazing!").
//
// ## Why this is a mask and not an <img>
//
// `assets/omniagent-logo.png` is a 1024px RGBA app icon, and its alpha
// channel is the *disc*, not the mark: 68.9% of it is fully opaque (the blue
// circle), 30.8% fully transparent (outside the circle), and the actual
// glyph is painted white-on-blue in the colour channels. Masking on that
// alpha would therefore tint a plain filled circle — i.e. reproduce exactly
// the dot this replaces, with the logo thrown away.
//
// So `assets/omniagent-mark-mask.png` is derived from it: a 256px alpha-only
// mask of the white glyph, cropped to the mark's measured bounding box
// (162,168)-(855,861) with an antialiased ramp instead of a threshold, so
// `mask-size: contain` fills this element with the mark's *exact* silhouette
// and `background` behind it becomes the tint. That is what makes the ring
// shape animatable: a conic sweep rotating behind a ring mask reads as a
// highlight chasing around the ring, which no `<img>` recolouring could do.
//
// ## Structure (three spans, and each one is load-bearing)
//
//   .session-light        filter: drop-shadow  — the glow
//     .session-light-mark  mask-image          — the silhouette
//       .session-light-fill background/anim    — the colour and the motion
//
// The glow has to live OUTSIDE the masked element: CSS applies `filter`
// before masking, so a drop-shadow on the masked span would be computed from
// the unmasked square and then clipped away by the mask itself. Splitting
// them means the glow traces the mark.
//
// The fill is a separate, oversized child (not a background on the masked
// span) so `chase` can rotate it without rotating the mask — the mark must
// stay upright while the highlight travels around it.
//
// All five motions are pure CSS keyframes (App.css). Nothing here drives a
// frame from JS: a busy workspace can have a dozen of these on screen at
// once, and `prefers-reduced-motion` has to be able to switch every one of
// them off at the stylesheet level.
import type { CSSProperties } from "react";
import { statusPresentation, type SessionStatus } from "../state/sessionStatus";

interface SessionStatusLightProps {
  /** `undefined` until this session's first status lands — renders the
   * neutral "Starting" mark, never a guess. */
  status?: SessionStatus;
  /** Rendered size in px (default 15, the pane-header size). */
  size?: number;
  /** Set when the light is decoration beside text that already says the
   * state (the hover card's badge) — drops it out of the accessibility tree
   * instead of reading the same sentence twice. */
  decorative?: boolean;
}

export default function SessionStatusLight({ status, size, decorative }: SessionStatusLightProps) {
  const presentation = statusPresentation(status);
  const style = size === undefined ? undefined : ({ "--light-size": `${size}px` } as CSSProperties);

  return (
    <span
      className="session-light"
      data-status={presentation.key}
      data-motion={presentation.motion}
      style={style}
      role={decorative ? undefined : "img"}
      aria-label={decorative ? undefined : presentation.ariaLabel}
      aria-hidden={decorative ? true : undefined}
      // "on hover, it explains, of course" (Bruno, 2026-07-26) — the light's
      // own affordance, and since 2026-07-26 (later) its ONLY one: the big
      // hover card that used to carry this sentence moved to the sidebar's
      // session row, so a pane header light that explained nothing would
      // have quietly lost a feature. Skipped when decorative, where the
      // label sitting next to it already says the same words.
      title={decorative ? undefined : presentation.ariaLabel}
    >
      <span className="session-light-mark">
        <span className="session-light-fill" />
      </span>
    </span>
  );
}
