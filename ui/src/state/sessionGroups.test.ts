import { describe, expect, it } from "vitest";
import {
  UNGROUPED_SESSION_ID,
  adjacentSessionTab,
  currentSessionGroupId,
  groupTabsBySession,
  newSessionGroupId,
  nextSessionName,
  sessionEngineBreakdown,
  sessionShapeBadge,
  tabsInSession,
  visibleSessionGroupId,
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

describe("adjacentSessionTab", () => {
  const tabs = [
    tab("first", "p1", "g1"),
    tab("second", "p1", "g2"),
    tab("second-pane", "p1", "g2"),
    tab("third", "p1", "g3"),
  ];

  it("moves to the first pane in the next session", () => {
    expect(adjacentSessionTab(tabs, "p1", "second-pane", 1)?.id).toBe("third");
  });

  it("moves to the first pane in the previous session", () => {
    expect(adjacentSessionTab(tabs, "p1", "second", -1)?.id).toBe("first");
  });

  it("stops at the outer session boundaries", () => {
    expect(adjacentSessionTab(tabs, "p1", "first", -1)).toBeNull();
    expect(adjacentSessionTab(tabs, "p1", "third", 1)).toBeNull();
  });

  it("starts from the visible first session when focus is outside the project", () => {
    expect(adjacentSessionTab([...tabs, tab("other", "p2", "g4")], "p1", "other", 1)?.id).toBe("second");
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

describe("sessionShapeBadge", () => {
  it("matches the design's badges", () => {
    expect(sessionShapeBadge(1)).toBe("1");
    expect(sessionShapeBadge(2)).toBe("1×2");
    expect(sessionShapeBadge(4)).toBe("2×2");
    expect(sessionShapeBadge(6)).toBe("2×3");
    expect(sessionShapeBadge(8)).toBe("2×4");
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

describe("visibleSessionGroupId — which session the pane grid puts on screen", () => {
  it("is the focused pane's session when the focused pane is in this workspace", () => {
    const tabs = [tab("a", "p1", "g1"), tab("b", "p1", "g2")];
    expect(visibleSessionGroupId(tabs, "p1", "b")).toBe("g2");
  });

  it("falls back to the workspace's first session when focus is in a DIFFERENT workspace", () => {
    // Selecting a workspace in the sidebar doesn't move focus, so the grid
    // still has to answer "which session am I showing" for a project whose
    // panes nobody is focused on. The topmost session in the sidebar is the
    // one the eye lands on, so that's the one that shows.
    const tabs = [tab("a", "p1", "g1"), tab("b", "p1", "g2"), tab("c", "p2", "g3")];
    expect(visibleSessionGroupId(tabs, "p1", "c")).toBe("g1");
  });

  it("falls back to the first session when nothing is focused at all", () => {
    const tabs = [tab("a", "p1", "g1"), tab("b", "p1", "g2")];
    expect(visibleSessionGroupId(tabs, "p1", null)).toBe("g1");
  });

  it("is null for a workspace with no panes — there is no session to show", () => {
    expect(visibleSessionGroupId([tab("a", "p1", "g1")], "p2", "a")).toBeNull();
  });

  it("is also the JOIN target for a new pane: null on an empty workspace, so the caller mints a session", () => {
    // Absorbed from the retired `sessionGroupForNewPane` (fix round,
    // 2026-07-27) — `requestNewTab` resolves `existingGroup` through this
    // function now, and its `existingGroup ?? newSessionGroupId()` branch
    // rests on `null` meaning "this workspace has no panes at all".
    expect(visibleSessionGroupId([tab("z", "p2", "g9")], "p1", "z")).toBeNull();
    expect(visibleSessionGroupId([], "p1", null)).toBeNull();
  });

  it("answers with the implicit session for pre-grouping panes", () => {
    const tabs = [tab("a", "p1"), tab("b", "p1")];
    expect(visibleSessionGroupId(tabs, "p1", "b")).toBe(UNGROUPED_SESSION_ID);
    expect(visibleSessionGroupId(tabs, "p1", null)).toBe(UNGROUPED_SESSION_ID);
  });

  it("survives a stale activeTabId (a pane closed out from under it)", () => {
    const tabs = [tab("a", "p1", "g1"), tab("b", "p1", "g2")];
    expect(visibleSessionGroupId(tabs, "p1", "gone")).toBe("g1");
  });

  it("agrees with the sidebar: the session it shows is the one marked current", () => {
    // `groupTabsBySession`'s `isCurrent` and this function must never
    // disagree about the focused case, or the grid would show one session
    // while the sidebar's accent rail pointed at another.
    const tabs = [tab("a", "p1", "g1"), tab("b", "p1", "g2")];
    const visible = visibleSessionGroupId(tabs, "p1", "b");
    const marked = groupTabsBySession(tabs, "b")
      .find((p) => p.project === "p1")!
      .sessions.find((s) => s.isCurrent)!.id;
    expect(visible).toBe(marked);
  });
});
