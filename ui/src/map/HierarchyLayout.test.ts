import { describe, expect, it } from "vitest";
import { dagLevelDistanceFor, hierarchyLinks, hierarchyRoots } from "./HierarchyLayout";

const link = (source: string, target: string, kind: string) => ({ source, target, kind });

describe("hierarchyLinks", () => {
  it("keeps only 'contains' edges", () => {
    const links = [
      link("p1", "p1:community:0", "contains"),
      link("p1:a.ts", "p1:b.ts", "imports"),
      link("p1:community:0", "p1:a.ts", "contains"),
      link("p1:a.ts", "p1:notes.md", "references"),
    ];
    const result = hierarchyLinks(links);
    expect(result).toHaveLength(2);
    expect(result.every((l) => l.kind === "contains")).toBe(true);
  });

  it("returns [] when there are no containment edges", () => {
    expect(hierarchyLinks([link("a", "b", "imports")])).toEqual([]);
  });

  it("preserves the original link objects (no field loss)", () => {
    const links = [{ source: "a", target: "b", kind: "contains", weight: 3.5 }];
    expect(hierarchyLinks(links)).toEqual(links);
  });
});

describe("hierarchyRoots", () => {
  it("finds nodes that are never a containment target", () => {
    const hier = [
      link("p1", "p1:community:0", "contains"),
      link("p1", "p1:community:1", "contains"),
      link("p2", "p2:community:0", "contains"),
    ];
    const roots = hierarchyRoots(["p1", "p2", "p1:community:0", "p1:community:1", "p2:community:0"], hier);
    expect(roots.sort()).toEqual(["p1", "p2"]);
  });

  it("every node is a root when there are no containment edges", () => {
    expect(hierarchyRoots(["a", "b"], [])).toEqual(["a", "b"]);
  });

  it("a node with a parent is excluded even if it also has children", () => {
    const hier = [link("root", "mid", "contains"), link("mid", "leaf", "contains")];
    const roots = hierarchyRoots(["root", "mid", "leaf"], hier);
    expect(roots).toEqual(["root"]);
  });
});

describe("dagLevelDistanceFor", () => {
  it("never goes below the base distance for tiny graphs", () => {
    expect(dagLevelDistanceFor(0)).toBe(70);
    expect(dagLevelDistanceFor(1)).toBeGreaterThanOrEqual(70);
  });

  it("grows with node count but is capped", () => {
    const small = dagLevelDistanceFor(10);
    const large = dagLevelDistanceFor(5000);
    expect(large).toBeGreaterThan(small);
    expect(large).toBeLessThanOrEqual(220);
  });
});
