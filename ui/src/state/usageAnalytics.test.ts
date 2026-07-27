import { describe, expect, it } from "vitest";
import {
  createUsageAnalyticsStore,
  deriveUsageInsights,
  parseTokenEstimateMax,
  recordInput,
  recordSessionOpened,
  recordStatusDuration,
  recordTokens,
} from "./usageAnalytics";

describe("usageAnalytics", () => {
  it("tracks sessions, commands, tokens and status duration", () => {
    const store = createUsageAnalyticsStore();
    const at = new Date("2026-07-28T10:00:00.000Z").getTime();
    recordSessionOpened(store, "proj-a", at);
    recordInput(store, "proj-a", 42, 2, at);
    recordTokens(store, "proj-a", 120, at);
    recordStatusDuration(store, "proj-a", "thinking", at, at + 30 * 60 * 1000);

    const insights = deriveUsageInsights(store, "proj-a", at + 2 * 24 * 60 * 60 * 1000);
    expect(insights.totals.sessionsOpened).toBe(1);
    expect(insights.totals.commandsSubmitted).toBe(2);
    expect(insights.totals.tokenCount).toBe(120);
    expect(insights.totals.thinkingMs).toBe(30 * 60 * 1000);
    expect(insights.bestHour).not.toBeNull();
  });

  it("extracts highest token mention from mixed output", () => {
    const text = "Cascading… (14s · ↓ 92 tokens)\nusage tokens: 105\nsomething else";
    expect(parseTokenEstimateMax(text)).toBe(105);
  });
});
