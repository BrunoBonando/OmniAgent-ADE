import { describe, expect, it } from "vitest";
import {
  accountBadgeInitial,
  accountBadgeSubtitle,
  accountMenuItems,
  brainLine,
  deriveAccountBadgeState,
} from "./accountBadgeState";
import { FAKE_ACCOUNT_NAME } from "../onboarding/authGateState";

describe("deriveAccountBadgeState", () => {
  it("defaults to signed in as the fake dev identity when nothing has been written", () => {
    // Bruno, 2026-07-26: "just make a fake one as if I was logged in as
    // BrunoBonando" — a fresh install shows the signed-in experience.
    expect(deriveAccountBadgeState(null, null)).toEqual({
      signedIn: true,
      personaLabel: null,
      displayName: FAKE_ACCOUNT_NAME,
    });
  });

  it("is not signed in after an explicit skip-from-login or log out", () => {
    expect(deriveAccountBadgeState("false", null)).toEqual({
      signedIn: false,
      personaLabel: null,
      displayName: null,
    });
  });

  it("is signed in with a resolved persona label", () => {
    expect(deriveAccountBadgeState("true", "data-ml")).toEqual({
      signedIn: true,
      personaLabel: "Data & ML",
      displayName: FAKE_ACCOUNT_NAME,
    });
  });

  it("is signed in with no persona when the personalize question was skipped", () => {
    expect(deriveAccountBadgeState("true", "").personaLabel).toBeNull();
    expect(deriveAccountBadgeState("true", null).personaLabel).toBeNull();
  });

  it("ignores a persona value when not signed in, even if one is somehow present", () => {
    // Defensive: authGateReducer never actually produces this combination,
    // but the badge must never show a persona (or a name) for a signed-out
    // user.
    expect(deriveAccountBadgeState("false", "software-engineering")).toEqual({
      signedIn: false,
      personaLabel: null,
      displayName: null,
    });
  });

  it("treats an unknown persona id the same as no persona", () => {
    expect(deriveAccountBadgeState("true", "not-a-real-id").personaLabel).toBeNull();
  });
});

describe("accountBadgeInitial", () => {
  it("is the signed-in user's initial", () => {
    expect(accountBadgeInitial(deriveAccountBadgeState("true", "data-ml"))).toBe("B");
    expect(accountBadgeInitial(deriveAccountBadgeState(null, null))).toBe("B");
  });

  it("is null when signed out, so the badge falls back to its placeholder glyph", () => {
    expect(accountBadgeInitial(deriveAccountBadgeState("false", null))).toBeNull();
  });
});

describe("accountBadgeSubtitle", () => {
  it("shows the captured persona when there is one", () => {
    expect(accountBadgeSubtitle(deriveAccountBadgeState("true", "devops-infra"))).toBe("DevOps & Infrastructure");
  });

  it("is honest that the identity is a dev-mode placeholder", () => {
    expect(accountBadgeSubtitle(deriveAccountBadgeState("true", null))).toContain("dev mode");
    expect(accountBadgeSubtitle(deriveAccountBadgeState("false", null))).toBe("Not signed in (dev mode).");
  });
});

describe("accountMenuItems", () => {
  it("signed in: everything enabled, Log out present, no Sign in row", () => {
    const items = accountMenuItems(true);
    expect(items.map((i) => i.id)).toEqual([
      "preferences",
      "keyboard-shortcuts",
      "view-logs",
      "review",
      "about",
      "billing",
      "log-out",
    ]);
    expect(items.every((i) => i.enabled)).toBe(true);
    expect(items.find((i) => i.id === "preferences")?.hint).toBeUndefined();
  });

  it("not signed in: account rows gated, the local ones still work, Sign in swapped in", () => {
    const items = accountMenuItems(false);
    expect(items.map((i) => i.id)).toEqual([
      "preferences",
      "keyboard-shortcuts",
      "view-logs",
      "review",
      "about",
      "billing",
      "sign-in",
    ]);
    expect(items.find((i) => i.id === "preferences")).toMatchObject({ enabled: false, hint: "Sign in to access" });
    expect(items.find((i) => i.id === "billing")).toMatchObject({ enabled: false, hint: "Sign in to access" });
    // Shortcuts and logs are facts about this machine, not about an account.
    expect(items.find((i) => i.id === "keyboard-shortcuts")?.enabled).toBe(true);
    expect(items.find((i) => i.id === "view-logs")?.enabled).toBe(true);
    expect(items.find((i) => i.id === "sign-in")).toMatchObject({ enabled: true, label: "Sign in" });
  });

  it("item order is stable across both auth states (no reshuffle on sign-in)", () => {
    expect(accountMenuItems(true).map((i) => i.id).slice(0, 4)).toEqual(
      accountMenuItems(false).map((i) => i.id).slice(0, 4),
    );
  });

  it("says of every row whether it really does something", () => {
    // The honesty contract: a row is a real action, an explicit placeholder,
    // or the auth reset — never a dead button pretending otherwise.
    for (const item of [...accountMenuItems(true), ...accountMenuItems(false)]) {
      expect(["action", "placeholder", "auth"]).toContain(item.kind);
    }
    const wired = accountMenuItems(true).filter((i) => i.kind === "action").map((i) => i.id);
    expect(wired).toEqual(["keyboard-shortcuts", "view-logs", "review", "about"]);
  });
});

describe("brainLine", () => {
  const MIN = 60_000;
  it("running ingestion wins", () => {
    expect(
      brainLine({ running: true, projects_total: 4, projects_done: 1, total_nodes: 10 }, null, 0),
    ).toEqual({ text: "Ingesting · 1 of 4 projects", tone: "busy" });
  });
  it("running ingestion wins even over an already-populated lastIndexedAt", () => {
    // Proves `running` is checked before the "already indexed" branch —
    // this is the re-ingesting-a-known-brain case, not the first-ever ingest
    // the "running ingestion wins" case above covers.
    expect(
      brainLine({ running: true, projects_total: 4, projects_done: 1, total_nodes: 10 }, 1_000_000, 1_500_000),
    ).toEqual({ text: "Ingesting · 1 of 4 projects", tone: "busy" });
  });
  it("error surfaces", () => {
    expect(
      brainLine({ running: false, projects_total: 0, projects_done: 0, total_nodes: 0, error: "boom" }, null, 0),
    ).toEqual({ text: "Ingest failed — open About to rebuild", tone: "error" });
  });
  it("error wins even over an already-populated lastIndexedAt", () => {
    // Proves `error` is checked before the "already indexed" branch — a
    // brain that indexed successfully before but just failed a re-ingest
    // must show the failure, not a stale "indexed Xm ago".
    expect(
      brainLine(
        { running: false, projects_total: 0, projects_done: 0, total_nodes: 0, error: "boom" },
        1_000_000,
        1_500_000,
      ),
    ).toEqual({ text: "Ingest failed — open About to rebuild", tone: "error" });
  });
  it("indexed shows relative minutes", () => {
    expect(brainLine(null, 1_000_000, 1_000_000 + 8 * MIN)).toEqual({ text: "Brain indexed · 8m ago", tone: "good" });
  });
  it("indexed over an hour ago shows hours", () => {
    expect(brainLine(null, 0, 90 * MIN).text).toBe("Brain indexed · 1h ago");
  });
  it("never indexed", () => {
    expect(brainLine(null, null, 0)).toEqual({ text: "Nothing indexed yet", tone: "idle" });
  });
});
