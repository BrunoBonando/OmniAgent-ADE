// Workspace dropdown (design ANALYSIS.md §3 "workspaceMenu"): anchored under
// the sidebar's workspace switcher. Lists every open workspace with its
// session count, checkmarks the active one, and carries the New-workspace
// and Import entry points that used to live in the sidebar header.
import { useEffect, useRef } from "react";
import type { ProjectInfo } from "../state/sessions";
import { idColor } from "../state/projectColors";

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

export function WorkspaceMenu({
  projects, activeProjectId, sessionCounts,
  onSelect, onNewWorkspace, onImport, onManage, onClose,
}: WorkspaceMenuProps) {
  const panelRef = useRef<HTMLDivElement>(null);
  useEffect(() => { panelRef.current?.focus(); }, []);

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
          return (
            <div
              key={p.id}
              role="menuitem"
              className={`workspace-menu-row${active ? " is-active" : ""}`}
              onClick={() => { if (!active) onSelect(p); onClose(); }}
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
                ⋯
              </button>
              {active ? (
                <span className="workspace-menu-check" aria-label="Active workspace">✓</span>
              ) : (
                <span className="workspace-menu-check-slot" />
              )}
            </div>
          );
        })}
        <div className="workspace-menu-divider" />
        <div role="menuitem" className="workspace-menu-new" onClick={() => { onNewWorkspace(); onClose(); }}>
          <span className="workspace-menu-new-tile">+</span>
          <span>New workspace</span>
        </div>
        <div role="menuitem" className="workspace-menu-new" onClick={() => { onImport(); onClose(); }}>
          <span className="workspace-menu-new-tile">⇥</span>
          <span>Import projects…</span>
        </div>
      </div>
    </>
  );
}
