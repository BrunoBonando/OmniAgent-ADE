// The confirmation ⌘W asks for (founder bug, Bruno, 2026-07-26, verbatim:
// *"cmd+w is closing the full app instead of confirming closing the current
// terminal"* — "confirming" is the ask, not just "closing").
//
// Closing a pane is destructive in a way the rest of the app isn't: it kills
// the engine and, with it, the tmux session behind it (`sessions.rs`'s
// `kill()` is the *only* thing that deletes one), so a mistyped ⌘W ends a live
// Claude conversation with no undo. Hence the same shape `AboutPanel` uses for
// "Rebuild brain" — state the consequence, then two buttons.
//
// Keyboard-first, like every other dialog here (`NewSessionModal`,
// `NewWorkspaceModal`): the panel takes focus on mount, Enter confirms, Esc
// cancels, so ⌘W-Enter closes a pane without touching the mouse.
import { useEffect, useRef } from "react";

interface ClosePaneConfirmProps {
  /** What the user calls this pane — its title, or failing that its engine. */
  label: string;
  onConfirm: () => void;
  onCancel: () => void;
}

export default function ClosePaneConfirm({ label, onConfirm, onCancel }: ClosePaneConfirmProps) {
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
        aria-label="Close terminal"
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <h2 className="close-pane-title">Close this terminal?</h2>
        <p className="close-pane-body">
          <strong>{label}</strong> and whatever it is running will be ended. A Claude or Codex
          conversation in this pane stops here — it is not restored the next time you open the
          app.
        </p>
        <div className="close-pane-actions">
          <button className="close-pane-confirm" onClick={onConfirm}>
            Close terminal
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
