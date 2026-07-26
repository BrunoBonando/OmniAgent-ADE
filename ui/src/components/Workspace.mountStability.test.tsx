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
//
// ## Session filtering rides on the SAME rule (2026-07-26)
//
// Founder: *"Inside each workspace (first column) it must show the session
// it's currently on the screen."* Making the grid honour that could not be
// done by rendering only the current session's panes — unmounting the other
// session's `<Terminal>`s is exactly the output-dropping bug above. So
// `Workspace.tsx` renders one always-mounted grid **per session** and
// toggles CSS `display`, the identical treatment cross-project switching
// already got. The last describe block in this file is the regression lock
// for that: real `Workspace`, real mosaic, a mount counter, sessions
// switched back and forth.
import { render } from "@testing-library/react";
import { useEffect } from "react";
import { Mosaic, MosaicWindow, type MosaicNode } from "react-mosaic-component";
import { describe, expect, it, vi } from "vitest";
import { addPane, removePane, type PaneTree } from "../state/paneGrid";
import type { ProjectInfo, TabInfo } from "../state/sessions";

const probes = vi.hoisted(() => ({
  /** Every `<Terminal>` mount, in order — the whole point of this file. A
   * second entry for an id that already mounted IS the bug. */
  terminalMounts: [] as string[],
}));

vi.mock("./Terminal", () => ({
  // `useEffect` is the file's own top-level import: a `vi.mock` factory is
  // lazy (it runs when the mocked module is first imported, which is inside
  // the `await import("./Workspace")` below), so module-scope bindings are
  // initialized by the time this closes over them.
  default: ({ sessionId, visible }: { sessionId: string; visible: boolean }) => {
    useEffect(() => {
      probes.terminalMounts.push(sessionId);
    }, []);
    return <div data-testid={`terminal-${sessionId}`} data-visible={String(visible)} />;
  },
}));

// The pane toolbar makes a real git-branch IPC call; same stub the other
// Workspace tests use.
vi.mock("./PaneHeader", () => ({
  default: ({ tab }: { tab: TabInfo }) => <div>{tab.id}</div>,
}));

const { default: Workspace } = await import("./Workspace");

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

// ---------------------------------------------------------------------------
// Session filtering — the same rule, one level down (founder, 2026-07-26:
// "Inside each workspace (first column) it must show the session it's
// currently on the screen").
//
// These render the REAL `Workspace` (real react-mosaic-component, real
// `paneGrid` reconciliation) with `<Terminal>` swapped for a mount-counting
// probe, and switch sessions the way the app does — by moving `activeTabId`.
// A session switch that unmounted anything would show up as a second entry
// for an id already in `terminalMounts`, and would mean a live agent's
// output stream silently going to nobody.
// ---------------------------------------------------------------------------

function project(id: string): ProjectInfo {
  return { id, label: id, path: `/tmp/${id}` };
}

function tab(id: string, projectId: string, group: string): TabInfo {
  return { id, project: projectId, engine: "claude", cwd: `/tmp/${projectId}`, createdAt: 0, group };
}

const noop = () => {};

/** The grid `Workspace` renders for one session, or null when it renders
 * none — found by the `data-session` attribute the component stamps on each
 * always-mounted per-session grid. */
function sessionGrid(container: HTMLElement, projectId: string, group: string): HTMLElement | null {
  return container.querySelector<HTMLElement>(
    `.pane-grid-project[data-project="${projectId}"][data-session="${group}"]`,
  );
}

function isShown(el: HTMLElement | null): boolean {
  return el !== null && el.style.display !== "none";
}

describe("session filtering shows one session without unmounting the others", () => {
  const p1 = project("p1");
  // One workspace, two sessions: g1 has two panes, g2 has one.
  const tabs = [tab("a", "p1", "g1"), tab("b", "p1", "g1"), tab("c", "p1", "g2")];

  const props = {
    projects: [p1],
    tabs,
    selectedProjectId: "p1",
    selectedProjectLabel: "p1",
    onActivateTab: noop,
    onCloseTab: noop,
    onNewTabInProject: noop,
    onRenameTab: noop,
    hidden: false,
  };

  it("mounts every session's terminals up front, and shows only the current one", () => {
    probes.terminalMounts = [];
    const { container } = render(<Workspace {...props} activeTabId="a" />);

    // Every terminal in the workspace is mounted, including the session
    // that isn't on screen — that is the whole design.
    expect([...probes.terminalMounts].sort()).toEqual(["a", "b", "c"]);

    // …but only the focused session's grid is displayed.
    expect(isShown(sessionGrid(container, "p1", "g1"))).toBe(true);
    expect(isShown(sessionGrid(container, "p1", "g2"))).toBe(false);
  });

  it("switching sessions back and forth never remounts a single terminal", () => {
    probes.terminalMounts = [];
    const { container, rerender } = render(<Workspace {...props} activeTabId="a" />);
    expect(probes.terminalMounts).toHaveLength(3);

    // Focus a pane in the other session — the sidebar's session row does
    // exactly this (`onActivateTab(session.tabs[0].id)`).
    rerender(<Workspace {...props} activeTabId="c" />);
    expect(isShown(sessionGrid(container, "p1", "g1"))).toBe(false);
    expect(isShown(sessionGrid(container, "p1", "g2"))).toBe(true);

    // …and back.
    rerender(<Workspace {...props} activeTabId="b" />);
    expect(isShown(sessionGrid(container, "p1", "g1"))).toBe(true);
    expect(isShown(sessionGrid(container, "p1", "g2"))).toBe(false);

    // Three switches later, still exactly three mounts. Every terminal kept
    // its scrollback and its `session-output:{id}` subscription.
    expect(probes.terminalMounts).toHaveLength(3);
    expect([...probes.terminalMounts].sort()).toEqual(["a", "b", "c"]);
  });

  it("tells the hidden session's terminals they are not visible", () => {
    // `Terminal.tsx` refits/refocuses on becoming visible; a pane in a
    // session nobody is looking at must not claim focus. Same `visible`
    // contract cross-project switching already had.
    const { container, rerender } = render(<Workspace {...props} activeTabId="a" />);
    const visibility = (id: string) =>
      container.querySelector<HTMLElement>(`[data-testid="terminal-${id}"]`)?.dataset.visible;

    expect(visibility("a")).toBe("true");
    expect(visibility("b")).toBe("true");
    expect(visibility("c")).toBe("false");

    rerender(<Workspace {...props} activeTabId="c" />);
    expect(visibility("a")).toBe("false");
    expect(visibility("c")).toBe("true");
  });

  it("keeps a session's own panes laid out together, not scattered across the workspace", () => {
    // g1's two panes share a grid; g2's one pane has its own. A session
    // with panes across the grid still lays out as that session's grid.
    const { container } = render(<Workspace {...props} activeTabId="a" />);
    const g1 = sessionGrid(container, "p1", "g1")!;
    const g2 = sessionGrid(container, "p1", "g2")!;

    expect(g1.querySelectorAll(".mosaic-tile")).toHaveLength(2);
    expect(g2.querySelectorAll(".mosaic-tile")).toHaveLength(1);
  });

  it("still never unmounts anything when the WORKSPACE is switched (the older guarantee, unchanged)", () => {
    probes.terminalMounts = [];
    const p2 = project("p2");
    const two = [...tabs, tab("d", "p2", "g3")];
    const both = { ...props, projects: [p1, p2], tabs: two };

    const { container, rerender } = render(<Workspace {...both} selectedProjectId="p1" activeTabId="a" />);
    expect(probes.terminalMounts).toHaveLength(4);

    rerender(<Workspace {...both} selectedProjectId="p2" activeTabId="d" />);
    expect(isShown(sessionGrid(container, "p2", "g3"))).toBe(true);
    expect(isShown(sessionGrid(container, "p1", "g1"))).toBe(false);

    rerender(<Workspace {...both} selectedProjectId="p1" activeTabId="a" />);
    expect(probes.terminalMounts).toHaveLength(4);
  });

  it("closing one pane of a session leaves its sibling — and the other session — mounted", () => {
    probes.terminalMounts = [];
    const { rerender } = render(<Workspace {...props} activeTabId="a" />);
    expect(probes.terminalMounts).toHaveLength(3);

    rerender(<Workspace {...props} tabs={[tab("a", "p1", "g1"), tab("c", "p1", "g2")]} activeTabId="a" />);
    // 'b' went away; nothing else was rebuilt.
    expect(probes.terminalMounts).toHaveLength(3);
  });
});
