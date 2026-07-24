import { describe, expect, it } from "vitest";
import { mergeGraphData, transformMapGraph, type GraphData } from "./graphTransform";
import type { MapGraph } from "../lib/tauri";

describe("transformMapGraph", () => {
  it("maps src/dst -> source/target and keeps kind/weight", () => {
    const wire: MapGraph = {
      nodes: [
        { id: "p1", kind: "project", label: "p1", project: "p1", size: 1 },
        { id: "p1:c0", kind: "community", label: "Community 0", project: "p1", size: 4 },
      ],
      links: [{ src: "p1", dst: "p1:c0", kind: "contains", weight: 2.5 }],
    };
    const result = transformMapGraph(wire);
    expect(result.nodes).toEqual(wire.nodes);
    expect(result.links).toEqual([{ source: "p1", target: "p1:c0", kind: "contains", weight: 2.5 }]);
  });

  it("empty graph in, empty graph out", () => {
    expect(transformMapGraph({ nodes: [], links: [] })).toEqual({ nodes: [], links: [] });
  });

  it("returns fresh node object identities every call (no aliasing)", () => {
    const wire: MapGraph = {
      nodes: [{ id: "a", kind: "file", label: "a", project: "p", size: 1 }],
      links: [],
    };
    const first = transformMapGraph(wire);
    const second = transformMapGraph(wire);
    expect(first.nodes[0]).not.toBe(second.nodes[0]);
    expect(first.nodes[0]).toEqual(second.nodes[0]);
  });
});

describe("mergeGraphData", () => {
  it("reuses the existing object identity for ids that persist, preserving simulation position", () => {
    const prev: GraphData = {
      nodes: [{ id: "a", kind: "file", label: "a", project: "p", size: 1, x: 42, y: -7, vx: 0.1, vy: 0.2 }],
      links: [],
    };
    const next: GraphData = {
      nodes: [{ id: "a", kind: "file", label: "a (renamed)", project: "p", size: 1 }],
      links: [],
    };
    const merged = mergeGraphData(prev, next);
    expect(merged.nodes[0]).toBe(prev.nodes[0]); // same object identity
    expect(merged.nodes[0].x).toBe(42); // position preserved
    expect(merged.nodes[0].y).toBe(-7);
    expect(merged.nodes[0].label).toBe("a (renamed)"); // data field refreshed
  });

  it("gives a brand-new id a fresh object (no crash, no stale data)", () => {
    const prev: GraphData = { nodes: [], links: [] };
    const next: GraphData = {
      nodes: [{ id: "new", kind: "file", label: "new", project: "p", size: 1 }],
      links: [],
    };
    const merged = mergeGraphData(prev, next);
    expect(merged.nodes).toEqual(next.nodes);
  });

  it("drops ids that disappeared (collapsed away / filtered out)", () => {
    const prev: GraphData = {
      nodes: [
        { id: "a", kind: "file", label: "a", project: "p", size: 1 },
        { id: "b", kind: "file", label: "b", project: "p", size: 1 },
      ],
      links: [],
    };
    const next: GraphData = {
      nodes: [{ id: "a", kind: "file", label: "a", project: "p", size: 1 }],
      links: [],
    };
    const merged = mergeGraphData(prev, next);
    expect(merged.nodes.map((n) => n.id)).toEqual(["a"]);
  });

  it("always uses next's links verbatim (links aren't merge-preserved, only nodes are)", () => {
    const prev: GraphData = { nodes: [], links: [{ source: "a", target: "b", kind: "imports", weight: 1 }] };
    const next: GraphData = { nodes: [], links: [] };
    const merged = mergeGraphData(prev, next);
    expect(merged.links).toEqual([]);
  });
});
