// Task 8.1 — first-run onboarding. Design intent (frontend-design skill):
// the app already spent its one big visual risk on the brain map itself
// (HUD glow, categorical node colors, force-directed motion) — DESIGN.md 4
// names the map's live growth as *the* onboarding moment, not a screen this
// component owns. So this stays deliberately quiet: a single terminal-boot-
// style prompt for the one real decision (which folder), then a thin
// telemetry readout that gets out of the map's way while it fills in. No
// wizard, no multi-step tour — picking a folder is the entire interaction.
//
// Three phases (see `onboardingState.ts`'s pure reducer for the transition
// logic this component just renders):
// - "pick": a blocking modal (matches EnginePicker/AboutPanel's frame) —
//   the only moment onboarding takes over the screen.
// - "ingesting": a small fixed HUD readout, non-blocking, while the map
//   (already switched into view) visibly grows behind it.
// - "done": the same readout, now static, offering the biggest project's
//   first terminal tab.
//
// "Import projects from other tools" (founder ask, 2026-07-25) extends the
// "pick" phase's single decision into two equally-weighted paths — "Browse
// for a folder" (unchanged) or "Import from other tools" (new) — rather
// than adding a new forced step, keeping this component's own "no wizard"
// principle intact (see the module doc above). Picking import swaps the
// panel for `ImportProjectsFlow` inside the SAME overlay (a local
// `importOpen` flag, not a new onboarding phase — `onboardingState.ts`'s
// reducer is untouched, since import never calls `rootsStartIngest` and so
// has nothing to do with its ingest-HUD phases at all: `add_project`
// ingests each project in the background on the same poll channel
// `App.tsx` already runs, same as the sidebar's "+" flow). Finishing an
// import with at least one project created dismisses onboarding outright
// (`onDismiss`) exactly like a successful folder pick would have — the
// user now has real projects, whichever path got them there.
import { useEffect, useReducer, useState, type CSSProperties } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { initialOnboardingState, onboardingReducer } from "./onboardingState";
import { rootsBiggestProject, rootsStartIngest, type IngestionStatus } from "../lib/tauri";
import type { ProjectInfo } from "../state/sessions";
import type { ImportBatchResult } from "../state/importState";
import ImportProjectsFlow from "../components/ImportProjectsFlow";

interface FirstRunProps {
  /** Owned centrally by `App.tsx` (already polling every ~2s for the
   * degradation badges) and simply forwarded here — see that file's module
   * doc for why onboarding doesn't run a second poll loop of its own. */
  ingestion: IngestionStatus | null;
  /** For `ImportProjectsFlow`'s duplicate-detection — `App.tsx`'s
   * `state.projects`. Onboarding can show up even when projects already
   * exist (its own gate is "no root folder ever picked", independent of
   * projects added one-by-one via "+"), so this is never assumed empty. */
  existingProjects: ProjectInfo[];
  onRequestView: (view: "workspace" | "map") => void;
  onOpenTerminal: (project: ProjectInfo) => void;
  /** Bubbles an import batch's outcome up to `App.tsx`'s
   * `handleImportCompleted` (project-list reload + failure banner) — same
   * split `Sidebar.tsx`'s own import trigger uses. */
  onImportCompleted: (result: ImportBatchResult) => void;
  onDismiss: () => void;
}

export default function FirstRun({
  ingestion,
  existingProjects,
  onRequestView,
  onOpenTerminal,
  onImportCompleted,
  onDismiss,
}: FirstRunProps) {
  const [state, dispatch] = useReducer(onboardingReducer, initialOnboardingState);
  const [picking, setPicking] = useState(false);
  const [pickError, setPickError] = useState<string | null>(null);
  const [biggest, setBiggest] = useState<ProjectInfo | null>(null);
  const [importOpen, setImportOpen] = useState(false);

  useEffect(() => {
    if (ingestion) dispatch({ type: "status_polled", status: ingestion });
  }, [ingestion]);

  useEffect(() => {
    if (state.phase !== "done") return;
    if (!state.status || state.status.projects_total === 0) return;
    rootsBiggestProject()
      .then(setBiggest)
      .catch((err) => console.error("rootsBiggestProject failed", err));
  }, [state.phase, state.status]);

  async function pickFolder() {
    setPickError(null);
    setPicking(true);
    try {
      const selected = await open({ directory: true, multiple: false, title: "Where do your projects live?" });
      if (!selected || Array.isArray(selected)) return; // user cancelled
      await rootsStartIngest(selected);
      dispatch({ type: "root_picked" });
      onRequestView("map"); // the growing map IS the rest of onboarding
    } catch (err) {
      console.error("roots_start_ingest failed", err);
      setPickError(String(err));
    } finally {
      setPicking(false);
    }
  }

  if (state.phase === "pick") {
    if (importOpen) {
      return (
        <ImportProjectsFlow
          existingProjects={existingProjects}
          onClose={() => setImportOpen(false)}
          onImported={(result) => {
            setImportOpen(false);
            onImportCompleted(result);
            if (result.created.length > 0) onDismiss(); // real projects exist now, same as a successful folder pick
          }}
        />
      );
    }
    return (
      <div className="overlay-backdrop">
        <div className="first-run-panel" role="dialog" aria-label="Set up your brain">
          <p className="first-run-eyebrow">&gt; initialize brain_</p>
          <h2 className="first-run-title">Where do your projects live?</h2>
          <p className="first-run-body">
            Point OmniAgent at a folder. Everything inside it gets walked, parsed, and linked into your
            local knowledge graph, automatically — nothing leaves this machine.
          </p>
          {pickError && <p className="first-run-error">Couldn't start ingestion: {pickError}</p>}
          <button className="first-run-cta" onClick={() => void pickFolder()} disabled={picking}>
            {picking ? "Choosing…" : "Browse for a folder…"}
          </button>
          <button className="first-run-secondary-cta" onClick={() => setImportOpen(true)}>
            Import from other tools…
          </button>
          <button className="first-run-skip" onClick={onDismiss}>
            Skip for now
          </button>
        </div>
      </div>
    );
  }

  if (state.phase === "ingesting") {
    const s = state.status;
    // Warp-direction reskin: the same projects_done/projects_total fraction
    // this readout already printed as plain digits, also drawn as a capsule
    // meter (Warp's own "Week 25%"-style bar) — no new field, just the
    // existing numbers visualized too. `projects_total` can be 0 right at
    // the very start of a run (before the walk even counts folders), so the
    // percent is guarded to 0 rather than dividing by zero.
    const projectsPct =
      s && s.projects_total > 0 ? Math.min(100, Math.round((s.projects_done / s.projects_total) * 100)) : 0;
    return (
      <div className="first-run-hud" role="status" aria-live="polite">
        <span className="first-run-hud-pulse" aria-hidden="true" />
        <span className="first-run-hud-label">Ingesting</span>
        {s?.current_project && <span className="first-run-hud-project">{s.current_project}</span>}
        <span className="first-run-hud-count">
          <span className="meter-track">
            <span className="meter-fill is-good" style={{ "--pct": projectsPct } as CSSProperties} />
          </span>
          {s?.projects_done ?? 0}/{s?.projects_total ?? "…"} projects
        </span>
        <span className="first-run-hud-nodes">{(s?.total_nodes ?? 0).toLocaleString()} nodes</span>
      </div>
    );
  }

  // phase === "done"
  const s = state.status;
  const foundNothing = (s?.projects_total ?? 0) === 0;

  return (
    <div className="first-run-hud is-done" role="status">
      {foundNothing ? (
        <>
          <span className="first-run-hud-label">No projects found in that folder.</span>
          <button className="first-run-hud-action" onClick={() => dispatch({ type: "retry" })}>
            Try a different folder
          </button>
        </>
      ) : (
        <>
          <span className="first-run-hud-label">
            Brain online — {s?.projects_done} project{s?.projects_done === 1 ? "" : "s"},{" "}
            {(s?.total_nodes ?? 0).toLocaleString()} nodes
          </span>
          {biggest && (
            <button
              className="first-run-hud-action"
              onClick={() => {
                onOpenTerminal(biggest);
                onDismiss();
              }}
            >
              Open terminal in {biggest.label}
            </button>
          )}
          <button className="first-run-hud-dismiss" onClick={onDismiss}>
            Dismiss
          </button>
        </>
      )}
    </div>
  );
}
