// "Import projects from other tools" — founder ask (Bruno, 2026-07-25,
// verbatim): "detect other dev tools already installed on the user's
// machine and offer to import their known project lists, so a new
// OmniAgent user doesn't have to manually '+ Add Project' one folder at a
// time." Part A (backend, frozen, `crates/brain-ingest/src/
// import_detect.rs`, 314 Rust tests green) built read-only detection for
// Claude Code / VS Code / Cursor. This is Part B: the UI, and the only
// place that turns a selected candidate into a real project — reusing the
// exact same `addProject` (`lib/tauri.ts`) call `NewWorkspaceModal.tsx`
// already uses, never a second `add_project` call shape.
//
// Interaction pattern (Bruno's own reference, BridgeMind/ChatGPT-style
// import): two phases in one overlay —
// (a) "tools" — `detectImportableTools()` results as a toggleable list.
//     An undetected tool (e.g. Cursor on a machine that's never installed
//     it) renders grayed and non-interactive with "not found", never
//     hidden — that's still useful signal ("we checked, it's not here").
// (b) "candidates" — `listImportCandidates()` for every checked tool,
//     merged/deduped/existing-project-aware (`importState.ts`'s
//     `mergeCandidates`), grouped by source tool, default all checked
//     (matching the reference) except rows that are already real
//     OmniAgent projects — those show disabled with an "Already added"
//     tag rather than being silently dropped.
// "Import Selected (N)" runs the bulk `add_project` loop sequentially
// (same shape as `App.tsx`'s `handleWorkspaceCreated`: one try/catch per
// item, one failure never aborts the rest), then shows a "done" summary
// with per-row ✓/✗ so a partial failure is never a dead end — the user can
// always close and keep whatever succeeded.
//
// Ownership split with the caller (`FirstRun.tsx` / `Sidebar.tsx`, both via
// `App.tsx`): this component owns every Tauri call in the flow
// (`detectImportableTools`, `listImportCandidates`, `addProject` per
// checked row) and its own error/progress display. Once the batch
// finishes, it calls `onImported(result)` — reloading the project list,
// selecting a newly-created project, and showing an error-banner summary
// for any failures all live in the caller, exactly the split
// `NewWorkspaceModal`'s `onCreate` already established.
import { useEffect, useReducer } from "react";
import {
  canProceedToCandidates,
  checkedCount,
  checkedPaths,
  importReducer,
  initialImportState,
  mergeCandidates,
  rowsByTool,
  selectableTools,
  summarizeImportResults,
  toBatchResult,
  toolGroupState,
  IMPORT_TOOL_COLOR,
  type ImportPhase,
  type ImportRow,
} from "../state/importState";
import type { ImportBatchResult } from "../state/importState";
import type { DetectedTool, ImportCandidate } from "../lib/tauri";
import { addProject, detectImportableTools, listImportCandidates } from "../lib/tauri";
import type { ProjectInfo } from "../state/sessions";
import Icon from "./Icon";

interface ImportProjectsFlowProps {
  /** For duplicate detection (`mergeCandidates`) — the caller's current
   * project list (`Sidebar`'s own `projects` prop / `App.tsx`'s
   * `state.projects`), never re-fetched here. */
  existingProjects: ProjectInfo[];
  onImported: (result: ImportBatchResult) => void;
  onClose: () => void;
}

function ToolStatusRow({ tool }: { tool: DetectedTool }) {
  return (
    <li className="import-tool-row is-unavailable" aria-disabled="true">
      <span className="import-tool-dot is-off" aria-hidden="true" />
      <span className="import-tool-label">{tool.name}</span>
      <span className="import-tool-status">not found</span>
    </li>
  );
}

export default function ImportProjectsFlow({ existingProjects, onImported, onClose }: ImportProjectsFlowProps) {
  const [state, dispatch] = useReducer(importReducer, initialImportState);

  // Load the tool list once, on mount.
  useEffect(() => {
    let cancelled = false;
    detectImportableTools()
      .then((tools) => {
        if (!cancelled) dispatch({ type: "tools_loaded", tools });
      })
      .catch((err) => {
        console.error("detect_importable_tools failed", err);
        if (!cancelled) dispatch({ type: "tools_load_failed", error: String(err) });
      });
    return () => {
      cancelled = true;
    };
  }, []);

  async function proceedToCandidates() {
    if (!canProceedToCandidates(state) || !state.tools) return;
    const checkedTools = selectableTools(state.tools).filter((t) => state.selectedTools[t.id]);
    dispatch({ type: "candidates_requested" });
    const byTool: Record<string, ImportCandidate[]> = {};
    const settled = await Promise.allSettled(
      checkedTools.map(async (tool) => {
        byTool[tool.id] = await listImportCandidates(tool.id);
      }),
    );
    // A single tool's `list_import_candidates` failing (shouldn't happen —
    // every id here came straight from `detectImportableTools()` — but IO
    // is IO) never aborts the rest of the checklist; it just contributes
    // zero rows, same "one bad source never blocks the others" philosophy
    // the Rust side documents for itself.
    for (const [i, result] of settled.entries()) {
      if (result.status === "rejected") {
        console.error(`list_import_candidates(${checkedTools[i].id}) failed`, result.reason);
      }
    }
    const rows = mergeCandidates(checkedTools, byTool, existingProjects);
    dispatch({ type: "candidates_loaded", rows });
  }

  async function runImport() {
    const toImport = checkedPaths(state);
    if (toImport.length === 0) return;
    dispatch({ type: "import_started" });
    for (const row of state.rows) {
      if (!toImport.includes(row.path)) continue;
      try {
        const project = await addProject(row.path, row.suggestedName);
        dispatch({ type: "row_result", result: { path: row.path, suggestedName: row.suggestedName, success: true, project } });
      } catch (err) {
        console.error(`add_project(${row.path}) failed`, err);
        dispatch({
          type: "row_result",
          result: { path: row.path, suggestedName: row.suggestedName, success: false, error: String(err) },
        });
      }
    }
    dispatch({ type: "import_finished" });
  }

  function finish() {
    onImported(toBatchResult(state.results));
    onClose();
  }

  const grouped = rowsByTool(state.rows);
  const resultByPath = new Map(state.results.map((r) => [r.path, r]));

  return (
    <div className="overlay-backdrop" onMouseDown={onClose}>
      <div
        className="import-flow-panel"
        role="dialog"
        aria-label="Import projects from other tools"
        onMouseDown={(e) => e.stopPropagation()}
      >
        <div className="import-flow-header">
          <h2 className="import-flow-title">Import projects</h2>
          {state.phase !== "importing" && (
            <button className="import-flow-close" onClick={onClose} aria-label="Close">
              &#215;
            </button>
          )}
        </div>

        {state.phase === "tools" && (
          <>
            <p className="import-flow-body">
              Pull in projects OmniAgent finds other tools already know about on this machine — nothing leaves
              your machine, this only reads local project history.
            </p>
            {state.tools === null ? (
              <p className="import-flow-loading">Checking installed tools…</p>
            ) : (
              <ul className="import-tool-list">
                {state.tools.map((tool) =>
                  tool.detected ? (
                    <li key={tool.id} className="import-tool-row">
                      <label>
                        <input
                          type="checkbox"
                          checked={!!state.selectedTools[tool.id]}
                          onChange={() => dispatch({ type: "tool_toggled", id: tool.id })}
                        />
                        <span
                          className="import-tool-dot"
                          style={{ background: IMPORT_TOOL_COLOR[tool.id] ?? "var(--ink-faint)" }}
                          aria-hidden="true"
                        />
                        <span className="import-tool-label">{tool.name}</span>
                        <span className="import-tool-count">
                          {tool.candidate_count} project{tool.candidate_count === 1 ? "" : "s"} found
                        </span>
                      </label>
                    </li>
                  ) : (
                    <ToolStatusRow key={tool.id} tool={tool} />
                  ),
                )}
              </ul>
            )}
            {state.error && <p className="import-flow-error">Couldn't check installed tools: {state.error}</p>}
            <div className="import-flow-footer">
              <button className="import-flow-cancel" onClick={onClose}>
                Cancel
              </button>
              <button
                className="import-flow-primary"
                onClick={() => void proceedToCandidates()}
                disabled={!canProceedToCandidates(state)}
              >
                Continue
              </button>
            </div>
          </>
        )}

        {(state.phase === "candidates" || state.phase === "importing" || state.phase === "done") && (
          <>
            {state.phase === "done" ? (
              <p className="import-flow-summary">{summarizeImportResults(state.results).message}</p>
            ) : (
              <p className="import-flow-body">Choose which projects to bring in — everything's checked by default.</p>
            )}
            <div className="import-flow-candidates">
              {grouped.map(({ tool, rows }) => (
                <ImportToolGroup
                  key={tool}
                  tool={tool}
                  rows={rows}
                  checked={state.checked}
                  phase={state.phase}
                  resultByPath={resultByPath}
                  onToggleRow={(path) => dispatch({ type: "candidate_toggled", path })}
                  onToggleGroup={(nextChecked) => dispatch({ type: "tool_group_set", tool, checked: nextChecked })}
                />
              ))}
              {grouped.length === 0 && <p className="import-flow-empty">No projects found for the selected tools.</p>}
            </div>
            <div className="import-flow-footer">
              {state.phase === "candidates" && (
                <>
                  <button className="import-flow-back" onClick={() => dispatch({ type: "back_to_tools" })}>
                    Back
                  </button>
                  <button className="import-flow-cancel" onClick={onClose}>
                    Cancel
                  </button>
                  <button
                    className="import-flow-primary"
                    onClick={() => void runImport()}
                    disabled={checkedCount(state) === 0}
                  >
                    Import Selected ({checkedCount(state)})
                  </button>
                </>
              )}
              {state.phase === "importing" && (
                <button className="import-flow-primary" disabled>
                  Importing… ({state.results.length}/{checkedPaths(state).length})
                </button>
              )}
              {state.phase === "done" && (
                <button className="import-flow-primary" onClick={finish}>
                  Done
                </button>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

function ImportToolGroup({
  tool,
  rows,
  checked,
  phase,
  resultByPath,
  onToggleRow,
  onToggleGroup,
}: {
  tool: string;
  rows: ImportRow[];
  checked: Record<string, boolean>;
  phase: ImportPhase;
  resultByPath: Map<string, { success: boolean; error?: string }>;
  onToggleRow: (path: string) => void;
  onToggleGroup: (checked: boolean) => void;
}) {
  const groupState = toolGroupState(rows, checked, tool);
  const toolLabel = toolDisplayName(tool);
  const locked = phase !== "candidates";

  return (
    <div className="import-tool-group">
      <div className="import-tool-group-header">
        <label className="import-tool-group-select-all">
          <input
            type="checkbox"
            checked={groupState === "all"}
            ref={(el) => {
              if (el) el.indeterminate = groupState === "some";
            }}
            disabled={locked}
            onChange={() => onToggleGroup(groupState !== "all")}
          />
          <span
            className="import-tool-dot"
            style={{ background: IMPORT_TOOL_COLOR[tool] ?? "var(--ink-faint)" }}
            aria-hidden="true"
          />
          <span className="import-tool-group-label">{toolLabel}</span>
        </label>
        <span className="import-tool-group-count">{rows.length}</span>
      </div>
      <ul className="import-candidate-list">
        {rows.map((row) => {
          const result = resultByPath.get(row.path);
          return (
            <li
              key={row.path}
              className={`import-candidate-row${row.alreadyAdded ? " is-already-added" : ""}`}
            >
              <label>
                <input
                  type="checkbox"
                  checked={!!checked[row.path]}
                  disabled={row.alreadyAdded || locked}
                  onChange={() => onToggleRow(row.path)}
                />
                <span className="import-candidate-name">{row.suggestedName}</span>
                <span className="import-candidate-path" title={row.path}>
                  {row.path}
                </span>
                {row.alreadyAdded && <span className="import-candidate-tag">Already added</span>}
                {result && (
                  <span className={`import-candidate-result ${result.success ? "is-ok" : "is-fail"}`} title={result.error}>
                    <Icon name={result.success ? "check" : "x"} size={13} strokeWidth={2.4} />
                  </span>
                )}
              </label>
            </li>
          );
        })}
      </ul>
    </div>
  );
}

/** `DetectedTool.name` is the friendlier label ("Claude Code", "VS Code"),
 * but `ImportRow` only carries the tool id — this recovers the display
 * name for a group header purely from the id, so `ImportToolGroup` doesn't
 * need the full `DetectedTool[]` threaded through it. Falls back to the id
 * itself for any future tool this list hasn't been updated for. */
function toolDisplayName(id: string): string {
  switch (id) {
    case "claude-code":
      return "Claude Code";
    case "vscode":
      return "VS Code";
    case "cursor":
      return "Cursor";
    default:
      return id;
  }
}
