// Hierarchy layout (Task 6.2): "roots -> projects -> communities ->
// entities" via the underlying library's DAG mode (`dagMode: 'radialout'`
// on react-force-graph-2d). react-force-graph derives node depth from
// *whatever links it's given* — passing the full, mixed-kind link set
// (imports/references/links_to/touched, alongside contains) would hand it
// a graph that isn't acyclic (e.g. two files that import each other) and
// isn't a tree (an entity can be `references`d from several places), which
// produces a cycle warning and a messy layout, not a clean cascade.
//
// `contains` is the one edge kind that IS a strict parent-owns-child
// relationship by construction (project -> community hub, file -> code
// entity — see `map_feed.rs`'s doc comment on re-routing) — a forest, never
// a cycle. So Hierarchy mode renders a *subset* of the loaded links: exactly
// `contains`, which is also exactly the "roots -> projects -> communities ->
// entities" cascade PLAN.md asks for. The other edge kinds still exist in
// the fetched data (Radial mode uses them) but are visual noise for a pure
// containment tree, so Hierarchy mode simply doesn't render them.

export interface HierarchyLink {
  source: string;
  target: string;
  kind: string;
}

/** The one edge kind that defines the hierarchy (see module doc). */
export const HIERARCHY_EDGE_KIND = "contains";

/** Filters a link list down to the containment edges Hierarchy mode's
 * `dagMode` should be computed from. Pure and generic over any link shape
 * carrying at least `{source, target, kind}` so it works equally on the
 * wire shape and on force-graph's runtime (possibly node-object-resolved)
 * shape. */
export function hierarchyLinks<T extends HierarchyLink>(links: readonly T[]): T[] {
  return links.filter((l) => l.kind === HIERARCHY_EDGE_KIND);
}

/** The "roots" tier: every node id that never appears as a `contains`
 * edge's target within `hierLinks` — i.e. nothing containing it in this
 * view. In practice these are `Project` nodes (nothing ever contains a
 * project) plus any node whose container happens to be collapsed/filtered
 * out of the current payload. Exposed mainly so the roots tier is a named,
 * independently testable concept rather than an implicit side effect of
 * `dagMode` — react-force-graph computes its own roots internally the same
 * way (nodes with no incoming link), this just makes that fact explicit
 * and verifiable for OmniAgent's specific edge semantics. */
export function hierarchyRoots(
  nodeIds: readonly string[],
  hierLinks: readonly HierarchyLink[],
): string[] {
  const hasParent = new Set(hierLinks.map((l) => l.target));
  return nodeIds.filter((id) => !hasParent.has(id));
}

/** `dagLevelDistance` heuristic: denser graphs need more radial breathing
 * room per level or labels collide; small graphs can sit tighter. Purely a
 * visual tuning knob, kept as a named pure function (rather than a magic
 * number inlined at the call site) so it's independently testable and the
 * reasoning is documented once. Clamped to a sane HUD-readable range. */
export function dagLevelDistanceFor(nodeCount: number): number {
  const base = 70;
  const perNode = 0.15;
  return Math.min(220, Math.max(base, base + nodeCount * perNode));
}
