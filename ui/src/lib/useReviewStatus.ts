// Poll `review_status` for the active workspace so the sidebar's FILES
// section can show live git badges (Task 7, left-pane redesign). Mirrors
// `useGitBranch.ts`'s exact shape — fetch on mount/root-change, then a coarse
// interval, cancellation guard against a stale in-flight response, `null` on
// anything that isn't a clean repo read (not-a-repo, transient IPC hiccup) so
// a pane's missing badges never breaks the sidebar. 15s rather than
// `useGitBranch`'s 30s: uncommitted file status changes far more often than a
// branch name does, but still doesn't need to be real-time (design's own
// "glanceable, not real-time" bar for this section).
// ponytail: poll-only; if it ever needs to be instant, refresh on the
// existing dir-changed events instead of shortening the interval.
import { useEffect, useState } from "react";
import { reviewStatus, type ReviewStatus } from "./tauri";

export const REVIEW_STATUS_POLL_MS = 15_000;

export function useReviewStatus(root: string | null): ReviewStatus | null {
  const [status, setStatus] = useState<ReviewStatus | null>(null);

  useEffect(() => {
    if (!root) {
      setStatus(null);
      return;
    }
    let cancelled = false;

    const fetchStatus = () => {
      reviewStatus(root)
        .then((result) => {
          if (!cancelled) setStatus(result);
        })
        .catch(() => {
          if (!cancelled) setStatus(null); // not a repo (or a transient hiccup) -> no badges
        });
    };

    fetchStatus();
    const interval = window.setInterval(fetchStatus, REVIEW_STATUS_POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [root]);

  return status;
}
