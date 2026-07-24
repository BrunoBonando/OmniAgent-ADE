import { describe, expect, it } from "vitest";
import { initialOnboardingState, onboardingReducer, type OnboardingState } from "./onboardingState";
import type { IngestionStatus } from "../lib/tauri";

function status(overrides: Partial<IngestionStatus>): IngestionStatus {
  return { running: false, projects_total: 0, projects_done: 0, total_nodes: 0, ...overrides };
}

describe("onboardingReducer", () => {
  it("starts in the pick phase", () => {
    expect(initialOnboardingState.phase).toBe("pick");
  });

  it("root_picked moves to ingesting regardless of starting state", () => {
    const next = onboardingReducer(initialOnboardingState, { type: "root_picked" });
    expect(next.phase).toBe("ingesting");
    expect(next.everRunning).toBe(false);
  });

  it("a status poll before the background thread has started (running: false, nothing done yet) stays ingesting", () => {
    const ingesting: OnboardingState = { phase: "ingesting", everRunning: false, status: null };
    const next = onboardingReducer(ingesting, {
      type: "status_polled",
      status: status({ running: false, projects_total: 0 }),
    });
    expect(next.phase).toBe("ingesting");
    expect(next.everRunning).toBe(false);
  });

  it("transitions to done only after running flips true then false", () => {
    let state: OnboardingState = { phase: "ingesting", everRunning: false, status: null };
    state = onboardingReducer(state, {
      type: "status_polled",
      status: status({ running: true, projects_total: 3, projects_done: 1, current_project: "demo" }),
    });
    expect(state.phase).toBe("ingesting");
    expect(state.everRunning).toBe(true);

    state = onboardingReducer(state, {
      type: "status_polled",
      status: status({ running: true, projects_total: 3, projects_done: 2 }),
    });
    expect(state.phase).toBe("ingesting");

    state = onboardingReducer(state, {
      type: "status_polled",
      status: status({ running: false, projects_total: 3, projects_done: 3, total_nodes: 42 }),
    });
    expect(state.phase).toBe("done");
    expect(state.status?.total_nodes).toBe(42);
  });

  it("ignores status polls once done or while still on the pick screen", () => {
    const done: OnboardingState = {
      phase: "done",
      everRunning: true,
      status: status({ running: false, projects_done: 1, projects_total: 1 }),
    };
    const next = onboardingReducer(done, {
      type: "status_polled",
      status: status({ running: true, projects_total: 9 }),
    });
    expect(next).toBe(done); // untouched — no accidental resurrection mid "done"

    const pick = onboardingReducer(initialOnboardingState, {
      type: "status_polled",
      status: status({ running: true }),
    });
    expect(pick).toBe(initialOnboardingState);
  });

  it("retry resets all the way back to the initial pick state", () => {
    const done: OnboardingState = {
      phase: "done",
      everRunning: true,
      status: status({ running: false, projects_total: 0 }),
    };
    expect(onboardingReducer(done, { type: "retry" })).toEqual(initialOnboardingState);
  });

  it("a fresh root_picked after done starts a brand new run (everRunning reset)", () => {
    const done: OnboardingState = {
      phase: "done",
      everRunning: true,
      status: status({ running: false }),
    };
    const next = onboardingReducer(done, { type: "root_picked" });
    expect(next).toEqual({ phase: "ingesting", everRunning: false, status: null });
  });
});
