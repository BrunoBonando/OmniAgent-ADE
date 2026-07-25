import { describe, expect, it } from "vitest";
import {
  accentForEntry,
  clampFileTreeWidth,
  DRAG_START_THRESHOLD_PX,
  excludeSelectedDescendants,
  extensionOf,
  FILE_TREE_MAX_WIDTH,
  FILE_TREE_MIN_WIDTH,
  flattenVisibleEntries,
  hasCrossedDragThreshold,
  iconKindForEntry,
  isExpanded,
  isValidDropTarget,
  migratePathKeys,
  nextDefaultCreateName,
  parentDirOf,
  prunePathKeys,
  resolveCreateTargetDir,
  resolveDragPayload,
  resolveRowDoubleClick,
  resolveSelectionClick,
  toggleExpanded,
  widthFromDrag,
} from "./fileTreeState";
import type { DirEntry } from "../lib/tauri";

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

describe("fileTreeState — double-click open resolution", () => {
  it("double-clicking a directory resolves to a toggle action", () => {
    const action = resolveRowDoubleClick({ path: "/p/src", is_dir: true });
    expect(action).toEqual({ type: "toggle", path: "/p/src" });
  });

  it("double-clicking a file resolves to an open action", () => {
    const action = resolveRowDoubleClick({ path: "/p/main.py", is_dir: false });
    expect(action).toEqual({ type: "open", path: "/p/main.py" });
  });
});

describe("fileTreeState — flattenVisibleEntries", () => {
  const root: DirEntry[] = [
    { name: "src", path: "/p/src", is_dir: true },
    { name: "main.py", path: "/p/main.py", is_dir: false },
  ];
  const srcChildren: DirEntry[] = [
    { name: "util.ts", path: "/p/src/util.ts", is_dir: false },
    { name: "nested", path: "/p/src/nested", is_dir: true },
  ];

  it("lists just the root when nothing is expanded", () => {
    const out = flattenVisibleEntries(root, new Set(), new Map());
    expect(out.map((e) => e.path)).toEqual(["/p/src", "/p/main.py"]);
  });

  it("splices in an expanded, loaded directory's children in order", () => {
    const expanded = new Set(["/p/src"]);
    const children = new Map<string, unknown>([["/p/src", srcChildren]]);
    const out = flattenVisibleEntries(root, expanded, children);
    expect(out.map((e) => e.path)).toEqual(["/p/src", "/p/src/util.ts", "/p/src/nested", "/p/main.py"]);
  });

  it("does not descend into an expanded directory that hasn't loaded yet", () => {
    const expanded = new Set(["/p/src"]);
    const children = new Map<string, unknown>([["/p/src", "loading"]]);
    const out = flattenVisibleEntries(root, expanded, children);
    expect(out.map((e) => e.path)).toEqual(["/p/src", "/p/main.py"]);
  });

  it("does not descend into an expanded directory that errored", () => {
    const expanded = new Set(["/p/src"]);
    const children = new Map<string, unknown>([["/p/src", { error: "boom" }]]);
    const out = flattenVisibleEntries(root, expanded, children);
    expect(out.map((e) => e.path)).toEqual(["/p/src", "/p/main.py"]);
  });

  it("recurses into nested expanded directories", () => {
    const expanded = new Set(["/p/src", "/p/src/nested"]);
    const children = new Map<string, unknown>([
      ["/p/src", srcChildren],
      ["/p/src/nested", [{ name: "deep.ts", path: "/p/src/nested/deep.ts", is_dir: false }]],
    ]);
    const out = flattenVisibleEntries(root, expanded, children);
    expect(out.map((e) => e.path)).toEqual([
      "/p/src",
      "/p/src/util.ts",
      "/p/src/nested",
      "/p/src/nested/deep.ts",
      "/p/main.py",
    ]);
  });

  it("returns an empty list for an undefined root", () => {
    expect(flattenVisibleEntries(undefined, new Set(), new Map())).toEqual([]);
  });
});

describe("fileTreeState — multi-select", () => {
  const order = ["/p/a", "/p/b", "/p/c", "/p/d", "/p/e"];

  it("a plain click replaces the selection with just that row and sets the anchor", () => {
    const result = resolveSelectionClick(new Set(["/p/a"]), order, "/p/c", "/p/a", {
      shiftKey: false,
      metaKey: false,
    });
    expect(result.selection).toEqual(new Set(["/p/c"]));
    expect(result.anchor).toBe("/p/c");
  });

  it("cmd-click adds an unselected row to the selection and moves the anchor to it", () => {
    const result = resolveSelectionClick(new Set(["/p/a"]), order, "/p/c", "/p/a", {
      shiftKey: false,
      metaKey: true,
    });
    expect(result.selection).toEqual(new Set(["/p/a", "/p/c"]));
    expect(result.anchor).toBe("/p/c");
  });

  it("cmd-click on an already-selected row removes it from the selection", () => {
    const result = resolveSelectionClick(new Set(["/p/a", "/p/c"]), order, "/p/c", "/p/c", {
      shiftKey: false,
      metaKey: true,
    });
    expect(result.selection).toEqual(new Set(["/p/a"]));
  });

  it("shift-click selects the contiguous range from the anchor forward", () => {
    const result = resolveSelectionClick(new Set(["/p/b"]), order, "/p/d", "/p/b", {
      shiftKey: true,
      metaKey: false,
    });
    expect(result.selection).toEqual(new Set(["/p/b", "/p/c", "/p/d"]));
    expect(result.anchor).toBe("/p/b"); // anchor stays put so the range can grow/shrink further
  });

  it("shift-click selects the contiguous range from the anchor backward", () => {
    const result = resolveSelectionClick(new Set(["/p/d"]), order, "/p/b", "/p/d", {
      shiftKey: true,
      metaKey: false,
    });
    expect(result.selection).toEqual(new Set(["/p/b", "/p/c", "/p/d"]));
    expect(result.anchor).toBe("/p/d");
  });

  it("shift-click with no prior anchor falls back to a plain single-select", () => {
    const result = resolveSelectionClick(new Set(), order, "/p/c", null, {
      shiftKey: true,
      metaKey: false,
    });
    expect(result.selection).toEqual(new Set(["/p/c"]));
    expect(result.anchor).toBe("/p/c");
  });

  it("shift-click falls back gracefully when the anchor scrolled out of the visible order", () => {
    const result = resolveSelectionClick(new Set(["/p/z"]), order, "/p/c", "/p/z", {
      shiftKey: true,
      metaKey: false,
    });
    expect(result.selection).toEqual(new Set(["/p/c"]));
    expect(result.anchor).toBe("/p/c");
  });
});

describe("fileTreeState — icons", () => {
  it("extensionOf lowercases and strips the leading dot", () => {
    expect(extensionOf("Main.TS")).toBe("ts");
    expect(extensionOf("archive.tar.gz")).toBe("gz");
  });

  it("extensionOf treats a bare dotfile as having no extension", () => {
    expect(extensionOf(".gitignore")).toBe("");
  });

  it("extensionOf returns empty for a name with no dot at all", () => {
    expect(extensionOf("Makefile")).toBe("");
  });

  it("folders resolve to folder/folder-open by expanded state, ignoring name", () => {
    expect(iconKindForEntry({ name: "src", is_dir: true }, false)).toBe("folder");
    expect(iconKindForEntry({ name: "src", is_dir: true }, true)).toBe("folder-open");
  });

  it.each([
    ["main.ts", "code"],
    ["app.tsx", "code"],
    ["index.js", "code"],
    ["script.py", "code"],
    ["lib.rs", "code"],
    ["main.go", "code"],
    ["README.md", "markup"],
    ["package.json", "markup"],
    ["config.yaml", "markup"],
    ["config.yml", "markup"],
    ["logo.png", "image"],
    ["photo.jpeg", "image"],
    ["diagram.svg", "image"],
    ["data.bin", "generic"],
    ["Makefile", "generic"],
  ])("%s -> %s", (name, kind) => {
    expect(iconKindForEntry({ name, is_dir: false }, false)).toBe(kind);
  });

  it("gives distinct accent colors to different code extensions", () => {
    const ts = accentForEntry({ name: "a.ts", is_dir: false });
    const py = accentForEntry({ name: "a.py", is_dir: false });
    const rs = accentForEntry({ name: "a.rs", is_dir: false });
    expect(ts).not.toBe(py);
    expect(py).not.toBe(rs);
    expect(ts).not.toBe(rs);
  });

  it("gives an unrecognized extension the default accent, not undefined", () => {
    expect(accentForEntry({ name: "data.xyz123", is_dir: false })).toBe("var(--ink-dim)");
  });

  it("folders always get the neutral ink-dim accent regardless of name", () => {
    expect(accentForEntry({ name: "src.ts", is_dir: true })).toBe("var(--ink-dim)");
  });
});

describe("fileTreeState — drag & drop", () => {
  it("hasCrossedDragThreshold is false for tiny jitter", () => {
    expect(hasCrossedDragThreshold(100, 100, 101, 100)).toBe(false);
  });

  it("hasCrossedDragThreshold is true once travel reaches the threshold", () => {
    expect(hasCrossedDragThreshold(100, 100, 100 + DRAG_START_THRESHOLD_PX, 100)).toBe(true);
  });

  it("dragging a row that's part of a multi-selection drags the whole selection", () => {
    const selected = new Set(["/p/a", "/p/b", "/p/c"]);
    expect(resolveDragPayload(selected, "/p/b").sort()).toEqual(["/p/a", "/p/b", "/p/c"]);
  });

  it("dragging a row NOT in the current selection drags only that row", () => {
    const selected = new Set(["/p/a", "/p/b"]);
    expect(resolveDragPayload(selected, "/p/z")).toEqual(["/p/z"]);
  });

  it("dragging the sole selected row drags just that row", () => {
    const selected = new Set(["/p/a"]);
    expect(resolveDragPayload(selected, "/p/a")).toEqual(["/p/a"]);
  });

  it("parentDirOf returns the containing directory", () => {
    expect(parentDirOf("/repo/demo/src/util.ts")).toBe("/repo/demo/src");
  });

  it("parentDirOf of a top-level path returns the root slash", () => {
    expect(parentDirOf("/repo")).toBe("/");
  });

  it("a folder is a valid drop target for an unrelated dragged file", () => {
    expect(isValidDropTarget("/p/dest", ["/p/src/a.txt"])).toBe(true);
  });

  it("rejects dropping an item onto itself", () => {
    expect(isValidDropTarget("/p/a.txt", ["/p/a.txt"])).toBe(false);
  });

  it("rejects dropping a folder into its own descendant", () => {
    expect(isValidDropTarget("/p/parent/child", ["/p/parent"])).toBe(false);
  });

  it("rejects dropping onto the item's own current parent (no-op, not an error)", () => {
    expect(isValidDropTarget("/p/src", ["/p/src/a.txt"])).toBe(false);
  });

  it("rejects when nothing is being dragged", () => {
    expect(isValidDropTarget("/p/dest", [])).toBe(false);
  });

  it("rejects a multi-item drag if ANY dragged item would be invalid", () => {
    // /p/dest is a fine target for a.txt, but IS b's own parent — one bad
    // apple invalidates the whole drop, since move_path would be called
    // once per item and b's call would fail/no-op.
    expect(isValidDropTarget("/p/dest", ["/p/src/a.txt", "/p/dest/b.txt"])).toBe(false);
  });
});

describe("fileTreeState — create (New File / New Folder)", () => {
  it("defaults to the Finder-style placeholder name when free", () => {
    expect(nextDefaultCreateName("folder", new Set())).toBe("untitled folder");
    expect(nextDefaultCreateName("file", new Set())).toBe("untitled file");
  });

  it("auto-suffixes on collision, Finder-style", () => {
    const existing = new Set(["untitled folder", "untitled folder 2"]);
    expect(nextDefaultCreateName("folder", existing)).toBe("untitled folder 3");
  });

  it("resolves the create target to the sole selected folder", () => {
    const selected = new Set(["/p/src"]);
    const lookup = (p: string) => (p === "/p/src" ? { is_dir: true } : undefined);
    expect(resolveCreateTargetDir(selected, lookup, "/p")).toBe("/p/src");
  });

  it("falls back to the project root when a file is selected", () => {
    const selected = new Set(["/p/main.py"]);
    const lookup = (p: string) => (p === "/p/main.py" ? { is_dir: false } : undefined);
    expect(resolveCreateTargetDir(selected, lookup, "/p")).toBe("/p");
  });

  it("falls back to the project root when nothing is selected", () => {
    expect(resolveCreateTargetDir(new Set(), () => undefined, "/p")).toBe("/p");
  });

  it("falls back to the project root when multiple items are selected", () => {
    const selected = new Set(["/p/src", "/p/main.py"]);
    const lookup = (p: string) => (p === "/p/src" ? { is_dir: true } : { is_dir: false });
    expect(resolveCreateTargetDir(selected, lookup, "/p")).toBe("/p");
  });
});

describe("fileTreeState — resize", () => {
  it("clamps below the minimum", () => {
    expect(clampFileTreeWidth(FILE_TREE_MIN_WIDTH - 50)).toBe(FILE_TREE_MIN_WIDTH);
  });

  it("clamps above the maximum", () => {
    expect(clampFileTreeWidth(FILE_TREE_MAX_WIDTH + 200)).toBe(FILE_TREE_MAX_WIDTH);
  });

  it("passes through an in-range width unchanged", () => {
    expect(clampFileTreeWidth(300)).toBe(300);
  });

  it("dragging the left edge leftward (pointer X decreases) widens the panel", () => {
    expect(widthFromDrag(260, 500, 460)).toBe(300);
  });

  it("dragging the left edge rightward narrows the panel", () => {
    expect(widthFromDrag(260, 500, 540)).toBe(220);
  });

  it("clamps the drag result to the minimum", () => {
    expect(widthFromDrag(260, 500, 900)).toBe(FILE_TREE_MIN_WIDTH);
  });

  it("clamps the drag result to the maximum", () => {
    expect(widthFromDrag(260, 500, -1000)).toBe(FILE_TREE_MAX_WIDTH);
  });
});

describe("fileTreeState — migratePathKeys (Bug 3: rename/move cache migration)", () => {
  it("moves an expanded path's entry from its old key to its new key", () => {
    const expanded = new Set(["/p/src"]);
    const { expanded: nextExpanded } = migratePathKeys("/p/src", "/p/lib", expanded, new Map());
    expect(nextExpanded.has("/p/src")).toBe(false);
    expect(nextExpanded.has("/p/lib")).toBe(true);
  });

  it("moves the children cache entry from its old key to its new key, carrying the cached listing forward", () => {
    const srcChildren: DirEntry[] = [{ name: "util.ts", path: "/p/src/util.ts", is_dir: false }];
    const children = new Map<string, unknown>([["/p/src", srcChildren]]);
    const { children: nextChildren } = migratePathKeys("/p/src", "/p/lib", new Set(), children);
    expect(nextChildren.has("/p/src")).toBe(false);
    expect(nextChildren.get("/p/lib")).toBe(srcChildren);
  });

  it("never mutates the input expanded/children — always returns fresh collections", () => {
    const expanded = new Set(["/p/src"]);
    const children = new Map<string, unknown>([["/p/src", []]]);
    const result = migratePathKeys("/p/src", "/p/lib", expanded, children);
    expect(expanded.has("/p/src")).toBe(true); // untouched
    expect(children.has("/p/src")).toBe(true); // untouched
    expect(result.expanded).not.toBe(expanded);
    expect(result.children).not.toBe(children);
  });

  it("leaves unrelated expanded/children entries untouched", () => {
    const expanded = new Set(["/p/src", "/p/docs"]);
    const children = new Map<string, unknown>([
      ["/p/src", []],
      ["/p/docs", []],
    ]);
    const result = migratePathKeys("/p/src", "/p/lib", expanded, children);
    expect(result.expanded.has("/p/docs")).toBe(true);
    expect(result.children.has("/p/docs")).toBe(true);
  });

  it("also re-keys expanded/cached DESCENDANTS of the renamed/moved path", () => {
    const expanded = new Set(["/p/src", "/p/src/nested"]);
    const children = new Map<string, unknown>([
      ["/p/src", []],
      ["/p/src/nested", [{ name: "deep.ts", path: "/p/src/nested/deep.ts", is_dir: false }]],
    ]);
    const result = migratePathKeys("/p/src", "/p/lib", expanded, children);
    expect(result.expanded.has("/p/src/nested")).toBe(false);
    expect(result.expanded.has("/p/lib/nested")).toBe(true);
    expect(result.children.has("/p/src/nested")).toBe(false);
    expect(result.children.get("/p/lib/nested")).toEqual([
      { name: "deep.ts", path: "/p/src/nested/deep.ts", is_dir: false },
    ]);
  });

  it("does not confuse a sibling whose name merely starts with the same prefix", () => {
    // /p/src-old must NOT be treated as a descendant of /p/src.
    const expanded = new Set(["/p/src", "/p/src-old"]);
    const result = migratePathKeys("/p/src", "/p/lib", expanded, new Map());
    expect(result.expanded.has("/p/src-old")).toBe(true); // untouched
    expect(result.expanded.has("/p/lib-old")).toBe(false); // not incorrectly migrated
  });
});

describe("fileTreeState — prunePathKeys (Bug 3: delete cache pruning)", () => {
  it("removes a deleted path's expanded entry", () => {
    const expanded = new Set(["/p/src", "/p/docs"]);
    const { expanded: next } = prunePathKeys(["/p/src"], expanded, new Map());
    expect(next.has("/p/src")).toBe(false);
    expect(next.has("/p/docs")).toBe(true);
  });

  it("removes a deleted path's children cache entry", () => {
    const children = new Map<string, unknown>([
      ["/p/src", []],
      ["/p/docs", []],
    ]);
    const { children: next } = prunePathKeys(["/p/src"], new Set(), children);
    expect(next.has("/p/src")).toBe(false);
    expect(next.has("/p/docs")).toBe(true);
  });

  it("also removes a deleted directory's DESCENDANTS' expanded/children entries", () => {
    const expanded = new Set(["/p/src", "/p/src/nested"]);
    const children = new Map<string, unknown>([
      ["/p/src", []],
      ["/p/src/nested", [{ name: "deep.ts", path: "/p/src/nested/deep.ts", is_dir: false }]],
    ]);
    const result = prunePathKeys(["/p/src"], expanded, children);
    expect(result.expanded.has("/p/src/nested")).toBe(false);
    expect(result.children.has("/p/src/nested")).toBe(false);
  });

  it("prunes multiple deleted paths in one pass", () => {
    const expanded = new Set(["/p/a", "/p/b", "/p/c"]);
    const result = prunePathKeys(["/p/a", "/p/b"], expanded, new Map());
    expect(result.expanded).toEqual(new Set(["/p/c"]));
  });

  it("never mutates the input collections", () => {
    const expanded = new Set(["/p/src"]);
    const children = new Map<string, unknown>([["/p/src", []]]);
    prunePathKeys(["/p/src"], expanded, children);
    expect(expanded.has("/p/src")).toBe(true);
    expect(children.has("/p/src")).toBe(true);
  });

  it("does not prune a sibling whose name merely starts with the same prefix", () => {
    const expanded = new Set(["/p/src", "/p/src-old"]);
    const result = prunePathKeys(["/p/src"], expanded, new Map());
    expect(result.expanded.has("/p/src-old")).toBe(true);
  });
});

describe("fileTreeState — excludeSelectedDescendants (Bug 4: multi-select drag-move)", () => {
  it("excludes a selected descendant of another selected path", () => {
    expect(excludeSelectedDescendants(["/proj/src", "/proj/src/a.ts"])).toEqual(["/proj/src"]);
  });

  it("keeps unrelated top-level paths in the selection", () => {
    const result = excludeSelectedDescendants(["/proj/src", "/proj/docs"]);
    expect(result.sort()).toEqual(["/proj/docs", "/proj/src"]);
  });

  it("collapses a deeply nested descendant to just its top-level ancestor", () => {
    expect(excludeSelectedDescendants(["/proj/src", "/proj/src/a/b.ts", "/proj/src/a"])).toEqual(["/proj/src"]);
  });

  it("returns every path unchanged when none are nested inside each other", () => {
    const paths = ["/proj/a.ts", "/proj/b.ts"];
    expect(excludeSelectedDescendants(paths)).toEqual(paths);
  });

  it("does not treat a same-prefix sibling as a descendant", () => {
    expect(excludeSelectedDescendants(["/proj/src", "/proj/src-old"])).toEqual(["/proj/src", "/proj/src-old"]);
  });

  it("handles an empty selection", () => {
    expect(excludeSelectedDescendants([])).toEqual([]);
  });
});
