import { describe, expect, it } from "vitest";
import {
  UNGROUPED_SESSION_ID,
  currentSessionGroupId,
  describeSession,
  groupTabsBySession,
  newSessionGroupId,
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

  it("labels sessions positionally within their own project", () => {
    const grouped = groupTabsBySession([tab("a", "p1", "g1"), tab("b", "p1", "g2"), tab("c", "p2", "g9")], null);
    expect(grouped[0].sessions.map((s) => s.label)).toEqual(["Session 1", "Session 2"]);
    expect(grouped[1].sessions.map((s) => s.label)).toEqual(["Session 1"]);
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

describe("describeSession", () => {
  const label = (e: string) => ({ claude: "Claude Code", codex: "Codex", shell: "Shell" })[e] ?? e;

  it("counts panes and lists each distinct engine once", () => {
    const session = groupTabsBySession(
      [tab("a", "p1", "g1"), tab("b", "p1", "g1", "shell"), tab("c", "p1", "g1")],
      null,
    )[0].sessions[0];
    expect(describeSession(session, label)).toBe("3 panes · Claude Code, Shell");
  });

  it("singularises a one-pane session", () => {
    const session = groupTabsBySession([tab("a", "p1", "g1", "codex")], null)[0].sessions[0];
    expect(describeSession(session, label)).toBe("1 pane · Codex");
  });
});
