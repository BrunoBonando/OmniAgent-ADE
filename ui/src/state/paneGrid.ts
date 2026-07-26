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

// ----------------------------------------------------------------------
// The approved grid shapes (founder brief, 2026-07-26, verbatim: "I want the
// layout of the terminals to be consistent when adding a new tab... it should
// automatically go to 2x1 and then 2x2 and the 3x2, 3x3, 4x3, 4x4. And then
// no more terminals are available.")
//
// `[cols, rows]`, ascending capacity. A session's grid is ALWAYS the first
// rung that fits its pane count, so the arrangement is a pure function of
// *how many* panes are open — never of the order they were opened in, which
// path opened them (⌘T, a bulk create, a restore), or what the previous shape
// happened to be. Two sessions with 5 panes each look identical.
const GRID_LADDER = [
  [1, 1],
  [2, 1],
  [2, 2],
  [3, 2],
  [3, 3],
  [4, 3],
  [4, 4],
] as const;

/** Panes one session can hold — the last rung's capacity. The open-a-terminal
 * path (`App.tsx`'s `requestNewTab`) refuses past this; `buildGrid` below
 * still lays out any excess (in more 4-wide rows) rather than dropping a live
 * session on the floor if one ever arrives another way (a restore of an older,
 * uncapped workspace). */
export const MAX_PANES = 16;

/** The approved shape for `count` panes. */
export function gridShape(count: number): { cols: number; rows: number } {
  const [cols] = GRID_LADDER.find(([c, r]) => c * r >= count) ?? GRID_LADDER[GRID_LADDER.length - 1];
  return { cols, rows: Math.max(1, Math.ceil(count / cols)) };
}

/**
 * Arranges `ids` into their approved grid: rows of `gridShape().cols`, left
 * to right, top to bottom, stacked in a column split. A single row needs no
 * column wrapper, and a row holding exactly one id renders as a bare leaf
 * rather than a pointless 1-child split.
 *
 * This is the ONLY function in this file that decides a shape — `syncPaneTree`
 * below routes every add and every close through it, so no caller can produce
 * an unapproved arrangement.
 *
 * ponytail: a shape change moves panes between rows, and
 * react-mosaic-component keys its split nodes by tree path (see
 * `Workspace.tsx`'s module doc), so the panes that change row are remounted —
 * their xterm loses its scrollback, while tmux keeps the session and repaints
 * the visible screen on the resize that every reflow causes. Within one rung
 * every full row keeps its path, so an add costs at most the one pane that was
 * alone on the last row. Upgrade path if the scrollback loss ever bites: a
 * `session_snapshot` command over `tmux capture-pane -p -e`, written into
 * xterm on mount.
 */
export function buildGrid(ids: string[]): PaneTree | null {
  if (ids.length === 0) return null;
  if (ids.length === 1) return ids[0];

  const { cols } = gridShape(ids.length);
  const rows: PaneTree[] = [];
  for (let i = 0; i < ids.length; i += cols) {
    const rowIds = ids.slice(i, i + cols);
    rows.push(rowIds.length === 1 ? rowIds[0] : { type: "split", direction: "row", children: rowIds });
  }
  return rows.length === 1 ? rows[0] : { type: "split", direction: "column", children: rows };
}

/**
 * Swaps one leaf's id for another, preserving the tree's exact shape,
 * nesting, position and split percentages — unlike a rebuild through
 * `buildGrid`, which puts the new id last. `null`/no-match are no-ops (same
 * reference back). Used by `syncPaneTree`'s 1-for-1-swap case below, and
 * exported on its own since it's independently useful (e.g. a future
 * caller that already knows exactly which old id maps to which new one).
 */
export function replacePaneId(tree: PaneTree | null, oldId: string, newId: string): PaneTree | null {
  if (tree === null) return null;
  if (typeof tree === "string") return tree === oldId ? newId : tree;
  return {
    type: "split",
    direction: tree.direction,
    children: tree.children.map((child) => replacePaneId(child, oldId, newId) as PaneTree),
    ...(tree.splitPercentages ? { splitPercentages: tree.splitPercentages } : {}),
  };
}

/**
 * Reconciles a grid tree against the desired set of open session ids for a
 * session — the one entry point `Workspace.tsx` uses. Any change to the set
 * re-lays the whole grid out through `buildGrid`, i.e. into the approved shape
 * for the new pane count: opening the 3rd terminal in a 2x1 gives a 2x2,
 * closing back down to 2 gives the 2x1 again. Surviving panes keep their
 * left-to-right order (including one the user drag-rearranged into); new ids
 * land at the end. Returns the *same* tree reference when the set hasn't
 * moved, so `Workspace.tsx` can skip a `setState` — and so a manual resize
 * (split percentages Mosaic attached) survives every render that isn't an
 * actual open or close.
 *
 * **1-for-1 swap special case**: when the diff between `tree`'s current ids
 * and `desiredIds` is *exactly* one id removed and one different id added,
 * it's treated as an in-place replacement (`replacePaneId`) rather than
 * remove-then-append. This is the shape `sessions.ts`'s `tab/engineRestarted`
 * action produces (`PaneHeader`'s 3-dot "Change engine": kill the old
 * session, spawn a new one with a fresh session id, same pane/slot — see
 * that action's own doc) and the ONLY shape that ever produces it: every
 * other mutation to the tabs array this app makes is add-only
 * (`tab/opened`, `tabs/opened_bulk`) or remove-only (`tab/closed`), so this
 * can never misfire against an unrelated coincidental close-then-open. It
 * keeps the restarted session's pane exactly where it was instead of
 * relocating it to the end of the grid, which a plain remove+add would do.
 */
export function syncPaneTree(tree: PaneTree | null, desiredIds: string[]): PaneTree | null {
  const desired = new Set(desiredIds);
  const present = paneIds(tree);
  const presentSet = new Set(present);

  const removed = present.filter((id) => !desired.has(id));
  const added = desiredIds.filter((id) => !presentSet.has(id));

  if (removed.length === 0 && added.length === 0) return tree;
  if (removed.length === 1 && added.length === 1) {
    return replacePaneId(tree, removed[0], added[0]);
  }
  return buildGrid([...present.filter((id) => desired.has(id)), ...added]);
}

// ----------------------------------------------------------------------
// The LAYOUT preset cards (NewWorkspaceModal / NewSessionModal /
// EmptyWorkspace — BridgeSpace "New Workspace" dialog reference, see
// NewWorkspaceModal.tsx's module doc). Now exactly the ladder rungs that fill
// a grid completely, so a card can never promise a shape the grid won't
// produce: pick "6" and you get the 3x2 `gridShape(6)` describes, because the
// grid derives its own shape from the pane count either way.
export const LAYOUT_PRESETS = [2, 4, 6, 9] as const;
export type LayoutPreset = (typeof LAYOUT_PRESETS)[number];

/** The plain-language caption the modals show under whichever LAYOUT card is
 * currently selected (the reference screenshot's own example: "2×2 grid
 * layout" under the selected "4" card). */
export function layoutCaption(preset: LayoutPreset): string {
  const { rows, cols } = gridShape(preset);
  return rows === 1 ? "Side-by-side split" : `${rows}×${cols} grid layout`;
}
