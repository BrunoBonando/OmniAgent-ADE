import { describe, expect, it } from "vitest";
import {
  addProjectReducer,
  basenameOf,
  canSubmit,
  initialAddProjectState,
  type AddProjectState,
} from "./addProjectState";

describe("basenameOf", () => {
  it("returns the last path segment", () => {
    expect(basenameOf("/Users/bruno/code/my-project")).toBe("my-project");
  });

  it("strips a trailing slash before taking the last segment", () => {
    expect(basenameOf("/Users/bruno/code/my-project/")).toBe("my-project");
  });

  it("returns the whole string when there's no separator", () => {
    expect(basenameOf("my-project")).toBe("my-project");
  });
});

describe("addProjectReducer", () => {
  it("starts in the pick phase with nothing chosen yet", () => {
    expect(initialAddProjectState).toEqual({ phase: "pick", path: null, name: "", error: null });
  });

  it("folder_picked moves to the name phase, defaulting the name to the folder basename", () => {
    const next = addProjectReducer(initialAddProjectState, { type: "folder_picked", path: "/tmp/demo-project" });
    expect(next).toEqual({ phase: "name", path: "/tmp/demo-project", name: "demo-project", error: null });
  });

  it("name_changed updates only the name", () => {
    const named: AddProjectState = { phase: "name", path: "/tmp/demo", name: "demo", error: null };
    const next = addProjectReducer(named, { type: "name_changed", name: "renamed" });
    expect(next).toEqual({ phase: "name", path: "/tmp/demo", name: "renamed", error: null });
  });

  it("choose_different_folder goes back to pick and clears the path", () => {
    const named: AddProjectState = { phase: "name", path: "/tmp/demo", name: "demo", error: null };
    const next = addProjectReducer(named, { type: "choose_different_folder" });
    expect(next.phase).toBe("pick");
    expect(next.path).toBeNull();
  });

  it("submit_started moves to submitting and clears any prior error", () => {
    const named: AddProjectState = { phase: "name", path: "/tmp/demo", name: "demo", error: "boom" };
    const next = addProjectReducer(named, { type: "submit_started" });
    expect(next.phase).toBe("submitting");
    expect(next.error).toBeNull();
  });

  it("submit_failed falls back to the name phase, carrying the error and keeping path/name", () => {
    const submitting: AddProjectState = { phase: "submitting", path: "/tmp/demo", name: "demo", error: null };
    const next = addProjectReducer(submitting, { type: "submit_failed", error: "disk full" });
    expect(next).toEqual({ phase: "name", path: "/tmp/demo", name: "demo", error: "disk full" });
  });
});

describe("canSubmit", () => {
  it("is false during pick (no path yet)", () => {
    expect(canSubmit(initialAddProjectState)).toBe(false);
  });

  it("is false with a blank/whitespace-only name", () => {
    expect(canSubmit({ phase: "name", path: "/tmp/demo", name: "   ", error: null })).toBe(false);
  });

  it("is true once the name phase has a non-blank name", () => {
    expect(canSubmit({ phase: "name", path: "/tmp/demo", name: "demo", error: null })).toBe(true);
  });

  it("is false while a submit is already in flight", () => {
    expect(canSubmit({ phase: "submitting", path: "/tmp/demo", name: "demo", error: null })).toBe(false);
  });
});
