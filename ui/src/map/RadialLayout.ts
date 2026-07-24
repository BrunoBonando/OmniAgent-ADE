// Radial layout math (Task 6.2): "project hubs pinned on a ring via fx/fy
// from polar coordinates, force sim inside" (PLAN.md). Pure trig, zero
// force-graph/React imports, so it's directly unit-testable without a
// canvas — see RadialLayout.test.ts.
//
// What counts as a "hub" here: `NodeKind::Project` nodes are OmniAgent's
// top-level category tier (the g-brain reference's "Sales/Finances/Tech/…"
// pillars) — the highest-level structural grouping the brain has. Everything
// else (community hubs, and real entities once a community is expanded)
// free-floats under the normal force simulation inside the ring.

export interface RadialPoint {
  id: string;
  x: number;
  y: number;
}

/**
 * Evenly spaces `hubIds.length` points around a circle of `radius` centered
 * at `(centerX, centerY)`, starting at 12 o'clock (matches the g-brain
 * reference's ring orientation) and proceeding clockwise. `hubIds.length ===
 * 0` returns `[]`; a single hub lands at the top rather than the center —
 * "one hub" is still "evenly spaced," trivially.
 */
export function computeRadialHubPositions(
  hubIds: readonly string[],
  radius: number,
  centerX = 0,
  centerY = 0,
): RadialPoint[] {
  const n = hubIds.length;
  if (n === 0) return [];
  return hubIds.map((id, i) => {
    const angle = (2 * Math.PI * i) / n - Math.PI / 2; // -90deg = 12 o'clock
    return {
      id,
      x: centerX + radius * Math.cos(angle),
      y: centerY + radius * Math.sin(angle),
    };
  });
}

/** Node shape this module reads/writes — deliberately minimal (just what
 * force-graph's pinning convention needs) rather than importing the full
 * render-time GraphNode type, so this stays a leaf module other map/*
 * files can depend on without a cycle. */
export interface Pinnable {
  id: string;
  fx?: number | null;
  fy?: number | null;
}

/**
 * Pins every node whose id is in `hubIds` to its ring position (mutates
 * `fx`/`fy` in place — these are force-graph/d3-force's own pinning
 * convention, read directly off the node object every simulation tick, so
 * mutation here IS the API, not a shortcut around it). Every other node's
 * `fx`/`fy` are cleared (set to `null`, d3-force's "unpin" signal) so a node
 * that was a hub before an expand/collapse and isn't anymore rejoins the
 * free simulation instead of staying stuck.
 */
export function applyRadialPositions<T extends Pinnable>(
  nodes: readonly T[],
  hubIds: readonly string[],
  radius: number,
  centerX = 0,
  centerY = 0,
): void {
  const positions = new Map(
    computeRadialHubPositions(hubIds, radius, centerX, centerY).map((p) => [p.id, p]),
  );
  for (const node of nodes) {
    const pos = positions.get(node.id);
    if (pos) {
      node.fx = pos.x;
      node.fy = pos.y;
    } else {
      node.fx = null;
      node.fy = null;
    }
  }
}

/** Clears every node's pin (used when leaving Radial layout, so Hierarchy's
 * dagMode isn't fighting leftover fx/fy from the ring). */
export function clearPins<T extends Pinnable>(nodes: readonly T[]): void {
  for (const node of nodes) {
    node.fx = null;
    node.fy = null;
  }
}
