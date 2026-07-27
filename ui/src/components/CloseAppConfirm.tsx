import { useEffect, useRef } from "react";

interface CloseAppConfirmProps {
  onLeaveRunning: () => void;
  onStopAndExit: () => void;
  onCancel: () => void;
}

export default function CloseAppConfirm({
  onLeaveRunning,
  onStopAndExit,
  onCancel,
}: CloseAppConfirmProps) {
  const panelRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") {
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
        aria-label="Active task running"
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
        style={{ maxWidth: 480 }}
      >
        <h2 className="close-pane-title">⚡ Active Agent Task Running</h2>
        <p className="close-pane-body">
          You have at least one terminal session currently executing an agent task.
          What would you like to do before closing?
        </p>
        <div className="close-pane-actions" style={{ flexDirection: "column", gap: 8 }}>
          <button
            className="close-pane-confirm"
            style={{ width: "100%", textAlign: "center" }}
            onClick={onLeaveRunning}
          >
            Leave Running in Background
          </button>
          <button
            className="close-pane-cancel"
            style={{ width: "100%", textAlign: "center", color: "#f87171", borderColor: "rgba(248,113,113,0.3)" }}
            onClick={onStopAndExit}
          >
            Stop Execution & Exit
          </button>
          <button
            className="close-pane-cancel"
            style={{ width: "100%", textAlign: "center" }}
            onClick={onCancel}
          >
            Cancel
          </button>
        </div>
        <div className="engine-picker-footer" style={{ marginTop: 12 }}>
          <span>esc cancel</span>
        </div>
      </div>
    </div>
  );
}
