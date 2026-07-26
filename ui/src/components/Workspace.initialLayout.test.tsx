// Regression coverage for the founder's approved layout ladder actually
// reaching the DOM: a session's panes are laid out in the shape
// `paneGrid.ts`'s `GRID_LADDER` prescribes for their *count* — 2x1, 2x2, 3x2,
// 3x3, 4x3, 4x4 — no matter how they got there (a bulk create, ⌘T one at a
// time, a close that drops the grid back down a rung). There is deliberately
// no layout hint plumbed from the create dialogs any more: the count IS the
// instruction, which is what makes every path agree.
//
// react-mosaic-component (real library, not mocked) renders every leaf as
// a `.mosaic-tile` positioned via inline `top`/`left`/`width`/`height`
// percentages computed from the tree's bounding-box splits (see
// `node_modules/react-mosaic-component/lib/MosaicRoot.mjs`'s
// `renderRecursively`) — so the *number of distinct top/left offsets* among
// the rendered tiles is a real, DOM-level fingerprint of the tree's shape: a
// flat row of N tiles has 1 distinct top and N distinct lefts; an R-row grid
// has R distinct tops. These tests read that fingerprint directly rather than
// reaching into React internals for the tree.
//
// `Terminal`/`PaneHeader` are stubbed to trivial probes — this test is
// about grid geometry, not terminal rendering (already covered by
// `Workspace.visibility.test.tsx` and `Workspace.mountStability.test.tsx`).
import { render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import type { ProjectInfo, TabInfo } from "../state/sessions";
import { initialAgentsState } from "../state/agents";

vi.mock("./Terminal", () => ({
  default: ({ sessionId }: { sessionId: string }) => <div data-testid={`terminal-${sessionId}`}>{sessionId}</div>,
}));

vi.mock("./PaneHeader", () => ({
  default: ({ tab }: { tab: TabInfo }) => <div>{tab.id}</div>,
}));

const { default: Workspace } = await import("./Workspace");

function project(id: string): ProjectInfo {
  return { id, label: id, path: `/tmp/${id}` };
}

function tab(id: string, projectId: string, group = "g1"): TabInfo {
  return { id, project: projectId, engine: "claude", cwd: `/tmp/${projectId}`, createdAt: 0, group };
}

const noop = () => {};

/** Every `.mosaic-tile`'s (top, left) as rounded numbers — the DOM-level
 * fingerprint of the rendered tree's shape (see this file's module doc). */
function tilePositions(container: HTMLElement): Array<{ top: number; left: number }> {
  return Array.from(container.querySelectorAll<HTMLElement>(".mosaic-tile")).map((el) => ({
    top: Math.round(parseFloat(el.style.top)),
    left: Math.round(parseFloat(el.style.left)),
  }));
}

/** `{ rows, cols }` as the rendered tiles actually report it: one row per
 * distinct top offset, and the width of the FIRST row as the column count —
 * a short final row (5 panes in a 3x2) uses its own wider left offsets, so
 * counting distinct lefts across the whole grid would over-count. */
function renderedShape(container: HTMLElement): { rows: number; cols: number; panes: number } {
  const positions = tilePositions(container);
  const tops = positions.map((p) => p.top);
  const firstRow = Math.min(...tops);
  return {
    rows: new Set(tops).size,
    cols: tops.filter((top) => top === firstRow).length,
    panes: positions.length,
  };
}

function workspaceWith(tabs: TabInfo[]) {
  return (
    <Workspace
      projects={[project("p1")]}
      tabs={tabs}
      activeTabId={tabs[tabs.length - 1]?.id ?? null}
      selectedProjectId="p1"
      onActivateTab={noop}
      onCloseTab={noop}
      onNewTabInProject={noop}
      onRenameTab={noop}
      agentState={initialAgentsState}
      hidden={false}
    />
  );
}

/** n panes in one session of project p1. */
function panes(n: number): TabInfo[] {
  return Array.from({ length: n }, (_, i) => tab(String(i + 1), "p1"));
}

describe("Workspace — a session's panes render in their approved shape", () => {
  it.each([
    [1, { rows: 1, cols: 1 }],
    [2, { rows: 1, cols: 2 }],
    [3, { rows: 2, cols: 2 }],
    [4, { rows: 2, cols: 2 }],
    [5, { rows: 2, cols: 3 }],
    [6, { rows: 2, cols: 3 }],
    [9, { rows: 3, cols: 3 }],
    [12, { rows: 3, cols: 4 }],
    [16, { rows: 4, cols: 4 }],
  ])("%i panes render as a real %o grid", (count, shape) => {
    const { container } = render(workspaceWith(panes(count)));
    expect(renderedShape(container)).toEqual({ ...shape, panes: count });
  });

  it("opening one more terminal reflows the grid up a rung, live", () => {
    const { container, rerender } = render(workspaceWith(panes(2)));
    expect(renderedShape(container)).toEqual({ rows: 1, cols: 2, panes: 2 });

    rerender(workspaceWith(panes(3)));
    expect(renderedShape(container)).toEqual({ rows: 2, cols: 2, panes: 3 });
  });

  it("closing one drops it back down a rung", () => {
    const { container, rerender } = render(workspaceWith(panes(5)));
    expect(renderedShape(container)).toEqual({ rows: 2, cols: 3, panes: 5 });

    rerender(workspaceWith(panes(4)));
    expect(renderedShape(container)).toEqual({ rows: 2, cols: 2, panes: 4 });
  });

  it("each session is shaped by its OWN pane count, not the workspace's", () => {
    // The ⌘N -> Session case: p1 holds one pane in session g1 and four in g2.
    // They don't share a tree (see Workspace.tsx's module doc), so g2 is a
    // 2x2 while g1 stays a single full-bleed pane in its own hidden grid.
    const tabs = [
      tab("a", "p1", "g1"),
      tab("b", "p1", "g2"),
      tab("c", "p1", "g2"),
      tab("d", "p1", "g2"),
      tab("e", "p1", "g2"),
    ];
    const { container } = render(workspaceWith(tabs));
    const gridFor = (group: string) =>
      container.querySelector<HTMLElement>(`.pane-grid-project[data-session="${group}"]`)!;

    const g2 = gridFor("g2");
    expect(g2.style.display).not.toBe("none"); // the focused session is the visible one
    expect(renderedShape(g2)).toEqual({ rows: 2, cols: 2, panes: 4 });

    const g1 = gridFor("g1");
    expect(g1.style.display).toBe("none");
    expect(tilePositions(g1)).toEqual([{ top: 0, left: 0 }]);
  });
});
