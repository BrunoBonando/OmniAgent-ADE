import { describe, expect, it } from "vitest";
import {
  UNGROUPED_SESSION_ID,
  currentSessionGroupId,
  groupTabsBySession,
  newSessionGroupId,
  nextSessionName,
  sessionEngineBreakdown,
  sessionGroupForNewPane,
  tabsInSession,
} from "./sessionGroups";
import { isValidSessionId, type Engine, type TabInfo } from "./sessions";

function tab(id: string, project: string, group?: string, engine: Engine = "claude"): TabInfo {
  return { id, project, engine, cwd: `/tmp/${project}`, createdAt: 0, group };
}

describe("newSessionGroupId", () => {
  it("mints unique ids", () => {
    const ids = new Set(Array.from({ length: 50 }, () => newSessionGroupId()));
    expect(ids.size).toBe(50);
  });

  it("mints ids the layout persister will actually keep", () => {
    // A group id that `isValidSessionId` rejects would be silently dropped
    // by `serializeLayout`, un-grouping every pane on the next launch.
    expect(isValidSessionId(newSessionGroupId())).toBe(true);
  });
});

describe("groupTabsBySession", () => {
  it("groups panes by project, then by session, in first-seen order", () => {
    const tabs = [
      tab("a", "p1", "g1"),
      tab("b", "p2", "g2"),
      tab("c", "p1", "g1"),
      tab("d", "p1", "g3"),
    ];
    const grouped = groupTabsBySession(tabs, null);
    expect(grouped.map((g) => g.project)).toEqual(["p1", "p2"]);
    expect(grouped[0].sessions.map((s) => s.id)).toEqual(["g1", "g3"]);
    expect(grouped[0].sessions[0].tabs.map((t) => t.id)).toEqual(["a", "c"]);
    expect(grouped[0].sessions[1].tabs.map((t) => t.id)).toEqual(["d"]);
    expect(grouped[1].sessions[0].tabs.map((t) => t.id)).toEqual(["b"]);
  });

  it("falls back to Session N, per project, for sessions nobody has named", () => {
    const grouped = groupTabsBySession([tab("a", "p1", "g1"), tab("b", "p1", "g2"), tab("c", "p2", "g9")], null);
    expect(grouped[0].sessions.map((s) => s.label)).toEqual(["Session 1", "Session 2"]);
    expect(grouped[1].sessions.map((s) => s.label)).toEqual(["Session 1"]);
    // …and nothing was *stored*: these are derived defaults for panes that
    // predate stored names.
    expect(grouped[0].sessions.map((s) => s.name)).toEqual([undefined, undefined]);
  });

  it("carries each session's own root — the cwd its first pane was created in", () => {
    const tabs = [
      { ...tab("a", "p1", "g1"), cwd: "/repo" },
      { ...tab("b", "p1", "g1"), cwd: "/repo/packages/api" },
      { ...tab("c", "p1", "g2"), cwd: "/repo/packages/web" },
    ];
    const sessions = groupTabsBySession(tabs, null)[0].sessions;
    expect(sessions.map((s) => s.cwd)).toEqual(["/repo", "/repo/packages/web"]);
  });

  it("collects pre-grouping panes under one implicit session per project", () => {
    const grouped = groupTabsBySession([tab("a", "p1"), tab("b", "p1"), tab("c", "p2")], null);
    expect(grouped[0].sessions).toHaveLength(1);
    expect(grouped[0].sessions[0].id).toBe(UNGROUPED_SESSION_ID);
    expect(grouped[0].sessions[0].tabs.map((t) => t.id)).toEqual(["a", "b"]);
    expect(grouped[1].sessions[0].id).toBe(UNGROUPED_SESSION_ID);
  });

  it("marks exactly the session holding the focused pane as current", () => {
    const grouped = groupTabsBySession([tab("a", "p1", "g1"), tab("b", "p1", "g2"), tab("c", "p2", "g3")], "b");
    expect(grouped[0].sessions.map((s) => s.isCurrent)).toEqual([false, true]);
    expect(grouped[1].sessions.map((s) => s.isCurrent)).toEqual([false]);
  });

  it("marks nothing current when no pane is focused", () => {
    const grouped = groupTabsBySession([tab("a", "p1", "g1")], null);
    expect(grouped[0].sessions[0].isCurrent).toBe(false);
  });

  it("returns nothing for no tabs", () => {
    expect(groupTabsBySession([], null)).toEqual([]);
  });
});

describe("currentSessionGroupId", () => {
  it("is the focused pane's group", () => {
    expect(currentSessionGroupId([tab("a", "p1", "g1"), tab("b", "p1", "g2")], "b")).toBe("g2");
  });

  it("is the implicit group for a focused pre-grouping pane", () => {
    expect(currentSessionGroupId([tab("a", "p1")], "a")).toBe(UNGROUPED_SESSION_ID);
  });

  it("is null with nothing focused, or a focus id that isn't a live tab", () => {
    expect(currentSessionGroupId([tab("a", "p1", "g1")], null)).toBeNull();
    expect(currentSessionGroupId([tab("a", "p1", "g1")], "ghost")).toBeNull();
  });
});

describe("sessionGroupForNewPane", () => {
  it("joins the session the focused pane is in", () => {
    const tabs = [tab("a", "p1", "g1"), tab("b", "p1", "g2")];
    expect(sessionGroupForNewPane(tabs, "p1", "a")).toBe("g1");
    expect(sessionGroupForNewPane(tabs, "p1", "b")).toBe("g2");
  });

  it("falls back to the project's newest session when focus is in another project", () => {
    const tabs = [tab("a", "p1", "g1"), tab("b", "p1", "g2"), tab("z", "p2", "g9")];
    expect(sessionGroupForNewPane(tabs, "p1", "z")).toBe("g2");
  });

  it("returns null for a project with no panes at all — the caller mints a session", () => {
    expect(sessionGroupForNewPane([tab("z", "p2", "g9")], "p1", "z")).toBeNull();
    expect(sessionGroupForNewPane([], "p1", null)).toBeNull();
  });
});

describe("tabsInSession", () => {
  it("selects one session's panes, never another project's same-named group", () => {
    const tabs = [tab("a", "p1", "g1"), tab("b", "p1", "g2"), tab("c", "p2", "g1")];
    expect(tabsInSession(tabs, "p1", "g1").map((t) => t.id)).toEqual(["a"]);
  });

  it("selects pre-grouping panes through the implicit id", () => {
    expect(tabsInSession([tab("a", "p1"), tab("b", "p1", "g1")], "p1", UNGROUPED_SESSION_ID).map((t) => t.id)).toEqual([
      "a",
    ]);
  });
});

// ---------------------------------------------------------------------------
// A session's NAME (founder brief, 2026-07-26: "Each session has a name and
// can be renamed. It starts with session #1"). Stored on the panes
// (`TabInfo.groupLabel`); only unnamed sessions fall back to a derived
// "Session N".
// ---------------------------------------------------------------------------

function named(id: string, project: string, group: string, groupLabel?: string): TabInfo {
  return { ...tab(id, project, group), groupLabel };
}

describe("groupTabsBySession — stored session names", () => {
  it("shows the name the session actually carries", () => {
    const sessions = groupTabsBySession([named("a", "p1", "g1", "auth refactor")], null)[0].sessions;
    expect(sessions[0].name).toBe("auth refactor");
    expect(sessions[0].label).toBe("auth refactor");
  });

  it("takes the name from the first pane in the session that carries one", () => {
    const sessions = groupTabsBySession(
      [named("a", "p1", "g1"), named("b", "p1", "g1", "auth refactor")],
      null,
    )[0].sessions;
    expect(sessions[0].label).toBe("auth refactor");
  });

  it("keeps a stored name stable when an earlier session closes", () => {
    const all = [named("a", "p1", "g1", "Session 1"), named("b", "p1", "g2", "Session 2")];
    const afterClosingTheFirst = groupTabsBySession(all.slice(1), null)[0].sessions;
    // Positional labelling would have renamed this to "Session 1" — the bug
    // stored names exist to kill.
    expect(afterClosingTheFirst[0].label).toBe("Session 2");
  });

  it("never derives a default that collides with a name already in the workspace", () => {
    const sessions = groupTabsBySession(
      [named("a", "p1", "g1"), named("b", "p1", "g2", "Session 1"), named("c", "p1", "g3")],
      null,
    )[0].sessions;
    expect(sessions.map((s) => s.label)).toEqual(["Session 2", "Session 1", "Session 3"]);
  });
});

describe("nextSessionName — what a session about to be created is called", () => {
  it("starts at Session 1 in a workspace with nothing open", () => {
    expect(nextSessionName([], "p1")).toBe("Session 1");
    expect(nextSessionName([named("z", "p2", "g9", "Session 1")], "p1")).toBe("Session 1");
  });

  it("takes the lowest free number, so re-creating after closing #2 gives Session 2 again", () => {
    const live = [named("a", "p1", "g1", "Session 1"), named("c", "p1", "g3", "Session 3")];
    expect(nextSessionName(live, "p1")).toBe("Session 2");
  });

  it("never collides with a live session, including one the user typed 'Session 2' onto", () => {
    const live = [named("a", "p1", "g1", "Session 1"), named("b", "p1", "g2", "Session 2")];
    expect(nextSessionName(live, "p1")).toBe("Session 3");
  });

  it("skips over derived names too — an unnamed legacy session still holds its number", () => {
    expect(nextSessionName([named("a", "p1", "g1")], "p1")).toBe("Session 2");
  });

  it("numbers per workspace, never globally", () => {
    const live = [named("a", "p1", "g1", "Session 1"), named("b", "p1", "g2", "Session 2")];
    expect(nextSessionName(live, "p2")).toBe("Session 1");
  });

  it("ignores a user-chosen name that isn't a number at all", () => {
    expect(nextSessionName([named("a", "p1", "g1", "auth refactor")], "p1")).toBe("Session 1");
  });
});

describe("sessionEngineBreakdown — how many terminals of which engine", () => {
  it("counts each engine once, in first-seen order, with its own tally", () => {
    const session = groupTabsBySession(
      [tab("a", "p1", "g1"), tab("b", "p1", "g1", "shell"), tab("c", "p1", "g1")],
      null,
    )[0].sessions[0];
    expect(sessionEngineBreakdown(session)).toEqual([
      { engine: "claude", count: 2 },
      { engine: "shell", count: 1 },
    ]);
  });
});
