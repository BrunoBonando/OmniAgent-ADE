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

// ----------------------------------------------------------------------
// NewWorkspaceModal's LAYOUT presets (BridgeSpace "New Workspace" dialog
// reference — a founder screenshot described precisely, no image file
// checked in; see NewWorkspaceModal.tsx's module doc) — the "2"/"4"/"6"/"8"
// preset cards, each previewing an RxC grid glyph. `addPane`/`syncPaneTree`
// above are deliberately dumb: every pane after the first two is always
// appended as a flat sibling of the root split (see `addPane`'s own doc —
// that flatness is load-bearing for mount stability). Neither function can
// produce an actual 2x2/2x3/2x4 grid shape, so a genuinely new pure
// function is needed for "arrange this fresh batch of panes into the
// chosen preset's grid" — this is that function, used exactly once, when
// NewWorkspaceModal's bulk session-create seeds a brand-new project's pane
// grid (see `ProjectPaneGrid`'s `initialTree` prop in `Workspace.tsx`).
// Every pane opened/closed *after* that initial arrangement still goes
// through the ordinary `addPane`/`removePane`/`syncPaneTree` path above,
// unchanged.
export const LAYOUT_PRESETS = [2, 4, 6, 8] as const;
export type LayoutPreset = (typeof LAYOUT_PRESETS)[number];

/** The (rows, cols) grid shape a preset represents when given exactly
 * `preset` panes — what the modal's glyph icon previews, and what
 * `buildLayoutTree` below targets as its row-wrap width for any actual
 * pane count (see that function's own doc for how counts that don't
 * exactly match `preset` are handled). "2" is a single row of 2 (the
 * reference's plain left/right split, not a "1x2 grid"); "4"/"6"/"8" are
 * always 2 rows, growing wider (2/3/4 columns) rather than taller — matches
 * the reference's own glyphs (2x2, 2x3, 2x4). */
export function nominalGridShape(preset: LayoutPreset): { rows: number; cols: number } {
  switch (preset) {
    case 2:
      return { rows: 1, cols: 2 };
    case 4:
      return { rows: 2, cols: 2 };
    case 6:
      return { rows: 2, cols: 3 };
    case 8:
      return { rows: 2, cols: 4 };
  }
}

/** The plain-language caption NewWorkspaceModal shows under whichever
 * LAYOUT card is currently selected (the reference screenshot's own
 * example: "2×2 grid layout" under the selected "4" card). */
export function layoutCaption(preset: LayoutPreset): string {
  const { rows, cols } = nominalGridShape(preset);
  return rows === 1 ? "Side-by-side split" : `${rows}×${cols} grid layout`;
}

/**
 * Arranges a freshly-created batch of pane ids into the chosen layout
 * preset's grid shape — wraps `ids` into rows of `nominalGridShape(preset)
 * .cols` (left to right, top to bottom), then stacks those rows in a
 * column split (a single row needs no column wrapper). A row left with
 * exactly one id renders as a bare leaf rather than a pointless 1-child
 * split, mirroring `addPane`/`removePane`'s own "no pointless single-child
 * split" rule above.
 *
 * The preset is an **arrangement-style hint, not an enforced slot count**
 * (NewWorkspaceModal's own product decision — see its module doc): this
 * never invents empty/placeholder panes to pad a short list up to the
 * preset's nominal count (checking only 2 agents under the "4" (2x2)
 * preset just gives a plain 2-wide row, not a 2x2 grid with two blank
 * cells), and never drops ids past the nominal count either (checking 5
 * agents under "4" wraps into a third, shorter row rather than silently
 * discarding the 5th) — `react-mosaic-component` trees aren't hard-capped,
 * so there's no real ceiling to enforce.
 */
export function buildLayoutTree(ids: string[], preset: LayoutPreset): PaneTree | null {
  if (ids.length === 0) return null;
  if (ids.length === 1) return ids[0];

  const { cols } = nominalGridShape(preset);
  const rows: PaneTree[] = [];
  for (let i = 0; i < ids.length; i += cols) {
    const rowIds = ids.slice(i, i + cols);
    rows.push(rowIds.length === 1 ? rowIds[0] : { type: "split", direction: "row", children: rowIds });
  }
  return rows.length === 1 ? rows[0] : { type: "split", direction: "column", children: rows };
}
