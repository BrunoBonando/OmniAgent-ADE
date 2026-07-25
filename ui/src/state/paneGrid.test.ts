import { describe, expect, it } from "vitest";
import { addPane, paneIds, removePane, syncPaneTree } from "./paneGrid";
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
});
