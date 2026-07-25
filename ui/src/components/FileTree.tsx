// Founder feedback, 2026-07-25 (verbatim): "It would be nice to have a
// folder/file navigation on the right panel." Always part of the original
// design intent — docs/PLAN.md's v1 scope named "file viewer + open-in-
// external only" as the deliberate no-code-editor alternative to a full
// editor pane, but no phase had actually built the tree browser itself
// until now. Still no code editor / no file preview — clicking a file opens
// it in whatever the OS considers its default app, same as DetailPanel's
// "Open file" action.
//
// Lazy, expand-on-click: `listDir` (src-tauri/src/commands.rs, thin wrapper
// over brain_ingest::walk::list_dir) is called once per directory the user
// actually opens, never eagerly for the whole project up front — DESIGN.md
// 5's "huge monorepo -> bounded, incremental" concern applies to a file
// tree exactly as much as it does to ingestion. Loaded children are cached
// per path in `children` so re-collapsing/re-expanding a folder never
// re-fetches it.
//
// Actions mirror `map/DetailPanel.tsx`'s exact pattern: `openPath`/
// `revealItemInDir` from `@tauri-apps/plugin-opener` called directly, no new
// Tauri command wrapping them — the plugin is already registered
// (`tauri_plugin_opener::init()` in `src-tauri/src/lib.rs`) and granted
// (`opener:default` in `capabilities/default.json`), so wrapping them again
// would just be reinventing what's already there. See that file's own
// module doc for the fuller reasoning.
//
// Optional productivity affordance (same founder feedback round): the
// drag-and-drop-a-file-onto-a-terminal feature (`Terminal.tsx`) already
// pastes a quoted path into the active session via `sessionWrite` — a small
// per-file "insert" control does the same when a terminal tab is currently
// active, using the identical quoting convention (`"path" `, trailing
// space) so it behaves exactly like a real drop. Deliberately a separate
// control from the row's main click (which always opens the file, per this
// task's required behavior) rather than overloading what one click means.
import { useCallback, useEffect, useState } from "react";
import { openPath, revealItemInDir } from "@tauri-apps/plugin-opener";
import { listDir, sessionWrite, type DirEntry } from "../lib/tauri";
import { isExpanded, resolveRowClick, toggleExpanded, type ExpandedPaths } from "../state/fileTreeState";
import type { ProjectInfo } from "../state/sessions";

/** One directory level's fetch state — `undefined`/absent from the cache
 * means "not fetched yet". */
type DirState = DirEntry[] | "loading" | { error: string };

interface FileTreeProps {
  /** The sidebar's currently-selected project — the tree's root. `null`
   * when nothing is selected yet (e.g. a fresh, empty brain). */
  project: ProjectInfo | null;
  /** `App.tsx`'s `state.activeTabId` — which terminal pane last had focus,
   * if any. Powers the optional "paste path into terminal" row action;
   * `null` simply hides that control rather than erroring. */
  activeTabId: string | null;
  /** Collapses the panel — same shape as `DetailPanel`'s `onClose`. */
  onClose: () => void;
}

const INDENT_PX = 14;
const BASE_PADDING_PX = 10;

export default function FileTree({ project, activeTabId, onClose }: FileTreeProps) {
  const [root, setRoot] = useState<DirState | null>(null); // null = nothing requested yet
  const [expanded, setExpanded] = useState<ExpandedPaths>(new Set());
  const [children, setChildren] = useState<Map<string, DirState>>(new Map());
  const [actionMessage, setActionMessage] = useState<string | null>(null);

  const load = useCallback((path: string, onDone: (state: DirState) => void) => {
    onDone("loading");
    listDir(path)
      .then((entries) => onDone(entries))
      .catch((err) => onDone({ error: String(err) }));
  }, []);

  // Reset everything and (re)fetch the root whenever the selected project
  // changes — stale expand state / cached children from a previous project
  // must never leak into the next one.
  useEffect(() => {
    setExpanded(new Set());
    setChildren(new Map());
    setActionMessage(null);
    if (!project?.path) {
      setRoot(null);
      return;
    }
    let cancelled = false;
    load(project.path, (state) => {
      if (!cancelled) setRoot(state);
    });
    return () => {
      cancelled = true;
    };
  }, [project?.path, load]);

  // Deliberately NOT done inside `setExpanded`'s updater function — this
  // app renders under `<React.StrictMode>` (main.tsx), which double-invokes
  // state updater functions to catch impurities. Firing `load` (a side
  // effect: two more `setState` calls plus a real `listDir` call) from
  // inside an updater would double-fetch under StrictMode. The toggle
  // itself stays a pure `setExpanded` call; the side effect runs once,
  // directly in this plain event-handler body.
  const handleToggle = useCallback(
    (path: string) => {
      const willExpand = !isExpanded(expanded, path);
      setExpanded((prev) => toggleExpanded(prev, path));
      if (willExpand && !children.has(path)) {
        load(path, (state) => {
          setChildren((prev) => new Map(prev).set(path, state));
        });
      }
    },
    [expanded, children, load],
  );

  async function handleOpenFile(path: string) {
    try {
      await openPath(path);
    } catch (err) {
      console.error("openPath failed", err);
      setActionMessage(`Couldn't open ${path}: ${err}`);
    }
  }

  async function handleReveal(path: string) {
    try {
      await revealItemInDir(path);
    } catch (err) {
      console.error("revealItemInDir failed", err);
      setActionMessage(`Couldn't reveal ${path}: ${err}`);
    }
  }

  async function handleInsert(path: string) {
    if (!activeTabId) return;
    try {
      await sessionWrite(activeTabId, `"${path}" `);
    } catch (err) {
      console.error("sessionWrite (insert path) failed", err);
      setActionMessage(`Couldn't paste ${path} into the terminal: ${err}`);
    }
  }

  function handleRowClick(entry: DirEntry) {
    const action = resolveRowClick(entry);
    if (action.type === "toggle") handleToggle(action.path);
    else void handleOpenFile(action.path);
  }

  function renderDirState(state: DirState | undefined, depth: number) {
    const padding = BASE_PADDING_PX + depth * INDENT_PX;
    if (state === undefined || state === "loading") {
      return (
        <div className="file-tree-loading" style={{ paddingLeft: padding }}>
          Loading…
        </div>
      );
    }
    if (!Array.isArray(state)) {
      return (
        <div className="file-tree-error" style={{ paddingLeft: padding }}>
          {state.error}
        </div>
      );
    }
    if (state.length === 0) {
      return (
        <div className="file-tree-empty-dir" style={{ paddingLeft: padding }}>
          Empty
        </div>
      );
    }
    return renderEntries(state, depth);
  }

  function renderEntries(entries: DirEntry[], depth: number) {
    return (
      <ul className="file-tree-list" role="group">
        {entries.map((entry) => {
          const open = entry.is_dir && isExpanded(expanded, entry.path);
          return (
            <li key={entry.path}>
              <div className="file-tree-row" style={{ paddingLeft: BASE_PADDING_PX + depth * INDENT_PX }}>
                <button className="file-tree-row-main" onClick={() => handleRowClick(entry)} title={entry.path}>
                  {entry.is_dir ? (
                    <span className={`file-tree-chevron${open ? " is-open" : ""}`} aria-hidden="true">
                      &#9656;
                    </span>
                  ) : (
                    <span className="file-tree-chevron is-file" aria-hidden="true" />
                  )}
                  <span className="file-tree-name">{entry.name}</span>
                </button>
                {!entry.is_dir && activeTabId && (
                  <button
                    className="file-tree-row-insert"
                    onClick={() => void handleInsert(entry.path)}
                    aria-label={`Paste ${entry.name}'s path into the active terminal`}
                    title="Paste path into the active terminal"
                  >
                    &#8618;
                  </button>
                )}
              </div>
              {open && renderDirState(children.get(entry.path), depth + 1)}
            </li>
          );
        })}
      </ul>
    );
  }

  function renderBody() {
    if (!project) {
      return <p className="file-tree-empty">Select a project to browse its files.</p>;
    }
    if (!project.path) {
      return <p className="file-tree-empty">This project has no known path yet.</p>;
    }
    if (root === null || root === "loading") {
      return <p className="file-tree-loading">Loading…</p>;
    }
    if (!Array.isArray(root)) {
      return <p className="file-tree-error">{root.error}</p>;
    }
    if (root.length === 0) {
      return <p className="file-tree-empty">Empty project — nothing to browse yet.</p>;
    }
    return renderEntries(root, 0);
  }

  return (
    <aside className="file-tree" aria-label="Project files">
      <div className="file-tree-header">
        <span className="file-tree-title">FILES</span>
        <div className="file-tree-header-actions">
          {project?.path && (
            <button
              className="file-tree-reveal"
              onClick={() => void handleReveal(project.path as string)}
              aria-label={`Reveal ${project.label} in Finder`}
              title="Reveal in Finder"
            >
              &#8689;
            </button>
          )}
          <button className="file-tree-close" onClick={onClose} aria-label="Hide file tree" title="Hide file tree">
            &times;
          </button>
        </div>
      </div>

      <div className="file-tree-body">{renderBody()}</div>

      {actionMessage && <div className="file-tree-action-message">{actionMessage}</div>}
    </aside>
  );
}
