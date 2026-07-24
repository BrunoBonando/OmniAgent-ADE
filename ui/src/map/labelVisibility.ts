// Label-visibility decision (post-ship founder feedback, Bruno 2026-07-24:
// "extremely smooth, without the text, only show texts if you zoom enough
// for specific ones, or when you hover... Check how Obsidian and g-brain do
// it"). The two gbrain reference screenshots (docs/reference/) confirm the
// idiom: individual nodes render as bare, unlabeled dots inside the ring;
// only the category/hub nodes carry an always-visible label.
//
// Extracted as a pure, canvas-free function — same split as
// `RadialLayout.ts`/`graphTransform.ts` — so the decision is unit-testable
// without a canvas. `BrainMap.tsx`'s `nodeCanvasObject` renderer calls this
// once per node per frame and only pays for the (comparatively expensive)
// `ctx.fillText` when it returns `true`.
import { isHubKind } from "./palette";

/** Above this camera zoom (`globalScale`, as passed to
 * react-force-graph-2d's `nodeCanvasObject(node, ctx, globalScale)` — 1 =
 * fit-to-view, higher = zoomed in), an individual leaf node's label is
 * legible and the user has intentionally zoomed in close enough to want
 * it. Unchanged from the pre-existing inline threshold this replaces. */
export const LEAF_LABEL_ZOOM_THRESHOLD = 2.2;

export interface LabelVisibilityInput {
  /** The node's `NodeKind` wire string (`"project"`, `"file"`, …). */
  kind: string;
  /** `globalScale` as passed to `nodeCanvasObject`. */
  globalScale: number;
  /** Whether this specific node is the currently-hovered node. */
  isHovered: boolean;
}

/**
 * Decides whether the canvas renderer should draw a text label for a node.
 * The node's dot/glyph is always drawn regardless of this result — only the
 * `ctx.fillText` call is gated.
 *
 * - Hub kinds (`project`, `community` — `palette.ts`'s `HUB_KINDS`, the
 *   map's landmark/category tier) always show their label, at any zoom —
 *   g-brain's "always-labeled ring hubs".
 * - Every other node's label only shows once zoomed in past
 *   {@link LEAF_LABEL_ZOOM_THRESHOLD}, OR while it's the hovered node.
 *
 * This is the "bare dot until you zoom in or point at it" idiom (Obsidian,
 * g-brain) instead of labeling every node on every frame.
 */
export function shouldShowNodeLabel({ kind, globalScale, isHovered }: LabelVisibilityInput): boolean {
  if (isHovered) return true;
  if (isHubKind(kind)) return true;
  return globalScale > LEAF_LABEL_ZOOM_THRESHOLD;
}
