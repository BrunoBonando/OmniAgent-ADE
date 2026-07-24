import { describe, expect, it } from "vitest";
import {
  GLOBAL_DEFAULT_ENGINE_KEY,
  PRESSURE_THRESHOLD,
  cycleEngine,
  defaultEngineSettingKey,
  deserializeLayout,
  initialSessionsState,
  isUnderPressure,
  resolveDefaultEngine,
  serializeLayout,
  sessionsReducer,
  tabsByProject,
  type SessionsState,
  type TabInfo,
} from "./sessions";

function tab(id: string, project: string, engine: TabInfo["engine"] = "claude"): TabInfo {
  return { id, project, engine, cwd: `/tmp/${project}`, createdAt: 0 };
}

describe("sessionsReducer — tab/opened", () => {
  it("appends the tab and makes it active", () => {
    const s1 = sessionsReducer(initialSessionsState, { type: "tab/opened", tab: tab("a", "p1") });
    expect(s1.tabs.map((t) => t.id)).toEqual(["a"]);
    expect(s1.activeTabId).toBe("a");

    const s2 = sessionsReducer(s1, { type: "tab/opened", tab: tab("b", "p1") });
    expect(s2.tabs.map((t) => t.id)).toEqual(["a", "b"]);
    expect(s2.activeTabId).toBe("b");
  });
});

describe("sessionsReducer — tab/closed ordering", () => {
  const three: SessionsState = {
    projects: [],
    tabs: [tab("a", "p1"), tab("b", "p1"), tab("c", "p2")],
    activeTabId: "b",
  };

  it("closing the active middle tab activates its left neighbor", () => {
    const next = sessionsReducer(three, { type: "tab/closed", id: "b" });
    expect(next.tabs.map((t) => t.id)).toEqual(["a", "c"]);
    expect(next.activeTabId).toBe("a");
  });

  it("closing the active first tab activates the tab that slides into its slot", () => {
    const next = sessionsReducer(three, { type: "tab/closed", id: "a" });
    expect(next.tabs.map((t) => t.id)).toEqual(["b", "c"]);
    expect(next.activeTabId).toBe("b");
  });

  it("closing the only remaining tab leaves activeTabId null", () => {
    const one: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(one, { type: "tab/closed", id: "a" });
    expect(next.tabs).toEqual([]);
    expect(next.activeTabId).toBeNull();
  });

  it("closing a background (non-active) tab does not change activeTabId", () => {
    const next = sessionsReducer(three, { type: "tab/closed", id: "c" });
    expect(next.activeTabId).toBe("b");
    expect(next.tabs.map((t) => t.id)).toEqual(["a", "b"]);
  });

  it("closing an unknown id is a no-op", () => {
    const next = sessionsReducer(three, { type: "tab/closed", id: "ghost" });
    expect(next).toBe(three);
  });
});

describe("sessionsReducer — tab/activated", () => {
  it("switches the active tab when it exists", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1"), tab("b", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/activated", id: "b" });
    expect(next.activeTabId).toBe("b");
  });

  it("ignores activation of a tab id that isn't open", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/activated", id: "ghost" });
    expect(next.activeTabId).toBe("a");
  });
});

describe("sessionsReducer — layout/restored", () => {
  it("replaces tabs and activates the first restored tab", () => {
    const restored = [tab("x", "p1"), tab("y", "p2")];
    const next = sessionsReducer(initialSessionsState, { type: "layout/restored", tabs: restored });
    expect(next.tabs).toEqual(restored);
    expect(next.activeTabId).toBe("x");
  });

  it("restoring an empty layout clears activeTabId", () => {
    const next = sessionsReducer(initialSessionsState, { type: "layout/restored", tabs: [] });
    expect(next.activeTabId).toBeNull();
  });
});

describe("tabsByProject", () => {
  it("groups tabs by project preserving first-seen project order", () => {
    const tabs = [tab("a", "p1"), tab("b", "p2"), tab("c", "p1")];
    const groups = tabsByProject(tabs);
    expect(groups.map((g) => g.project)).toEqual(["p1", "p2"]);
    expect(groups[0].tabs.map((t) => t.id)).toEqual(["a", "c"]);
    expect(groups[1].tabs.map((t) => t.id)).toEqual(["b"]);
  });
});

describe("isUnderPressure", () => {
  it("is false at and below the threshold", () => {
    const tabs = Array.from({ length: PRESSURE_THRESHOLD }, (_, i) => tab(String(i), "p1"));
    expect(isUnderPressure(tabs)).toBe(false);
  });

  it("is true once past the threshold", () => {
    const tabs = Array.from({ length: PRESSURE_THRESHOLD + 1 }, (_, i) => tab(String(i), "p1"));
    expect(isUnderPressure(tabs)).toBe(true);
  });
});

describe("resolveDefaultEngine (EnginePicker default-selection logic)", () => {
  it("falls back to claude with no settings at all", () => {
    expect(resolveDefaultEngine("p1", {})).toBe("claude");
  });

  it("uses the global default when no per-project override exists", () => {
    const settings = { [GLOBAL_DEFAULT_ENGINE_KEY]: "shell" };
    expect(resolveDefaultEngine("p1", settings)).toBe("shell");
  });

  it("prefers the per-project override over the global default", () => {
    const settings = {
      [GLOBAL_DEFAULT_ENGINE_KEY]: "shell",
      [defaultEngineSettingKey("p1")]: "codex",
    };
    expect(resolveDefaultEngine("p1", settings)).toBe("codex");
  });

  it("ignores garbage values and falls back to claude", () => {
    const settings = { [defaultEngineSettingKey("p1")]: "not-a-real-engine" };
    expect(resolveDefaultEngine("p1", settings)).toBe("claude");
  });
});

describe("cycleEngine", () => {
  it("cycles forward through claude -> codex -> shell -> claude", () => {
    expect(cycleEngine("claude", 1)).toBe("codex");
    expect(cycleEngine("codex", 1)).toBe("shell");
    expect(cycleEngine("shell", 1)).toBe("claude");
  });

  it("cycles backward wrapping at the start", () => {
    expect(cycleEngine("claude", -1)).toBe("shell");
  });
});

describe("layout serialize/deserialize round trip", () => {
  it("round trips tabs through JSON, dropping ids (fresh session_create per restore)", () => {
    const tabs = [tab("sess-1", "p1", "codex"), tab("sess-2", "p2", "shell")];
    const json = serializeLayout(tabs);
    const restored = deserializeLayout(json);
    expect(restored).toEqual([
      { project: "p1", engine: "codex", cwd: "/tmp/p1" },
      { project: "p2", engine: "shell", cwd: "/tmp/p2" },
    ]);
  });

  it("deserializing null/undefined/garbage never throws and returns []", () => {
    expect(deserializeLayout(null)).toEqual([]);
    expect(deserializeLayout(undefined)).toEqual([]);
    expect(deserializeLayout("not json")).toEqual([]);
    expect(deserializeLayout("{}")).toEqual([]);
    expect(deserializeLayout(JSON.stringify({ tabs: [{ project: "p1" }] }))).toEqual([]);
  });

  it("filters out individually malformed tab entries but keeps the valid ones", () => {
    const raw = JSON.stringify({
      tabs: [
        { project: "p1", engine: "claude", cwd: "/tmp/p1" },
        { project: "p2", engine: "not-real", cwd: "/tmp/p2" },
      ],
    });
    expect(deserializeLayout(raw)).toEqual([{ project: "p1", engine: "claude", cwd: "/tmp/p1" }]);
  });
});
