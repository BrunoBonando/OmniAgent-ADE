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

/** Prefix for a `buildGrid`-inserted filler leaf — a cell no open session
 * claims, rendered by `Workspace.tsx` as an empty placeholder rather than a
 * real pane. */
const HOLE_PREFIX = "__pane-hole-";

function holeId(i: number): string {
  return `${HOLE_PREFIX}${i}`;
}

/** True for a hole leaf (`buildGrid`'s filler), never a real session id —
 * `Workspace.tsx`'s `renderTile` uses this to render the empty-gradient
 * placeholder instead of a `<Terminal>`. */
export function isPaneHole(id: string): boolean {
  return id.startsWith(HOLE_PREFIX);
}

/** Every real (non-hole) leaf id in the tree, in FILL order — top to bottom
 * within a column, columns left to right (the tree is a row split of column
 * splits, so depth-first IS that order). Exactly the order `buildGrid`
 * consumes, so `buildGrid(paneIds(tree))` reproduces the same arrangement —
 * the round-trip `syncPaneTree` relies on to keep surviving panes where they
 * were. */
export function paneIds(tree: PaneTree | null): string[] {
  if (tree === null) return [];
  if (typeof tree === "string") return isPaneHole(tree) ? [] : [tree];
  return tree.children.flatMap(paneIds);
}

// ----------------------------------------------------------------------
// The approved grid shapes (founder brief, 2026-07-26: "the only layouts
// possible are: 1, 1x2, 2x2, 2x3, 2x4. And no more terminals are allowed" —
// max 8 terminals a session can hold).
//
// `[cols, rows]`, ascending capacity. A session's grid is ALWAYS the first
// rung that fits its pane count, so the arrangement is a pure function of
// *how many* panes are open — never of the order they were opened in, which
// path opened them (⌘T, a bulk create, a restore), or what the previous shape
// happened to be. A count that doesn't exactly fill a rung does NOT shrink
// the shape down to what's there — `buildGrid` below pads the leftover cells
// with holes ("if a number of terminals is not even, it's okay to have a
// hole in the matrix"), so e.g. 3 panes always render as a real 2x2, one
// cell empty, never a lopsided row of 2 plus a lone 1.
const GRID_LADDER = [
  [1, 1],
  [2, 1],
  [2, 2],
  [3, 2],
  [4, 2],
] as const;

/** Panes one session can hold — the last rung's capacity. The open-a-terminal
 * path (`App.tsx`'s `requestNewTab`) refuses past this; `buildGrid` below
 * still lays out any excess (in more 4-wide rows) rather than dropping a live
 * session on the floor if one ever arrives another way (a restore of an older,
 * uncapped workspace). */
export const MAX_PANES = 8;

/** The approved shape for `count` panes. */
export function gridShape(count: number): { cols: number; rows: number } {
  const [cols] = GRID_LADDER.find(([c, r]) => c * r >= count) ?? GRID_LADDER[GRID_LADDER.length - 1];
  return { cols, rows: Math.max(1, Math.ceil(count / cols)) };
}

/**
 * Arranges `ids` into their approved grid, COLUMN-major: `gridShape`'s
 * columns side by side (a row split), each column filled top to bottom (a
 * column split), any leftover cells padded with holes — always the complete
 * rung's rectangle, never a short row.
 *
 * The column-major fill is the default placement rule: a new terminal lands
 * at the TOP of a brand-new right-hand column when the grid was full, or
 * drops into the bottom hole when it wasn't — and every already-open terminal
 * stays exactly where it was. The hole itself doubles as the "Add Terminal"
 * affordance (`Workspace.tsx`'s hole tile).
 *
 * This is the ONLY function in this file that decides a shape — `syncPaneTree`
 * below routes every add and every close through it, so no caller can produce
 * an unapproved arrangement.
 *
 * ponytail: react-mosaic-component keys split nodes by tree path (see
 * `Workspace.tsx`'s module doc), so a reflow that restacks a pane into a
 * different column remounts it — its xterm loses scrollback, while tmux keeps
 * the session and repaints on the resize every reflow causes. Column-major
 * growth makes that rare: adding or dropping a whole column (4->5, 5->4,
 * 6->7…) keeps every surviving leaf's path, so only the 2->3 restack (the
 * side-by-side pair becomes the first stacked column) still pays. Upgrade
 * path if the scrollback loss ever bites: a `session_snapshot` command over
 * `tmux capture-pane -p -e`, written into xterm on mount.
 */
export function buildGrid(ids: string[]): PaneTree | null {
  if (ids.length === 0) return null;
  if (ids.length === 1) return ids[0];

  const { cols, rows } = gridShape(ids.length);
  const cells = ids.slice();
  for (let i = 0; cells.length < cols * rows; i++) cells.push(holeId(i));

  const colNodes: PaneTree[] = [];
  for (let i = 0; i < cells.length; i += rows) {
    const colCells = cells.slice(i, i + rows);
    colNodes.push(colCells.length === 1 ? colCells[0] : { type: "split", direction: "column", children: colCells });
  }
  return { type: "split", direction: "row", children: colNodes };
}

/** Rewrites every leaf id through `fn`, keeping the tree's exact shape,
 * nesting and split percentages. The two functions below are both this. */
function mapPaneIds(tree: PaneTree | null, fn: (id: string) => string): PaneTree | null {
  if (tree === null) return null;
  if (typeof tree === "string") return fn(tree);
  return { ...tree, children: tree.children.map((child) => mapPaneIds(child, fn) as PaneTree) };
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
  return mapPaneIds(tree, (id) => (id === oldId ? newId : id));
}

/**
 * Trades two panes' positions (founder ask, 2026-07-26: *"Make dragged
 * terminal able to exchange places with another terminal"*) — everything
 * else about the tree, including the approved shape and any manual resize,
 * is untouched, because a swap is exactly the one rearrangement that can't
 * produce a grid `buildGrid` wouldn't. Dropping a pane on itself, or on an
 * id that isn't in the tree, is a no-op.
 */
export function swapPaneIds(tree: PaneTree | null, a: string, b: string): PaneTree | null {
  const present = paneIds(tree);
  if (a === b || !present.includes(a) || !present.includes(b)) return tree;
  return mapPaneIds(tree, (id) => (id === a ? b : id === b ? a : id));
}

/**
 * Reconciles a grid tree against the desired set of open session ids for a
 * session — the one entry point `Workspace.tsx` uses. Any change to the set
 * re-lays the whole grid out into the approved shape for the new pane count:
 * opening the 3rd terminal in a 2x1 gives a 2x2, closing back down to 2 gives
 * the 2x1 again. Surviving panes keep their left-to-right order (including
 * one the user drag-rearranged into); new ids land at the end. Returns the
 * *same* tree reference when the set hasn't moved, so `Workspace.tsx` can skip
 * a `setState` — and so a manual resize (split percentages Mosaic attached)
 * survives every render that isn't an actual open or close.
 *
 * **2 -> 3 special case**: adding one pane to the side-by-side split now
 * lands the new terminal in the LOWER-LEFT cell of the 2x2 rung. Existing
 * panes stay on the top row (left then right), and the lone hole becomes the
 * lower-right cell.
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
  if (removed.length === 0 && added.length === 1 && present.length === 2) {
    return {
      type: "split",
      direction: "row",
      children: [
        { type: "split", direction: "column", children: [present[0], added[0]] },
        { type: "split", direction: "column", children: [present[1], holeId(0)] },
      ],
    };
  }
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
export const LAYOUT_PRESETS = [1, 2, 4, 6, 8] as const;
export type LayoutPreset = (typeof LAYOUT_PRESETS)[number];

/** The plain-language caption the modals show under whichever LAYOUT card is
 * currently selected (the reference screenshot's own example: "2×2 grid
 * layout" under the selected "4" card). */
export function layoutCaption(preset: LayoutPreset): string {
  if (preset === 1) return "Single terminal";
  const { rows, cols } = gridShape(preset);
  return rows === 1 ? "Side-by-side split" : `${rows}×${cols} grid layout`;
}
