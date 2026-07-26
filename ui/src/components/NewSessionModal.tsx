// ⌘N -> "Session" (founder brief, 2026-07-26, verbatim: *"Each session can
// be created with a new layout, agents, etc... but in the same folder or
// subfolder."*).
//
// Deliberately `NewWorkspaceModal` minus one section and plus one
// constraint — same LAYOUT preset cards, same AI AGENTS checklist, same
// footer — because a session and a workspace are the same act of creation
// scoped differently, and two dialogs that looked unrelated would hide
// that. What changes is the middle section: instead of picking a brand-new
// folder and naming a project, this one starts in the *already-selected
// project's* folder and can only ever be narrowed to a folder inside it.
//
// The boundary is enforced in `state/newSessionState.ts`
// (`isInsideProjectRoot`, component-wise, mirroring
// `crates/brain-ingest/src/fileops.rs`'s discipline — see that module's own
// doc for what this guard is and isn't), so a folder picked outside the
// project is refused with a sentence rather than silently accepted.
//
// **Ownership split with the caller**, same shape `NewWorkspaceModal`
// established: this component owns the dialog and the folder pick; the
// caller (`App.tsx`'s `handleSessionCreated`) owns spawning the sessions,
// minting the session-group id, and closing the modal — so a partial
// mid-batch failure lands the user in the project with whatever succeeded
// and uses the existing error banner rather than a second error surface
// inside an already-closed dialog.
import { useEffect, useReducer, useRef } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import {
  canSubmit,
  checkedEngines,
  displaySessionPath,
  initialNewSessionState,
  isSubfolder,
  newSessionReducer,
} from "../state/newSessionState";
import { LAYOUT_PRESETS, layoutCaption, nominalGridShape, type LayoutPreset } from "../state/paneGrid";
import { ENGINES, type Engine, type ProjectInfo } from "../state/sessions";
import { ENGINE_COLOR, ENGINE_LABEL } from "../theme";

interface NewSessionModalProps {
  project: ProjectInfo;
  onCreate: (project: ProjectInfo, cwd: string, engines: Engine[], layout: LayoutPreset) => void;
  onClose: () => void;
}

/** Same CSS-drawn preset preview `NewWorkspaceModal` uses — shared through
 * `nominalGridShape` so the glyph can never drift from the arrangement
 * `buildLayoutTree` actually produces. */
function LayoutGlyph({ preset }: { preset: LayoutPreset }) {
  const { rows, cols } = nominalGridShape(preset);
  return (
    <span
      className="new-workspace-layout-glyph"
      style={{ gridTemplateRows: `repeat(${rows}, 1fr)`, gridTemplateColumns: `repeat(${cols}, 1fr)` }}
      aria-hidden
    >
      {Array.from({ length: rows * cols }).map((_, i) => (
        <span key={i} className="new-workspace-layout-glyph-cell" />
      ))}
    </span>
  );
}

function FolderIcon() {
  return (
    <svg className="new-workspace-folder-icon" viewBox="0 0 20 16" width="16" height="13" fill="none" aria-hidden>
      <path
        d="M1 2.5C1 1.67 1.67 1 2.5 1H7l2 2h8.5c.83 0 1.5.67 1.5 1.5v9c0 .83-.67 1.5-1.5 1.5h-15C1.67 15 1 14.33 1 13.5v-11Z"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export default function NewSessionModal({ project, onCreate, onClose }: NewSessionModalProps) {
  const projectRoot = project.path ?? project.id;
  const [state, dispatch] = useReducer(newSessionReducer, projectRoot, initialNewSessionState);
  const panelRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  async function pickFolder() {
    try {
      const selected = await open({
        directory: true,
        multiple: false,
        // Opens *inside* the project, so the common case (a subfolder) is
        // one click away and leaving the project takes deliberate effort.
        defaultPath: state.path,
        title: `Folder for this session in ${project.label}`,
      });
      if (!selected || Array.isArray(selected)) return; // user cancelled
      dispatch({ type: "folder_picked", path: selected });
    } catch (err) {
      console.error("new-session folder picker failed", err);
    }
  }

  function confirm() {
    if (!canSubmit(state)) return;
    dispatch({ type: "submit_started" });
    onCreate(project, state.path, checkedEngines(state), state.layout);
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
      return;
    }
    // Keys typed into a TEXT field belong to that field. A checkbox is a
    // different story and a real-browser pass caught it: after clicking an
    // agent row, focus sits on that checkbox, and blanket-ignoring keys
    // there meant Enter silently stopped creating the session — the exact
    // dead end "keyboard first" forbids. Enter and the layout digits do
    // nothing native on a checkbox, so they still belong to this dialog;
    // Space (which toggles it) is never handled here at all.
    const target = e.target as HTMLElement;
    if (target.tagName === "TEXTAREA") return;
    if (target.tagName === "INPUT" && (target as HTMLInputElement).type !== "checkbox") return;
    if (e.key === "Enter") {
      e.preventDefault();
      confirm();
      return;
    }
    const digit = Number(e.key);
    if (Number.isInteger(digit) && digit >= 1 && digit <= LAYOUT_PRESETS.length) {
      e.preventDefault();
      dispatch({ type: "layout_selected", layout: LAYOUT_PRESETS[digit - 1] });
    }
  }

  const checked = checkedEngines(state);

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        ref={panelRef}
        className="new-workspace-panel"
        role="dialog"
        aria-label="New Session"
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="new-workspace-header">
          <h2 className="new-workspace-title">New Session</h2>
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
          <span className="new-workspace-section-label">FOLDER — {project.label.toUpperCase()}</span>
          <div className="new-workspace-directory-row">
            <FolderIcon />
            <span className="new-workspace-path" title={state.path}>
              {displaySessionPath(state)}
            </span>
            <button type="button" className="new-workspace-browse" onClick={() => void pickFolder()}>
              Browse
            </button>
          </div>
          <p className="new-session-scope-hint">
            {isSubfolder(state) ? (
              <>
                Runs in this subfolder.{" "}
                <button type="button" className="new-session-scope-reset" onClick={() => dispatch({ type: "folder_reset" })}>
                  Use the project folder
                </button>
              </>
            ) : (
              "Runs in the project folder. Browse to narrow it to a subfolder."
            )}
          </p>
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
              {ENGINES.map((engine) => (
                <li key={engine} className="new-workspace-agent-row">
                  <label>
                    <input
                      type="checkbox"
                      checked={state.engines[engine]}
                      onChange={() => dispatch({ type: "engine_toggled", engine })}
                    />
                    <span className="engine-dot" style={{ background: ENGINE_COLOR[engine] }} aria-hidden />
                    <span className="new-workspace-agent-label">{ENGINE_LABEL[engine]}</span>
                  </label>
                </li>
              ))}
            </ul>
          )}
        </div>

        {state.error && <p className="new-workspace-error">{state.error}</p>}

        <div className="new-workspace-footer">
          <button className="new-workspace-cancel" onClick={onClose}>
            Cancel
          </button>
          <button className="new-workspace-submit" onClick={confirm} disabled={!canSubmit(state)}>
            {state.submitting ? "Starting…" : "Create Session"}
          </button>
        </div>
      </div>
    </div>
  );
}
