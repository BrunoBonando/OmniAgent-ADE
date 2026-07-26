import { describe, expect, it } from "vitest";
import {
  addPane,
  addPaneSubtree,
  buildLayoutTree,
  layoutCaption,
  LAYOUT_PRESETS,
  nominalGridShape,
  paneIds,
  removePane,
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

describe("addPane", () => {
  it("returns the id itself when the tree is empty", () => {
    expect(addPane(null, "a")).toBe("a");
  });

  it("wraps a single leaf and the new id in a row split", () => {
    const next = addPane("a", "b");
    expect(next).toEqual(row(["a", "b"]));
  });

  it("appends onto an existing split as a sibling, not by re-wrapping it", () => {
    // Load-bearing shape, not cosmetic — see this function's own doc comment
    // and Workspace.mountStability.test.tsx: re-wrapping the existing split
    // (the old behavior) changes every existing leaf's tree path, which is
    // exactly what makes react-mosaic-component remount their `<Terminal>`.
    const tree = row(["a", "b"]);
    const next = addPane(tree, "c");
    expect(next).toEqual(row(["a", "b", "c"]));
  });

  it("keeps appending flat siblings for a 4th, 5th... pane", () => {
    const next = addPane(row(["a", "b", "c"]), "d");
    expect(next).toEqual(row(["a", "b", "c", "d"]));
  });

  it("preserves the existing split's direction when appending", () => {
    const next = addPane(column(["a", "b"]), "c");
    expect(next).toEqual(column(["a", "b", "c"]));
  });

  it("is a no-op (returns the same tree reference) when the id is already present", () => {
    const tree = row(["a", "b"]);
    expect(addPane(tree, "a")).toBe(tree);
    expect(addPane("a", "a")).toBe("a");
  });
});

describe("removePane", () => {
  it("removes the sole leaf, leaving an empty tree", () => {
    expect(removePane("a", "a")).toBeNull();
  });

  it("collapses a two-child split down to the remaining sibling", () => {
    const tree = row(["a", "b"]);
    expect(removePane(tree, "b")).toBe("a");
    expect(removePane(tree, "a")).toBe("b");
  });

  it("removes a leaf from a nested split, preserving the rest of the shape", () => {
    const tree = row([column(["a", "b"]), "c"]);
    expect(removePane(tree, "b")).toEqual(row(["a", "c"]));
  });

  it("preserves the split direction of the surviving parent split", () => {
    const tree = column(["a", "b", "c"]);
    expect(removePane(tree, "b")).toEqual(column(["a", "c"]));
  });

  it("removing an id that is not in the tree is a no-op (same reference back)", () => {
    const tree = row(["a", "b"]);
    expect(removePane(tree, "ghost")).toBe(tree);
    expect(removePane(null, "ghost")).toBeNull();
  });

  it("removing from a 3-way split keeps the other two as a split, not collapsed further than needed", () => {
    const tree = row(["a", "b", "c"]);
    expect(removePane(tree, "b")).toEqual(row(["a", "c"]));
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
    const tree = row([column(["a", "b"]), "c"]);
    expect(paneIds(tree)).toEqual(["a", "b", "c"]);
  });
});

describe("syncPaneTree", () => {
  it("builds a fresh tree from scratch when starting from null", () => {
    const next = syncPaneTree(null, ["a", "b"]);
    expect(paneIds(next).sort()).toEqual(["a", "b"]);
  });

  it("adds only the missing ids, preserving the existing arrangement", () => {
    const tree = row(["a", "b"]);
    const next = syncPaneTree(tree, ["a", "b", "c"]);
    expect(next).toEqual(row(["a", "b", "c"]));
  });

  it("removes ids no longer present", () => {
    const tree = row(["a", "b", "c"]);
    const next = syncPaneTree(tree, ["a", "c"]);
    expect(paneIds(next).sort()).toEqual(["a", "c"]);
  });

  it("adds and removes in the same pass", () => {
    const tree = row(["a", "b"]);
    const next = syncPaneTree(tree, ["a", "c"]);
    expect(paneIds(next).sort()).toEqual(["a", "c"]);
  });

  it("returns the exact same tree reference when already in sync (no unnecessary re-render)", () => {
    const tree = row(["a", "b"]);
    const next = syncPaneTree(tree, ["a", "b"]);
    expect(next).toBe(tree);
    const alsoSame = syncPaneTree(tree, ["b", "a"]); // order doesn't matter for sync purposes
    expect(alsoSame).toBe(tree);
  });

  it("clearing every id resolves to null", () => {
    const tree = row(["a", "b"]);
    expect(syncPaneTree(tree, [])).toBeNull();
  });

  it("stays null when there is nothing to add", () => {
    expect(syncPaneTree(null, [])).toBeNull();
  });

  it("treats a 1-for-1 swap (engine restart) as an in-place replacement, preserving position", () => {
    // PaneHeader's 3-dot "Change engine": kill session "b", spawn a new one
    // ("b2") in the very same pane slot — a plain remove-then-add would
    // relocate the new pane to the end of the grid (`addPane`'s own
    // "always append as a sibling" rule); the swap case must not.
    const tree = row(["a", "b", "c"]);
    const next = syncPaneTree(tree, ["a", "b2", "c"]);
    expect(next).toEqual(row(["a", "b2", "c"]));
  });

  it("a 1-for-1 swap in a nested split preserves the nesting, not just top-level position", () => {
    const tree = row([column(["a", "b"]), "c"]);
    const next = syncPaneTree(tree, ["a", "b2", "c"]);
    expect(next).toEqual(row([column(["a", "b2"]), "c"]));
  });

  it("does not treat a 2-for-2 (or other non-1-for-1) diff as a swap", () => {
    const tree = row(["a", "b"]);
    const next = syncPaneTree(tree, ["c", "d"]);
    expect(paneIds(next).sort()).toEqual(["c", "d"]);
  });
});

describe("replacePaneId", () => {
  it("swaps a bare leaf", () => {
    expect(replacePaneId("a", "a", "a2")).toBe("a2");
  });

  it("is a no-op when the old id isn't present", () => {
    const tree = row(["a", "b"]);
    expect(replacePaneId(tree, "ghost", "x")).toEqual(row(["a", "b"]));
  });

  it("swaps a leaf deep inside a nested split, preserving every sibling's position", () => {
    const tree = column([row(["a", "b"]), "c"]);
    expect(replacePaneId(tree, "b", "b2")).toEqual(column([row(["a", "b2"]), "c"]));
  });

  it("returns null for a null tree", () => {
    expect(replacePaneId(null, "a", "b")).toBeNull();
  });
});

// ------------------------------------------------------------------------
// NewWorkspaceModal's LAYOUT presets (2/4/6/8) — see this file's own doc
// comment on `buildLayoutTree` for why `addPane`/`syncPaneTree` above can't
// express these shapes (they only ever append flat siblings to a row).
describe("nominalGridShape", () => {
  it("maps every preset to its (rows, cols) grid shape", () => {
    expect(nominalGridShape(2)).toEqual({ rows: 1, cols: 2 });
    expect(nominalGridShape(4)).toEqual({ rows: 2, cols: 2 });
    expect(nominalGridShape(6)).toEqual({ rows: 2, cols: 3 });
    expect(nominalGridShape(8)).toEqual({ rows: 2, cols: 4 });
  });

  it("LAYOUT_PRESETS lists exactly the four presets in ascending order", () => {
    expect(LAYOUT_PRESETS).toEqual([2, 4, 6, 8]);
  });
});

describe("layoutCaption", () => {
  it("describes the 2 preset as a side-by-side split, not a '1x2 grid'", () => {
    expect(layoutCaption(2)).toBe("Side-by-side split");
  });

  it("describes 4/6/8 as an RxC grid layout", () => {
    expect(layoutCaption(4)).toBe("2×2 grid layout");
    expect(layoutCaption(6)).toBe("2×3 grid layout");
    expect(layoutCaption(8)).toBe("2×4 grid layout");
  });
});

describe("buildLayoutTree", () => {
  it("returns null for an empty id list", () => {
    expect(buildLayoutTree([], 4)).toBeNull();
  });

  it("returns the bare leaf for a single id, regardless of preset", () => {
    expect(buildLayoutTree(["a"], 8)).toBe("a");
  });

  it("preset 2 with exactly 2 ids: a plain row split (the reference's left/right two-way split)", () => {
    expect(buildLayoutTree(["a", "b"], 2)).toEqual(row(["a", "b"]));
  });

  it("preset 4 with exactly 4 ids: a literal 2x2 grid (column of two 2-wide rows)", () => {
    const tree = buildLayoutTree(["a", "b", "c", "d"], 4);
    expect(tree).toEqual(column([row(["a", "b"]), row(["c", "d"])]));
  });

  it("preset 6 with exactly 6 ids: a literal 2x3 grid", () => {
    const tree = buildLayoutTree(["a", "b", "c", "d", "e", "f"], 6);
    expect(tree).toEqual(column([row(["a", "b", "c"]), row(["d", "e", "f"])]));
  });

  it("preset 8 with exactly 8 ids: a literal 2x4 grid", () => {
    const tree = buildLayoutTree(["a", "b", "c", "d", "e", "f", "g", "h"], 8);
    expect(tree).toEqual(column([row(["a", "b", "c", "d"]), row(["e", "f", "g", "h"])]));
  });

  it("fewer ids than the preset's nominal count: fits in one row, no pointless empty panes or column wrap", () => {
    // 2 checked agents but the "4" (2x2) preset chosen — no placeholder
    // panes for the unchecked slots, just the 2 real ones arranged as a
    // single row (the preset is a hint, never an enforced slot count).
    expect(buildLayoutTree(["a", "b"], 4)).toEqual(row(["a", "b"]));
  });

  it("odd leftover row gets a bare leaf, not a pointless 1-child split", () => {
    const tree = buildLayoutTree(["a", "b", "c"], 4);
    expect(tree).toEqual(column([row(["a", "b"]), "c"]));
  });

  it("more ids than the preset's nominal count: extra panes just make another row, nothing is dropped", () => {
    // 5 checked agents with the "4" (2x2, cols=2) preset chosen -> 3 rows
    // of up to 2 rather than silently discarding the 5th selection.
    const tree = buildLayoutTree(["a", "b", "c", "d", "e"], 4);
    expect(tree).toEqual(column([row(["a", "b"]), row(["c", "d"]), "e"]));
    expect(paneIds(tree).sort()).toEqual(["a", "b", "c", "d", "e"]);
  });

  it("every id from the input is present exactly once in the built tree, for every preset", () => {
    const ids = ["a", "b", "c", "d", "e", "f", "g"];
    for (const preset of LAYOUT_PRESETS) {
      const tree = buildLayoutTree(ids, preset);
      expect(paneIds(tree).sort()).toEqual([...ids].sort());
    }
  });
});

describe("addPaneSubtree — a new session's panes join the project's grid", () => {
  it("an empty grid becomes the sub-tree itself", () => {
    expect(addPaneSubtree(null, row(["a", "b"]))).toEqual(row(["a", "b"]));
  });

  it("a single-leaf grid pairs with the sub-tree in a row split", () => {
    expect(addPaneSubtree("a", row(["b", "c"]))).toEqual(row(["a", row(["b", "c"])]));
  });

  it("appends to the existing root split rather than re-wrapping it", () => {
    // The mount-stability rule: every already-open pane keeps its exact tree
    // path, so its live <Terminal> is never remounted (see addPane's doc).
    const before = row(["a", "b"]);
    const after = addPaneSubtree(before, column(["c", "d"]));
    expect(after).toEqual(row(["a", "b", column(["c", "d"])]));
    const children = (after as { children: PaneTree[] }).children;
    expect(children[0]).toBe("a");
    expect(children[1]).toBe("b");
  });

  it("keeps every existing and incoming id exactly once", () => {
    const after = addPaneSubtree(column([row(["a", "b"]), "c"]), row(["d", "e"]));
    expect(paneIds(after).sort()).toEqual(["a", "b", "c", "d", "e"]);
  });

  it("drops incoming ids that are already on the grid", () => {
    const after = addPaneSubtree(row(["a", "b"]), row(["b", "c"]));
    expect(paneIds(after)).toEqual(["a", "b", "c"]);
  });

  it("is a no-op when the sub-tree adds nothing new", () => {
    const before = row(["a", "b"]);
    expect(addPaneSubtree(before, "a")).toBe(before);
    expect(addPaneSubtree(before, row(["a", "b"]))).toBe(before);
  });

  it("a sub-tree built for the chosen preset lands with its arrangement intact", () => {
    const subtree = buildLayoutTree(["s1", "s2", "s3", "s4"], 4);
    const after = addPaneSubtree("existing", subtree!);
    expect(after).toEqual(row(["existing", column([row(["s1", "s2"]), row(["s3", "s4"])])]));
  });
});
