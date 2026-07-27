import { describe, expect, it } from "vitest";
import {
  LAYOUT_PRESETS,
  MAX_PANES,
  buildGrid,
  gridShape,
  isPaneHole,
  layoutCaption,
  paneIds,
  replacePaneId,
  swapPaneIds,
  syncPaneTree,
} from "./paneGrid";
import type { PaneTree } from "./paneGrid";

function row(children: PaneTree[]): PaneTree {
  return { type: "split", direction: "row", children };
}

function column(children: PaneTree[]): PaneTree {
  return { type: "split", direction: "column", children };
}

/** ids "1".."n" — keeps the bigger grid expectations readable. */
function ids(n: number): string[] {
  return Array.from({ length: n }, (_, i) => String(i + 1));
}

/** Every leaf id, holes included — unlike the exported `paneIds`, which
 * exists precisely to hide holes from every other caller. */
function allLeaves(tree: PaneTree | null): string[] {
  if (tree === null) return [];
  if (typeof tree === "string") return [tree];
  return tree.children.flatMap(allLeaves);
}

describe("gridShape — the founder's approved ladder", () => {
  it("walks 1x1 -> 2x1 -> 2x2 -> 3x2 -> 4x2 and stops", () => {
    // Founder, 2026-07-26: "the only layouts possible are: 1, 1x2, 2x2, 2x3,
    // 2x4. And no more terminals are allowed." `[cols, rows]` per pane count,
    // 1..8:
    const expected: Array<[number, number]> = [
      [1, 1], // 1
      [2, 1], // 2
      [2, 2], // 3
      [2, 2], // 4
      [3, 2], // 5
      [3, 2], // 6
      [4, 2], // 7
      [4, 2], // 8
    ];
    expected.forEach(([cols, rows], i) => {
      expect(gridShape(i + 1), `${i + 1} panes`).toEqual({ cols, rows });
    });
  });

  it("MAX_PANES is the last rung's capacity", () => {
    expect(MAX_PANES).toBe(8);
    const { cols, rows } = gridShape(MAX_PANES);
    expect(cols * rows).toBe(MAX_PANES);
  });

  it("past the cap it keeps the widest shape and grows rows rather than losing panes", () => {
    // The open-a-terminal path refuses past MAX_PANES, but a restored
    // workspace from before the cap must still render every live session.
    expect(gridShape(9)).toEqual({ cols: 4, rows: 3 });
    expect(paneIds(buildGrid(ids(9)))).toEqual(ids(9));
  });
});

describe("buildGrid", () => {
  it("is null for no panes and a bare leaf for one (no pointless split)", () => {
    expect(buildGrid([])).toBeNull();
    expect(buildGrid(["a"])).toBe("a");
  });

  it("2 panes: a plain side-by-side row, no column wrapper", () => {
    expect(buildGrid(["a", "b"])).toEqual(row(["a", "b"]));
  });

  it("3 panes: the 2x2 rung filled column-major, the bottom-right cell a hole", () => {
    // Column-major: "a" top-left, "b" below it, "c" tops the new right-hand
    // column, the hole under "c" — the founder's "new terminal always starts
    // on top right" rule.
    const tree = buildGrid(["a", "b", "c"]);
    expect(paneIds(tree)).toEqual(["a", "b", "c"]);
    const leaves = allLeaves(tree);
    expect(leaves.slice(0, 3)).toEqual(["a", "b", "c"]);
    expect(leaves).toHaveLength(4);
    expect(isPaneHole(leaves[3])).toBe(true);
    expect(tree).toEqual(row([column(["a", "b"]), column(["c", leaves[3]])]));
  });

  it("4 panes: a literal 2x2 (two stacked columns), no holes", () => {
    expect(buildGrid(["a", "b", "c", "d"])).toEqual(row([column(["a", "b"]), column(["c", "d"])]));
  });

  it("5 panes: the 3x2 rung — two full columns, then the new pane atop a hole", () => {
    const tree = buildGrid(ids(5));
    const leaves = allLeaves(tree);
    expect(paneIds(tree)).toEqual(ids(5));
    expect(leaves).toHaveLength(6);
    expect(isPaneHole(leaves[5])).toBe(true);
    expect(tree).toEqual(row([column(["1", "2"]), column(["3", "4"]), column(["5", leaves[5]])]));
  });

  it("8 panes: a literal 2x4 (four stacked columns), no holes", () => {
    const tree = buildGrid(ids(8));
    expect(tree).toEqual(
      row([column(["1", "2"]), column(["3", "4"]), column(["5", "6"]), column(["7", "8"])]),
    );
  });

  it("keeps every real id exactly once, in order, at every count up to the cap", () => {
    for (let n = 1; n <= MAX_PANES; n++) {
      expect(paneIds(buildGrid(ids(n))), `${n} panes`).toEqual(ids(n));
    }
  });

  it("pads every rung to its full rectangle with holes, never a short row", () => {
    for (let n = 1; n <= MAX_PANES; n++) {
      const { cols, rows } = gridShape(n);
      expect(allLeaves(buildGrid(ids(n))), `${n} panes`).toHaveLength(cols * rows);
    }
  });
});

describe("paneIds", () => {
  it("is empty for a null tree", () => {
    expect(paneIds(null)).toEqual([]);
  });

  it("returns the single leaf", () => {
    expect(paneIds("a")).toEqual(["a"]);
  });

  it("returns every leaf in a nested tree, left to right", () => {
    expect(paneIds(row([column(["a", "b"]), "c"]))).toEqual(["a", "b", "c"]);
  });
});

describe("syncPaneTree", () => {
  it("builds a fresh grid from scratch when starting from null", () => {
    expect(syncPaneTree(null, ["a", "b"])).toEqual(row(["a", "b"]));
  });

  it("a new terminal moves the grid up a rung, landing LOWER-LEFT (2x1 -> 2x2)", () => {
    // Keep the original side-by-side pair on the top row; the new terminal
    // takes lower-left and the hole (the next Add Terminal spot) is lower-right.
    const tree = syncPaneTree(row(["a", "b"]), ["a", "b", "c"]);
    const hole = allLeaves(tree)[3];
    expect(isPaneHole(hole)).toBe(true);
    expect(tree).toEqual(row([column(["a", "c"]), column(["b", hole])]));
  });

  it("growing a full 2x2 to 5 panes adds a column on the right — nobody already open moves", () => {
    // Founder, 2026-07-26: "the new terminal would simply always start on top
    // right if full". Columns [1,2] and [3,4] are untouched, byte for byte.
    const at4 = buildGrid(ids(4));
    const tree = syncPaneTree(at4, ids(5));
    const hole = allLeaves(tree)[5];
    expect(isPaneHole(hole)).toBe(true);
    expect(tree).toEqual(row([column(["1", "2"]), column(["3", "4"]), column(["5", hole])]));
  });

  it("a new terminal within the current rung fills the hole — 'bottom if not full' (7 -> 8)", () => {
    const at7 = buildGrid(ids(7));
    expect(syncPaneTree(at7, ids(8))).toEqual(
      row([column(["1", "2"]), column(["3", "4"]), column(["5", "6"]), column(["7", "8"])]),
    );
  });

  it("closing a terminal reflows back DOWN a rung (2x2 -> 2x1)", () => {
    const at3 = buildGrid(["a", "b", "c"]);
    expect(syncPaneTree(at3, ["a", "b"])).toEqual(row(["a", "b"]));
  });

  it("survivors keep their fill order, including one the user dragged", () => {
    // A drag-rearranged tree is the input here (c before a) — reflowing must
    // respect the arrangement the user made, not reset to creation order.
    const dragged = row([column(["c", "b"]), "a"]);
    expect(syncPaneTree(dragged, ["a", "b", "c", "d"])).toEqual(
      row([column(["c", "b"]), column(["a", "d"])]),
    );
  });

  it("returns the exact same tree reference when already in sync (no re-render, no lost resize)", () => {
    const tree = row(["a", "b"]);
    expect(syncPaneTree(tree, ["a", "b"])).toBe(tree);
    expect(syncPaneTree(tree, ["b", "a"])).toBe(tree); // membership, not order
  });

  it("clearing every id resolves to null, and null stays null", () => {
    expect(syncPaneTree(row(["a", "b"]), [])).toBeNull();
    expect(syncPaneTree(null, [])).toBeNull();
  });

  it("treats a 1-for-1 swap (engine restart) as an in-place replacement, preserving position", () => {
    // PaneHeader's 3-dot "Change engine": kill session "b", spawn a new one
    // ("b2") in the very same slot. Rebuilding the grid would put the new id
    // at the end; this must not.
    const before = buildGrid(["a", "b", "c"]);
    const hole = allLeaves(before)[3];
    expect(syncPaneTree(before, ["a", "b2", "c"])).toEqual(
      row([column(["a", "b2"]), column(["c", hole])]),
    );
  });

  it("does not treat a 2-for-2 (or other non-1-for-1) diff as a swap", () => {
    expect(paneIds(syncPaneTree(row(["a", "b"]), ["c", "d"])).sort()).toEqual(["c", "d"]);
  });
});

describe("replacePaneId", () => {
  it("swaps a bare leaf", () => {
    expect(replacePaneId("a", "a", "a2")).toBe("a2");
  });

  it("is a no-op when the old id isn't present", () => {
    expect(replacePaneId(row(["a", "b"]), "ghost", "x")).toEqual(row(["a", "b"]));
  });

  it("swaps a leaf deep inside a nested split, preserving every sibling's position", () => {
    const tree = column([row(["a", "b"]), "c"]);
    expect(replacePaneId(tree, "b", "b2")).toEqual(column([row(["a", "b2"]), "c"]));
  });

  it("returns null for a null tree", () => {
    expect(replacePaneId(null, "a", "b")).toBeNull();
  });
});

describe("swapPaneIds — dragging one terminal onto another to trade places", () => {
  it("trades two panes across columns, leaving every other pane where it was", () => {
    const tree = buildGrid(ids(4)); // columns [1,2] [3,4]
    expect(swapPaneIds(tree, "1", "4")).toEqual(row([column(["4", "2"]), column(["3", "1"])]));
  });

  it("keeps the shape and any manual resize (split percentages)", () => {
    const tree: PaneTree = { type: "split", direction: "row", children: ["a", "b"], splitPercentages: [30, 70] };
    expect(swapPaneIds(tree, "a", "b")).toEqual({
      type: "split",
      direction: "row",
      children: ["b", "a"],
      splitPercentages: [30, 70],
    });
  });

  it("is a no-op for a pane dropped on itself, an unknown id, or a null tree", () => {
    const tree = row(["a", "b"]);
    expect(swapPaneIds(tree, "a", "a")).toBe(tree);
    expect(swapPaneIds(tree, "a", "ghost")).toBe(tree);
    expect(swapPaneIds(null, "a", "b")).toBeNull();
  });
});

describe("LAYOUT presets", () => {
  it("are exactly the ladder rungs that fill a grid completely", () => {
    expect(LAYOUT_PRESETS).toEqual([1, 2, 4, 6, 8]);
    for (const preset of LAYOUT_PRESETS) {
      const { cols, rows } = gridShape(preset);
      expect(cols * rows, `preset ${preset}`).toBe(preset);
    }
  });

  it("captions 1 as a single terminal, 2 as a side-by-side split, the rest as an RxC grid", () => {
    expect(layoutCaption(1)).toBe("Single terminal");
    expect(layoutCaption(2)).toBe("Side-by-side split");
    expect(layoutCaption(4)).toBe("2×2 grid layout");
    expect(layoutCaption(6)).toBe("2×3 grid layout");
    expect(layoutCaption(8)).toBe("2×4 grid layout");
  });
});
