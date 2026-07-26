import { describe, expect, it } from "vitest";
import {
  GLOBAL_DEFAULT_ENGINE_KEY,
  PRESSURE_THRESHOLD,
  UNGROUPED_SESSION_ID,
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

  // 2026-07-26: activation used to also clear a latched `needsAttention`
  // badge. That field is gone (folded into the five-state `status` — see
  // `TabInfo`'s doc), so activation is now pure focus and must never
  // rebuild the tabs array.
  it("only moves focus — the tabs array itself is untouched", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1"), tab("b", "p1")], activeTabId: "b" };
    const next = sessionsReducer(state, { type: "tab/activated", id: "a" });
    expect(next.activeTabId).toBe("a");
    expect(next.tabs).toBe(state.tabs);
  });

  it("does not touch a session's status — looking at a pane doesn't change what it's doing", () => {
    const state: SessionsState = {
      projects: [],
      tabs: [{ ...tab("a", "p1"), status: "awaiting_approval" }, tab("b", "p1")],
      activeTabId: "b",
    };
    const next = sessionsReducer(state, { type: "tab/activated", id: "a" });
    expect(next.tabs.find((t) => t.id === "a")?.status).toBe("awaiting_approval");
  });

  it("activating an unknown tab id is a no-op", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/activated", id: "ghost" });
    expect(next).toBe(state);
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

describe("sessionsReducer — tab/autoTitled", () => {
  // Auto-title from the first prompt (founder ask): fires once a session's
  // first real input line resolves (Terminal.tsx -> autoTitle.ts). Unlike
  // `tab/renamed` (always applies, an explicit user action), this must
  // NEVER clobber a label the tab already has — manual rename, a carried-
  // over label from an engine restart, or (defensively) a duplicate fire
  // must all win over an auto-title.
  it("sets the label on a tab that has none yet", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/autoTitled", id: "a", label: "fix the login bug" });
    expect(next.tabs[0].label).toBe("fix the login bug");
  });

  it("never overwrites a tab that already has a label (manual rename always wins)", () => {
    const state: SessionsState = {
      projects: [],
      tabs: [{ ...tab("a", "p1"), label: "renamed by hand" }],
      activeTabId: "a",
    };
    const next = sessionsReducer(state, { type: "tab/autoTitled", id: "a", label: "from first prompt" });
    expect(next.tabs[0].label).toBe("renamed by hand");
  });

  it("is idempotent — a second auto-title fire for the same tab is a no-op", () => {
    const state: SessionsState = {
      projects: [],
      tabs: [{ ...tab("a", "p1"), label: "first prompt" }],
      activeTabId: "a",
    };
    const next = sessionsReducer(state, { type: "tab/autoTitled", id: "a", label: "second prompt" });
    expect(next.tabs[0].label).toBe("first prompt");
  });

  it("auto-titling an unknown tab id is a no-op", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/autoTitled", id: "ghost", label: "x" });
    expect(next).toBe(state);
  });
});

describe("sessionsReducer — tab/engineRestarted", () => {
  // PaneHeader's 3-dot "Change engine": the old session was killed and a
  // new one spawned with a different engine, same pane/slot — this swaps
  // the TabInfo in place (same array index) rather than remove+append, so
  // `paneGrid.ts`'s syncPaneTree 1-for-1-swap case can keep the pane where
  // it was.
  it("replaces the old tab with the new one at the same array position", () => {
    const state: SessionsState = {
      projects: [],
      tabs: [tab("a", "p1"), tab("b", "p1", "codex"), tab("c", "p1")],
      activeTabId: "a",
    };
    const restarted = tab("b2", "p1", "shell");
    const next = sessionsReducer(state, { type: "tab/engineRestarted", oldId: "b", tab: restarted });
    expect(next.tabs.map((t) => t.id)).toEqual(["a", "b2", "c"]);
    expect(next.tabs[1].engine).toBe("shell");
  });

  it("moves activeTabId to the new id when the restarted tab was focused", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const restarted = tab("a2", "p1", "codex");
    const next = sessionsReducer(state, { type: "tab/engineRestarted", oldId: "a", tab: restarted });
    expect(next.activeTabId).toBe("a2");
  });

  it("leaves activeTabId alone when a background tab was restarted", () => {
    const state: SessionsState = {
      projects: [],
      tabs: [tab("a", "p1"), tab("b", "p1")],
      activeTabId: "a",
    };
    const restarted = tab("b2", "p1", "codex");
    const next = sessionsReducer(state, { type: "tab/engineRestarted", oldId: "b", tab: restarted });
    expect(next.activeTabId).toBe("a");
  });

  it("is a no-op when the old id isn't open", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/engineRestarted", oldId: "ghost", tab: tab("x", "p1") });
    expect(next).toBe(state);
  });
});

describe("sessionsReducer — tab/themeChanged", () => {
  it("sets a per-pane theme override", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/themeChanged", id: "a", themeId: "matrix" });
    expect(next.tabs[0].themeId).toBe("matrix");
  });

  it("clears the override back to the global default when themeId is undefined", () => {
    const state: SessionsState = {
      projects: [],
      tabs: [{ ...tab("a", "p1"), themeId: "matrix" }],
      activeTabId: "a",
    };
    const next = sessionsReducer(state, { type: "tab/themeChanged", id: "a", themeId: undefined });
    expect(next.tabs[0].themeId).toBeUndefined();
  });

  it("changing the theme of an unknown tab id is a no-op", () => {
    const state: SessionsState = { projects: [], tabs: [tab("a", "p1")], activeTabId: "a" };
    const next = sessionsReducer(state, { type: "tab/themeChanged", id: "ghost", themeId: "amber" });
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
  it("cycles forward through all engines", () => {
    expect(cycleEngine("claude", 1)).toBe("codex");
    expect(cycleEngine("codex", 1)).toBe("shell");
    expect(cycleEngine("shell", 1)).toBe("copilot");
    expect(cycleEngine("copilot", 1)).toBe("antigravity");
    expect(cycleEngine("antigravity", 1)).toBe("claude");
  });

  it("cycles backward wrapping at the start", () => {
    expect(cycleEngine("claude", -1)).toBe("antigravity");
  });
});

describe("layout serialize/deserialize round trip", () => {
  // Changed 2026-07-26: this used to assert ids were DROPPED ("fresh
  // session_create per restore", DESIGN 3.1). tmux-backed session restore
  // (src-tauri/src/sessions.rs) made the id the thing the whole feature
  // hangs on — `session_create({ …, restoreId })` reattaches to the live
  // engine only if the frontend can hand back the id it got last run.
  it("round trips tabs through JSON, KEEPING ids so they can be replayed as restoreId", () => {
    const tabs = [tab("sess-1", "p1", "codex"), tab("sess-2", "p2", "shell")];
    const json = serializeLayout(tabs);
    const restored = deserializeLayout(json);
    expect(restored).toEqual([
      { id: "sess-1", project: "p1", engine: "codex", cwd: "/tmp/p1" },
      { id: "sess-2", project: "p2", engine: "shell", cwd: "/tmp/p2" },
    ]);
  });

  it("restores a layout written before ids were persisted, with no id and no restoreId to send", () => {
    const legacy = JSON.stringify({
      tabs: [{ project: "p1", engine: "claude", cwd: "/tmp/p1", label: "old" }],
    });
    expect(deserializeLayout(legacy)).toEqual([
      { project: "p1", engine: "claude", cwd: "/tmp/p1", label: "old" },
    ]);
  });

  it("drops an id the backend would reject rather than the whole tab", () => {
    const raw = JSON.stringify({
      tabs: [
        { id: "has spaces", project: "p1", engine: "claude", cwd: "/tmp/p1" },
        { id: "slash/es", project: "p2", engine: "claude", cwd: "/tmp/p2" },
        { id: "x".repeat(97), project: "p3", engine: "claude", cwd: "/tmp/p3" },
        { id: "", project: "p4", engine: "claude", cwd: "/tmp/p4" },
        { id: 7, project: "p5", engine: "claude", cwd: "/tmp/p5" },
      ],
    });
    const restored = deserializeLayout(raw);
    expect(restored).toHaveLength(5);
    for (const t of restored) expect(t).not.toHaveProperty("id");
  });

  it("keeps only the first of two tabs persisted with the same id (the backend rejects a re-used restoreId)", () => {
    const raw = JSON.stringify({
      tabs: [
        { id: "sess-dup", project: "p1", engine: "claude", cwd: "/tmp/p1" },
        { id: "sess-dup", project: "p2", engine: "claude", cwd: "/tmp/p2" },
      ],
    });
    const restored = deserializeLayout(raw);
    expect(restored).toHaveLength(2);
    expect(restored[0].id).toBe("sess-dup");
    expect(restored[1]).not.toHaveProperty("id");
  });

  it("never persists the live-process fields — a restored pane must not claim a stale light", () => {
    const json = serializeLayout([{ ...tab("sess-1", "p1"), status: "error", restored: true }]);
    const raw = JSON.parse(json).tabs[0];
    expect(raw).not.toHaveProperty("status");
    expect(raw).not.toHaveProperty("restored");
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
    expect(restored).toEqual([
      { id: "sess-1", project: "p1", engine: "codex", cwd: "/tmp/p1", label: "backend fix" },
    ]);
  });

  it("omits the label key entirely for un-renamed tabs (existing layouts stay unaffected)", () => {
    const json = serializeLayout([tab("a", "p1")]);
    expect(JSON.parse(json).tabs[0]).not.toHaveProperty("label");
    expect(deserializeLayout(json)).toEqual([{ id: "a", project: "p1", engine: "claude", cwd: "/tmp/p1" }]);
  });

  it("round trips a per-pane terminal theme override so it survives a relaunch", () => {
    const tabs = [{ ...tab("sess-1", "p1", "codex"), themeId: "matrix" as const }];
    const json = serializeLayout(tabs);
    expect(deserializeLayout(json)).toEqual([
      { id: "sess-1", project: "p1", engine: "codex", cwd: "/tmp/p1", themeId: "matrix" },
    ]);
  });

  it("omits the themeId key entirely when a tab has no per-pane override", () => {
    const json = serializeLayout([tab("a", "p1")]);
    expect(JSON.parse(json).tabs[0]).not.toHaveProperty("themeId");
  });

  it("drops a garbage themeId rather than restoring it", () => {
    const raw = JSON.stringify({
      tabs: [{ project: "p1", engine: "claude", cwd: "/tmp/p1", themeId: "not-a-real-theme" }],
    });
    expect(deserializeLayout(raw)).toEqual([{ project: "p1", engine: "claude", cwd: "/tmp/p1" }]);
  });
});

describe("sessionsReducer — tab/status (the five-state light)", () => {
  const two: SessionsState = { projects: [], tabs: [tab("a", "p1"), tab("b", "p1")], activeTabId: "a" };

  it("sets the light on exactly the tab the event names", () => {
    const next = sessionsReducer(two, { type: "tab/status", id: "b", status: "awaiting_approval" });
    expect(next.tabs.map((t) => t.status)).toEqual([undefined, "awaiting_approval"]);
  });

  it("replaces the previous light on a later transition", () => {
    const s1 = sessionsReducer(two, { type: "tab/status", id: "a", status: "thinking" });
    const s2 = sessionsReducer(s1, { type: "tab/status", id: "a", status: "ready" });
    expect(s2.tabs[0].status).toBe("ready");
  });

  it("is a no-op — same array identity — when the light didn't change, so the on-mount pull never re-renders every pane", () => {
    const s1 = sessionsReducer(two, { type: "tab/status", id: "a", status: "ready" });
    const s2 = sessionsReducer(s1, { type: "tab/status", id: "a", status: "ready" });
    expect(s2).toBe(s1);
    expect(s2.tabs).toBe(s1.tabs);
  });

  it("ignores a status for a tab that has already closed", () => {
    const next = sessionsReducer(two, { type: "tab/status", id: "gone", status: "error" });
    expect(next).toBe(two);
  });

  it("is the only thing that says a session needs attention — there is no second latched flag", () => {
    // 2026-07-26: `needsAttention` folded into this status (TabInfo's doc).
    // A session that resolves itself goes from error to ready and stops
    // asking for the user, with nothing left behind to clear.
    const blocked: SessionsState = {
      ...two,
      tabs: [{ ...tab("a", "p1"), status: "error" }, tab("b", "p1")],
    };
    const next = sessionsReducer(blocked, { type: "tab/status", id: "a", status: "ready" });
    expect(next.tabs[0].status).toBe("ready");
    expect(Object.keys(next.tabs[0])).not.toContain("needsAttention");
  });
});

describe("sessionsReducer — tabs/opened_bulk", () => {
  // NewWorkspaceModal's bulk-create: all N of a brand-new project's sessions
  // land in ONE dispatch (never one `tab/opened` per session) so
  // `ProjectPaneGrid` (Workspace.tsx) mounts directly with the full,
  // final tab set already present -- an incremental, one-at-a-time reveal
  // would instead walk the grid up one approved shape per pane
  // (paneGrid.ts's GRID_LADDER), remounting panes on each rung it crossed.
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

// ---------------------------------------------------------------------------
// Sessions are first-class, named things (founder brief, 2026-07-26, verbatim:
// "Each session has a name and can be renamed. It starts with session #1").
// The name is STORED on every pane of the session (`TabInfo.groupLabel`) and
// persisted with the layout, so it can never drift when sessions are closed
// out of order — see `sessionGroups.ts` for the numbering rule.
// ---------------------------------------------------------------------------

describe("sessionsReducer — session/renamed", () => {
  function grouped(id: string, project: string, group: string | undefined, groupLabel?: string): TabInfo {
    return { ...tab(id, project), group, groupLabel };
  }

  it("names every pane of that session, and nothing else", () => {
    const before: SessionsState = {
      projects: [],
      tabs: [grouped("a", "p1", "g1"), grouped("b", "p1", "g1"), grouped("c", "p1", "g2"), grouped("d", "p2", "g1")],
      activeTabId: "a",
    };
    const next = sessionsReducer(before, {
      type: "session/renamed",
      project: "p1",
      group: "g1",
      name: "auth refactor",
    });
    expect(next.tabs.map((t) => t.groupLabel)).toEqual(["auth refactor", "auth refactor", undefined, undefined]);
  });

  it("trims the typed name", () => {
    const before: SessionsState = { projects: [], tabs: [grouped("a", "p1", "g1")], activeTabId: "a" };
    const next = sessionsReducer(before, { type: "session/renamed", project: "p1", group: "g1", name: "  ship it  " });
    expect(next.tabs[0].groupLabel).toBe("ship it");
  });

  it("clears the stored name back to its derived default when renamed to nothing", () => {
    const before: SessionsState = { projects: [], tabs: [grouped("a", "p1", "g1", "Session 1")], activeTabId: "a" };
    const next = sessionsReducer(before, { type: "session/renamed", project: "p1", group: "g1", name: "   " });
    expect(next.tabs[0].groupLabel).toBeUndefined();
  });

  it("renames a pre-grouping session addressed through the implicit group id", () => {
    const before: SessionsState = {
      projects: [],
      tabs: [grouped("a", "p1", undefined), grouped("b", "p1", "g1")],
      activeTabId: "a",
    };
    const next = sessionsReducer(before, {
      type: "session/renamed",
      project: "p1",
      group: UNGROUPED_SESSION_ID,
      name: "old work",
    });
    expect(next.tabs[0].groupLabel).toBe("old work");
    expect(next.tabs[1].groupLabel).toBeUndefined();
  });

  it("is a no-op for a session that has no panes", () => {
    const before: SessionsState = { projects: [], tabs: [grouped("a", "p1", "g1")], activeTabId: "a" };
    expect(sessionsReducer(before, { type: "session/renamed", project: "p1", group: "nope", name: "x" })).toBe(before);
  });
});

describe("layout persistence — the session name rides along", () => {
  it("round trips a renamed session so it comes back named after a relaunch", () => {
    const tabs: TabInfo[] = [
      { ...tab("sess-1", "p1"), group: "sess-grp-1", groupLabel: "auth refactor" },
      { ...tab("sess-2", "p1"), group: "sess-grp-1", groupLabel: "auth refactor" },
    ];
    expect(deserializeLayout(serializeLayout(tabs))).toEqual([
      { id: "sess-1", project: "p1", engine: "claude", cwd: "/tmp/p1", group: "sess-grp-1", groupLabel: "auth refactor" },
      { id: "sess-2", project: "p1", engine: "claude", cwd: "/tmp/p1", group: "sess-grp-1", groupLabel: "auth refactor" },
    ]);
  });

  it("persists the default name too, so numbering can never shift under the user", () => {
    const json = serializeLayout([{ ...tab("sess-1", "p1"), group: "sess-grp-1", groupLabel: "Session 2" }]);
    expect(JSON.parse(json).tabs[0].groupLabel).toBe("Session 2");
  });

  it("omits groupLabel entirely for a session that has never been named", () => {
    const json = serializeLayout([{ ...tab("a", "p1"), group: "sess-grp-1" }]);
    expect(JSON.parse(json).tabs[0]).not.toHaveProperty("groupLabel");
  });

  it("drops a garbage session name rather than the whole pane", () => {
    const raw = JSON.stringify({
      tabs: [
        { project: "p1", engine: "claude", cwd: "/tmp/p1", groupLabel: 7 },
        { project: "p2", engine: "claude", cwd: "/tmp/p2", groupLabel: "   " },
      ],
    });
    const restored = deserializeLayout(raw);
    expect(restored).toHaveLength(2);
    for (const t of restored) expect(t).not.toHaveProperty("groupLabel");
  });

  it("keeps a session name on a pane whose group id was rejected — it is still that pane's session", () => {
    const raw = JSON.stringify({
      tabs: [{ project: "p1", engine: "claude", cwd: "/tmp/p1", group: "bad group", groupLabel: "old work" }],
    });
    expect(deserializeLayout(raw)).toEqual([
      { project: "p1", engine: "claude", cwd: "/tmp/p1", groupLabel: "old work" },
    ]);
  });
});
