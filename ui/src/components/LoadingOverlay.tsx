// Full-window loading overlay — shown whenever the app is restoring a
// workspace's first session after the workspace shell is already visible
// (workspace switch from the sidebar, or the startup-screen → workspace
// transition). Uses the blue-gradient working animation, but at 112 px so it
// reads as an app-level event rather than a per-pane one.
//
// The overlay fades IN when `visible` flips true, and fades OUT over 280 ms
// when it flips false — `mounted` stays true for exactly that window so the
// CSS exit transition has something to animate against before the node
// leaves the DOM.
import { useEffect, useState } from "react";
import SessionStatusLight from "./SessionStatusLight";

interface LoadingOverlayProps {
  visible: boolean;
}

export default function LoadingOverlay({ visible }: LoadingOverlayProps) {
  const [mounted, setMounted] = useState(visible);

  useEffect(() => {
    if (visible) {
      setMounted(true);
      return;
    }
    const timeout = window.setTimeout(() => setMounted(false), 280);
    return () => window.clearTimeout(timeout);
  }, [visible]);

  if (!mounted) return null;

  return (
    <div
      className={`loading-overlay${visible ? "" : " is-exiting"}`}
      role="status"
      aria-live="polite"
      aria-label="Loading workspace"
    >
      <div className="loading-overlay-modal">
        <SessionStatusLight status="thinking" size={112} decorative />
        <p className="loading-overlay-label">Loading...</p>
      </div>
    </div>
  );
}
