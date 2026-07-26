// Regression coverage for NewWorkspaceModal's LAYOUT presets actually
// landing as the *starting arrangement* of a brand-new project's pane
// grid, not just as a value `buildLayoutTree` (paneGrid.ts) computes in
// isolation. `ProjectPaneGrid`'s `tree` state is otherwise built purely by
// `syncPaneTree`/`addPane` (see Workspace.tsx's own module doc), which
// always appends new panes as flat siblings of the root split — on its
// own it can never produce an actual 2x2/2x3/2x4 grid. The
// `sessionLayouts` map App.tsx passes down (keyed by session-group id
// since 2026-07-26, when a project gained the ability to hold several
// sessions) is what lets a freshly-created batch of panes land in the
// chosen preset's real shape — as the whole grid for a brand-new project,
// or merged in beside what's already there for a new session inside one.
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

describe("Workspace — a session's layout preset seeds the shape its panes land in", () => {
  it("with a sessionLayouts entry matching the 2x2 preset, renders a real 2-row x 2-col grid (not a flat row)", () => {
    const p1 = project("p1");
    const tabs = [tab("a", "p1"), tab("b", "p1"), tab("c", "p1"), tab("d", "p1")];
    const sessionLayouts = new Map([["g1", buildLayoutTree(["a", "b", "c", "d"], 4)!]]);

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
        sessionLayouts={sessionLayouts}
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

  it("without a matching sessionLayouts entry, falls back to the ordinary flat-row arrangement (unchanged existing behavior)", () => {
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

  it("a sessionLayouts entry for a DIFFERENT session never gets applied to this project (keyed by group, not first-match)", () => {
    const p1 = project("p1");
    const tabs = [tab("a", "p1"), tab("b", "p1")];
    // Deliberately mismatched: an entry under a different project id, plus
    // one for p1 that doesn't match its actual ids — neither should apply.
    const sessionLayouts = new Map([
      ["someone-elses-session", buildLayoutTree(["x", "y", "z", "w"], 4)!],
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
        sessionLayouts={sessionLayouts}
      />,
    );

    // Ordinary 2-pane flat row: 1 top, 2 lefts.
    const positions = tilePositions(container);
    expect(positions).toHaveLength(2);
    expect(new Set(positions.map((p) => p.top)).size).toBe(1);
    expect(new Set(positions.map((p) => p.left)).size).toBe(2);
  });

  it("a second session's preset merges in beside the panes already open, without disturbing them", () => {
    // The ⌘N -> Session case: project p1 already has one pane from session
    // g1; session g2 arrives as a 2x2 batch of four. Result: five tiles,
    // and the four new ones really are arranged as a grid (2 distinct row
    // offsets) rather than flattened into one long row.
    const p1 = project("p1");
    const tabs = [
      tab("a", "p1", "g1"),
      tab("b", "p1", "g2"),
      tab("c", "p1", "g2"),
      tab("d", "p1", "g2"),
      tab("e", "p1", "g2"),
    ];
    const sessionLayouts = new Map([["g2", buildLayoutTree(["b", "c", "d", "e"], 4)!]]);

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
        sessionLayouts={sessionLayouts}
      />,
    );

    const positions = tilePositions(container);
    expect(positions).toHaveLength(5);
    expect(new Set(positions.map((p) => p.top)).size).toBe(2);
  });
});
