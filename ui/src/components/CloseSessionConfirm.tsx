// The confirmation behind the session row's hover-revealed close (founder
// ask, 2026-07-26: "I must be able to close a session") — the same dialog
// shape as `CloseWorkspaceConfirm`, scoped to one session: closing kills
// every terminal in the session (`session_kill` tears down each tmux session
// behind them), so it can end a Claude conversation mid-thought. State the
// consequence in numbers, then two buttons.
//
// Unlike a workspace close, nothing is hidden or remembered: the workspace
// row stays, only this session's panes go.
import { useEffect, useRef } from "react";

interface CloseSessionConfirmProps {
  /** The session's display name (`SessionGroup.label`). */
  label: string;
  /** How many live terminals are about to be killed. */
  terminals: number;
  onConfirm: () => void;
  onCancel: () => void;
}

export default function CloseSessionConfirm({
  label,
  terminals,
  onConfirm,
  onCancel,
}: CloseSessionConfirmProps) {
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
        aria-label="Close session"
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <h2 className="close-pane-title">Close this session?</h2>
        <p className="close-pane-body">
          <strong>{label}</strong> and its {terminals} {terminals === 1 ? "terminal" : "terminals"}{" "}
          stop now — a Claude or Codex conversation running in one of them ends here. The
          workspace stays open.
        </p>
        <div className="close-pane-actions">
          <button className="close-pane-confirm" onClick={onConfirm}>
            Close session
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
