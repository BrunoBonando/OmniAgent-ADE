// Pure, framework-free logic for the per-project terminal pane grid (the
// BridgeSpace-reference rebuild — see docs/DESIGN.md and the founder's
// screenshot at docs/reference/bridgespace-pane-grid-reference.png). Mirrors
// `sessions.ts`'s own house style: zero React/Tauri/react-mosaic-component
// imports so this is trivial to unit test (`paneGrid.test.ts`) and so
// `Workspace.tsx` stays a thin binding of these functions to `<Mosaic>`'s
// `value`/`onChange` — all the "how does opening/closing a session change
// the grid shape" logic lives here, once.
//
// `PaneTree` is intentionally a local structural type rather than importing
// `MosaicNode<string>` from `react-mosaic-component` — it's structurally
// identical to (and assignable as) that library's own `MosaicSplitNode<string>
// | string` shape (a leaf id, or `{type: "split", direction, children}`),
// but keeping this file import-free from the grid library means these
// functions (and their tests) don't depend on react-mosaic-component's own
// internals or need a DOM/React test environment.
export type PaneTree =
  | string
  | { type: "split"; direction: "row" | "column"; children: PaneTree[]; splitPercentages?: number[] };

/** Every leaf (session) id in the tree, left to right. */
export function paneIds(tree: PaneTree | null): string[] {
  if (tree === null) return [];
  if (typeof tree === "string") return [tree];
  return tree.children.flatMap(paneIds);
}

/**
 * Adds a new pane for `id`. A brand-new grid becomes a single leaf; the
 * second pane wraps that leaf into a 2-child row split; every pane after
 * that is appended as an *additional child of the existing root split*
 * rather than by wrapping the whole tree in a new one — a deterministic,
 * always-correct placement (PLAN's accepted v1 simplification: no attempt
 * to guess "the right place" to insert a directional split; the user can
 * drag to rearrange afterward, same as the founder's screenshot allows).
 *
 * The "append as a sibling, don't re-wrap" choice is load-bearing, not
 * cosmetic: `Workspace.tsx` renders each pane's `<Terminal>` directly
 * inside `react-mosaic-component`'s `renderTile`, and that library keys
 * intermediate split nodes by *tree path* (see that file's module doc) —
 * wrapping the whole existing tree in a new split changes every existing
 * leaf's path, which is exactly what makes react-mosaic-component discard
 * and remount their subtrees (confirmed against the real library in
 * `Workspace.mountStability.test.tsx`; a leaf directly rendered in
 * `renderTile` loses its React state exactly when its parent path
 * changes). Appending to the existing root split's `children` array keeps
 * every existing leaf's path identical, so opening a 3rd/4th/Nth terminal
 * in a project never disturbs the ones already open. A no-op (returns the
 * same tree reference) when `id` is already present.
 */
export function addPane(tree: PaneTree | null, id: string): PaneTree {
  if (tree === null) return id;
  if (paneIds(tree).includes(id)) return tree;
  if (typeof tree !== "string" && tree.type === "split") {
    return { type: "split", direction: tree.direction, children: [...tree.children, id] };
  }
  return { type: "split", direction: "row", children: [tree, id] };
}

/**
 * Removes `id`'s pane. A split left with exactly one remaining child
 * collapses to that child directly (so closing a pane never leaves a
 * pointless single-child split node around) — recursively, so removing the
 * second-to-last leaf out of a deeply nested tree still resolves to a plain
 * leaf. Returns `null` if the removed id was the only pane. A no-op (same
 * reference back) when `id` isn't present. For the common case — removing
 * one child from a flat, single-level split (i.e. undoing what `addPane`
 * above builds) — the survivors keep their existing path, so, same as
 * `addPane`, this never remounts their `<Terminal>` (verified in
 * `Workspace.mountStability.test.tsx`).
 */
export function removePane(tree: PaneTree | null, id: string): PaneTree | null {
  if (tree === null) return null;
  if (typeof tree === "string") return tree === id ? null : tree;
  if (!paneIds(tree).includes(id)) return tree;

  const children = tree.children
    .map((child) => removePane(child, id))
    .filter((child): child is PaneTree => child !== null);

  if (children.length === 0) return null;
  if (children.length === 1) return children[0];
  return { type: "split", direction: tree.direction, children };
}

/**
 * Reconciles a grid tree against the desired set of open session ids for a
 * project — adds any missing ids, removes any stale ones, and leaves
 * everything else (arrangement, split percentages Mosaic has attached)
 * untouched. Returns the *same* tree reference when nothing changed, so
 * `Workspace.tsx` can skip a `setState` (and the resulting re-render) on
 * every tick where a project's open-tab set hasn't actually moved. Order of
 * `desiredIds` doesn't matter — this only cares about set membership.
 */
export function syncPaneTree(tree: PaneTree | null, desiredIds: string[]): PaneTree | null {
  const desired = new Set(desiredIds);
  const present = new Set(paneIds(tree));

  let next = tree;
  for (const id of present) {
    if (!desired.has(id)) next = removePane(next, id);
  }
  for (const id of desiredIds) {
    if (!present.has(id)) next = addPane(next, id);
  }
  return next;
}
