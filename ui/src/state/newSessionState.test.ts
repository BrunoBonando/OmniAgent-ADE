import { describe, expect, it } from "vitest";
import type { Agent, AgentsState } from "./agents";
import type { ProjectInfo } from "./sessions";
import {
  canSubmit,
  initialNewSessionStateFor,
  isInsideProjectRoot,
  newSessionReducer,
  normalizePath,
  resizeSlots,
  sessionNameFromPrompt,
} from "./newSessionState";

const ROOT = "/Users/bruno/code/omniagent";
const PROJECT: ProjectInfo = { id: "omniagent", label: "OmniAgent", path: ROOT };

/** An `AgentsState` where the listed agents are installed AND the first one
 * is what the user last picked — which is what makes
 * `getDefaultAgentSelection` answer with it rather than falling back to
 * shell (its "more than one installed, nothing remembered" case). */
function agentsWith(installed: Agent[]): AgentsState {
  return { installed: new Set(installed), lastSelected: installed.slice(0, 1), installing: new Map() };
}

describe("initialNewSessionStateFor", () => {
  it("starts in the project's own folder, with an empty prompt", () => {
    const state = initialNewSessionStateFor(PROJECT, agentsWith(["claude"]));
    expect(state.path).toBe(ROOT);
    expect(state.projectRoot).toBe(ROOT);
    expect(state.prompt).toBe("");
    expect(canSubmit(state)).toBe(true); // Enter alone starts the session
  });

  it("falls back to the project id when the project has no path on disk", () => {
    const state = initialNewSessionStateFor({ id: "/tmp/x", label: "X", path: null }, agentsWith(["claude"]));
    expect(state.projectRoot).toBe("/tmp/x");
    expect(state.path).toBe("/tmp/x");
  });

  it("falls back to shell when nothing is installed", () => {
    expect(initialNewSessionStateFor(PROJECT, agentsWith([])).slots).toEqual(["shell", "shell"]);
  });
});

describe("slots", () => {
  it("initial state: layout 2, slots padded with the default engine", () => {
    const s = initialNewSessionStateFor(PROJECT, agentsWith(["claude"]));
    expect(s.layout).toBe(2);
    expect(s.slots).toEqual(["claude", "claude"]);
    expect(s.prompt).toBe("");
  });

  it("resizeSlots preserves prefix and pads", () => {
    expect(resizeSlots(["claude", "codex"], 4, "claude")).toEqual(["claude", "codex", "claude", "claude"]);
    expect(resizeSlots(["claude", "codex", "shell", "shell"], 2, "claude")).toEqual(["claude", "codex"]);
  });

  it("layout action resizes slots", () => {
    let s = initialNewSessionStateFor(PROJECT, agentsWith(["claude"]));
    s = newSessionReducer(s, { type: "layout", layout: 4 });
    expect(s.slots).toHaveLength(4);
    expect(s.layout).toBe(4);
  });

  it("keeps the engines already picked when the layout grows, and drops the tail when it shrinks", () => {
    let s = initialNewSessionStateFor(PROJECT, agentsWith(["claude", "codex"]));
    s = newSessionReducer(s, { type: "slot", index: 1, engine: "codex" });
    s = newSessionReducer(s, { type: "layout", layout: 4 });
    expect(s.slots).toEqual(["claude", "codex", "claude", "claude"]);
    s = newSessionReducer(s, { type: "layout", layout: 1 });
    expect(s.slots).toEqual(["claude"]);
  });

  it("slot action swaps one engine", () => {
    let s = initialNewSessionStateFor(PROJECT, agentsWith(["claude", "codex"]));
    s = newSessionReducer(s, { type: "slot", index: 1, engine: "codex" });
    expect(s.slots).toEqual(["claude", "codex"]);
  });

  it("ignores a slot that isn't on screen", () => {
    const s = initialNewSessionStateFor(PROJECT, agentsWith(["claude"]));
    expect(newSessionReducer(s, { type: "slot", index: 7, engine: "codex" }).slots).toEqual(s.slots);
  });
});

describe("sessionNameFromPrompt", () => {
  it("trims, collapses, caps at 60", () => {
    expect(sessionNameFromPrompt("  coalesce   refresh-token rotation  ")).toBe("coalesce refresh-token rotation");
    expect(sessionNameFromPrompt("x".repeat(80))).toHaveLength(60);
    expect(sessionNameFromPrompt("   ")).toBeUndefined();
  });

  it("collapses newlines and tabs too, so a pasted paragraph still names a row", () => {
    expect(sessionNameFromPrompt("fix\n\tthe   flake")).toBe("fix the flake");
  });
});

describe("the prompt", () => {
  it("is stored verbatim — trimming is the name's business, not the field's", () => {
    const s = newSessionReducer(initialNewSessionStateFor(PROJECT, agentsWith(["claude"])), {
      type: "prompt",
      value: "  fix issue 2 ",
    });
    expect(s.prompt).toBe("  fix issue 2 ");
  });
});

describe("newSessionReducer — the folder stays inside the project", () => {
  const initial = () => initialNewSessionStateFor(PROJECT, agentsWith(["claude"]));

  it("accepts a subfolder", () => {
    const next = newSessionReducer(initial(), { type: "path", path: `${ROOT}/ui/src` });
    expect(next.path).toBe(`${ROOT}/ui/src`);
    expect(next.error).toBeNull();
  });

  it("accepts the project root itself", () => {
    const next = newSessionReducer(initial(), { type: "path", path: `${ROOT}/` });
    expect(next.path).toBe(ROOT);
    expect(next.error).toBeNull();
  });

  it("refuses a folder outside the project, and says so", () => {
    const next = newSessionReducer(initial(), { type: "path", path: "/etc" });
    expect(next.path).toBe(ROOT); // unchanged
    expect(next.error).toContain("outside this project");
  });

  it("refuses a sibling whose name merely starts with the root's", () => {
    const next = newSessionReducer(initial(), { type: "path", path: `${ROOT}-scratch/src` });
    expect(next.path).toBe(ROOT);
    expect(next.error).toContain("outside this project");
  });

  it("refuses a traversal that climbs back out", () => {
    const next = newSessionReducer(initial(), { type: "path", path: `${ROOT}/ui/../../elsewhere` });
    expect(next.path).toBe(ROOT);
    expect(next.error).toContain("outside this project");
  });
});

describe("newSessionReducer — submitting", () => {
  const initial = () => initialNewSessionStateFor(PROJECT, agentsWith(["claude"]));

  it("cannot submit while a submit is in flight", () => {
    expect(canSubmit(newSessionReducer(initial(), { type: "submit_started" }))).toBe(false);
  });

  it("surfaces a failure and lets the user try again", () => {
    let state = newSessionReducer(initial(), { type: "submit_started" });
    state = newSessionReducer(state, { type: "submit_failed", error: "claude: not found" });
    expect(state.error).toBe("claude: not found");
    expect(canSubmit(state)).toBe(true);
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
