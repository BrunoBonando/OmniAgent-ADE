// The sidebar's "+" flow — founder feedback, 2026-07-24 (Bruno, verbatim):
// "Open one terminal, and start from there... the user can add multiple
// sessions within one project or add a new project (item on the left)".
// Pick a folder, optionally rename it, confirm -> `add_project` creates the
// sidebar row immediately and starts ingesting it invisibly in the
// background (same `ingestion_status` channel Task 8.1 already built — no
// second poll loop, see `App.tsx`/`Sidebar.tsx`). Same overlay-backdrop
// frame as EnginePicker/AboutPanel/FirstRun's pick step; the folder picker
// itself reuses FirstRun's `@tauri-apps/plugin-dialog` pattern. Unlike
// FirstRun (which points at a ROOT folder full of many repos), this adds
// exactly one project directory — see `state/addProjectState.ts`'s module
// doc and `src-tauri/src/roots.rs`'s `add_project` for why those two flows
// deliberately stay separate.
import { useEffect, useReducer, useRef, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { addProjectReducer, canSubmit, initialAddProjectState } from "../state/addProjectState";
import { addProject } from "../lib/tauri";
import type { ProjectInfo } from "../state/sessions";

interface AddProjectModalProps {
  onAdded: (project: ProjectInfo) => void;
  onClose: () => void;
}

export default function AddProjectModal({ onAdded, onClose }: AddProjectModalProps) {
  const [state, dispatch] = useReducer(addProjectReducer, initialAddProjectState);
  const [picking, setPicking] = useState(false);
  const panelRef = useRef<HTMLDivElement | null>(null);
  const nameInputRef = useRef<HTMLInputElement | null>(null);

  useEffect(() => {
    if (state.phase === "name") nameInputRef.current?.focus();
    else panelRef.current?.focus();
  }, [state.phase]);

  async function pickFolder() {
    setPicking(true);
    try {
      const selected = await open({ directory: true, multiple: false, title: "Add a project" });
      if (!selected || Array.isArray(selected)) return; // user cancelled
      dispatch({ type: "folder_picked", path: selected });
    } catch (err) {
      console.error("add-project folder picker failed", err);
    } finally {
      setPicking(false);
    }
  }

  async function confirm() {
    if (!canSubmit(state) || !state.path) return;
    dispatch({ type: "submit_started" });
    try {
      const summary = await addProject(state.path, state.name.trim());
      onAdded(summary);
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
    if (e.key === "Enter" && state.phase === "name") {
      e.preventDefault();
      void confirm();
    }
  }

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        ref={panelRef}
        className="add-project-panel"
        role="dialog"
        aria-label="Add project"
        tabIndex={-1}
        onKeyDown={handleKeyDown}
        onMouseDown={(e) => e.stopPropagation()}
      >
        <p className="add-project-eyebrow">&gt; add project_</p>

        {state.phase === "pick" && (
          <>
            <p className="add-project-body">
              Pick a folder to add as a project. It shows up in the sidebar right away — a terminal is one
              click away — while ingestion happens quietly in the background.
            </p>
            <button className="add-project-cta" onClick={() => void pickFolder()} disabled={picking}>
              {picking ? "Choosing…" : "Choose folder…"}
            </button>
          </>
        )}

        {(state.phase === "name" || state.phase === "submitting") && (
          <>
            <p className="add-project-path" title={state.path ?? undefined}>
              {state.path}
            </p>
            <label className="add-project-name-label" htmlFor="add-project-name">
              Project name
            </label>
            <input
              id="add-project-name"
              ref={nameInputRef}
              className="add-project-name-input"
              value={state.name}
              onChange={(e) => dispatch({ type: "name_changed", name: e.target.value })}
              disabled={state.phase === "submitting"}
            />
            {state.error && <p className="add-project-error">Couldn't add project: {state.error}</p>}
            <div className="add-project-actions">
              <button
                className="add-project-back"
                onClick={() => dispatch({ type: "choose_different_folder" })}
                disabled={state.phase === "submitting"}
              >
                Choose a different folder
              </button>
              <button
                className="add-project-cta"
                onClick={() => void confirm()}
                disabled={!canSubmit(state)}
              >
                {state.phase === "submitting" ? "Adding…" : "Add project"}
              </button>
            </div>
          </>
        )}

        <button className="add-project-skip" onClick={onClose}>
          Cancel
        </button>
      </div>
    </div>
  );
}
