// Small in-app branding surface (the task explicitly asks for the real app
// icon to show up somewhere in-app besides the dock/title bar). Also the
// "Settings-ish spot" Task 8.1 names for "Rebuild brain" — this panel is
// already the closest thing to a settings surface next to ReviewPanel
// (which is specifically about session-summary review, not general config).
import { useState } from "react";
import logo from "../assets/omniagent-logo.png";
import { rootsRebuild } from "../lib/tauri";

export default function AboutPanel({ onClose }: { onClose: () => void }) {
  const [confirming, setConfirming] = useState(false);
  const [rebuilding, setRebuilding] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function rebuild() {
    setRebuilding(true);
    setError(null);
    try {
      // Fire-and-forget: `roots_rebuild` starts a background thread and
      // returns immediately. `App.tsx`'s always-on ingestion_status poll
      // (the same one that drives the map's live growth during onboarding)
      // picks up the run and reloads the project list once it finishes —
      // no separate wiring needed here.
      await rootsRebuild();
      onClose();
    } catch (err) {
      console.error("roots_rebuild failed", err);
      setError(String(err));
      setRebuilding(false);
    }
  }

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div className="about-panel" role="dialog" aria-label="About OmniAgent ADE" onMouseDown={(e) => e.stopPropagation()}>
        <img src={logo} alt="OmniAgent" className="about-logo" />
        <h2>OmniAgent ADE</h2>
        <p className="about-tagline">The knowledge graph is the operating system.</p>
        <p className="about-body">
          A local-first agentic development environment: parallel agent-CLI terminal sessions
          grouped per project, all feeding and fed by one fully local second brain.
        </p>
        <p className="about-version">v0.1.0 — dogfood build</p>

        <div className="about-rebuild-section">
          <p className="about-rebuild-hint">
            Something look wrong with the graph? Rebuilding deletes the derived database and
            re-ingests every known project root from scratch. Your Markdown memory notes are
            never touched.
          </p>
          {error && <p className="about-rebuild-error">Rebuild failed: {error}</p>}
          {confirming ? (
            <div className="about-rebuild-confirm">
              <span>Delete the graph and re-ingest everything?</span>
              <div className="about-rebuild-confirm-actions">
                <button disabled={rebuilding} onClick={() => void rebuild()}>
                  {rebuilding ? "Rebuilding…" : "Yes, rebuild"}
                </button>
                <button disabled={rebuilding} onClick={() => setConfirming(false)}>
                  Cancel
                </button>
              </div>
            </div>
          ) : (
            <button className="about-rebuild-trigger" onClick={() => setConfirming(true)}>
              Rebuild brain…
            </button>
          )}
        </div>

        <button className="about-close" onClick={onClose}>
          Close
        </button>
      </div>
    </div>
  );
}
