// Unit coverage for `newWorkspaceState.ts` — the New Workspace dialog's
// pure state, rewritten for the left-pane redesign (Task 12): folder +
// stats + two toggles, no name/layout/engines.
import { describe, expect, it } from "vitest";
import type { FolderStats } from "../lib/tauri";
import {
  canSubmit,
  initialNewWorkspaceState,
  newWorkspaceReducer,
  workspaceNameFromPath,
  type NewWorkspaceState,
} from "./newWorkspaceState";

const STATS: FolderStats = { files: 1234, languages: ["TS", "Rust"], git: true, branches: 3 };

describe("workspaceNameFromPath", () => {
  it("takes the basename", () => {
    expect(workspaceNameFromPath("/Users/b/Bruno.Digital/omniagent-web")).toBe("omniagent-web");
    expect(workspaceNameFromPath("/x/y/")).toBe("y");
  });

  it("survives trailing slashes, no slashes, and ~ paths", () => {
    expect(workspaceNameFromPath("/x/y///")).toBe("y");
    expect(workspaceNameFromPath("~/code/thing")).toBe("thing");
    expect(workspaceNameFromPath("plain")).toBe("plain");
    // "/" has no basename to speak of — fall back rather than return "".
    expect(workspaceNameFromPath("/")).toBe("/");
  });
});

describe("initialNewWorkspaceState", () => {
  it("defaults: ingest on, review notes off, no stats", () => {
    const s = initialNewWorkspaceState();
    expect(s).toMatchObject({ path: null, stats: null, ingestNow: true, reviewNotes: false });
    expect(s.submitting).toBe(false);
    expect(s.error).toBeNull();
  });

  it("is a fresh object each call — one dialog's edits never leak into the next", () => {
    expect(initialNewWorkspaceState()).not.toBe(initialNewWorkspaceState());
  });
});

describe("newWorkspaceReducer", () => {
  it("picking a path marks stats loading", () => {
    const s = newWorkspaceReducer(initialNewWorkspaceState(), { type: "path", path: "/p" });
    expect(s.path).toBe("/p");
    expect(s.stats).toBe("loading");
  });

  it("re-picking clears the previous folder's stats rather than showing them for the new one", () => {
    const first = newWorkspaceReducer(initialNewWorkspaceState(), { type: "path", path: "/a" });
    const loaded = newWorkspaceReducer(first, { type: "stats", stats: STATS });
    expect(loaded.stats).toEqual(STATS);
    const second = newWorkspaceReducer(loaded, { type: "path", path: "/b" });
    expect(second.stats).toBe("loading");
  });

  it("stats can land as null — a failed lookup shows placeholders, not an error", () => {
    const picked = newWorkspaceReducer(initialNewWorkspaceState(), { type: "path", path: "/p" });
    expect(newWorkspaceReducer(picked, { type: "stats", stats: null }).stats).toBeNull();
  });

  it("picking a path clears a previous error", () => {
    const withError: NewWorkspaceState = { ...initialNewWorkspaceState(), error: "boom" };
    expect(newWorkspaceReducer(withError, { type: "path", path: "/p" }).error).toBeNull();
  });

  it("toggles flip", () => {
    const base = initialNewWorkspaceState();
    const ingestOff = newWorkspaceReducer(base, { type: "ingestNow" });
    expect(ingestOff.ingestNow).toBe(false);
    expect(newWorkspaceReducer(ingestOff, { type: "ingestNow" }).ingestNow).toBe(true);

    const reviewOn = newWorkspaceReducer(base, { type: "reviewNotes" });
    expect(reviewOn.reviewNotes).toBe(true);
    expect(newWorkspaceReducer(reviewOn, { type: "reviewNotes" }).reviewNotes).toBe(false);
  });

  it("submit_started sets submitting and clears the error", () => {
    const withError: NewWorkspaceState = { ...initialNewWorkspaceState(), path: "/p", error: "boom" };
    const next = newWorkspaceReducer(withError, { type: "submit_started" });
    expect(next.submitting).toBe(true);
    expect(next.error).toBeNull();
  });

  it("submit_failed clears submitting and keeps the picked folder", () => {
    const submitting: NewWorkspaceState = {
      ...initialNewWorkspaceState(),
      path: "/p",
      submitting: true,
    };
    const next = newWorkspaceReducer(submitting, { type: "submit_failed", error: "disk full" });
    expect(next).toMatchObject({ submitting: false, error: "disk full", path: "/p" });
  });
});

describe("canSubmit", () => {
  it("is false with no folder picked", () => {
    expect(canSubmit(initialNewWorkspaceState())).toBe(false);
  });

  it("is true as soon as a folder is picked — stats never gate the button", () => {
    const picked = newWorkspaceReducer(initialNewWorkspaceState(), { type: "path", path: "/p" });
    expect(picked.stats).toBe("loading");
    expect(canSubmit(picked)).toBe(true);
  });

  it("is false while a submit is in flight", () => {
    const picked = newWorkspaceReducer(initialNewWorkspaceState(), { type: "path", path: "/p" });
    expect(canSubmit(newWorkspaceReducer(picked, { type: "submit_started" }))).toBe(false);
  });
});
