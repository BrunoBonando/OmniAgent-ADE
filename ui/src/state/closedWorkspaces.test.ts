import { describe, expect, it } from "vitest";
import {
  deserializeClosedWorkspaces,
  nextSelectedAfterClose,
  openWorkspaces,
  serializeClosedWorkspaces,
} from "./closedWorkspaces";
import type { ProjectInfo } from "./sessions";

function project(id: string): ProjectInfo {
  return { id, label: id, path: `/tmp/${id}` };
}

describe("openWorkspaces — which projects the sidebar lists", () => {
  it("hides the closed ones, keeping the brain's order", () => {
    const projects = [project("a"), project("b"), project("c")];
    expect(openWorkspaces(projects, new Set(["b"])).map((p) => p.id)).toEqual(["a", "c"]);
  });

  it("is the whole list when nothing is closed", () => {
    const projects = [project("a"), project("b")];
    expect(openWorkspaces(projects, new Set())).toEqual(projects);
  });

  it("ignores a closed id for a project that no longer exists", () => {
    expect(openWorkspaces([project("a")], new Set(["ghost"])).map((p) => p.id)).toEqual(["a"]);
  });
});

describe("nextSelectedAfterClose — where the sidebar lands", () => {
  const projects = [project("a"), project("b"), project("c")];

  it("keeps the current selection when a different workspace was closed", () => {
    expect(nextSelectedAfterClose(projects, new Set(["a"]), "a", "c")).toBe("c");
  });

  it("falls to the left neighbour when the selected workspace itself closed", () => {
    expect(nextSelectedAfterClose(projects, new Set(["b"]), "b", "b")).toBe("a");
  });

  it("falls to the right when the first workspace closed", () => {
    expect(nextSelectedAfterClose(projects, new Set(["a"]), "a", "a")).toBe("b");
  });

  it("is null when the last open workspace closed", () => {
    expect(nextSelectedAfterClose([project("a")], new Set(["a"]), "a", "a")).toBeNull();
  });
});

describe("closed-workspace persistence", () => {
  it("round trips through the settings table", () => {
    const raw = serializeClosedWorkspaces(new Set(["a", "b"]));
    expect(deserializeClosedWorkspaces(raw).sort()).toEqual(["a", "b"]);
  });

  it("never throws on missing or corrupt state — a bad row just reopens everything", () => {
    expect(deserializeClosedWorkspaces(null)).toEqual([]);
    expect(deserializeClosedWorkspaces(undefined)).toEqual([]);
    expect(deserializeClosedWorkspaces("not json")).toEqual([]);
    expect(deserializeClosedWorkspaces("{}")).toEqual([]);
  });

  it("keeps only real, non-empty ids", () => {
    expect(deserializeClosedWorkspaces(JSON.stringify(["a", 7, "", "  ", null, "b"]))).toEqual(["a", "b"]);
  });

  it("de-duplicates so a doubled entry can't grow the row forever", () => {
    expect(deserializeClosedWorkspaces(JSON.stringify(["a", "a", "b"]))).toEqual(["a", "b"]);
  });
});
