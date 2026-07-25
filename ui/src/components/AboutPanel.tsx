// Small in-app branding surface (the task explicitly asks for the real app
// icon to show up somewhere in-app besides the dock/title bar). Also the
// "Settings-ish spot" Task 8.1 names for "Rebuild brain" — this panel is
// already the closest thing to a settings surface next to ReviewPanel
// (which is specifically about session-summary review, not general config).
import { useEffect, useState } from "react";
import logo from "../assets/omniagent-logo.png";
import { rootsRebuild, settingsGet } from "../lib/tauri";
import {
  AUTH_PERSONA_SETTING_KEY,
  AUTH_SIGNED_IN_SETTING_KEY,
  describeAuthSummary,
} from "../onboarding/authGateState";

interface AboutPanelProps {
  onClose: () => void;
  /** Clears the persisted fake-sign-in outcome and re-shows the gate —
   * `App.tsx` owns the actual settings writes (`resetAuthGate`), this
   * panel just triggers it and closes itself. Optional so this component
   * still renders fine if a caller doesn't wire the auth gate at all. */
  onResetAuthGate?: () => void;
}

export default function AboutPanel({ onClose, onResetAuthGate }: AboutPanelProps) {
  const [confirming, setConfirming] = useState(false);
  const [rebuilding, setRebuilding] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // Light-touch surfacing of the fake-sign-in gate's captured answer
  // (Task: onboarding — "nice to have, not required"). Read-only, best
  // effort: a failed read just leaves the line blank rather than showing
  // an error in a panel that's mostly about branding.
  const [authSummary, setAuthSummary] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const [signedIn, persona] = await Promise.all([
          settingsGet(AUTH_SIGNED_IN_SETTING_KEY),
          settingsGet(AUTH_PERSONA_SETTING_KEY),
        ]);
        if (!cancelled) setAuthSummary(describeAuthSummary(signedIn, persona));
      } catch (err) {
        console.error("failed to read auth gate settings", err);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

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
        {authSummary && <p className="about-auth-summary">{authSummary}</p>}

        {onResetAuthGate && (
          <div className="about-reset-section">
            <p className="about-reset-hint">
              Testing the sign-in workflow? This clears the fake sign-in and personalization
              answer so the flow runs again next time.
            </p>
            <button className="about-reset-trigger" onClick={onResetAuthGate}>
              Reset sign-in flow
            </button>
          </div>
        )}

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
