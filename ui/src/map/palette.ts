// Node-kind -> color (Task 6.2: "a legend — kind -> color mapping,
// consistent with whatever palette you choose — dataviz-aware, accessible,
// not just random colors"). Built per the `dataviz` skill's method rather
// than eyeballed:
//
// - The 8 `NodeKind` wire-strings are a nominal categorical (kind is
//   identity, not rank) — so this uses the skill's 8-hue fixed-order
//   categorical palette (dark-mode steps, since this app is dark-only —
//   `color-scheme: dark` in App.css, no light variant), assigned in the
//   documented fixed order (never cycled/reassigned per-render).
// - VALIDATED: `node scripts/validate_palette.js
//   "#3987e5,#d95926,#199e70,#c98500,#d55181,#008300,#9085e9,#e66767"
//   --mode dark --surface "#0a0d12"` (this app's own `--void` HUD
//   background, darker than the skill's reference dark surface) — all 6
//   checks PASS on the *adjacent* pairlist (worst CVD ΔE 8.4, worst
//   normal-vision ΔE 19.3, all >=3:1 contrast).
// - The brain map is closer to a scatter/bubble chart than a bar/line chart
//   (any two node kinds can end up neighbors in the force layout, not just
//   adjacent slots) — under the stricter `--pairs all` check the full 8
//   does NOT clear the floor (no 8-hue ordering can, per the skill's own
//   documented palette notes: only the first 3 slots validate all-pairs).
//   Rather than dropping to 3 visible kinds (identity genuinely matters for
//   all 8 here — hiding "session" vs "decision" behind an "Other" bucket
//   would make the map less useful, not more), this ships the secondary
//   encoding the skill requires for that case: hub kinds (`project`,
//   `community`) render as a distinct ringed glyph, not just a filled dot
//   (see `BrainMap.tsx`'s `paintNode`), the Lens panel is an always-visible
//   legend (kind -> swatch, name never color-alone), and every node has a
//   hover label (kind + label) as the "readable another way" relief valve
//   for the near-collision pairs (magenta/doc vs aqua/file; red/session vs
//   orange/community).
import type { NodeKindWire } from "./graphState";

export const KIND_COLOR: Record<NodeKindWire, string> = {
  project: "#3987e5", // blue   — slot 1: root/category tier, ring-pinned
  community: "#d95926", // orange — slot 2: collapsed hub (echoes the g-brain reference's own orange core)
  file: "#199e70", // aqua   — slot 3
  code_entity: "#c98500", // yellow — slot 4
  doc: "#d55181", // magenta— slot 5
  memory: "#008300", // green  — slot 6
  decision: "#9085e9", // violet — slot 7
  session: "#e66767", // red    — slot 8
};

/** Hub kinds get the ringed/glow glyph treatment in `BrainMap.tsx` — both
 * the LOD model's structural hubs (a project owns everything under it, a
 * collapsed community stands in for its members) and the two kinds most at
 * CVD-collision risk once shape is the only thing telling them apart from
 * their nearest categorical neighbor at a glance. */
export const HUB_KINDS: ReadonlySet<NodeKindWire> = new Set(["project", "community"]);

export const KIND_LABEL: Record<NodeKindWire, string> = {
  project: "Project",
  file: "File",
  code_entity: "Code entity",
  doc: "Doc",
  memory: "Memory",
  decision: "Decision",
  session: "Session",
  community: "Community",
};

const FALLBACK_COLOR = "#66748a"; // --ink-dim — an unrecognized kind reads as neutral, not invisible

export function colorForKind(kind: string): string {
  return (KIND_COLOR as Record<string, string>)[kind] ?? FALLBACK_COLOR;
}

export function labelForKind(kind: string): string {
  return (KIND_LABEL as Record<string, string>)[kind] ?? kind;
}

export function isHubKind(kind: string): boolean {
  return HUB_KINDS.has(kind as NodeKindWire);
}
