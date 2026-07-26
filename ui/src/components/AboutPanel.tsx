// Small in-app branding surface (the task explicitly asks for the real app
// icon to show up somewhere in-app besides the dock/title bar). Also the
// "Settings-ish spot" Task 8.1 names for "Rebuild brain" — this panel is
// already the closest thing to a settings surface next to ReviewPanel
// (which is specifically about session-summary review, not general config).
//
// 2026-07-26: this used to also own a "Reset sign-in flow" button — the
// only way to re-run `AuthGate` short of devtools settings surgery.
// Removed now that `AccountBadge.tsx` (the persistent sidebar-header
// badge — see `Sidebar.tsx`'s `.sidebar-header-actions`) exposes the exact
// same underlying action as its own "Sign in"/"Log out" menu rows, wired
// to the very same `App.tsx` `resetAuthGate` callback this panel used to
// call. Keeping both would just be the same action in two places under
// different labels — the badge's copy is always visible and reads
// unambiguously as an account action, so it fully subsumes this panel's
// old one rather than living alongside it. The read-only `authSummary`
// line below stays: it's a different kind of information (a passive
// status readout that belongs in "About", not an account action) and
// doesn't duplicate anything the badge's menu shows.
//
// 2026-07-26, later the same day: the version line stopped being the
// literal `v0.1.0 — dogfood build`. There is exactly one version in this
// repo — `tauri.conf.json`'s `version` field — and it already had two
// honest readers: the window title (via `PackageInfo::version` in
// `src-tauri/src/lib.rs`'s `window_title`) and the bundler, which stamps it
// into the `.app`. This panel was the third reader and the only one holding
// a *copy* of it, which meant the next release would ship an About panel
// quietly claiming the previous version. See `aboutVersionLine` below.
import { useEffect, useState } from "react";
import { getVersion } from "@tauri-apps/api/app";
import logo from "../assets/omniagent-logo.png";
import { rootsRebuild, settingsGet } from "../lib/tauri";
import {
  AUTH_PERSONA_SETTING_KEY,
  AUTH_SIGNED_IN_SETTING_KEY,
  describeAuthSummary,
} from "../onboarding/authGateState";

interface AboutPanelProps {
  onClose: () => void;
}

/** The version line, shaped in one place.
 *
 * `null` (rather than a placeholder) while the version is still being read,
 * and also when reading it failed: this panel is a branding surface, and a
 * line that says "v— dogfood build" or "vunknown" is worse than no line at
 * all. Same best-effort posture as the `authSummary` line below. */
export function aboutVersionLine(version: string | null): string | null {
  return version === null ? null : `v${version} — dogfood build`;
}

export default function AboutPanel({ onClose }: AboutPanelProps) {
  const [confirming, setConfirming] = useState(false);
  const [rebuilding, setRebuilding] = useState(false);
  const [error, setError] = useState<string | null>(null);
  // The shipped version, read from the running app rather than typed in
  // here. `getVersion()` (@tauri-apps/api/app) resolves `PackageInfo::
  // version`, which `tauri::generate_context!` compiles from
  // `tauri.conf.json`'s own `version` field — the exact same value
  // `src-tauri/src/lib.rs`'s `window_title` puts in the title bar and the
  // bundler stamps into the `.app`. So the panel and the title bar can no
  // longer disagree, and a release bump moves all three at once.
  //
  // Tauri's built-in API rather than a new command of our own: `core:app:
  // default` (already granted by `core:default` in
  // `src-tauri/capabilities/default.json`) includes `allow-version`, so
  // this needs no backend code and no permission change.
  const [version, setVersion] = useState<string | null>(null);
  // Light-touch surfacing of the fake-sign-in gate's captured answer
  // (Task: onboarding — "nice to have, not required"). Read-only, best
  // effort: a failed read just leaves the line blank rather than showing
  // an error in a panel that's mostly about branding.
  const [authSummary, setAuthSummary] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;
    getVersion()
      .then((v) => {
        if (!cancelled) setVersion(v);
      })
      .catch((err) => {
        // Best effort, exactly like the auth summary below: a panel that
        // can't name its own version is a missing line, never an error
        // screen.
        console.error("failed to read the app version", err);
      });
    return () => {
      cancelled = true;
    };
  }, []);

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

  const versionLine = aboutVersionLine(version);

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
        {versionLine && <p className="about-version">{versionLine}</p>}
        {authSummary && <p className="about-auth-summary">{authSummary}</p>}

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
