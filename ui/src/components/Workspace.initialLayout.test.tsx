// Regression coverage for the founder's approved layout ladder actually
// reaching the DOM: a session's panes are laid out in the shape
// `paneGrid.ts`'s `GRID_LADDER` prescribes for their *count* — 1x2, 2x2, 2x3,
// 2x4, capped at 8 — no matter how they got there (a bulk create, ⌘T one at a
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
import { fireEvent, render, screen } from "@testing-library/react";
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

function workspaceWith(tabs: TabInfo[], onNewTabInProject: (p: ProjectInfo) => void = noop) {
  return (
    <Workspace
      projects={[project("p1")]}
      tabs={tabs}
      activeTabId={tabs[tabs.length - 1]?.id ?? null}
      selectedProjectId="p1"
      onActivateTab={noop}
      onCloseTab={noop}
      onNewTabInProject={onNewTabInProject}
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
  // `panes` here is the total CELL count (`rows * cols`), not the pane count
  // passed in: a count that doesn't exactly fill the rung (3, 5, 7) still
  // renders the full rectangle, the leftover cell(s) a hole (see the
  // dedicated hole tests below) — so `.mosaic-tile` count is always the
  // rung's full capacity.
  it.each([
    [1, { rows: 1, cols: 1 }],
    [2, { rows: 1, cols: 2 }],
    [3, { rows: 2, cols: 2 }],
    [4, { rows: 2, cols: 2 }],
    [5, { rows: 2, cols: 3 }],
    [6, { rows: 2, cols: 3 }],
    [7, { rows: 2, cols: 4 }],
    [8, { rows: 2, cols: 4 }],
  ])("%i panes render as a real %o grid", (count, shape) => {
    const { container } = render(workspaceWith(panes(count)));
    expect(renderedShape(container)).toEqual({ ...shape, panes: shape.rows * shape.cols });
  });

  it("opening one more terminal reflows the grid up a rung, live", () => {
    const { container, rerender } = render(workspaceWith(panes(2)));
    expect(renderedShape(container)).toEqual({ rows: 1, cols: 2, panes: 2 });

    rerender(workspaceWith(panes(3)));
    expect(renderedShape(container)).toEqual({ rows: 2, cols: 2, panes: 4 }); // 3 real + 1 hole
  });

  it("closing one drops it back down a rung", () => {
    const { container, rerender } = render(workspaceWith(panes(5)));
    expect(renderedShape(container)).toEqual({ rows: 2, cols: 3, panes: 6 }); // 5 real + 1 hole

    rerender(workspaceWith(panes(4)));
    expect(renderedShape(container)).toEqual({ rows: 2, cols: 2, panes: 4 });
  });

  it("a count that doesn't fill the rung renders the leftover cell as a hole, not a real pane", () => {
    // 3 panes -> the 2x2 rung: a real gradient-filled placeholder in the 4th
    // cell (founder, 2026-07-26: "if a number of terminals is not even, it's
    // okay to have a hole in the matrix... represented by gradient dark
    // blue, just like the one from when it's without terminals"), never a
    // 4th terminal and never a shrunk 2-then-1 shape.
    const { container } = render(workspaceWith(panes(3)));
    const holes = container.querySelectorAll(".pane-hole");
    expect(holes).toHaveLength(1);
    expect(holes[0].querySelector("[data-testid^='terminal-']")).toBeNull();
    expect(container.querySelectorAll("[data-testid^='terminal-']")).toHaveLength(3);
  });

  it("the hole is an Add Terminal button — clicking it opens one more terminal here", () => {
    // Founder, 2026-07-26: "on the blank space... a small square button with
    // an image of a terminal and a text under saying: add Terminal". Wired to
    // the same handler as the pane header's split, and the new terminal fills
    // exactly this cell (`buildGrid`'s bottom-of-column fill).
    const onNewTab = vi.fn();
    render(workspaceWith(panes(3), onNewTab));
    fireEvent.click(screen.getByRole("button", { name: /add terminal/i }));
    expect(onNewTab).toHaveBeenCalledWith(project("p1"));
  });

  it("the new pane lands top of the new column; nobody already open changes cell (4 -> 5)", () => {
    // Founder, 2026-07-26: "the new terminal would simply always start on top
    // right if full or bottom if not full". At 4 (full 2x2), pane 5 appears
    // top-right with the hole under it. Column widths re-divide (50% -> 33%),
    // so the invariant is each pane's CELL — its row, and its column's rank.
    const cellOf = (container: HTMLElement, id: string) => {
      const t = tileOf(container, id);
      const lefts = [...new Set(tilePositions(container).map((p) => p.left))].sort((a, b) => a - b);
      return {
        row: Math.round(parseFloat(t.style.top)) === 0 ? 0 : 1,
        col: lefts.indexOf(Math.round(parseFloat(t.style.left))),
      };
    };
    const { container, rerender } = render(workspaceWith(panes(4)));
    expect(cellOf(container, "1")).toEqual({ row: 0, col: 0 });
    expect(cellOf(container, "2")).toEqual({ row: 1, col: 0 });
    expect(cellOf(container, "3")).toEqual({ row: 0, col: 1 });
    expect(cellOf(container, "4")).toEqual({ row: 1, col: 1 });

    rerender(workspaceWith(panes(5)));
    // Panes 1-4 keep their cells; 5 tops the new third column, the hole under it.
    expect(cellOf(container, "1")).toEqual({ row: 0, col: 0 });
    expect(cellOf(container, "2")).toEqual({ row: 1, col: 0 });
    expect(cellOf(container, "3")).toEqual({ row: 0, col: 1 });
    expect(cellOf(container, "4")).toEqual({ row: 1, col: 1 });
    expect(cellOf(container, "5")).toEqual({ row: 0, col: 2 });
    const hole = container.querySelector<HTMLElement>(".pane-hole")!.closest<HTMLElement>(".mosaic-tile")!;
    expect(Math.round(parseFloat(hole.style.top))).toBe(50);
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

// ---------------------------------------------------------------------------
// Drag one terminal onto another to trade places (founder ask, 2026-07-26:
// "Make dragged terminal able to exchange places with another terminal...
// while dragging I see the square being highlighted, indicating it will
// change places"). The header is a plain HTML5 drag handle and the pane body
// is the drop zone — react-mosaic's own header drag (edge drops, which build
// a split the ladder above would never produce) is off. A swap is the one
// rearrangement that can't leave the approved shape, so these assert both
// halves: the panes traded positions, and the geometry didn't move.
// ---------------------------------------------------------------------------

/** The `.mosaic-tile` currently holding pane `id` — found through the probe
 * `<Terminal>` stub, so it follows the pane wherever the swap puts it. */
function tileOf(container: HTMLElement, id: string): HTMLElement {
  return Array.from(container.querySelectorAll<HTMLElement>(".mosaic-tile")).find((el) =>
    el.querySelector(`[data-testid="terminal-${id}"]`),
  )!;
}

/** Which pane sits at a given tile offset — "left column" is `left: 0`. */
function paneAt(container: HTMLElement, left: number): string | undefined {
  const tile = Array.from(container.querySelectorAll<HTMLElement>(".mosaic-tile")).find(
    (el) => Math.round(parseFloat(el.style.left)) === left,
  );
  return tile?.querySelector<HTMLElement>("[data-testid^='terminal-']")?.textContent ?? undefined;
}

describe("Workspace — dragging a terminal onto another exchanges their places", () => {
  const dataTransfer = { setData: () => {}, effectAllowed: "" };

  it("swaps the two panes and leaves the grid's shape alone", () => {
    const { container } = render(workspaceWith(panes(2)));
    expect(paneAt(container, 0)).toBe("1");
    expect(paneAt(container, 50)).toBe("2");

    // Drag the right-hand terminal onto the left one, the founder's example.
    fireEvent.dragStart(tileOf(container, "2").querySelector(".pane-toolbar-wrap")!, { dataTransfer });
    const target = tileOf(container, "1").querySelector<HTMLElement>(".pane-body")!;
    fireEvent.dragOver(target);

    // The affordance: the pane about to be traded with lights up.
    expect(target.className).toContain("is-swap-target");

    fireEvent.drop(target);
    expect(paneAt(container, 0)).toBe("2");
    expect(paneAt(container, 50)).toBe("1");
    expect(renderedShape(container)).toEqual({ rows: 1, cols: 2, panes: 2 });
  });

  it("swaps across rows too, and highlights nothing once the drag ends", () => {
    const { container } = render(workspaceWith(panes(4))); // 2x2: [1,2] / [3,4]
    fireEvent.dragStart(tileOf(container, "4").querySelector(".pane-toolbar-wrap")!, { dataTransfer });
    const target = tileOf(container, "1").querySelector<HTMLElement>(".pane-body")!;
    fireEvent.dragOver(target);
    fireEvent.drop(target);

    expect(tileOf(container, "4").style.top).toBe("0%");
    expect(tileOf(container, "1").style.top).toBe("50%");
    expect(renderedShape(container)).toEqual({ rows: 2, cols: 2, panes: 4 });
    expect(container.querySelector(".is-swap-target")).toBeNull();
  });

  it("dropping a pane on itself changes nothing", () => {
    const { container } = render(workspaceWith(panes(2)));
    const own = tileOf(container, "1");
    fireEvent.dragStart(own.querySelector(".pane-toolbar-wrap")!, { dataTransfer });
    const body = own.querySelector<HTMLElement>(".pane-body")!;
    fireEvent.dragOver(body);
    expect(body.className).not.toContain("is-swap-target");

    fireEvent.drop(body);
    expect(paneAt(container, 0)).toBe("1");
    expect(paneAt(container, 50)).toBe("2");
  });
});
