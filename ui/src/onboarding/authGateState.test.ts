import { describe, expect, it } from "vitest";
import {
  AUTH_GATE_RESOLVED_SETTING_KEY,
  AUTH_PERSONA_SETTING_KEY,
  AUTH_SIGNED_IN_SETTING_KEY,
  PERSONA_OPTIONS,
  authGateAlreadyResolved,
  authGateReducer,
  describeAuthSummary,
  initialAuthGateState,
  personaLabel,
  type AuthGateState,
} from "./authGateState";

describe("authGateReducer", () => {
  it("starts on the login phase with no outcome yet", () => {
    expect(initialAuthGateState).toEqual({ phase: "login", outcome: null });
  });

  it("skip-from-login resolves immediately as not signed in, no persona", () => {
    const next = authGateReducer(initialAuthGateState, { type: "skip_login" });
    expect(next).toEqual({ phase: "resolved", outcome: { signedIn: false, persona: null } });
  });

  it("sign_in moves from login to the personalize phase without resolving yet", () => {
    const next = authGateReducer(initialAuthGateState, { type: "sign_in" });
    expect(next).toEqual({ phase: "personalize", outcome: null });
  });

  it("sign-in-then-answer resolves as signed in with the chosen persona", () => {
    let state: AuthGateState = initialAuthGateState;
    state = authGateReducer(state, { type: "sign_in" });
    state = authGateReducer(state, { type: "answer_selected", persona: "software-engineering" });
    expect(state).toEqual({
      phase: "resolved",
      outcome: { signedIn: true, persona: "software-engineering" },
    });
  });

  it("sign-in-then-skip-the-question resolves as signed in with no persona", () => {
    let state: AuthGateState = initialAuthGateState;
    state = authGateReducer(state, { type: "sign_in" });
    state = authGateReducer(state, { type: "skip_personalize" });
    expect(state).toEqual({ phase: "resolved", outcome: { signedIn: true, persona: null } });
  });

  it("ignores skip_login once past the login phase", () => {
    const personalizing: AuthGateState = { phase: "personalize", outcome: null };
    expect(authGateReducer(personalizing, { type: "skip_login" })).toBe(personalizing);
  });

  it("ignores sign_in once past the login phase", () => {
    const personalizing: AuthGateState = { phase: "personalize", outcome: null };
    expect(authGateReducer(personalizing, { type: "sign_in" })).toBe(personalizing);
  });

  it("ignores answer_selected/skip_personalize while still on login", () => {
    expect(authGateReducer(initialAuthGateState, { type: "answer_selected", persona: "student" })).toBe(
      initialAuthGateState,
    );
    expect(authGateReducer(initialAuthGateState, { type: "skip_personalize" })).toBe(initialAuthGateState);
  });

  it("ignores every action once resolved (terminal state)", () => {
    const resolved: AuthGateState = { phase: "resolved", outcome: { signedIn: true, persona: "research" } };
    expect(authGateReducer(resolved, { type: "sign_in" })).toBe(resolved);
    expect(authGateReducer(resolved, { type: "skip_login" })).toBe(resolved);
    expect(authGateReducer(resolved, { type: "answer_selected", persona: "other" })).toBe(resolved);
    expect(authGateReducer(resolved, { type: "skip_personalize" })).toBe(resolved);
  });
});

describe("authGateAlreadyResolved (the 'don't show again' gating logic)", () => {
  it("is false when the setting was never written (fresh install)", () => {
    expect(authGateAlreadyResolved(null)).toBe(false);
  });

  it("is true only for the exact string \"true\"", () => {
    expect(authGateAlreadyResolved("true")).toBe(true);
  });

  it("is false for anything else, including a stale/reset \"false\"", () => {
    expect(authGateAlreadyResolved("false")).toBe(false);
    expect(authGateAlreadyResolved("")).toBe(false);
    expect(authGateAlreadyResolved("1")).toBe(false);
    expect(authGateAlreadyResolved("TRUE")).toBe(false);
  });
});

describe("PERSONA_OPTIONS", () => {
  it("is a non-empty list of unique {id, label} pairs, dev-tool-relevant (not ChatGPT's business functions)", () => {
    expect(PERSONA_OPTIONS.length).toBeGreaterThan(0);
    const ids = PERSONA_OPTIONS.map((o) => o.id);
    expect(new Set(ids).size).toBe(ids.length);
    for (const o of PERSONA_OPTIONS) {
      expect(o.label.length).toBeGreaterThan(0);
    }
    // Sanity: the generic ChatGPT business-function categories don't belong here.
    const labels = PERSONA_OPTIONS.map((o) => o.label.toLowerCase());
    expect(labels).not.toContain("marketing");
    expect(labels).not.toContain("sales");
    expect(labels).not.toContain("human resources");
  });
});

describe("personaLabel", () => {
  it("resolves a known persona id to its label", () => {
    expect(personaLabel("software-engineering")).toBe("Software Engineering");
  });

  it("returns null for an unknown or empty id", () => {
    expect(personaLabel("not-a-real-id")).toBeNull();
    expect(personaLabel("")).toBeNull();
    expect(personaLabel(null)).toBeNull();
  });
});

describe("describeAuthSummary (AboutPanel's light-touch surfacing)", () => {
  it("describes a fresh/unresolved state plainly", () => {
    expect(describeAuthSummary(null, null)).toBe("Not signed in (dev mode).");
  });

  it("describes an explicit skip", () => {
    expect(describeAuthSummary("false", null)).toBe("Not signed in (dev mode).");
  });

  it("describes a fake sign-in with a captured persona", () => {
    expect(describeAuthSummary("true", "data-ml")).toBe("Signed in — Data & ML.");
  });

  it("describes a fake sign-in where the question was skipped", () => {
    expect(describeAuthSummary("true", null)).toBe("Signed in.");
    expect(describeAuthSummary("true", "")).toBe("Signed in.");
  });
});

describe("settings keys", () => {
  it("are distinct, stable string constants", () => {
    const keys = [AUTH_GATE_RESOLVED_SETTING_KEY, AUTH_SIGNED_IN_SETTING_KEY, AUTH_PERSONA_SETTING_KEY];
    expect(new Set(keys).size).toBe(keys.length);
    for (const k of keys) expect(typeof k).toBe("string");
  });
});
