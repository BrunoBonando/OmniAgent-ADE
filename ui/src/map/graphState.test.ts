import { describe, expect, it } from "vitest";
import { initialMapUiState, mapUiReducer, type MapUiState } from "./graphState";

describe("mapUiReducer — community/expand", () => {
  it("adds an id to the expanded set", () => {
    const s = mapUiReducer(initialMapUiState, { type: "community/expand", id: "c1" });
    expect(s.expanded).toEqual(["c1"]);
  });

  it("is idempotent — expanding the same id twice doesn't duplicate", () => {
    const s1 = mapUiReducer(initialMapUiState, { type: "community/expand", id: "c1" });
    const s2 = mapUiReducer(s1, { type: "community/expand", id: "c1" });
    expect(s2.expanded).toEqual(["c1"]);
    expect(s2).toBe(s1); // no-op returns the same reference
  });

  it("accumulates multiple distinct ids", () => {
    const s1 = mapUiReducer(initialMapUiState, { type: "community/expand", id: "c1" });
    const s2 = mapUiReducer(s1, { type: "community/expand", id: "c2" });
    expect(s2.expanded).toEqual(["c1", "c2"]);
  });
});

describe("mapUiReducer — community/collapseAll", () => {
  it("clears the expanded set (double-click background)", () => {
    const seeded: MapUiState = { ...initialMapUiState, expanded: ["c1", "c2"] };
    const s = mapUiReducer(seeded, { type: "community/collapseAll" });
    expect(s.expanded).toEqual([]);
  });

  it("is a no-op when already empty", () => {
    const s = mapUiReducer(initialMapUiState, { type: "community/collapseAll" });
    expect(s).toBe(initialMapUiState);
  });
});

describe("mapUiReducer — filter/toggle", () => {
  it("adds a kind not yet in the filter", () => {
    const s = mapUiReducer(initialMapUiState, { type: "filter/toggle", kind: "memory" });
    expect(s.filter).toEqual(["memory"]);
  });

  it("removes a kind already in the filter (toggle off)", () => {
    const s1 = mapUiReducer(initialMapUiState, { type: "filter/toggle", kind: "memory" });
    const s2 = mapUiReducer(s1, { type: "filter/toggle", kind: "memory" });
    expect(s2.filter).toEqual([]);
  });

  it("supports multiple kinds simultaneously (an allow-list, matching map_graph's filter param)", () => {
    const s1 = mapUiReducer(initialMapUiState, { type: "filter/toggle", kind: "memory" });
    const s2 = mapUiReducer(s1, { type: "filter/toggle", kind: "decision" });
    expect(s2.filter.sort()).toEqual(["decision", "memory"]);
  });
});

describe("mapUiReducer — filter/clear", () => {
  it("resets to no filtering", () => {
    const seeded: MapUiState = { ...initialMapUiState, filter: ["memory", "decision"] };
    const s = mapUiReducer(seeded, { type: "filter/clear" });
    expect(s.filter).toEqual([]);
  });
});

describe("mapUiReducer — layout/set", () => {
  it("switches layout", () => {
    const s = mapUiReducer(initialMapUiState, { type: "layout/set", layout: "hierarchy" });
    expect(s.layout).toBe("hierarchy");
  });

  it("does not disturb expanded/filter state when switching layouts", () => {
    const seeded: MapUiState = { ...initialMapUiState, expanded: ["c1"], filter: ["file"] };
    const s = mapUiReducer(seeded, { type: "layout/set", layout: "hierarchy" });
    expect(s.expanded).toEqual(["c1"]);
    expect(s.filter).toEqual(["file"]);
  });

  it("is a no-op when already on that layout", () => {
    const s = mapUiReducer(initialMapUiState, { type: "layout/set", layout: "radial" });
    expect(s).toBe(initialMapUiState);
  });
});

describe("mapUiReducer — fullscreen/toggle", () => {
  it("flips the boolean each call", () => {
    const s1 = mapUiReducer(initialMapUiState, { type: "fullscreen/toggle" });
    expect(s1.fullscreen).toBe(true);
    const s2 = mapUiReducer(s1, { type: "fullscreen/toggle" });
    expect(s2.fullscreen).toBe(false);
  });
});

describe("mapUiReducer — node/select", () => {
  it("sets the selected node id, opening the detail panel", () => {
    const s = mapUiReducer(initialMapUiState, { type: "node/select", id: "n1" });
    expect(s.selectedNodeId).toBe("n1");
  });

  it("selecting null closes the detail panel", () => {
    const seeded: MapUiState = { ...initialMapUiState, selectedNodeId: "n1" };
    const s = mapUiReducer(seeded, { type: "node/select", id: null });
    expect(s.selectedNodeId).toBeNull();
  });
});

describe("mapUiReducer — search/set", () => {
  it("stores the raw query text", () => {
    const s = mapUiReducer(initialMapUiState, { type: "search/set", query: "parse_config" });
    expect(s.searchQuery).toBe("parse_config");
  });
});
