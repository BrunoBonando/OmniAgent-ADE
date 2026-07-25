import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { GIT_BRANCH_POLL_MS, useGitBranch } from "./useGitBranch";
import * as tauri from "./tauri";

describe("useGitBranch", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("is null before the first fetch resolves, and null for a missing cwd", () => {
    const { result } = renderHook(() => useGitBranch(null));
    expect(result.current).toBeNull();
  });

  it("fetches the branch once for a given cwd and reflects it once resolved", async () => {
    vi.spyOn(tauri, "gitBranch").mockResolvedValue("main");
    const { result } = renderHook(() => useGitBranch("/tmp/sample-project"));
    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current).toBe("main");
    expect(tauri.gitBranch).toHaveBeenCalledWith("/tmp/sample-project");
    expect(tauri.gitBranch).toHaveBeenCalledTimes(1);
  });

  it("resolves to null (not an error) when the command rejects — a non-git directory shouldn't break the pane", async () => {
    vi.spyOn(tauri, "gitBranch").mockRejectedValue(new Error("not a git repo"));
    const { result } = renderHook(() => useGitBranch("/tmp/not-a-repo"));
    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current).toBeNull();
  });

  it("re-fetches on the poll interval, not more often", async () => {
    const spy = vi.spyOn(tauri, "gitBranch").mockResolvedValue("main");
    renderHook(() => useGitBranch("/tmp/sample-project"));
    await act(async () => {
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(1);

    await act(async () => {
      vi.advanceTimersByTime(GIT_BRANCH_POLL_MS - 1);
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(1);

    await act(async () => {
      vi.advanceTimersByTime(1);
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(2);
  });

  it("re-fetches immediately when cwd changes rather than waiting for the poll", async () => {
    const spy = vi.spyOn(tauri, "gitBranch").mockImplementation(async (path: string) =>
      path === "/tmp/a" ? "main" : "feature/x",
    );
    const { result, rerender } = renderHook(({ cwd }) => useGitBranch(cwd), {
      initialProps: { cwd: "/tmp/a" },
    });
    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current).toBe("main");

    rerender({ cwd: "/tmp/b" });
    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current).toBe("feature/x");
    expect(spy).toHaveBeenCalledWith("/tmp/b");
  });

  it("stops polling after unmount", async () => {
    const spy = vi.spyOn(tauri, "gitBranch").mockResolvedValue("main");
    const { unmount } = renderHook(() => useGitBranch("/tmp/sample-project"));
    await act(async () => {
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(1);
    unmount();
    await act(async () => {
      vi.advanceTimersByTime(GIT_BRANCH_POLL_MS * 3);
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it("ignoring a falsy cwd never calls the command", () => {
    const spy = vi.spyOn(tauri, "gitBranch");
    renderHook(() => useGitBranch(undefined));
    expect(spy).not.toHaveBeenCalled();
  });
});
