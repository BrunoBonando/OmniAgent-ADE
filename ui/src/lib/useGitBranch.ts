// The pane header's git-branch pill (`⑂ main`, see the BridgeSpace
// reference at docs/reference/bridgespace-pane-grid-reference.png). A
// session's cwd/branch rarely changes mid-session, so this fetches once on
// mount (or whenever `cwd` itself changes) and otherwise only re-checks on a
// coarse interval — no need to poll on every render or every keystroke in
// the terminal. `gitBranch` (lib/tauri.ts -> `git_branch` in
// src-tauri/src/commands.rs) already resolves to `null` instead of
// rejecting for the common "not a repo" case; this hook also treats an
// actual rejection (e.g. a transient IPC hiccup) the same way — a pane's
// branch pill silently not showing is fine, breaking the pane over it isn't.
import { useEffect, useState } from "react";
import { gitBranch } from "./tauri";

/** "A git branch rarely changes mid-session; refreshing on session focus or
 * a coarse interval like 30s is plenty" (task brief, verbatim cadence). */
export const GIT_BRANCH_POLL_MS = 30_000;

export function useGitBranch(cwd: string | null | undefined): string | null {
  const [branch, setBranch] = useState<string | null>(null);

  useEffect(() => {
    if (!cwd) {
      setBranch(null);
      return;
    }
    let cancelled = false;

    const fetchBranch = () => {
      gitBranch(cwd)
        .then((result) => {
          if (!cancelled) setBranch(result);
        })
        .catch(() => {
          if (!cancelled) setBranch(null);
        });
    };

    fetchBranch();
    const interval = window.setInterval(fetchBranch, GIT_BRANCH_POLL_MS);
    return () => {
      cancelled = true;
      window.clearInterval(interval);
    };
  }, [cwd]);

  return branch;
}
