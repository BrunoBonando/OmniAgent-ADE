import { describe, expect, it } from "vitest";
import { collapseHome, deriveHoverCard } from "./sessionHoverCard";
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

describe("deriveHoverCard — what the card actually shows", () => {
  it("derives every field the card renders from data the frontend genuinely has", () => {
    const model = deriveHoverCard({
      tab: tab({ label: "backend fix", status: "awaiting_approval" }),
      projectLabel: "My-Brain",
      branch: "main",
    });

    expect(model.title).toBe("backend fix");
    expect(model.projectLabel).toBe("My-Brain");
    expect(model.path).toBe("~/Documents/Bruno.Digital/My-Brain");
    expect(model.branch).toBe("main");
    expect(model.engine).toBe("claude");
    expect(model.engineLabel).toBe("Claude Code");
    expect(model.status.label).toBe("Needs approval");
    expect(model.status.explanation).toContain("approve");
    expect(model.restored).toBe(false);
  });

  it("falls back to the engine name as the title for a tab that was never renamed", () => {
    expect(deriveHoverCard({ tab: tab({ engine: "codex" }), projectLabel: "P" }).title).toBe("codex");
  });

  it("shows the neutral pre-signal state when no status has arrived yet", () => {
    const model = deriveHoverCard({ tab: tab({ status: undefined }), projectLabel: "P" });
    expect(model.status.key).toBe("unknown");
  });

  it("carries the branch through as null when the session's cwd isn't a git repo", () => {
    expect(deriveHoverCard({ tab: tab(), projectLabel: "P", branch: null }).branch).toBeNull();
    expect(deriveHoverCard({ tab: tab(), projectLabel: "P" }).branch).toBeNull();
  });

  it("reports a restored session so the card can say the tab came back alive", () => {
    expect(deriveHoverCard({ tab: tab({ restored: true }), projectLabel: "P" }).restored).toBe(true);
  });

  it("leaves the diff stat null — the git-review data does not exist yet, and a number here would be invented", () => {
    expect(deriveHoverCard({ tab: tab(), projectLabel: "P" }).diff).toBeNull();
  });
});
