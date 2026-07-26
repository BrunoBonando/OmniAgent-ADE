// The confirmation behind the sidebar's hover-revealed workspace close
// (founder ask, 2026-07-26, verbatim: "add the possibility to close a
// workspace, on hover").
//
// Closing a workspace kills every terminal in it — `session_kill` also tears
// down the tmux session behind each one — so it can end a Claude session
// that is mid-thought. That is exactly the situation ⌘W's `ClosePaneConfirm`
// was built for, one terminal at a time, and this is the same dialog shape
// for the many-at-once case: state the consequence in numbers, then two
// buttons.
//
// The copy carries the *other* half of the answer just as plainly, because
// "close" is a word that could reasonably mean "delete this project from
// OmniAgent": nothing is deleted, the brain keeps everything it ingested,
// and adding the folder again brings the workspace straight back. See
// `state/closedWorkspaces.ts` for why that is the reading this implements.
import { useEffect, useRef } from "react";

interface CloseWorkspaceConfirmProps {
  label: string;
  /** How many live terminals are about to be killed. */
  terminals: number;
  /** …across how many sessions. */
  sessions: number;
  onConfirm: () => void;
  onCancel: () => void;
}

function count(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`;
}

export default function CloseWorkspaceConfirm({
  label,
  terminals,
  sessions,
  onConfirm,
  onCancel,
}: CloseWorkspaceConfirmProps) {
  const panelRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Enter") {
      e.preventDefault();
      onConfirm();
    } else if (e.key === "Escape") {
      e.preventDefault();
      onCancel();
    }
  }

  return (
    <div className="overlay-backdrop" onMouseDown={onCancel}>
      <div
        ref={panelRef}
        className="close-pane-panel"
        role="dialog"
        aria-label="Close workspace"
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <h2 className="close-pane-title">Close this workspace?</h2>
        <p className="close-pane-body">
          {terminals > 0 ? (
            <>
              <strong>{label}</strong> leaves the sidebar, and{" "}
              {count(terminals, "terminal", "terminals")} in{" "}
              {count(sessions, "session", "sessions")} stop now — a Claude or Codex conversation
              running in one of them ends here.
            </>
          ) : (
            <>
              <strong>{label}</strong> leaves the sidebar. Nothing is running in it.
            </>
          )}
        </p>
        <p className="close-pane-body">
          Nothing is deleted: the folder, everything OmniAgent has ingested from it and every
          memory note stay in your brain. Add the folder again to reopen it.
        </p>
        <div className="close-pane-actions">
          <button className="close-pane-confirm" onClick={onConfirm}>
            Close workspace
          </button>
          <button className="close-pane-cancel" onClick={onCancel}>
            Cancel
          </button>
        </div>
        <div className="engine-picker-footer">
          <span>&#8629; confirm</span>
          <span>esc cancel</span>
        </div>
      </div>
    </div>
  );
}
