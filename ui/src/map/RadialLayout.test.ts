import { describe, expect, it } from "vitest";
import { applyRadialPositions, clearPins, computeRadialHubPositions } from "./RadialLayout";

describe("computeRadialHubPositions", () => {
  it("returns [] for zero hubs", () => {
    expect(computeRadialHubPositions([], 100)).toEqual([]);
  });

  it("places a single hub at the top of the ring", () => {
    const [p] = computeRadialHubPositions(["only"], 100);
    expect(p.x).toBeCloseTo(0, 6);
    expect(p.y).toBeCloseTo(-100, 6);
  });

  it("evenly spaces 4 hubs at 12/3/6/9 o'clock", () => {
    const points = computeRadialHubPositions(["a", "b", "c", "d"], 100);
    expect(points).toHaveLength(4);
    // top
    expect(points[0].x).toBeCloseTo(0, 6);
    expect(points[0].y).toBeCloseTo(-100, 6);
    // right
    expect(points[1].x).toBeCloseTo(100, 6);
    expect(points[1].y).toBeCloseTo(0, 6);
    // bottom
    expect(points[2].x).toBeCloseTo(0, 6);
    expect(points[2].y).toBeCloseTo(100, 6);
    // left
    expect(points[3].x).toBeCloseTo(-100, 6);
    expect(points[3].y).toBeCloseTo(0, 6);
  });

  it("every point sits exactly `radius` from the center, for any n", () => {
    const points = computeRadialHubPositions(
      ["a", "b", "c", "d", "e", "f", "g"],
      42,
      10,
      -5,
    );
    for (const p of points) {
      const dist = Math.hypot(p.x - 10, p.y - -5);
      expect(dist).toBeCloseTo(42, 6);
    }
  });

  it("consecutive points are separated by exactly 2π/n radians", () => {
    const n = 6;
    const points = computeRadialHubPositions(
      Array.from({ length: n }, (_, i) => `h${i}`),
      50,
    );
    const angles = points.map((p) => Math.atan2(p.y, p.x));
    const expectedDelta = (2 * Math.PI) / n;
    for (let i = 1; i < angles.length; i++) {
      let delta = angles[i] - angles[i - 1];
      if (delta < 0) delta += 2 * Math.PI;
      expect(delta).toBeCloseTo(expectedDelta, 6);
    }
  });

  it("respects a custom center offset", () => {
    const [p] = computeRadialHubPositions(["only"], 10, 500, 300);
    expect(p.x).toBeCloseTo(500, 6);
    expect(p.y).toBeCloseTo(290, 6); // 300 - radius
  });

  it("ids in the output match the input ids, in order", () => {
    const points = computeRadialHubPositions(["z", "y", "x"], 10);
    expect(points.map((p) => p.id)).toEqual(["z", "y", "x"]);
  });
});

describe("applyRadialPositions", () => {
  it("pins hub nodes to their ring position and unpins everything else", () => {
    const nodes = [
      { id: "hub-a" },
      { id: "hub-b" },
      { id: "leaf-1", fx: 5, fy: 5 }, // previously pinned by a stale hub id
    ];
    applyRadialPositions(nodes, ["hub-a", "hub-b"], 100);

    const hubA = nodes.find((n) => n.id === "hub-a")!;
    const hubB = nodes.find((n) => n.id === "hub-b")!;
    const leaf = nodes.find((n) => n.id === "leaf-1")!;

    expect(hubA.fx).toBeCloseTo(0, 6); // 1st of 2 -> top (12 o'clock)
    expect(hubA.fy).toBeCloseTo(-100, 6);
    expect(hubB.fx).toBeCloseTo(0, 6); // 2nd of 2 -> +180deg from top -> bottom
    expect(hubB.fy).toBeCloseTo(100, 6);
    expect(leaf.fx).toBeNull();
    expect(leaf.fy).toBeNull();
  });

  it("is a no-op-safe call with zero hubs — every node gets unpinned", () => {
    const nodes = [{ id: "a", fx: 1, fy: 1 }];
    applyRadialPositions(nodes, [], 100);
    expect(nodes[0].fx).toBeNull();
    expect(nodes[0].fy).toBeNull();
  });
});

describe("clearPins", () => {
  it("nulls fx/fy on every node", () => {
    const nodes = [
      { id: "a", fx: 1, fy: 2 },
      { id: "b", fx: -3, fy: 4 },
    ];
    clearPins(nodes);
    expect(nodes.every((n) => n.fx === null && n.fy === null)).toBe(true);
  });
});
