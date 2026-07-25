// Regression coverage for the single hardest constraint in the BridgeSpace
// pane-grid rebuild: a live session's `<Terminal>` must never unmount,
// because `sessions.rs` only streams `session-output:{id}` events to
// whoever is subscribed *right now* — an unmount+remount silently drops
// whatever the PTY printed in between (see `Terminal.tsx`'s own module
// doc). `Workspace.tsx` renders `<Terminal>` directly inside
// `react-mosaic-component`'s `renderTile` (no portal — an earlier version
// of this file tried portaling to a stable container to dodge this
// problem, but a hand-written experiment proved react-dom's `createPortal`
// does *not* preserve a child's identity across a container change, even
// with a matching `key`, so the portal indirection bought nothing and was
// removed).
//
// What actually protects mount stability is `paneGrid.ts`'s `addPane`/
// `removePane` shape: react-mosaic-component's `MosaicRoot` keys
// intermediate split nodes by *tree path* (see that library's
// `MosaicRoot.tsx`), so a leaf whose parent path changes gets discarded
// and remounted by React, regardless of the leaf's own stable key. These
// tests render the *real* library (not a mock) and assert, with a mount
// counter, exactly which tree edits are safe — this is what caught the
// original `addPane` implementation (wrap the *whole* existing tree in a
// new split on every add) silently remounting every already-open pane's
// terminal each time a new one opened.
import { render } from "@testing-library/react";
import { useEffect } from "react";
import { Mosaic, MosaicWindow, type MosaicNode } from "react-mosaic-component";
import { describe, expect, it } from "vitest";
import { addPane, removePane, type PaneTree } from "../state/paneGrid";

let mounts: string[] = [];

function Probe({ id }: { id: string }) {
  useEffect(() => {
    mounts.push(id);
  }, [id]);
  return <div>{id}</div>;
}

function Harness({ tree }: { tree: PaneTree | null }) {
  return (
    <Mosaic<string>
      value={tree as MosaicNode<string> | null}
      onChange={() => {}}
      renderTile={(id, path) => (
        <MosaicWindow<string> path={path} title={id}>
          <Probe id={id} />
        </MosaicWindow>
      )}
    />
  );
}

describe("mount stability against the real react-mosaic-component library", () => {
  it("opening a 2nd, 3rd, and 4th pane via addPane never remounts the ones already open", () => {
    mounts = [];
    let tree: PaneTree | null = null;
    const { rerender } = render(<Harness tree={tree} />);

    tree = addPane(tree, "a");
    rerender(<Harness tree={tree} />);
    expect(mounts).toEqual(["a"]);

    tree = addPane(tree, "b");
    rerender(<Harness tree={tree} />);
    expect(mounts).toEqual(["a", "b"]); // 'a' did not remount

    tree = addPane(tree, "c");
    rerender(<Harness tree={tree} />);
    expect(mounts).toEqual(["a", "b", "c"]); // neither 'a' nor 'b' remounted

    tree = addPane(tree, "d");
    rerender(<Harness tree={tree} />);
    expect(mounts).toEqual(["a", "b", "c", "d"]);
  });

  it("closing one pane out of several never remounts the survivors", () => {
    mounts = [];
    let tree: PaneTree | null = "a";
    tree = addPane(tree, "b");
    tree = addPane(tree, "c");
    const { rerender } = render(<Harness tree={tree} />);
    expect(mounts).toEqual(["a", "b", "c"]);

    tree = removePane(tree, "b");
    rerender(<Harness tree={tree} />);
    expect(mounts).toEqual(["a", "b", "c"]); // no new entries — 'a' and 'c' stayed mounted
  });

  it("resizing (splitPercentages only) never remounts any pane", () => {
    mounts = [];
    const before: PaneTree = { type: "split", direction: "row", children: ["a", "b"], splitPercentages: [50, 50] };
    const { rerender } = render(<Harness tree={before} />);
    expect(mounts).toEqual(["a", "b"]);

    const resized: PaneTree = { type: "split", direction: "row", children: ["a", "b"], splitPercentages: [30, 70] };
    rerender(<Harness tree={resized} />);
    expect(mounts).toEqual(["a", "b"]);
  });

  it("documents the known gap: a topology-changing drag-rearrange DOES remount the panes whose nesting depth changes", () => {
    // This is a real, verified limitation of rendering directly in
    // `renderTile` (portals don't fix it either — see the module doc
    // above), not something this task's scope covers a full fix for.
    // Opening/closing/resizing — the interactions the founder actually
    // asked for and the overwhelming majority of real usage — are all
    // unaffected (see the other tests in this file). Only a user
    // physically dragging one pane's header onto a *different* pane's
    // edge (forcing a brand-new split, not just reordering within the
    // existing one) hits this. Left as a documented follow-up rather than
    // fixed here — see the task report for the suggested mitigation.
    mounts = [];
    const before: PaneTree = { type: "split", direction: "row", children: ["a", "b", "c"] };
    const { rerender } = render(<Harness tree={before} />);
    expect(mounts).toEqual(["a", "b", "c"]);

    // Equivalent to dragging 'a' onto 'c's edge: 'a' now nests under a new
    // split alongside 'c', while 'b' stays a root-level sibling.
    const afterDrag: PaneTree = {
      type: "split",
      direction: "row",
      children: ["b", { type: "split", direction: "column", children: ["c", "a"] }],
    };
    mounts = [];
    rerender(<Harness tree={afterDrag} />);
    // 'b' keeps its root-level path and survives; 'a' and 'c' both moved
    // to a new path and both remount.
    expect(mounts.sort()).toEqual(["a", "c"]);
  });
});
