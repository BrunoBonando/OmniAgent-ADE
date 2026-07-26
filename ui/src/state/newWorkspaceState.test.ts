import { describe, expect, it } from "vitest";
import {
  canSubmit,
  checkedEngines,
  DEFAULT_ENGINE_SELECTION,
  initialNewWorkspaceState,
  newWorkspaceReducer,
  type NewWorkspaceState,
} from "./newWorkspaceState";

describe("initialNewWorkspaceState", () => {
  it("starts with no folder chosen, the 4-pane (2x2) layout, and only Claude checked", () => {
    expect(initialNewWorkspaceState).toEqual({
      path: null,
      name: "",
      layout: 4,
      engines: { claude: true, codex: false, shell: false, copilot: false, antigravity: false },
      agentsCollapsed: false,
      submitting: false,
      error: null,
    });
  });

  it("DEFAULT_ENGINE_SELECTION checks only claude — the established 'Claude is the sensible default' precedent", () => {
    expect(DEFAULT_ENGINE_SELECTION).toEqual({ claude: true, codex: false, shell: false, copilot: false, antigravity: false });
  });
});

describe("newWorkspaceReducer", () => {
  it("folder_picked sets the path and defaults the name to its basename", () => {
    const next = newWorkspaceReducer(initialNewWorkspaceState, {
      type: "folder_picked",
      path: "/tmp/demo-workspace",
    });
    expect(next.path).toBe("/tmp/demo-workspace");
    expect(next.name).toBe("demo-workspace");
  });

  it("folder_picked clears any prior error", () => {
    const withError: NewWorkspaceState = { ...initialNewWorkspaceState, error: "boom" };
    const next = newWorkspaceReducer(withError, { type: "folder_picked", path: "/tmp/x" });
    expect(next.error).toBeNull();
  });

  it("name_changed updates only the name", () => {
    const picked = newWorkspaceReducer(initialNewWorkspaceState, { type: "folder_picked", path: "/tmp/demo" });
    const next = newWorkspaceReducer(picked, { type: "name_changed", name: "renamed" });
    expect(next.name).toBe("renamed");
    expect(next.path).toBe("/tmp/demo");
  });

  it("layout_selected updates only the layout", () => {
    const next = newWorkspaceReducer(initialNewWorkspaceState, { type: "layout_selected", layout: 6 });
    expect(next.layout).toBe(6);
    expect(next.engines).toEqual(initialNewWorkspaceState.engines);
  });

  it("engine_toggled flips exactly one engine's checked state", () => {
    const next = newWorkspaceReducer(initialNewWorkspaceState, { type: "engine_toggled", engine: "codex" });
    expect(next.engines).toEqual({ claude: true, codex: true, shell: false, copilot: false, antigravity: false });

    const toggledBack = newWorkspaceReducer(next, { type: "engine_toggled", engine: "codex" });
    expect(toggledBack.engines).toEqual({ claude: true, codex: false, shell: false, copilot: false, antigravity: false });
  });

  it("engine_toggled allows unchecking every engine (canSubmit is what gates that, not the reducer)", () => {
    const next = newWorkspaceReducer(initialNewWorkspaceState, { type: "engine_toggled", engine: "claude" });
    expect(next.engines).toEqual({ claude: false, codex: false, shell: false, copilot: false, antigravity: false });
  });

  it("agents_collapsed_toggled flips the AI AGENTS section's collapsed state", () => {
    const next = newWorkspaceReducer(initialNewWorkspaceState, { type: "agents_collapsed_toggled" });
    expect(next.agentsCollapsed).toBe(true);
    const back = newWorkspaceReducer(next, { type: "agents_collapsed_toggled" });
    expect(back.agentsCollapsed).toBe(false);
  });

  it("submit_started sets submitting and clears any prior error", () => {
    const withError: NewWorkspaceState = { ...initialNewWorkspaceState, path: "/tmp/x", error: "boom" };
    const next = newWorkspaceReducer(withError, { type: "submit_started" });
    expect(next.submitting).toBe(true);
    expect(next.error).toBeNull();
  });

  it("submit_failed clears submitting and carries the error, keeping path/name/layout/engines", () => {
    const submitting: NewWorkspaceState = {
      ...initialNewWorkspaceState,
      path: "/tmp/x",
      name: "x",
      submitting: true,
    };
    const next = newWorkspaceReducer(submitting, { type: "submit_failed", error: "disk full" });
    expect(next).toEqual({ ...submitting, submitting: false, error: "disk full" });
  });
});

describe("checkedEngines", () => {
  it("returns just claude by default, in ENGINES order", () => {
    expect(checkedEngines(initialNewWorkspaceState)).toEqual(["claude"]);
  });

  it("returns every checked engine in ENGINES order regardless of toggle order", () => {
    const state: NewWorkspaceState = {
      ...initialNewWorkspaceState,
      engines: { shell: true, claude: true, codex: true, copilot: false, antigravity: false },
    };
    expect(checkedEngines(state)).toEqual(["claude", "codex", "shell"]);
  });

  it("returns an empty array when nothing is checked", () => {
    const state: NewWorkspaceState = {
      ...initialNewWorkspaceState,
      engines: { claude: false, codex: false, shell: false, copilot: false, antigravity: false },
    };
    expect(checkedEngines(state)).toEqual([]);
  });
});

describe("canSubmit", () => {
  it("is false with no folder chosen yet", () => {
    expect(canSubmit(initialNewWorkspaceState)).toBe(false);
  });

  it("is true once a folder is chosen, the name is non-blank, and at least one engine is checked", () => {
    const state: NewWorkspaceState = { ...initialNewWorkspaceState, path: "/tmp/demo", name: "demo" };
    expect(canSubmit(state)).toBe(true);
  });

  it("is false with a blank/whitespace-only name", () => {
    const state: NewWorkspaceState = { ...initialNewWorkspaceState, path: "/tmp/demo", name: "   " };
    expect(canSubmit(state)).toBe(false);
  });

  it("is false when every engine is unchecked, even with a valid path/name", () => {
    const state: NewWorkspaceState = {
      ...initialNewWorkspaceState,
      path: "/tmp/demo",
      name: "demo",
      engines: { claude: false, codex: false, shell: false, copilot: false, antigravity: false },
    };
    expect(canSubmit(state)).toBe(false);
  });

  it("is false while a submit is already in flight", () => {
    const state: NewWorkspaceState = {
      ...initialNewWorkspaceState,
      path: "/tmp/demo",
      name: "demo",
      submitting: true,
    };
    expect(canSubmit(state)).toBe(false);
  });
});
