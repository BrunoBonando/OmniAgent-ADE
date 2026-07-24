// Task 8.1 — the sidebar's per-project context menu: pause-ingestion toggle
// + a manual "re-check now" action for a stale project. Same small-popover
// pattern as the rest of the shell's overlay chrome (backdrop + panel), just
// anchored under the triggering row instead of centered — a project menu is
// a utility, not a modal moment, so its backdrop is transparent (click-away
// to dismiss) rather than the dimmed/blurred `.overlay-backdrop` used for
// AboutPanel/ReviewPanel/EnginePicker.
import type { ProjectInfo } from "../state/sessions";
import type { ProjectStaleness } from "../lib/tauri";

function timeAgo(unixSeconds: number): string {
  const deltaS = Math.max(0, Math.floor(Date.now() / 1000) - unixSeconds);
  if (deltaS < 60) return "just now";
  const deltaMin = Math.floor(deltaS / 60);
  if (deltaMin < 60) return `${deltaMin}m ago`;
  const deltaH = Math.floor(deltaMin / 60);
  if (deltaH < 24) return `${deltaH}h ago`;
  return `${Math.floor(deltaH / 24)}d ago`;
}

interface ProjectMenuProps {
  project: ProjectInfo;
  paused: boolean;
  staleness?: ProjectStaleness;
  busy: boolean;
  onTogglePause: () => void;
  onReingest: () => void;
  onClose: () => void;
}

export default function ProjectMenu({
  project,
  paused,
  staleness,
  busy,
  onTogglePause,
  onReingest,
  onClose,
}: ProjectMenuProps) {
  return (
    <>
      <div className="project-menu-backdrop" onMouseDown={onClose} />
      <div className="project-menu" role="menu" aria-label={`${project.label} options`} onMouseDown={(e) => e.stopPropagation()}>
        <div className="project-menu-title">{project.label}</div>

        {staleness?.stale && (
          <div className="project-menu-stale">
            <span className="project-menu-stale-dot" aria-hidden="true" />
            Stale — last ingested {staleness.last_ingested ? timeAgo(staleness.last_ingested) : "a while ago"}
          </div>
        )}

        <label className="project-menu-row">
          <input type="checkbox" checked={paused} disabled={busy} onChange={onTogglePause} />
          Pause ingestion
        </label>
        <p className="project-menu-hint">
          {paused
            ? "Skipped by onboarding, rebuild, and future re-ingest passes."
            : "Included the next time this brain ingests or rebuilds."}
        </p>

        <button className="project-menu-recheck" disabled={busy} onClick={onReingest}>
          {busy ? "Re-checking…" : "Re-check now"}
        </button>
      </div>
    </>
  );
}
