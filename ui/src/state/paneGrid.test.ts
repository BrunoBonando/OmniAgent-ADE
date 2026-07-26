import { describe, expect, it } from "vitest";
import {
  LAYOUT_PRESETS,
  MAX_PANES,
  buildGrid,
  gridShape,
  layoutCaption,
  paneIds,
  replacePaneId,
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

describe("gridShape — the founder's approved ladder", () => {
  it("walks 1x1 -> 2x1 -> 2x2 -> 3x2 -> 3x3 -> 4x3 -> 4x4 and stops", () => {
    // Founder, 2026-07-26: "it should go automatically go to 2x1 and then 2x2
    // and the 3x2, 3x3, 4x3, 4x4. And then no more terminals are available."
    // `[cols, rows]` per pane count, 1..16:
    const expected: Array<[number, number]> = [
      [1, 1], // 1
      [2, 1], // 2
      [2, 2], // 3
      [2, 2], // 4
      [3, 2], // 5
      [3, 2], // 6
      [3, 3], // 7
      [3, 3], // 8
      [3, 3], // 9
      [4, 3], // 10
      [4, 3], // 11
      [4, 3], // 12
      [4, 4], // 13
      [4, 4], // 14
      [4, 4], // 15
      [4, 4], // 16
    ];
    expected.forEach(([cols, rows], i) => {
      expect(gridShape(i + 1), `${i + 1} panes`).toEqual({ cols, rows });
    });
  });

  it("MAX_PANES is the last rung's capacity", () => {
    expect(MAX_PANES).toBe(16);
    const { cols, rows } = gridShape(MAX_PANES);
    expect(cols * rows).toBe(MAX_PANES);
  });

  it("past the cap it keeps the widest shape and grows rows rather than losing panes", () => {
    // The open-a-terminal path refuses past MAX_PANES, but a restored
    // workspace from before the cap must still render every live session.
    expect(gridShape(17)).toEqual({ cols: 4, rows: 5 });
    expect(paneIds(buildGrid(ids(17)))).toEqual(ids(17));
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

  it("3 panes: the 2x2 rung, with the odd one as a bare leaf row", () => {
    expect(buildGrid(["a", "b", "c"])).toEqual(column([row(["a", "b"]), "c"]));
  });

  it("4 panes: a literal 2x2", () => {
    expect(buildGrid(["a", "b", "c", "d"])).toEqual(column([row(["a", "b"]), row(["c", "d"])]));
  });

  it("5 panes: the 3x2 rung — 3 wide first, remainder on the second row", () => {
    expect(buildGrid(ids(5))).toEqual(column([row(["1", "2", "3"]), row(["4", "5"])]));
  });

  it("9 panes: a literal 3x3", () => {
    expect(buildGrid(ids(9))).toEqual(
      column([row(["1", "2", "3"]), row(["4", "5", "6"]), row(["7", "8", "9"])]),
    );
  });

  it("16 panes: a literal 4x4", () => {
    const tree = buildGrid(ids(16));
    expect(tree).toEqual(
      column([
        row(["1", "2", "3", "4"]),
        row(["5", "6", "7", "8"]),
        row(["9", "10", "11", "12"]),
        row(["13", "14", "15", "16"]),
      ]),
    );
  });

  it("keeps every id exactly once, in order, at every count up to the cap", () => {
    for (let n = 1; n <= MAX_PANES; n++) {
      expect(paneIds(buildGrid(ids(n))), `${n} panes`).toEqual(ids(n));
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

  it("a new terminal moves the whole grid up a rung (2x1 -> 2x2)", () => {
    expect(syncPaneTree(row(["a", "b"]), ["a", "b", "c"])).toEqual(column([row(["a", "b"]), "c"]));
  });

  it("a new terminal within the current rung keeps the shape (7 -> 8 stays 3x3)", () => {
    const at7 = buildGrid(ids(7));
    expect(syncPaneTree(at7, ids(8))).toEqual(
      column([row(["1", "2", "3"]), row(["4", "5", "6"]), row(["7", "8"])]),
    );
  });

  it("closing a terminal reflows back DOWN a rung (2x2 -> 2x1)", () => {
    const at3 = buildGrid(["a", "b", "c"]);
    expect(syncPaneTree(at3, ["a", "b"])).toEqual(row(["a", "b"]));
  });

  it("survivors keep their left-to-right order, including one the user dragged", () => {
    // A drag-rearranged tree is the input here (c before a) — reflowing must
    // respect the arrangement the user made, not reset to creation order.
    const dragged = column([row(["c", "b"]), "a"]);
    expect(syncPaneTree(dragged, ["a", "b", "c", "d"])).toEqual(column([row(["c", "b"]), row(["a", "d"])]));
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
    expect(syncPaneTree(buildGrid(["a", "b", "c"]), ["a", "b2", "c"])).toEqual(
      column([row(["a", "b2"]), "c"]),
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

describe("LAYOUT presets", () => {
  it("are exactly the ladder rungs that fill a grid completely", () => {
    expect(LAYOUT_PRESETS).toEqual([2, 4, 6, 9]);
    for (const preset of LAYOUT_PRESETS) {
      const { cols, rows } = gridShape(preset);
      expect(cols * rows, `preset ${preset}`).toBe(preset);
    }
  });

  it("captions the 2 preset as a side-by-side split, the rest as an RxC grid", () => {
    expect(layoutCaption(2)).toBe("Side-by-side split");
    expect(layoutCaption(4)).toBe("2×2 grid layout");
    expect(layoutCaption(6)).toBe("2×3 grid layout");
    expect(layoutCaption(9)).toBe("3×3 grid layout");
  });
});
