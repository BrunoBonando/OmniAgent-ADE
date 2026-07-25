import { describe, expect, it } from "vitest";
import { accountBadgeInitial, accountMenuItems, deriveAccountBadgeState } from "./accountBadgeState";

describe("deriveAccountBadgeState", () => {
  it("is not signed in for a fresh/never-resolved state", () => {
    expect(deriveAccountBadgeState(null, null)).toEqual({ signedIn: false, personaLabel: null });
  });

  it("is not signed in after an explicit skip-from-login", () => {
    expect(deriveAccountBadgeState("false", null)).toEqual({ signedIn: false, personaLabel: null });
  });

  it("is signed in with a resolved persona label", () => {
    expect(deriveAccountBadgeState("true", "data-ml")).toEqual({ signedIn: true, personaLabel: "Data & ML" });
  });

  it("is signed in with no persona when the personalize question was skipped", () => {
    expect(deriveAccountBadgeState("true", "")).toEqual({ signedIn: true, personaLabel: null });
    expect(deriveAccountBadgeState("true", null)).toEqual({ signedIn: true, personaLabel: null });
  });

  it("ignores a persona value when not signed in, even if one is somehow present", () => {
    // Defensive: authGateReducer never actually produces this combination,
    // but the badge must never show a persona for a signed-out user.
    expect(deriveAccountBadgeState("false", "software-engineering")).toEqual({
      signedIn: false,
      personaLabel: null,
    });
  });

  it("treats an unknown persona id the same as no persona", () => {
    expect(deriveAccountBadgeState("true", "not-a-real-id")).toEqual({ signedIn: true, personaLabel: null });
  });
});

describe("accountBadgeInitial", () => {
  it("is null when there's no persona label (not signed in, or signed in but skipped)", () => {
    expect(accountBadgeInitial({ signedIn: false, personaLabel: null })).toBeNull();
    expect(accountBadgeInitial({ signedIn: true, personaLabel: null })).toBeNull();
  });

  it("is the uppercased first letter of the persona label", () => {
    expect(accountBadgeInitial({ signedIn: true, personaLabel: "Data & ML" })).toBe("D");
    expect(accountBadgeInitial({ signedIn: true, personaLabel: "Student" })).toBe("S");
  });
});

describe("accountMenuItems", () => {
  it("signed in: Preferences/Billing enabled with no gating hint, Log out present, no Sign in row", () => {
    const items = accountMenuItems(true);
    expect(items.map((i) => i.id)).toEqual(["preferences", "billing", "log-out"]);
    expect(items.every((i) => i.enabled)).toBe(true);
    expect(items.find((i) => i.id === "preferences")?.hint).toBeUndefined();
    expect(items.find((i) => i.id === "billing")?.hint).toBeUndefined();
  });

  it("not signed in: Preferences/Billing disabled with a gating hint, Sign in present and enabled, no Log out row", () => {
    const items = accountMenuItems(false);
    expect(items.map((i) => i.id)).toEqual(["preferences", "billing", "sign-in"]);
    expect(items.find((i) => i.id === "preferences")).toMatchObject({ enabled: false, hint: "Sign in to access" });
    expect(items.find((i) => i.id === "billing")).toMatchObject({ enabled: false, hint: "Sign in to access" });
    expect(items.find((i) => i.id === "sign-in")).toMatchObject({ enabled: true, label: "Sign in" });
  });

  it("item order is stable across both auth states (no reshuffle on sign-in)", () => {
    expect(accountMenuItems(true).map((i) => i.id).slice(0, 2)).toEqual(["preferences", "billing"]);
    expect(accountMenuItems(false).map((i) => i.id).slice(0, 2)).toEqual(["preferences", "billing"]);
  });
});
