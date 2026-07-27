// ⌘N -> "Session" (design §3's New session modal, Task 10).
//
// The dialog asks **one** question — *what are you doing?* — and spends the
// rest of its height on the two things that answer can't decide for you:
// how many terminals, and what runs in each one. The prompt does double
// duty (`state/newSessionState.ts`'s `sessionNameFromPrompt`): it names the
// session in the sidebar AND is delivered as the first prompt to its lead
// terminal, so the session starts working instead of waiting to be told
// what it's for.
//
// What this replaced, and why: a name field, a row of engine checkboxes and
// a layout preview that only previewed itself. Checkboxes could say "claude
// + shell" but never *which pane* got which, so a mixed session was
// assembled by luck; the layout card was a picture rather than an
// instruction. Here `layout` IS the terminal count and `slots` is one
// engine per terminal, kept in lockstep by the reducer — what the grid
// shows is what gets spawned.
//
// The folder section stays scoped to the project (`isInsideProjectRoot`,
// component-wise, mirroring `crates/brain-ingest/src/fileops.rs`'s
// discipline — see that module's own doc for what this guard is and isn't),
// so a folder picked outside the project is refused with a sentence rather
// than silently accepted.
//
// **Ownership split with the caller**, the shape `NewWorkspaceModal`
// established: this component owns the dialog and the folder pick; the
// caller (`App.tsx`'s `handleSessionCreated`) owns spawning the terminals,
// minting the session-group id, and closing the modal — so a partial
// mid-batch failure lands the user in the project with whatever succeeded
// and uses the existing error banner rather than a second error surface
// inside an already-closed dialog.
import { useEffect, useReducer, useRef, useState } from "react";
import { open } from "@tauri-apps/plugin-dialog";
import { AVAILABLE_AGENTS, type AgentsState } from "../state/agents";
import {
  canSubmit,
  initialNewSessionStateFor,
  newSessionReducer,
} from "../state/newSessionState";
import { LAYOUT_PRESETS, MAX_PANES, gridShape, type LayoutPreset } from "../state/paneGrid";
import { sessionShapeBadge } from "../state/sessionGroups";
import type { Engine, ProjectInfo } from "../state/sessions";
import { ingestionStatus } from "../lib/tauri";
import { AGENT_ICON, ENGINE_LABEL } from "../theme";
import Icon from "./Icon";

interface NewSessionModalProps {
  project: ProjectInfo;
  agentState: AgentsState;
  onCreate: (project: ProjectInfo, cwd: string, slots: Engine[], prompt: string) => void;
  onClose: () => void;
}

/** The CSS-drawn preset preview every layout picker uses
 * (`NewWorkspaceModal` and `EmptyWorkspace` import it from here) — shared
 * through `gridShape` so the glyph can never drift from the arrangement the
 * grid actually produces, and one hand-copy per dialog is how they would
 * eventually disagree. */
export function LayoutGlyph({ preset }: { preset: LayoutPreset }) {
  const { rows, cols } = gridShape(preset);
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

/** One terminal's engine, as a numbered row that opens a short menu of the
 * engines this machine actually has (plus shell, which every machine has).
 * Private to this dialog: the numbering is the slot's identity — "terminal
 * 2 runs Codex" — which means nothing anywhere else.
 *
 * The menu is absolutely positioned inside the row rather than portalled,
 * and `.new-session-panel` opts out of `.modal-panel`'s clipping so it can
 * hang past the section. Outside-click is caught in the **capture** phase:
 * the panel stops mousedown from bubbling (that's what keeps a click inside
 * the dialog from reaching the backdrop's close), so a bubble-phase
 * listener would never see a click on another row. */
function SlotPicker({
  index,
  engine,
  agentState,
  onPick,
}: {
  index: number;
  engine: Engine;
  agentState: AgentsState;
  onPick: (engine: Engine) => void;
}) {
  const [menuOpen, setMenuOpen] = useState(false);
  const rootRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!menuOpen) return;
    function onMouseDown(e: MouseEvent) {
      if (!rootRef.current?.contains(e.target as Node)) setMenuOpen(false);
    }
    document.addEventListener("mousedown", onMouseDown, true);
    return () => document.removeEventListener("mousedown", onMouseDown, true);
  }, [menuOpen]);

  // An engine with no CLI installed can't run, so it isn't offered — this
  // dialog spawns immediately, unlike ⌘T's list which can offer an install.
  const options = AVAILABLE_AGENTS.filter((agent) => agent === "shell" || agentState.installed.has(agent));

  return (
    <div
      className="slot-picker"
      ref={rootRef}
      onKeyDown={(e) => {
        // Escape belongs to the menu while it's open — the dialog's own
        // Escape (close everything) is one keypress further out.
        if (menuOpen && e.key === "Escape") {
          e.preventDefault();
          e.stopPropagation();
          setMenuOpen(false);
        }
      }}
    >
      <button
        type="button"
        className="slot-picker-trigger"
        aria-haspopup="listbox"
        aria-expanded={menuOpen}
        aria-label={`Terminal ${index + 1} engine: ${ENGINE_LABEL[engine]}`}
        onClick={() => setMenuOpen((v) => !v)}
      >
        <span className="slot-picker-index">{index + 1}</span>
        <span className="slot-picker-icon">
          <Icon name={AGENT_ICON[engine]} size={14} />
        </span>
        <span className="slot-picker-name">{ENGINE_LABEL[engine]}</span>
        <span className="slot-picker-chevron">
          <Icon name="chevron-down" size={9} strokeWidth={2.4} />
        </span>
      </button>
      {menuOpen && (
        <div className="slot-picker-menu" role="listbox" aria-label={`Engine for terminal ${index + 1}`}>
          {options.map((option) => (
            <button
              key={option}
              type="button"
              role="option"
              aria-selected={option === engine}
              className={`slot-picker-option${option === engine ? " is-selected" : ""}`}
              onClick={() => {
                onPick(option);
                setMenuOpen(false);
              }}
            >
              <span className="slot-picker-icon">
                <Icon name={AGENT_ICON[option]} size={14} />
              </span>
              <span className="slot-picker-name">{ENGINE_LABEL[option]}</span>
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

export default function NewSessionModal({ project, agentState, onCreate, onClose }: NewSessionModalProps) {
  const [state, dispatch] = useReducer(
    newSessionReducer,
    { project, agentState },
    ({ project: p, agentState: a }) => initialNewSessionStateFor(p, a),
  );
  const promptRef = useRef<HTMLInputElement | null>(null);
  // The brain's node count, for the footer's one line of reassurance ("these
  // terminals start knowing your codebase"). Read once on mount, same as
  // every other dialog that shows a backend number; a failure just leaves it
  // at 0 rather than blocking a dialog that has nothing to do with ingestion.
  const [nodeCount, setNodeCount] = useState(0);

  useEffect(() => {
    promptRef.current?.focus();
  }, []);

  useEffect(() => {
    let live = true;
    ingestionStatus()
      .then((status) => {
        if (live) setNodeCount(status.total_nodes ?? 0);
      })
      .catch((err) => console.error("new-session brain count failed", err));
    return () => {
      live = false;
    };
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
      dispatch({ type: "path", path: selected });
    } catch (err) {
      console.error("new-session folder picker failed", err);
    }
  }

  function confirm() {
    if (!canSubmit(state)) return;
    dispatch({ type: "submit_started" });
    onCreate(project, state.path, state.slots, state.prompt);
  }

  function handleKeyDown(e: React.KeyboardEvent) {
    if (e.key === "Escape") {
      e.preventDefault();
      onClose();
      return;
    }
    const active = document.activeElement;
    if (e.key === "Enter") {
      // Enter from the prompt (or from nothing) starts the session. Enter
      // on a slot's trigger belongs to that button — it opens the menu, and
      // stealing it would submit the session the user was still assembling.
      if (active === promptRef.current || active === null || active === document.body) {
        e.preventDefault();
        confirm();
      }
      return;
    }
    // Digits pick a layout — but only outside the prompt. "fix issue 2" is
    // a sentence, not a keyboard shortcut, and a field that silently
    // rearranges the dialog as you describe your work is worse than no
    // shortcut at all.
    if (active === promptRef.current) return;
    const digit = Number(e.key);
    if (Number.isInteger(digit) && digit >= 1 && digit <= LAYOUT_PRESETS.length) {
      e.preventDefault();
      dispatch({ type: "layout", layout: LAYOUT_PRESETS[digit - 1] });
    }
  }

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        className="modal-panel new-session-panel"
        role="dialog"
        aria-label="New session"
        onMouseDown={(e) => e.stopPropagation()}
        onKeyDown={handleKeyDown}
      >
        <div className="modal-header">
          <span>New session</span>
          <span className="modal-header-context">in {project.label} workspace</span>
          <span className="modal-header-key">⌘N</span>
        </div>

        <div className="modal-section">
          <div className="modal-field-label">What are you doing?</div>
          <input
            ref={promptRef}
            className="modal-text-input"
            aria-label="What are you doing?"
            value={state.prompt}
            onChange={(e) => dispatch({ type: "prompt", value: e.target.value })}
          />
          <div className="modal-field-help">
            Becomes the session name and the first prompt. Leave empty for a bare terminal.
          </div>
        </div>

        <div className="modal-section">
          <div className="modal-field-row">
            <span className="modal-field-label">Terminal layout</span>
            <span className="modal-field-note">max {MAX_PANES} terminals per session</span>
          </div>
          <div className="layout-thumb-row">
            {LAYOUT_PRESETS.map((preset) => (
              <button
                key={preset}
                type="button"
                className={`layout-thumb${state.layout === preset ? " is-selected" : ""}`}
                aria-pressed={state.layout === preset}
                onClick={() => dispatch({ type: "layout", layout: preset })}
              >
                <LayoutGlyph preset={preset} />
                <span className="layout-thumb-caption">{sessionShapeBadge(preset)}</span>
              </button>
            ))}
          </div>
        </div>

        <div className="modal-section">
          <div className="modal-field-row">
            <span className="modal-field-label">Engine per terminal</span>
            <span className="modal-field-note">each terminal runs its own agent or shell</span>
          </div>
          <div className="slot-grid">
            {state.slots.map((engine, i) => (
              <SlotPicker
                key={i}
                index={i}
                engine={engine}
                agentState={agentState}
                onPick={(picked) => dispatch({ type: "slot", index: i, engine: picked })}
              />
            ))}
          </div>
        </div>

        <div className="modal-section modal-section-last">
          <div className="modal-field-label">Working folder</div>
          <div className="folder-row">
            <span className="folder-row-path" title={state.path}>
              {state.path}
            </span>
            <button type="button" className="folder-row-change" onClick={() => void pickFolder()}>
              Change
            </button>
          </div>
          {state.error && <div className="modal-field-help modal-field-error">{state.error}</div>}
        </div>

        <div className="modal-footer">
          <span className="modal-footer-hint">
            <span className="modal-footer-dot" />
            {state.layout} terminal{state.layout === 1 ? "" : "s"} boot briefed on{" "}
            {nodeCount.toLocaleString()} brain nodes
          </span>
          <button type="button" className="btn-ghost" onClick={onClose}>
            Cancel
          </button>
          <button type="button" className="btn-primary" onClick={confirm} disabled={!canSubmit(state)}>
            Start session ⏎
          </button>
        </div>
      </div>
    </div>
  );
}
