import { describe, expect, it } from "vitest";
import { collapseHome, deriveSessionCard } from "./sessionHoverCard";
import { groupTabsBySession } from "./sessionGroups";
import type { TabInfo } from "./sessions";

function tab(overrides: Partial<TabInfo> = {}): TabInfo {
  return {
    id: "sess-1",
    project: "p1",
    engine: "claude",
    cwd: "/Users/bonando/Documents/Bruno.Digital/My-Brain",
    createdAt: 0,
    ...overrides,
  };
}

describe("collapseHome — Warp's `~/Documents/…` path rendering", () => {
  it("collapses a macOS home directory to ~", () => {
    expect(collapseHome("/Users/bonando/Documents/Bruno.Digital/My-Brain")).toBe(
      "~/Documents/Bruno.Digital/My-Brain",
    );
  });

  it("collapses the home directory itself, with no trailing slash", () => {
    expect(collapseHome("/Users/bonando")).toBe("~");
    expect(collapseHome("/Users/bonando/")).toBe("~");
  });

  it("collapses a Linux home too", () => {
    expect(collapseHome("/home/bruno/code/thing")).toBe("~/code/thing");
  });

  it("leaves paths outside a home directory exactly as they are", () => {
    expect(collapseHome("/tmp/p1")).toBe("/tmp/p1");
    expect(collapseHome("/Users")).toBe("/Users");
    expect(collapseHome("/opt/homebrew/bin")).toBe("/opt/homebrew/bin");
  });

  it("never throws on an empty or odd path", () => {
    expect(collapseHome("")).toBe("");
    expect(collapseHome("relative/path")).toBe("relative/path");
  });
});

describe("deriveSessionCard — what the card shows about a whole session", () => {
  // The card moved from the pane header to the sidebar's session row
  // (founder, 2026-07-26: "The hover part is currently wrong: it's not on
  // the terminal itself, but on session menu on the left"), so every field
  // is now scoped to the session rather than to one terminal.
  function session(tabs: TabInfo[], activeTabId: string | null = null) {
    return groupTabsBySession(tabs, activeTabId)[0].sessions[0];
  }

  it("derives every field the card renders from data the frontend genuinely has", () => {
    const model = deriveSessionCard({
      session: session([
        tab({ id: "s1", group: "g1", groupLabel: "auth refactor", status: "thinking" }),
        tab({ id: "s2", group: "g1", engine: "shell", status: "awaiting_approval" }),
      ]),
      projectLabel: "My-Brain",
      branch: "main",
    });

    expect(model.name).toBe("auth refactor");
    expect(model.projectLabel).toBe("My-Brain");
    expect(model.path).toBe("~/Documents/Bruno.Digital/My-Brain");
    expect(model.branch).toBe("main");
    expect(model.terminals).toBe(2);
    expect(model.engines).toEqual([
      { engine: "claude", label: "Claude Code", count: 1 },
      { engine: "shell", label: "Shell", count: 1 },
    ]);
    // The session speaks with its most significant terminal's voice.
    expect(model.status.label).toBe("Needs approval");
    expect(model.status.explanation).toContain("approve");
    expect(model.restored).toBe(false);
  });

  it("names an unnamed session by its derived default", () => {
    const model = deriveSessionCard({ session: session([tab({ group: "g1" })]), projectLabel: "P" });
    expect(model.name).toBe("Session 1");
  });

  it("reads the path from the session's own root, not from whichever terminal moved", () => {
    const model = deriveSessionCard({
      session: session([
        tab({ id: "s1", group: "g1", cwd: "/Users/bonando/code/api" }),
        tab({ id: "s2", group: "g1", cwd: "/Users/bonando/code/api/vendor" }),
      ]),
      projectLabel: "P",
    });
    expect(model.path).toBe("~/code/api");
  });

  it("shows the neutral pre-signal state when nothing in the session has reported yet", () => {
    const model = deriveSessionCard({ session: session([tab({ group: "g1" })]), projectLabel: "P" });
    expect(model.status.key).toBe("unknown");
  });

  it("carries the branch through as null when the session's root isn't a git repo", () => {
    const s = session([tab({ group: "g1" })]);
    expect(deriveSessionCard({ session: s, projectLabel: "P", branch: null }).branch).toBeNull();
    expect(deriveSessionCard({ session: s, projectLabel: "P" }).branch).toBeNull();
  });

  it("says a session was restored when ANY of its terminals came back alive", () => {
    const model = deriveSessionCard({
      session: session([
        tab({ id: "s1", group: "g1" }),
        tab({ id: "s2", group: "g1", restored: true }),
      ]),
      projectLabel: "P",
    });
    expect(model.restored).toBe(true);
  });

  it("counts terminals per engine so two Claudes read as two, not one", () => {
    const model = deriveSessionCard({
      session: session([
        tab({ id: "s1", group: "g1" }),
        tab({ id: "s2", group: "g1" }),
        tab({ id: "s3", group: "g1", engine: "codex" }),
      ]),
      projectLabel: "P",
    });
    expect(model.terminals).toBe(3);
    expect(model.engines).toEqual([
      { engine: "claude", label: "Claude Code", count: 2 },
      { engine: "codex", label: "Codex", count: 1 },
    ]);
  });

  it("leaves the diff stat null — the git-review data does not exist yet, and a number here would be invented", () => {
    expect(deriveSessionCard({ session: session([tab({ group: "g1" })]), projectLabel: "P" }).diff).toBeNull();
  });
});
