import { describe, expect, it } from "vitest";
import {
  canSubmit,
  checkedEngines,
  displaySessionPath,
  initialNewSessionState,
  isInsideProjectRoot,
  isSubfolder,
  newSessionReducer,
  normalizePath,
} from "./newSessionState";

const ROOT = "/Users/bruno/code/omniagent";

describe("initialNewSessionState", () => {
  it("starts in the project's own folder with Claude checked", () => {
    const state = initialNewSessionState(ROOT);
    expect(state.path).toBe(ROOT);
    expect(state.projectRoot).toBe(ROOT);
    expect(checkedEngines(state)).toEqual(["claude"]);
    expect(canSubmit(state)).toBe(true); // Enter alone creates a Claude session here
  });
});

describe("newSessionReducer — the folder stays inside the project", () => {
  it("accepts a subfolder", () => {
    const next = newSessionReducer(initialNewSessionState(ROOT), {
      type: "folder_picked",
      path: `${ROOT}/ui/src`,
    });
    expect(next.path).toBe(`${ROOT}/ui/src`);
    expect(next.error).toBeNull();
  });

  it("accepts the project root itself", () => {
    const next = newSessionReducer(initialNewSessionState(ROOT), { type: "folder_picked", path: `${ROOT}/` });
    expect(next.path).toBe(ROOT);
    expect(next.error).toBeNull();
  });

  it("refuses a folder outside the project, and says so", () => {
    const next = newSessionReducer(initialNewSessionState(ROOT), { type: "folder_picked", path: "/etc" });
    expect(next.path).toBe(ROOT); // unchanged
    expect(next.error).toContain("outside this project");
  });

  it("refuses a sibling whose name merely starts with the root's", () => {
    const next = newSessionReducer(initialNewSessionState(ROOT), {
      type: "folder_picked",
      path: `${ROOT}-scratch/src`,
    });
    expect(next.path).toBe(ROOT);
    expect(next.error).toContain("outside this project");
  });

  it("refuses a traversal that climbs back out", () => {
    const next = newSessionReducer(initialNewSessionState(ROOT), {
      type: "folder_picked",
      path: `${ROOT}/ui/../../elsewhere`,
    });
    expect(next.path).toBe(ROOT);
    expect(next.error).toContain("outside this project");
  });

  it("resets back to the project folder", () => {
    let state = newSessionReducer(initialNewSessionState(ROOT), { type: "folder_picked", path: `${ROOT}/ui` });
    state = newSessionReducer(state, { type: "folder_reset" });
    expect(state.path).toBe(ROOT);
    expect(isSubfolder(state)).toBe(false);
  });
});

describe("newSessionReducer — layout, agents, submit", () => {
  it("selects a layout preset", () => {
    expect(newSessionReducer(initialNewSessionState(ROOT), { type: "layout_selected", layout: 6 }).layout).toBe(6);
  });

  it("toggles engines, always reporting them in ENGINES order", () => {
    let state = newSessionReducer(initialNewSessionState(ROOT), { type: "engine_toggled", engine: "shell" });
    state = newSessionReducer(state, { type: "engine_toggled", engine: "codex" });
    expect(checkedEngines(state)).toEqual(["claude", "codex", "shell"]);
  });

  it("cannot submit with no agent checked", () => {
    const state = newSessionReducer(initialNewSessionState(ROOT), { type: "engine_toggled", engine: "claude" });
    expect(checkedEngines(state)).toEqual([]);
    expect(canSubmit(state)).toBe(false);
  });

  it("cannot submit while a submit is in flight", () => {
    expect(canSubmit(newSessionReducer(initialNewSessionState(ROOT), { type: "submit_started" }))).toBe(false);
  });

  it("surfaces a failure and lets the user try again", () => {
    let state = newSessionReducer(initialNewSessionState(ROOT), { type: "submit_started" });
    state = newSessionReducer(state, { type: "submit_failed", error: "claude: not found" });
    expect(state.error).toBe("claude: not found");
    expect(canSubmit(state)).toBe(true);
  });

  it("collapses and expands the agents list", () => {
    const collapsed = newSessionReducer(initialNewSessionState(ROOT), { type: "agents_collapsed_toggled" });
    expect(collapsed.agentsCollapsed).toBe(true);
    expect(newSessionReducer(collapsed, { type: "agents_collapsed_toggled" }).agentsCollapsed).toBe(false);
  });
});

describe("normalizePath", () => {
  it("collapses slashes, dots and trailing separators", () => {
    expect(normalizePath("/a//b/./c/")).toBe("/a/b/c");
    expect(normalizePath("/a/b/../c")).toBe("/a/c");
    expect(normalizePath("/")).toBe("/");
  });

  it("refuses anything that isn't an absolute path", () => {
    expect(normalizePath("relative/path")).toBe("");
    expect(normalizePath("")).toBe("");
    expect(normalizePath("/../etc")).toBe("");
  });
});

describe("isInsideProjectRoot", () => {
  it("accepts the root and any depth below it", () => {
    expect(isInsideProjectRoot("/repo/app", "/repo/app")).toBe(true);
    expect(isInsideProjectRoot("/repo/app", "/repo/app/ui")).toBe(true);
    expect(isInsideProjectRoot("/repo/app", "/repo/app/ui/src/state")).toBe(true);
  });

  it("compares on path components, not string prefixes", () => {
    expect(isInsideProjectRoot("/repo/app", "/repo/app-2")).toBe(false);
    expect(isInsideProjectRoot("/repo/app", "/repo/application/src")).toBe(false);
  });

  it("rejects a parent, a sibling and an unrelated absolute path", () => {
    expect(isInsideProjectRoot("/repo/app", "/repo")).toBe(false);
    expect(isInsideProjectRoot("/repo/app", "/repo/other")).toBe(false);
    expect(isInsideProjectRoot("/repo/app", "/etc/passwd")).toBe(false);
  });

  it("rejects relative and malformed paths on either side", () => {
    expect(isInsideProjectRoot("/repo/app", "ui/src")).toBe(false);
    expect(isInsideProjectRoot("repo/app", "/repo/app/ui")).toBe(false);
    expect(isInsideProjectRoot("/repo/app", "")).toBe(false);
  });

  it("normalizes both sides before comparing", () => {
    expect(isInsideProjectRoot("/repo/app/", "/repo/app/ui/")).toBe(true);
    expect(isInsideProjectRoot("/repo/app", "/repo/app/ui/../lib")).toBe(true);
    expect(isInsideProjectRoot("/repo/app", "/repo/app/..")).toBe(false);
  });
});

describe("displaySessionPath", () => {
  it("shows the project folder as itself and a subfolder relative to it", () => {
    const state = initialNewSessionState(ROOT);
    expect(displaySessionPath(state)).toBe(ROOT);
    const nested = newSessionReducer(state, { type: "folder_picked", path: `${ROOT}/ui/src` });
    expect(displaySessionPath(nested)).toBe("ui/src");
    expect(isSubfolder(nested)).toBe(true);
  });
});
