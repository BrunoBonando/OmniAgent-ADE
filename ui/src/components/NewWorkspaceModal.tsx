// The sidebar's "+" flow, rebuilt from a founder reference (Bruno,
// 2026-07-25): a screenshot of BridgeSpace's "New Workspace" dialog,
// described precisely rather than checked in as an image. Structure: a
// title + close button; a LAYOUT section (four preset cards — 2/4/6/9 —
// each a small grid glyph with a caption for whichever is selected); a
// DIRECTORY section (folder path + Browse, plus an editable project name);
// a collapsible AI AGENTS section (checkbox rows, one per agent); a
// footer (Cancel / Create Workspace).
//
// The checklist is built directly from the real `ENGINES` array (which is
// `AVAILABLE_AGENTS` from `state/agents.ts`), with `ENGINE_COLOR`/
// `ENGINE_LABEL` (theme.ts) supplying each row's dot color and label.
// When a new agent is added to `AVAILABLE_AGENTS`, it appears here for free.
//
// **This REPLACES `AddProjectModal.tsx`** as the sidebar's "+" trigger
// (`Sidebar.tsx`'s own doc comment has the reasoning: this flow is a
// strict superset — folder pick + optional rename, PLUS choosing which
// engines to boot and how to arrange them). It reuses
// `addProjectState.ts`'s `basenameOf` (via `newWorkspaceState.ts`) rather
// than re-deriving that pure folder-picking logic, and follows the exact
// same pick-folder Tauri-dialog pattern `AddProjectModal.tsx` established.
//
// **Ownership split with the caller** (same shape `AddProjectModal.tsx` /
// `Sidebar.tsx` already used for `onAdded`): this component owns picking a
// folder and creating the project (`add_project` — a hard failure here
// surfaces inline and keeps the dialog open, exactly like
// `AddProjectModal`'s `submit_failed`). Once that succeeds, it hands off
// to the caller's `onCreate(project, engines, layout)` — bulk session
// creation (N `session_create` calls, one per checked engine, using the
// exact same per-engine spawn logic `App.tsx`'s `confirmNewTab` already
// uses) and closing the modal both live in `App.tsx`/`Sidebar.tsx`, not
// here, so partial mid-batch failures can land the user in the project
// with whatever succeeded and use `App.tsx`'s existing `errorBanner`
// rather than a second error surface inside this already-closed dialog.
import { useEffect, useRef } from "react";
import { useReducer } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import {
  canSubmit,
  checkedEngines,
  initialNewWorkspaceState,
  newWorkspaceReducer,
} from "../state/newWorkspaceState";
import { LAYOUT_PRESETS, layoutCaption, type LayoutPreset } from "../state/paneGrid";
import { LayoutGlyph } from "./NewSessionModal";
import { ENGINES, type Engine, type ProjectInfo } from "../state/sessions";
import { type AgentsState, type Agent, AVAILABLE_AGENTS } from "../state/agents";
import { ENGINE_COLOR, ENGINE_LABEL } from "../theme";
import { addProject } from "../lib/tauri";

interface NewWorkspaceModalProps {
  onCreate: (project: ProjectInfo, engines: Engine[], layout: LayoutPreset) => void;
  onClose: () => void;
  agentState: AgentsState;
  onInstallAgent: (agent: Agent) => void;
}

/** Simple inline folder icon — the reference's DIRECTORY section leads with
 * one; a single hand-drawn path rather than an icon library dependency. */
function FolderIcon() {
  return (
    <svg
      className="new-workspace-folder-icon"
      viewBox="0 0 20 16"
      width="16"
      height="13"
      fill="none"
      aria-hidden
    >
      <path
        d="M1 2.5C1 1.67 1.67 1 2.5 1H7l2 2h8.5c.83 0 1.5.67 1.5 1.5v9c0 .83-.67 1.5-1.5 1.5h-15C1.67 15 1 14.33 1 13.5v-11Z"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export default function NewWorkspaceModal({ onCreate, onClose, agentState, onInstallAgent }: NewWorkspaceModalProps) {
  const [state, dispatch] = useReducer(newWorkspaceReducer, initialNewWorkspaceState);
  const panelRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  async function pickFolder() {
    try {
      const selected = await open({ directory: true, multiple: false, title: "New workspace folder" });
      if (!selected || Array.isArray(selected)) return; // user cancelled
      dispatch({ type: "folder_picked", path: selected });
    } catch (err) {
      console.error("new-workspace folder picker failed", err);
    }
  }

  async function confirm() {
    if (!canSubmit(state) || !state.path) return;
    dispatch({ type: "submit_started" });
    try {
      const project = await addProject(state.path, state.name.trim());
      onCreate(project, checkedEngines(state), state.layout);
    } catch (err) {
      console.error("add_project failed", err);
      dispatch({ type: "submit_failed", error: String(err) });
    }
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
      return;
    }
    if (e.key === "Enter" && (e.target as HTMLElement).tagName === "INPUT") {
      e.preventDefault();
      void confirm();
    }
  }

  const checked = checkedEngines(state);

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        ref={panelRef}
        className="new-workspace-panel"
        role="dialog"
        aria-label="New Workspace"
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="new-workspace-header">
          <h2 className="new-workspace-title">New Workspace</h2>
          <button className="new-workspace-close" onClick={onClose} aria-label="Close">
            &#215;
          </button>
        </div>

        <div className="new-workspace-section">
          <span className="new-workspace-section-label">LAYOUT</span>
          <div className="new-workspace-layout-row">
            {LAYOUT_PRESETS.map((preset) => (
              <button
                key={preset}
                type="button"
                className={`new-workspace-layout-card${state.layout === preset ? " is-selected" : ""}`}
                onClick={() => dispatch({ type: "layout_selected", layout: preset })}
                aria-pressed={state.layout === preset}
              >
                <LayoutGlyph preset={preset} />
                <span className="new-workspace-layout-number">{preset}</span>
              </button>
            ))}
          </div>
          <p className="new-workspace-layout-caption">{layoutCaption(state.layout)}</p>
        </div>

        <div className="new-workspace-section">
          <span className="new-workspace-section-label">DIRECTORY</span>
          <div className="new-workspace-directory-row">
            <FolderIcon />
            <span className="new-workspace-path" title={state.path ?? undefined}>
              {state.path ?? "No folder chosen yet"}
            </span>
            <button type="button" className="new-workspace-browse" onClick={() => void pickFolder()}>
              Browse
            </button>
          </div>
          <label className="new-workspace-name-label" htmlFor="new-workspace-name">
            Project name
          </label>
          <input
            id="new-workspace-name"
            className="new-workspace-name-input"
            value={state.name}
            placeholder={state.path ? undefined : "Choose a folder first"}
            disabled={state.path === null || state.submitting}
            onChange={(e) => dispatch({ type: "name_changed", name: e.target.value })}
          />
        </div>

        <div className="new-workspace-section">
          <div className="new-workspace-agents-header">
            <span className="new-workspace-section-label">AI AGENTS</span>
            <span className="new-workspace-agents-count">
              {checked.length}/{ENGINES.length}
            </span>
            <button
              type="button"
              className="new-workspace-agents-toggle"
              onClick={() => dispatch({ type: "agents_collapsed_toggled" })}
              aria-expanded={!state.agentsCollapsed}
            >
              <span
                className={`new-workspace-agents-chevron${state.agentsCollapsed ? " is-collapsed" : ""}`}
                aria-hidden
              >
                &#9656;
              </span>
              {state.agentsCollapsed ? "Expand" : "Collapse"}
            </button>
          </div>
          {!state.agentsCollapsed && (
            <ul className="new-workspace-agent-list">
              {AVAILABLE_AGENTS.map((agent) => {
                const isInstalled = agentState.installed.has(agent);
                const isInstalling = agentState.installing.has(agent);
                const installStatus = agentState.installing.get(agent);

                return (
                  <li key={agent} className="new-workspace-agent-row">
                    <label>
                      <input
                        type="checkbox"
                        checked={state.engines[agent as Engine]}
                        onChange={() => dispatch({ type: "engine_toggled", engine: agent as Engine })}
                        disabled={!isInstalled}
                      />
                      <span className="engine-dot" style={{ background: ENGINE_COLOR[agent as Engine] }} aria-hidden />
                      <span className="new-workspace-agent-label">{ENGINE_LABEL[agent as Engine]}</span>
                    </label>
                    {!isInstalled && !isInstalling && (
                      <button
                        type="button"
                        className="new-workspace-install-btn"
                        onClick={() => onInstallAgent(agent)}
                      >
                        Install
                      </button>
                    )}
                    {isInstalling && (
                      <span className="new-workspace-agent-status">
                        {installStatus === 'failed' ? (
                          <>
                            <span className="status-failed">Failed</span>
                            <button
                              type="button"
                              className="new-workspace-retry-btn"
                              onClick={() => onInstallAgent(agent)}
                            >
                              Retry
                            </button>
                          </>
                        ) : (
                          <span className="status-installing">Installing…</span>
                        )}
                      </span>
                    )}
                  </li>
                );
              })}
            </ul>
          )}
        </div>

        {state.error && <p className="new-workspace-error">Couldn't create workspace: {state.error}</p>}

        <div className="new-workspace-footer">
          <button className="new-workspace-cancel" onClick={onClose}>
            Cancel
          </button>
          <button
            className="new-workspace-submit"
            onClick={() => void confirm()}
            disabled={!canSubmit(state)}
          >
            {state.submitting ? "Creating…" : "Create Workspace"}
          </button>
        </div>
      </div>
    </div>
  );
}
