import { describe, expect, it } from "vitest";
import { isExpanded, resolveRowClick, toggleExpanded } from "./fileTreeState";

describe("fileTreeState — expand/collapse", () => {
  it("starts collapsed for a path not yet in the set", () => {
    const expanded = new Set<string>();
    expect(isExpanded(expanded, "/p/src")).toBe(false);
  });

  it("toggling an unexpanded path expands it", () => {
    const expanded = new Set<string>();
    const next = toggleExpanded(expanded, "/p/src");
    expect(isExpanded(next, "/p/src")).toBe(true);
  });

  it("toggling an already-expanded path collapses it", () => {
    const expanded = new Set<string>(["/p/src"]);
    const next = toggleExpanded(expanded, "/p/src");
    expect(isExpanded(next, "/p/src")).toBe(false);
  });

  it("toggling one path never touches a sibling's expanded state", () => {
    const expanded = new Set<string>(["/p/src", "/p/docs"]);
    const next = toggleExpanded(expanded, "/p/src");
    expect(isExpanded(next, "/p/src")).toBe(false);
    expect(isExpanded(next, "/p/docs")).toBe(true);
  });

  it("never mutates the input set — always returns a fresh one", () => {
    const expanded = new Set<string>();
    const next = toggleExpanded(expanded, "/p/src");
    expect(expanded.size).toBe(0);
    expect(next).not.toBe(expanded);
  });
});

describe("fileTreeState — row click resolution", () => {
  it("clicking a directory resolves to a toggle action", () => {
    const action = resolveRowClick({ path: "/p/src", is_dir: true });
    expect(action).toEqual({ type: "toggle", path: "/p/src" });
  });

  it("clicking a file resolves to an open action", () => {
    const action = resolveRowClick({ path: "/p/main.py", is_dir: false });
    expect(action).toEqual({ type: "open", path: "/p/main.py" });
  });
});
