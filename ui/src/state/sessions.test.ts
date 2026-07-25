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
  tabDisplayLabel,
  tabsByProject,
  type SessionsState,
  type TabInfo,
} from "./sessions";

function tab(id: string, project: string, engine: TabInfo["engine"] = "claude"): TabInfo {
  return { id, project, engine, cwd: `/tmp/${project}`, createdAt: 0, needsAttention: false };
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

  // Founder feedback, 2026-07-24: activating a tab is "the user actually
  // looked at it" — clears any pending attention badge.
  it("clears needsAttention on the activated tab", () => {
    const state: SessionsState = {
      projects: [],
      tabs: [{ ...tab("a", "p1"), needsAttention: true }, tab("b", "p1")],
      activeTabId: "b",
    };
    const next = sessionsReducer(state, { type: "tab/activated", id: "a" });
    expect(next.activeTabId).toBe("a");
    expect(next.tabs.find((t) => t.id === "a")?.needsAttention).toBe(false);
  });

  it("leaves other tabs' needsAttention untouched", () => {
    const state: SessionsState = {
      projects: [],
      tabs: [{ ...tab("a", "p1"), needsAttention: true }, { ...tab("b", "p1"), needsAttention: true }],
      activeTabId: "a",
    };
    const next = sessionsReducer(state, { type: "tab/activated", id: "a" });
    expect(next.tabs.find((t) => t.id === "a")?.needsAttention).toBe(false);
    expect(next.tabs.find((t) => t.id === "b")?.needsAttention).toBe(true);
  });

  it("activating a tab with no pending attention returns the same tabs array (no unnecessary rebuild)", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1"), tab("b", "p1")], activeTabId: "b" };
    const next = sessionsReducer(state, { type: "tab/activated", id: "a" });
    expect(next.tabs).toBe(state.tabs);
  });

  it("activating an unknown tab id is a no-op even when other tabs need attention", () => {
    const state: SessionsState = {
      projects: [],
      tabs: [{ ...tab("a", "p1"), needsAttention: true }],
      activeTabId: "a",
    };
    const next = sessionsReducer(state, { type: "tab/activated", id: "ghost" });
    expect(next).toBe(state);
  });
});

describe("sessionsReducer — tab/attention", () => {
  it("sets needsAttention on the matching tab, leaving others untouched", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1"), tab("b", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/attention", id: "b" });
    expect(next.tabs.find((t) => t.id === "a")?.needsAttention).toBe(false);
    expect(next.tabs.find((t) => t.id === "b")?.needsAttention).toBe(true);
  });

  it("setting it on the already-active tab still flags it (clearing only happens on (re-)activation)", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/attention", id: "a" });
    expect(next.tabs[0].needsAttention).toBe(true);
  });

  it("is idempotent when fired repeatedly for the same tab (debounced upstream, but the reducer shouldn't care)", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const once = sessionsReducer(state, { type: "tab/attention", id: "a" });
    const twice = sessionsReducer(once, { type: "tab/attention", id: "a" });
    expect(twice.tabs[0].needsAttention).toBe(true);
  });

  it("firing it for an unknown tab id is a no-op", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/attention", id: "ghost" });
    expect(next).toBe(state);
  });

  it("round trips: attention set, then tab activation clears it", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const flagged = sessionsReducer(state, { type: "tab/attention", id: "a" });
    expect(flagged.tabs[0].needsAttention).toBe(true);
    const cleared = sessionsReducer(flagged, { type: "tab/activated", id: "a" });
    expect(cleared.tabs[0].needsAttention).toBe(false);
  });
});

describe("sessionsReducer — tab/renamed", () => {
  it("sets a custom label on the matching tab, leaving others untouched", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1"), tab("b", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/renamed", id: "a", label: "backend fix" });
    expect(next.tabs.find((t) => t.id === "a")?.label).toBe("backend fix");
    expect(next.tabs.find((t) => t.id === "b")?.label).toBeUndefined();
  });

  it("trims surrounding whitespace", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/renamed", id: "a", label: "  spaced out  " });
    expect(next.tabs[0].label).toBe("spaced out");
  });

  it("a blank label clears back to the engine default", () => {
    const withLabel: SessionsState = {
      projects: [],
      tabs: [{ ...tab("a", "p1"), label: "custom" }],
      activeTabId: "a",
    };
    const next = sessionsReducer(withLabel, { type: "tab/renamed", id: "a", label: "   " });
    expect(next.tabs[0].label).toBeUndefined();
  });

  it("renaming an unknown tab id is a no-op", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/renamed", id: "ghost", label: "x" });
    expect(next).toBe(state);
  });
});

describe("tabDisplayLabel", () => {
  it("falls back to the engine name when no custom label is set", () => {
    expect(tabDisplayLabel(tab("a", "p1", "codex"))).toBe("codex");
  });

  it("prefers the custom label once one is set", () => {
    expect(tabDisplayLabel({ ...tab("a", "p1"), label: "my session" })).toBe("my session");
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

  // Bug: App.tsx's boot effect sequentially awaits sessionCreate for every
  // persisted tab, then fires a single `layout/restored` only once the whole
  // loop finishes — nothing disables the sidebar's new-tab affordances while
  // that's in flight. If the user opens a tab mid-restore, `tab/opened` adds
  // it to `state.tabs`, but a wholesale-replace `layout/restored` would then
  // silently drop it from the UI while its real backend PTY session (already
  // spawned via `sessionCreate`) keeps running orphaned forever. These three
  // cases lock in the merge fix instead.
  it("merges restored tabs with a tab opened during the restore window, instead of discarding it", () => {
    const liveTab = tab("live-1", "live");
    const afterOpen = sessionsReducer(initialSessionsState, { type: "tab/opened", tab: liveTab });
    const restored = [tab("restored-1", "p1")];

    const next = sessionsReducer(afterOpen, { type: "layout/restored", tabs: restored });

    expect(next.tabs.map((t) => t.id).sort()).toEqual(["live-1", "restored-1"]);
  });

  it("does not steal focus away from a tab opened during restore back to the first restored tab", () => {
    const liveTab = tab("live-1", "live");
    const afterOpen = sessionsReducer(initialSessionsState, { type: "tab/opened", tab: liveTab });
    expect(afterOpen.activeTabId).toBe("live-1");
    const restored = [tab("restored-1", "p1")];

    const next = sessionsReducer(afterOpen, { type: "layout/restored", tabs: restored });

    expect(next.activeTabId).toBe("live-1");
  });

  it("still defaults focus to the first restored tab when nothing else has claimed focus yet", () => {
    const restored = [tab("restored-1", "p1"), tab("restored-2", "p2")];
    const next = sessionsReducer(initialSessionsState, { type: "layout/restored", tabs: restored });
    expect(next.activeTabId).toBe("restored-1");
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

  it("round trips a renamed tab's custom label so it survives a relaunch", () => {
    const tabs = [{ ...tab("sess-1", "p1", "codex"), label: "backend fix" }];
    const json = serializeLayout(tabs);
    const restored = deserializeLayout(json);
    expect(restored).toEqual([{ project: "p1", engine: "codex", cwd: "/tmp/p1", label: "backend fix" }]);
  });

  it("omits the label key entirely for un-renamed tabs (existing layouts stay unaffected)", () => {
    const json = serializeLayout([tab("a", "p1")]);
    expect(JSON.parse(json).tabs[0]).not.toHaveProperty("label");
    expect(deserializeLayout(json)).toEqual([{ project: "p1", engine: "claude", cwd: "/tmp/p1" }]);
  });
});

describe("sessionsReducer — tabs/opened_bulk", () => {
  // NewWorkspaceModal's bulk-create: all N of a brand-new project's sessions
  // land in ONE dispatch (never one `tab/opened` per session) so
  // `ProjectPaneGrid` (Workspace.tsx) mounts directly with the full,
  // final tab set already present -- see paneGrid.ts's `buildLayoutTree`
  // doc and Workspace.tsx's `initialTree` prop for why an incremental,
  // one-at-a-time reveal would defeat the chosen LAYOUT preset's
  // arrangement and risk remounting already-open panes.
  it("appends every tab in one go and activates the last one", () => {
    const next = sessionsReducer(initialSessionsState, {
      type: "tabs/opened_bulk",
      tabs: [tab("a", "p1"), tab("b", "p1", "codex"), tab("c", "p1", "shell")],
    });
    expect(next.tabs.map((t) => t.id)).toEqual(["a", "b", "c"]);
    expect(next.activeTabId).toBe("c");
  });

  it("appends onto whatever tabs already existed, rather than replacing them", () => {
    const before: SessionsState = { projects: [], tabs: [tab("x", "other")], activeTabId: "x" };
    const next = sessionsReducer(before, {
      type: "tabs/opened_bulk",
      tabs: [tab("a", "p1"), tab("b", "p1")],
    });
    expect(next.tabs.map((t) => t.id)).toEqual(["x", "a", "b"]);
    expect(next.activeTabId).toBe("b");
  });

  it("is a no-op when the batch is empty (e.g. every session in the batch failed to create)", () => {
    const before: SessionsState = { projects: [], tabs: [tab("x", "p1")], activeTabId: "x" };
    const next = sessionsReducer(before, { type: "tabs/opened_bulk", tabs: [] });
    expect(next).toBe(before);
  });

  it("a single-tab batch behaves the same as tab/opened", () => {
    const next = sessionsReducer(initialSessionsState, {
      type: "tabs/opened_bulk",
      tabs: [tab("a", "p1")],
    });
    expect(next.tabs.map((t) => t.id)).toEqual(["a"]);
    expect(next.activeTabId).toBe("a");
  });
});
