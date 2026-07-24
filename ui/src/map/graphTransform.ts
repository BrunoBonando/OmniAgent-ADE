// Pure transforms between `map_graph`'s wire shape (`{nodes:[{id,kind,label,
// project,size}], links:[{src,dst,kind,weight}]}`) and the shape
// react-force-graph-2d wants (`links` keyed `source`/`target`, and node
// objects that the library itself mutates in place with `x`/`y`/`vx`/`vy`
// and, for pinned nodes, `fx`/`fy`). Kept dependency-free (no force-graph
// import) so both directions are testable without a canvas.
import type { MapGraph as WireGraph, MapLink as WireLink, MapNode as WireNode } from "../lib/tauri";

/** A render-time node: the wire fields plus whatever force-graph/d3-force
 * attach at runtime (`x`, `y`, `vx`, `vy`, and — for pinned hubs — `fx`,
 * `fy`). Declared as an intersection with `Record<string, unknown>` rather
 * than enumerating force-graph's internal fields, since this module never
 * reads them — only `RadialLayout.ts` does, through its own narrower
 * `Pinnable` view. */
export type GraphNode = WireNode & Record<string, unknown>;

export interface GraphLink {
  source: string;
  target: string;
  kind: string;
  weight: number;
}

export interface GraphData {
  nodes: GraphNode[];
  links: GraphLink[];
}

/** `MapGraph` (the `map_graph` wire shape) -> force-graph's `graphData`
 * shape. Always returns fresh node objects — callers that need position
 * continuity across repeated fetches (every expand/collapse/filter click
 * re-fetches) should run the result through {@link mergeGraphData}. */
export function transformMapGraph(wire: WireGraph): GraphData {
  return {
    nodes: wire.nodes.map((n): GraphNode => ({ ...n })),
    links: wire.links.map(
      (l: WireLink): GraphLink => ({ source: l.src, target: l.dst, kind: l.kind, weight: l.weight }),
    ),
  };
}

/**
 * Merges a freshly transformed `next` into `prev`, reusing the same node
 * *object* (not just the same data) for every id that survives the update.
 * force-graph/d3-force store each node's live simulation position (`x`,
 * `y`, `vx`, `vy`) and any pin (`fx`, `fy`) directly on that object — handing
 * the library a brand-new object per id on every re-fetch would reset the
 * simulation and make already-settled nodes visibly jump on every
 * expand/collapse/filter click (react-force-graph's own documented pattern
 * for "smooth" dynamic updates is exactly this: mutate/reuse persisting
 * node objects, let genuinely new/removed ids be added/dropped).
 *
 * A node whose id is new gets a fresh object (force-graph will drop it into
 * the simulation, unpositioned, and let the forces settle it). A node whose
 * id disappeared (collapsed away, filtered out) is simply absent from the
 * result — nothing further to do, GC reclaims it once force-graph's own
 * next digest drops its canvas/quadtree references.
 */
export function mergeGraphData(prev: GraphData, next: GraphData): GraphData {
  const prevById = new Map(prev.nodes.map((n) => [n.id, n]));
  const nodes = next.nodes.map((n) => {
    const existing = prevById.get(n.id);
    if (!existing) return n;
    // `n` only ever carries the wire fields (id/kind/label/project/size) —
    // assigning it onto `existing` refreshes those in case the server-side
    // label/size/kind changed, while `existing`'s runtime-only fields
    // (x/y/vx/vy/fx/fy) are untouched because `n` never has those keys.
    Object.assign(existing, n);
    return existing;
  });
  return { nodes, links: next.links };
}
