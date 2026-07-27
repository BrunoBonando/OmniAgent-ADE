// Workspace dropdown (design ANALYSIS.md §3 "workspaceMenu"): anchored under
// the sidebar's workspace switcher. Lists every open workspace with its
// session count, checkmarks the active one, and carries the New-workspace
// and Import entry points that used to live in the sidebar header.
import { useEffect, useRef, type KeyboardEvent } from "react";
import type { ProjectInfo } from "../state/sessions";
import { idColor } from "../state/projectColors";
import Icon from "./Icon";

export function sessionCountLabel(n: number): string {
  if (n === 0) return "no sessions";
  return n === 1 ? "1 session" : `${n} sessions`;
}

export interface WorkspaceMenuProps {
  projects: ProjectInfo[];
  activeProjectId: string | null;
  sessionCounts: Map<string, number>;
  onSelect: (project: ProjectInfo) => void;
  onNewWorkspace: () => void;
  onImport: () => void;
  onManage: (project: ProjectInfo) => void;
  onClose: () => void;
}

/**
 * Enter/Space on a `role="menuitem"` div = the click it already has. Since
 * Task 3 retired the sidebar's per-project rows, this dropdown is the only
 * direct path to switching, adding or importing a workspace, so leaving its
 * rows mouse-only made the app's primary navigation surface keyboard-dead.
 *
 * `e.target === e.currentTarget` keeps a keystroke aimed at something nested
 * inside a row (the "⋯" manage button) from ALSO firing the row: that button
 * already stops click propagation for the same reason, and a native button
 * turns Enter into a click that would otherwise bubble straight back here.
 * The rows stay divs — converting the whole menu to native <button>s is
 * tracked separately.
 */
function activateOnKey(e: KeyboardEvent, run: () => void) {
  if (e.target !== e.currentTarget) return;
  if (e.key !== "Enter" && e.key !== " ") return;
  // Space would scroll the panel behind the menu.
  e.preventDefault();
  run();
}

export function WorkspaceMenu({
  projects, activeProjectId, sessionCounts,
  onSelect, onNewWorkspace, onImport, onManage, onClose,
}: WorkspaceMenuProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  useEffect(() => { panelRef.current?.focus(); }, []);

  const newWorkspace = () => { onNewWorkspace(); onClose(); };
  const importProjects = () => { onImport(); onClose(); };

  return (
    <>
      <div className="workspace-menu-backdrop" onMouseDown={onClose} />
      <div
        className="workspace-menu"
        role="menu"
        tabIndex={-1}
        ref={panelRef}
        onKeyDown={(e) => { if (e.key === "Escape") onClose(); }}
      >
        <div className="workspace-menu-header">
          <span className="workspace-menu-title">WORKSPACES</span>
          <span className="workspace-menu-count">{projects.length}</span>
        </div>
        {projects.map((p) => {
          const active = p.id === activeProjectId;
          const choose = () => { if (!active) onSelect(p); onClose(); };
          return (
            <div
              key={p.id}
              role="menuitem"
              tabIndex={0}
              className={`workspace-menu-row${active ? " is-active" : ""}`}
              onClick={choose}
              onKeyDown={(e) => activateOnKey(e, choose)}
            >
              <span
                className="workspace-menu-avatar"
                style={{ background: idColor(p.id) }}
                aria-hidden
              >
                {p.label.slice(0, 1).toUpperCase()}
              </span>
              <span className="workspace-menu-identity">
                <span className="workspace-menu-name">{p.label}</span>
                <span className="workspace-menu-path">{p.path ?? ""}</span>
              </span>
              <span className="workspace-menu-sessions">
                {sessionCountLabel(sessionCounts.get(p.id) ?? 0)}
              </span>
              <button
                type="button"
                className="workspace-menu-manage"
                title="Workspace settings"
                onClick={(e) => { e.stopPropagation(); onManage(p); }}
              >
                <Icon name="more" size={15} />
              </button>
              {active ? (
                <span className="workspace-menu-check" aria-label="Active workspace"><Icon name="check" size={13} strokeWidth={2.4} /></span>
              ) : (
                <span className="workspace-menu-check-slot" />
              )}
            </div>
          );
        })}
        <div className="workspace-menu-divider" />
        <div
          role="menuitem"
          tabIndex={0}
          className="workspace-menu-new"
          onClick={newWorkspace}
          onKeyDown={(e) => activateOnKey(e, newWorkspace)}
        >
          <span className="workspace-menu-new-tile"><Icon name="plus" size={14} /></span>
          <span>New workspace</span>
        </div>
        <div
          role="menuitem"
          tabIndex={0}
          className="workspace-menu-new"
          onClick={importProjects}
          onKeyDown={(e) => activateOnKey(e, importProjects)}
        >
          <span className="workspace-menu-new-tile"><Icon name="import" size={14} /></span>
          <span>Import projects…</span>
        </div>
      </div>
    </>
  );
}
