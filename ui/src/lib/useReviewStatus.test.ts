// Task 7 (left-pane redesign): mirrors `useGitBranch.test.ts`'s exact
// coverage shape for the new `useReviewStatus` hook — same poll-and-set
// pattern, same cancellation/cleanup guarantees, just against `reviewStatus`
// instead of `gitBranch`.
import { act, renderHook } from "@testing-library/react";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { REVIEW_STATUS_POLL_MS, useReviewStatus } from "./useReviewStatus";
import * as tauri from "./tauri";
import type { ReviewStatus } from "./tauri";

function makeStatus(overrides: Partial<ReviewStatus> = {}): ReviewStatus {
  return {
    repo_root: "/tmp/sample-project",
    branch: "main",
    detached: false,
    has_head: true,
    files: [],
    file_count: 0,
    added: 0,
    removed: 0,
    binary_count: 0,
    truncated: false,
    ...overrides,
  };
}

describe("useReviewStatus", () => {
  beforeEach(() => {
    vi.useFakeTimers();
  });

  afterEach(() => {
    vi.useRealTimers();
    vi.restoreAllMocks();
  });

  it("is null before the first fetch resolves, and null for a missing root", () => {
    const { result } = renderHook(() => useReviewStatus(null));
    expect(result.current).toBeNull();
  });

  it("fetches status once for a given root and reflects it once resolved", async () => {
    const status = makeStatus();
    vi.spyOn(tauri, "reviewStatus").mockResolvedValue(status);
    const { result } = renderHook(() => useReviewStatus("/tmp/sample-project"));
    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current).toEqual(status);
    expect(tauri.reviewStatus).toHaveBeenCalledWith("/tmp/sample-project");
    expect(tauri.reviewStatus).toHaveBeenCalledTimes(1);
  });

  it("resolves to null (not an error) when the command rejects — a non-repo root shouldn't break the sidebar", async () => {
    vi.spyOn(tauri, "reviewStatus").mockRejectedValue(new Error("not a git repo"));
    const { result } = renderHook(() => useReviewStatus("/tmp/not-a-repo"));
    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current).toBeNull();
  });

  it("re-fetches on the poll interval, not more often", async () => {
    const spy = vi.spyOn(tauri, "reviewStatus").mockResolvedValue(makeStatus());
    renderHook(() => useReviewStatus("/tmp/sample-project"));
    await act(async () => {
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(1);

    await act(async () => {
      vi.advanceTimersByTime(REVIEW_STATUS_POLL_MS - 1);
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(1);

    await act(async () => {
      vi.advanceTimersByTime(1);
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(2);
  });

  it("re-fetches immediately when root changes rather than waiting for the poll", async () => {
    const spy = vi.spyOn(tauri, "reviewStatus").mockImplementation(async (path: string) =>
      makeStatus({ repo_root: path }),
    );
    const { result, rerender } = renderHook(({ root }) => useReviewStatus(root), {
      initialProps: { root: "/tmp/a" },
    });
    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current?.repo_root).toBe("/tmp/a");

    rerender({ root: "/tmp/b" });
    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current?.repo_root).toBe("/tmp/b");
    expect(spy).toHaveBeenCalledWith("/tmp/b");
  });

  it("stops polling after unmount", async () => {
    const spy = vi.spyOn(tauri, "reviewStatus").mockResolvedValue(makeStatus());
    const { unmount } = renderHook(() => useReviewStatus("/tmp/sample-project"));
    await act(async () => {
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(1);
    unmount();
    await act(async () => {
      vi.advanceTimersByTime(REVIEW_STATUS_POLL_MS * 3);
      await Promise.resolve();
    });
    expect(spy).toHaveBeenCalledTimes(1);
  });

  it("ignoring a falsy root never calls the command", () => {
    const spy = vi.spyOn(tauri, "reviewStatus");
    renderHook(() => useReviewStatus(undefined as unknown as null));
    expect(spy).not.toHaveBeenCalled();
  });

  it("clears status back to null when root becomes null", async () => {
    vi.spyOn(tauri, "reviewStatus").mockResolvedValue(makeStatus());
    const { result, rerender } = renderHook(({ root }) => useReviewStatus(root), {
      initialProps: { root: "/tmp/a" as string | null },
    });
    await act(async () => {
      await Promise.resolve();
    });
    expect(result.current).not.toBeNull();

    rerender({ root: null });
    expect(result.current).toBeNull();
  });
});
