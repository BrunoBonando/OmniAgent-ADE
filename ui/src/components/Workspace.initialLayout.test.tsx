// Regression coverage for NewWorkspaceModal's LAYOUT presets actually
// landing as the *starting arrangement* of a brand-new project's pane
// grid, not just as a value `buildLayoutTree` (paneGrid.ts) computes in
// isolation. `ProjectPaneGrid`'s `tree` state is otherwise built purely by
// `syncPaneTree`/`addPane` (see Workspace.tsx's own module doc), which
// always appends new panes as flat siblings of the root split — on its
// own it can never produce an actual 2x2/2x3/2x4 grid. The `initialTree`
// prop (looked up per-project from the `initialLayouts` map App.tsx
// passes down) is what lets a freshly-created workspace's very first
// render skip straight to the chosen preset's real shape.
//
// react-mosaic-component (real library, not mocked) renders every leaf as
// a `.mosaic-tile` positioned via inline `top`/`left`/`width`/`height`
// percentages computed from the tree's bounding-box splits (see
// `node_modules/react-mosaic-component/lib/MosaicRoot.cjs`'s
// `renderRecursively`) — so the *number of distinct top/left offsets*
// among the rendered tiles is a real, DOM-level fingerprint of the tree's
// shape: a flat row of N tiles has 1 distinct top and N distinct lefts; an
// R-row grid has R distinct tops. This test reads that fingerprint
// directly rather than reaching into React internals for the tree.
//
// `Terminal`/`PaneHeader` are stubbed to trivial probes — this test is
// about grid geometry, not terminal rendering (already covered by
// `Workspace.visibility.test.tsx` and `Workspace.mountStability.test.tsx`).
import { render } from "@testing-library/react";
import { describe, expect, it, vi } from "vitest";
import { buildLayoutTree } from "../state/paneGrid";
import type { ProjectInfo, TabInfo } from "../state/sessions";

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

function tab(id: string, projectId: string): TabInfo {
  return { id, project: projectId, engine: "claude", cwd: `/tmp/${projectId}`, createdAt: 0, needsAttention: false };
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

describe("Workspace — NewWorkspaceModal's initialLayouts seeds a brand-new project's grid shape", () => {
  it("with an initialLayouts entry matching the 2x2 preset, renders a real 2-row x 2-col grid (not a flat row)", () => {
    const p1 = project("p1");
    const tabs = [tab("a", "p1"), tab("b", "p1"), tab("c", "p1"), tab("d", "p1")];
    const initialLayouts = new Map([["p1", buildLayoutTree(["a", "b", "c", "d"], 4)!]]);

    const { container } = render(
      <Workspace
        projects={[p1]}
        tabs={tabs}
        activeTabId="d"
        selectedProjectId="p1"
        selectedProjectLabel="p1"
        onActivateTab={noop}
        onCloseTab={noop}
        onNewTabInProject={noop}
        onRenameTab={noop}
        hidden={false}
        initialLayouts={initialLayouts}
      />,
    );

    const positions = tilePositions(container);
    expect(positions).toHaveLength(4);
    const tops = new Set(positions.map((p) => p.top));
    const lefts = new Set(positions.map((p) => p.left));
    // A literal 2x2 grid: exactly 2 distinct row offsets, 2 distinct
    // column offsets — a flat row of 4 would instead be 1 top x 4 lefts.
    expect(tops.size).toBe(2);
    expect(lefts.size).toBe(2);
  });

  it("without a matching initialLayouts entry, falls back to the ordinary flat-row arrangement (unchanged existing behavior)", () => {
    const p1 = project("p1");
    const tabs = [tab("a", "p1"), tab("b", "p1"), tab("c", "p1"), tab("d", "p1")];

    const { container } = render(
      <Workspace
        projects={[p1]}
        tabs={tabs}
        activeTabId="d"
        selectedProjectId="p1"
        selectedProjectLabel="p1"
        onActivateTab={noop}
        onCloseTab={noop}
        onNewTabInProject={noop}
        onRenameTab={noop}
        hidden={false}
      />,
    );

    const positions = tilePositions(container);
    expect(positions).toHaveLength(4);
    const tops = new Set(positions.map((p) => p.top));
    const lefts = new Set(positions.map((p) => p.left));
    expect(tops.size).toBe(1);
    expect(lefts.size).toBe(4);
  });

  it("an initialLayouts entry for a DIFFERENT project never gets applied to this one (keyed lookup, not first-match)", () => {
    const p1 = project("p1");
    const tabs = [tab("a", "p1"), tab("b", "p1")];
    // Deliberately mismatched: an entry under a different project id, plus
    // one for p1 that doesn't match its actual ids — neither should apply.
    const initialLayouts = new Map([
      ["someone-elses-project", buildLayoutTree(["x", "y", "z", "w"], 4)!],
    ]);

    const { container } = render(
      <Workspace
        projects={[p1]}
        tabs={tabs}
        activeTabId="b"
        selectedProjectId="p1"
        selectedProjectLabel="p1"
        onActivateTab={noop}
        onCloseTab={noop}
        onNewTabInProject={noop}
        onRenameTab={noop}
        hidden={false}
        initialLayouts={initialLayouts}
      />,
    );

    // Ordinary 2-pane flat row: 1 top, 2 lefts.
    const positions = tilePositions(container);
    expect(positions).toHaveLength(2);
    expect(new Set(positions.map((p) => p.top)).size).toBe(1);
    expect(new Set(positions.map((p) => p.left)).size).toBe(2);
  });
});
