// Task 8.1 — the sidebar's per-project context menu: pause-ingestion toggle
// + a manual "re-check now" action for a stale project. Same small-popover
// pattern as the rest of the shell's overlay chrome (backdrop + panel), just
// anchored under the triggering row instead of centered — a project menu is
// a utility, not a modal moment, so its backdrop is transparent (click-away
// to dismiss) rather than the dimmed/blurred `.overlay-backdrop` used for
// AboutPanel/ReviewPanel/EnginePicker.
//
// Rename (founder ask: closing the root cause of "OmniAgent-ADE" — a
// project's real folder-basename-derived label — showing up in every pane
// header, with no way to change it): double-click the title, same
// dblclick-to-rename gesture `PaneHeader.tsx` already established for tabs,
// rather than inventing a second interaction for the same idea. `onRename`
// is a lifted callback (`Sidebar.tsx` -> `App.tsx`'s `handleRenameProject`,
// which calls the real `rename_project` Tauri command and reloads the
// project list) — this component owns only the inline edit UI/validation,
// not the Tauri call itself, matching this file's existing
// onTogglePause/onReingest split.
import { useState } from "react";
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
  /** Renames the project's *display* label — `Sidebar.tsx`/`App.tsx` own
   * the actual `rename_project` Tauri call + reloading `state.projects`
   * afterward (see this file's module doc). Called only with a non-empty,
   * actually-changed, trimmed value. */
  onRename: (newLabel: string) => void;
  /** Close the workspace (founder ask, 2026-07-26: "add the possibility to
   * close a workspace"). It used to be a "×" in the project row's hover
   * cluster; the left-pane redesign (Task 3) replaced that row list with one
   * workspace switcher, so the per-workspace actions all arrive through this
   * menu now — this is where closing one had to land with it. Optional, same
   * convention as `Sidebar`'s own `onCloseWorkspace`: absent means no
   * control at all. `Sidebar` still confirms (`CloseWorkspaceConfirm`)
   * before a single terminal is killed. */
  onCloseWorkspace?: () => void;
  onClose: () => void;
}

export default function ProjectMenu({
  project,
  paused,
  staleness,
  busy,
  onTogglePause,
  onReingest,
  onRename,
  onCloseWorkspace,
  onClose,
}: ProjectMenuProps) {
  const [renaming, setRenaming] = useState(false);
  const [draft, setDraft] = useState("");

  function startRename() {
    setDraft(project.label);
    setRenaming(true);
  }

  function commitRename() {
    const trimmed = draft.trim();
    setRenaming(false);
    if (trimmed.length > 0 && trimmed !== project.label) {
      onRename(trimmed);
      onClose();
    }
  }

  return (
    <>
      <div className="project-menu-backdrop" onMouseDown={onClose} />
      <div className="project-menu" role="menu" aria-label={`${project.label} options`} onMouseDown={(e) => e.stopPropagation()}>
        {renaming ? (
          <input
            className="project-menu-rename-input"
            value={draft}
            autoFocus
            onChange={(e) => setDraft(e.target.value)}
            onBlur={commitRename}
            onKeyDown={(e) => {
              e.stopPropagation();
              if (e.key === "Enter") {
                e.preventDefault();
                commitRename();
              } else if (e.key === "Escape") {
                e.preventDefault();
                setRenaming(false);
              }
            }}
          />
        ) : (
          <div className="project-menu-title" onDoubleClick={startRename} title="Double-click to rename">
            {project.label}
          </div>
        )}

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

        {/* Last, and the only item here that ends something — same placement
            and the same "asks first, deletes nothing" contract the row's "×"
            had. The label carries the workspace name so it stays
            distinguishable from `CloseWorkspaceConfirm`'s own confirm
            button. */}
        {onCloseWorkspace && (
          <button
            className="project-menu-close-workspace"
            onClick={onCloseWorkspace}
            aria-label={`Close workspace ${project.label}`}
            title="Ends every terminal in this workspace — nothing is deleted"
          >
            Close workspace
          </button>
        )}
      </div>
    </>
  );
}
