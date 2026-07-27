// The sidebar's "+" flow — "New workspace".
//
// ## Rewritten for the left-pane redesign (Task 12)
//
// The old BridgeSpace-derived dialog asked four questions (name, folder,
// LAYOUT, AI AGENTS). This one asks *one* — which folder — and then tells
// you what is in it.
//
// - The name is the folder's basename (`workspaceNameFromPath`); renaming
//   lives in the workspace menu's ⋯ → ProjectMenu.
// - Layout and engines are gone: adding a workspace no longer starts
//   terminals. `App.handleWorkspaceCreated` opens `NewSessionModal`
//   immediately after this closes, and that dialog owns which engines run
//   in which panes — one owner instead of two dialogs that could disagree.
//
// What replaces them is the FOUND IN THIS FOLDER strip: a `folder_stats`
// call (`src-tauri/src/commands/mod.rs`) reporting the file count the
// *ingestion walker* would actually walk, the top languages, and git
// status. Adding a folder stops being a leap of faith — you can see you
// picked `~/code/api` and not `~/code` before committing to a walk.
//
// The two toggles are the only real choices left, and both are about the
// folder rather than about terminals: whether to ingest now, and whether
// memory notes get reviewed before they commit (the same
// `REVIEW_MEMORY_SETTING_KEY` `ReviewPanel` owns — this dialog just writes
// the same "true"/"false" encoding rather than inventing a second one).
//
// **Ownership split with the caller** (unchanged in shape from the old
// dialog, and the same one `NewSessionModal` uses): this component owns
// picking a folder and creating the project — an `add_project` failure
// surfaces inline and keeps the dialog open. Once that succeeds it hands
// off `onCreate(project)`; closing the modal, selecting the workspace and
// opening the session dialog all live in `Sidebar`/`App`.
import { useEffect, useReducer, useRef } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import {
  canSubmit,
  initialNewWorkspaceState,
  newWorkspaceReducer,
  workspaceNameFromPath,
} from "../state/newWorkspaceState";
import type { ProjectInfo } from "../state/sessions";
import {
  REVIEW_MEMORY_SETTING_KEY,
  addProject,
  folderStats,
  rootsSetPaused,
  settingsSet,
} from "../lib/tauri";

interface NewWorkspaceModalProps {
  onCreate: (project: ProjectInfo) => void;
  onClose: () => void;
}

export default function NewWorkspaceModal({ onCreate, onClose }: NewWorkspaceModalProps) {
  const [state, dispatch] = useReducer(newWorkspaceReducer, undefined, initialNewWorkspaceState);
  const panelRef = useRef<HTMLDivElement | null>(null);
  // Guards against a double submit when Enter both fires the footer
  // button's own click AND reaches `handleKeyDown` — `state.submitting`
  // can't do it alone, because a React state update isn't visible to the
  // second handler running in the same event.
  const inFlight = useRef(false);

  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  async function pickFolder() {
    try {
      const selected = await open({
        directory: true,
        multiple: false,
        title: "New workspace folder",
      });
      if (!selected || Array.isArray(selected)) return; // user cancelled
      dispatch({ type: "path", path: selected });
      try {
        dispatch({ type: "stats", stats: await folderStats(selected) });
      } catch (err) {
        // The strip is information, not validation — a folder we can't
        // summarise still adds fine, so this degrades to placeholders
        // rather than blocking the flow with an error surface.
        console.error("folder_stats failed", err);
        dispatch({ type: "stats", stats: null });
      }
    } catch (err) {
      console.error("new-workspace folder picker failed", err);
    }
  }

  async function confirm() {
    if (!canSubmit(state) || !state.path || inFlight.current) return;
    inFlight.current = true;
    dispatch({ type: "submit_started" });
    try {
      const project = await addProject(state.path, workspaceNameFromPath(state.path));
      // Preferences are deliberately non-fatal: the workspace now exists,
      // and failing to persist a toggle must not strand the user in a
      // dialog whose only button would re-add the folder.
      try {
        if (!state.ingestNow) await rootsSetPaused(project.id, true);
        await settingsSet(REVIEW_MEMORY_SETTING_KEY, state.reviewNotes ? "true" : "false");
      } catch (err) {
        console.error("new-workspace preferences failed", err);
      }
      onCreate(project);
    } catch (err) {
      console.error("add_project failed", err);
      inFlight.current = false;
      dispatch({ type: "submit_failed", error: String(err) });
    }
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
      return;
    }
    if (e.key !== "Enter") return;
    // Enter adds the workspace from anywhere in the dialog EXCEPT the
    // folder row, where it belongs to "Browse…" (opening a native picker
    // and submitting at once would be two actions from one keypress).
    //
    // Stated as one exclusion on purpose — the same lesson
    // `NewSessionModal` records: the obvious-looking "only confirm when
    // nothing has focus" spelling makes Enter a DEAD KEY right at the end
    // of the flow, because clicking a toggle moves focus to that button.
    // Space still toggles a focused switch; Enter still submits.
    const active = document.activeElement;
    if (active instanceof Element && active.closest(".folder-row") !== null) return;
    e.preventDefault();
    void confirm();
  }

  const stats = state.stats;
  const loading = stats === "loading";

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      {/* `tabIndex={-1}` is a keyboard backstop, not a focus target — see
          `NewSessionModal`'s copy of this note: WKWebView does not hand
          mouse-click focus to <button> the way Chrome does, so focus needs
          somewhere in-tree to land for `handleKeyDown` to see anything. */}
      <div
        ref={panelRef}
        className="modal-panel new-workspace-panel-v2"
        role="dialog"
        aria-label="New workspace"
        tabIndex={-1}
        onMouseDown={(e) => e.stopPropagation()}
        onKeyDown={handleKeyDown}
      >
        <div className="modal-header">
          <span>New workspace</span>
        </div>

        <div className="modal-section">
          <div className="modal-field-label">Project folder</div>
          <div className="folder-row">
            <span className="folder-row-path" title={state.path ?? undefined}>
              {state.path ?? "No folder chosen yet"}
            </span>
            <button type="button" className="folder-row-change" onClick={() => void pickFolder()}>
              Browse…
            </button>
          </div>
        </div>

        {state.path !== null && (
          <div className="modal-section">
            <div className="modal-field-label">Found in this folder</div>
            <div className="stats-strip">
              <div className="stats-strip-cell">
                <div className="stats-strip-value">
                  {loading || !stats ? "…" : stats.files.toLocaleString()}
                </div>
                <div className="stats-strip-label">files to walk</div>
              </div>
              <div className="stats-strip-cell">
                <div className="stats-strip-value">
                  {loading || !stats ? "…" : stats.languages.join(" · ") || "—"}
                </div>
                <div className="stats-strip-label">languages</div>
              </div>
              <div className="stats-strip-cell">
                <div className={`stats-strip-value${stats && stats !== "loading" && stats.git ? " is-good" : ""}`}>
                  {loading || !stats ? "…" : stats.git ? "git ✓" : "no git"}
                </div>
                <div className="stats-strip-label">
                  {loading || !stats ? "…" : stats.git ? `${stats.branches} branches` : "init later"}
                </div>
              </div>
            </div>
          </div>
        )}

        <div className="modal-section modal-section-last">
          <div className="toggle-row">
            <span className="toggle-row-text">
              <span className="toggle-row-title">Ingest into the brain now</span>
              <span className="toggle-row-sub">
                Walk, parse and link in the background — you can start working immediately.
              </span>
            </span>
            <button
              type="button"
              role="switch"
              aria-checked={state.ingestNow}
              aria-label="Ingest into the brain now"
              className="switch"
              onClick={() => dispatch({ type: "ingestNow" })}
            />
          </div>
          <div className="toggle-row toggle-row-second">
            <span className="toggle-row-text">
              <span className="toggle-row-title">Review memory notes before commit</span>
              <span className="toggle-row-sub">Off: session notes auto-commit to your repo.</span>
            </span>
            <button
              type="button"
              role="switch"
              aria-checked={state.reviewNotes}
              aria-label="Review memory notes before commit"
              className="switch"
              onClick={() => dispatch({ type: "reviewNotes" })}
            />
          </div>
          {state.error && (
            <div className="modal-field-help modal-field-error">
              Couldn't create workspace: {state.error}
            </div>
          )}
        </div>

        <div className="modal-footer">
          <span className="modal-footer-hint">
            <span className="modal-footer-dot" />
            Scoped access — only this folder is readable.
          </span>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button
            type="button"
            className="btn-primary"
            onClick={() => void confirm()}
            disabled={!canSubmit(state)}
          >
            {state.submitting ? "Adding…" : "Add workspace ⏎"}
          </button>
        </div>
      </div>
    </div>
  );
}
