// Founder feedback, 2026-07-25 (verbatim, Part A): "It would be nice to have
// a folder/file navigation on the right panel." Part B (this task, same
// day): "make sure the file view works correctly, with it's own file
// visualization. It must work exactly like the Finder from Mac OS. It's
// very important for an agent development environment" — plus a follow-up:
// "make sure that we're able to resize the right panel where the file view
// is." Still no code editor / no file preview — double-clicking a file opens
// it in whatever the OS considers its default app, same as DetailPanel's
// "Open file" action (DESIGN.md's v1 cut list: file viewer + open-in-
// external only).
//
// **2026-07-27 left-pane redesign, Task 6**: the standalone right-hand dock
// this component used to own is gone — it now lives embedded in the
// sidebar's FILES section (`Sidebar.tsx`, below the session list), rendered
// with the new `embedded` prop (no resize handle, no dock header) and an
// optional `filter` substring typed into the sidebar's own filter input.
// Every data-fetching/mutation path below (lazy `listDir`, the watcher,
// rename/move/trash) is unchanged and shared by both modes — only chrome and
// a client-side name filter differ.
//
// Lazy, expand-on-toggle: `listDir` (src-tauri/src/commands.rs, thin wrapper
// over brain_ingest::walk::list_dir) is called once per directory the user
// actually opens, never eagerly for the whole project up front — DESIGN.md
// 5's "huge monorepo -> bounded, incremental" concern applies to a file
// tree exactly as much as it does to ingestion. Loaded children are cached
// per path in `children` so re-collapsing/re-expanding a folder never
// re-fetches it (an external change made *while collapsed* isn't reflected
// until something else refreshes that directory — watch/unwatch below only
// covers currently-*expanded* directories, matching the brief's own "watch
// when expanded, unwatch when collapsed").
//
// Click = select, double-click = open/toggle (Finder's own distinction —
// see `state/fileTreeState.ts`'s `resolveRowDoubleClick`/`resolveSelectionClick`
// doc comments for the click-vs-double-click reasoning, including why
// inline RENAME is menu-triggered rather than double-click-triggered despite
// `PaneHeader.tsx`'s own rename using double-click — that trigger is already
// taken here by "open").
//
// Actions mirror `map/DetailPanel.tsx`'s exact pattern: `openPath`/
// `revealItemInDir` from `@tauri-apps/plugin-opener` called directly, no new
// Tauri command wrapping them — the plugin is already registered
// (`tauri_plugin_opener::init()` in `src-tauri/src/lib.rs`) and granted
// (`opener:default` in `capabilities/default.json`), so wrapping them again
// would just be reinventing what's already there. See that file's own
// module doc for the fuller reasoning. Mutations (`rename_path`/`move_path`/
// `duplicate_path`/`delete_to_trash`/`create_file`/`create_dir`) are Part
// A's frozen backend contract, thin-wrapped in `lib/tauri.ts` — every error
// they reject with is already user-facing and shown directly via
// `actionMessage` below, never re-wrapped.
//
// Drag-and-drop-to-move is deliberately NOT the HTML5 Drag and Drop API —
// see `fileTreeState.ts`'s "drag & drop" section for why (it's mutually
// exclusive, in a Tauri webview on macOS, with the native OS file-drop
// `Terminal.tsx` relies on for its own "drag a real file from Finder onto a
// terminal" feature). Internal tree-to-tree dragging here is plain
// `mousedown`/`mousemove`/`mouseup` tracking, which is a completely
// different event mechanism and never touches Tauri's drag-drop system —
// the two features can't conflict.
//
// Optional productivity affordance (Part A's founder feedback round): the
// drag-and-drop-a-file-onto-a-terminal feature (`Terminal.tsx`) already
// pastes a quoted path into the active session via `sessionWrite` — a small
// per-file "insert" control does the same when a terminal tab is currently
// active, using the identical quoting convention (`"path" `, trailing
// space) so it behaves exactly like a real drop. Deliberately a separate
// control from the row's main double-click (which always opens the file)
// rather than overloading what a click means.
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { openPath, revealItemInDir } from "@tauri-apps/plugin-opener";
import {
  createDir,
  createFile,
  deleteToTrash,
  duplicatePath,
  FILE_TREE_WIDTH_SETTING_KEY,
  listDir,
  movePath,
  renamePath,
  sessionWrite,
  settingsGet,
  settingsSet,
  watchDir,
  unwatchDir,
  type DirEntry,
} from "../lib/tauri";
import {
  accentForEntry,
  clampFileTreeWidth,
  excludeSelectedDescendants,
  FILE_TREE_DEFAULT_WIDTH,
  flattenVisibleEntries,
  hasCrossedDragThreshold,
  iconKindForEntry,
  isExpanded,
  isValidDropTarget,
  migratePathKeys,
  nextDefaultCreateName,
  parentDirOf,
  prunePathKeys,
  resolveCreateTargetDir,
  resolveDragPayload,
  resolveRowDoubleClick,
  resolveSelectionClick,
  toggleExpanded,
  widthFromDrag,
  type ExpandedPaths,
} from "../state/fileTreeState";
import type { ProjectInfo } from "../state/sessions";
import FileIcon from "./FileIcon";
import FileTreeContextMenu, { type FileTreeContextMenuTarget } from "./FileTreeContextMenu";

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
  /** Task 6 (left-pane redesign): `true` when rendered as the sidebar's
   * FILES section (`Sidebar.tsx`) rather than the old standalone right-hand
   * dock. Suppresses the resize handle and the dock header (title, New
   * File/New Folder, Reveal, Close) — the sidebar supplies its own header
   * (label + Task 7's future "N changed" chip) and the tree fills whatever
   * width the sidebar itself has, no independent resize. Everything else
   * (lazy loading, the watcher, selection, context menu, rename, drag-move)
   * is identical in both modes — this prop only toggles chrome. */
  embedded?: boolean;
  /** Task 6: case-insensitive substring filter typed into the sidebar's
   * `.sidebar-files-filter` input, applied here to whatever rows are
   * currently loaded/rendered — see the `// ponytail` note at the filter's
   * one call site for why this deliberately isn't a recursive search. */
  filter?: string;
}

const INDENT_PX = 14;
const BASE_PADDING_PX = 10;

/** Where the pointer currently is during an active internal drag —
 * `{kind:"row", ...}` over a specific row (file or folder), `{kind:"root"}`
 * over empty tree space (the drop target is then the project root), or
 * `null` when not currently over anything recognized (e.g. the header). */
type DragHover = { kind: "row"; path: string; is_dir: boolean } | { kind: "root" } | null;

/** Resolves what's under the pointer via `elementFromPoint` + walking up to
 * the nearest tagged ancestor. Not itself unit-tested (it's a thin DOM
 * lookup, not decision logic) — the decision of whether that target is a
 * *valid* drop target is `fileTreeState.ts`'s pure, tested
 * `isValidDropTarget`. Guards `elementFromPoint`'s absence (not implemented
 * in jsdom) so this degrades to "nothing hovered" in tests rather than
 * throwing. */
function resolveHoverAt(x: number, y: number): DragHover {
  const el = document.elementFromPoint?.(x, y) ?? null;
  if (!el || !(el instanceof Element)) return null;
  const rowEl = el.closest<HTMLElement>("[data-file-tree-path]");
  if (rowEl) {
    return { kind: "row", path: rowEl.dataset.fileTreePath!, is_dir: rowEl.dataset.fileTreeIsDir === "true" };
  }
  if (el.closest(".file-tree-body")) return { kind: "root" };
  return null;
}

export default function FileTree({ project, activeTabId, onClose, embedded, filter }: FileTreeProps) {
  const [root, setRoot] = useState<DirState | null>(null); // null = nothing requested yet
  const [expanded, setExpanded] = useState<ExpandedPaths>(new Set());
  const [children, setChildren] = useState<Map<string, DirState>>(new Map());
  const [actionMessage, setActionMessage] = useState<string | null>(null);

  // ---- multi-select (Task 3) --------------------------------------------
  const [selected, setSelected] = useState<ReadonlySet<string>>(new Set());
  const [anchor, setAnchor] = useState<string | null>(null);

  // ---- inline rename (Task 5) --------------------------------------------
  const [renamingPath, setRenamingPath] = useState<string | null>(null);
  const [renameDraft, setRenameDraft] = useState("");

  // ---- right-click context menu (Task 4) ---------------------------------
  const [contextMenu, setContextMenu] = useState<{ x: number; y: number; target: FileTreeContextMenuTarget | null } | null>(
    null,
  );

  // ---- drag-and-drop-to-move (Task 6) -------------------------------------
  const [draggedPaths, setDraggedPaths] = useState<string[] | null>(null);
  const [dragHover, setDragHover] = useState<DragHover>(null);
  const didDragRef = useRef(false);

  // ---- resizable panel (Task 9) -------------------------------------------
  const [width, setWidth] = useState(FILE_TREE_DEFAULT_WIDTH);

  // "Latest value" refs so long-lived callbacks (the dir-watch listeners
  // below, registered once per watched path and potentially outliving
  // several renders) never act on stale `project`/`children` — see
  // `refreshDir`'s own comment for why this matters.
  const projectPathRef = useRef<string | null>(null);
  projectPathRef.current = project?.path ?? null;
  const childrenRef = useRef(children);
  childrenRef.current = children;
  // Bug 6: `refreshDir` needs the CURRENT context menu (to invalidate it if
  // its target vanished) from inside the same long-lived `listen()`
  // callbacks `projectPathRef`/`childrenRef` already guard against staleness
  // for — same reasoning, same pattern.
  const contextMenuRef = useRef(contextMenu);
  contextMenuRef.current = contextMenu;

  const load = useCallback((path: string, onDone: (state: DirState) => void) => {
    onDone("loading");
    listDir(path)
      .then((entries) => onDone(entries))
      .catch((err) => onDone({ error: String(err) }));
  }, []);

  /** Bug 6: after a directory refresh lands, closes the currently-open
   * context menu if ITS target lived in that directory and is no longer
   * present in the freshly-fetched listing — the menu's actions
   * (Open/Rename/Duplicate/Move to Trash/...) all assume the target still
   * exists, and silently keeping it open invites acting on something an
   * external change already removed. A menu with no target (empty-space
   * right-click, offering only New File/New Folder) is never affected. */
  function invalidateContextMenuIfTargetMissing(dirPath: string, state: DirState) {
    // A transient "loading"/error state is not positive evidence the target
    // is gone (this fires on every `load()`, including its synchronous
    // "loading" kickoff) — only a real, settled listing can prove absence.
    if (!Array.isArray(state)) return;
    const target = contextMenuRef.current?.target;
    if (!target || parentDirOf(target.path) !== dirPath) return;
    const stillPresent = state.some((entry) => entry.path === target.path);
    if (!stillPresent) setContextMenu(null);
  }

  /** Re-fetches one directory's listing in place — the single refresh path
   * used after every mutation (rename/move/duplicate/delete) AND by the
   * `dir-changed:{path}` live-update listener. Only actually refetches the
   * project root or a directory whose children are already tracked
   * (currently expanded/visible) — refreshing an untracked, collapsed
   * directory would just populate a cache entry nothing reads yet. Reads
   * `project`/`children` through refs rather than closing over them
   * directly, so it stays correct no matter how long ago the caller
   * (especially a `listen()` callback) was created. */
  const refreshDir = useCallback(
    (dirPath: string) => {
      const projectPath = projectPathRef.current;
      if (!projectPath) return;
      if (dirPath === projectPath) {
        load(projectPath, (state) => {
          setRoot(state);
          invalidateContextMenuIfTargetMissing(dirPath, state);
        });
      } else if (childrenRef.current.has(dirPath)) {
        load(dirPath, (state) => {
          setChildren((prev) => new Map(prev).set(dirPath, state));
          invalidateContextMenuIfTargetMissing(dirPath, state);
        });
      }
    },
    [load],
  );

  // Reset everything and (re)fetch the root whenever the selected project
  // changes — stale expand/select/rename state or cached children from a
  // previous project must never leak into the next one.
  useEffect(() => {
    setExpanded(new Set());
    setChildren(new Map());
    setActionMessage(null);
    setSelected(new Set());
    setAnchor(null);
    setRenamingPath(null);
    setContextMenu(null);
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

  // ---- Task 9: load the persisted width once, apply on every mount ------
  useEffect(() => {
    let cancelled = false;
    settingsGet(FILE_TREE_WIDTH_SETTING_KEY)
      .then((raw) => {
        if (cancelled || raw === null) return;
        const parsed = Number(raw);
        if (Number.isFinite(parsed)) setWidth(clampFileTreeWidth(parsed));
      })
      .catch((err) => console.error("failed to read file_tree_width setting, using the default", err));
    return () => {
      cancelled = true;
    };
  }, []);

  // ---- Task 8: watch every currently-visible directory (project root +
  // every expanded folder), unwatch the rest, and refresh on change. Mirrors
  // `App.tsx`'s own `attentionListeners` pattern for `session-attention:{id}`
  // (a keyed map of per-id `listen()` subscriptions, diffed against the
  // live set on every render) — same shape, keyed by directory path instead
  // of session id, bracketed with `watchDir`/`unwatchDir` calls. -----------
  const dirWatchers = useRef<Map<string, UnlistenFn>>(new Map());
  useEffect(() => {
    const watchers = dirWatchers.current;
    const desired = new Set<string>();
    if (project?.path) desired.add(project.path);
    for (const p of expanded) desired.add(p);

    for (const [path, unlisten] of watchers) {
      if (!desired.has(path)) {
        unlisten();
        watchers.delete(path);
        void unwatchDir(path).catch((err) => console.error(`unwatch_dir(${path}) failed`, err));
      }
    }

    for (const path of desired) {
      if (watchers.has(path)) continue;
      let cancelled = false;
      watchers.set(path, () => {
        cancelled = true;
      });
      void watchDir(path).catch((err) => console.error(`watch_dir(${path}) failed`, err));
      void listen(`dir-changed:${path}`, () => refreshDir(path)).then((unlisten) => {
        if (cancelled) {
          unlisten();
          return;
        }
        watchers.set(path, unlisten);
      });
    }
  }, [project?.path, expanded, refreshDir]);

  // Unwatch everything on unmount/panel-close — never leak a watcher past
  // this component's lifetime.
  useEffect(() => {
    const watchers = dirWatchers.current;
    return () => {
      for (const [path, unlisten] of watchers) {
        unlisten();
        void unwatchDir(path).catch(() => {});
      }
      watchers.clear();
    };
  }, []);

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

  // ---- flattened visible order — powers shift-range-select AND by-path
  // entry lookups (context menu target kind, create-target resolution) from
  // one traversal (`fileTreeState.ts`'s `flattenVisibleEntries`). ---------
  const visibleEntries = useMemo(
    () => flattenVisibleEntries(Array.isArray(root) ? root : undefined, expanded, children),
    [root, expanded, children],
  );
  const visibleOrder = useMemo(() => visibleEntries.map((e) => e.path), [visibleEntries]);
  const entriesByPath = useMemo(() => new Map(visibleEntries.map((e) => [e.path, e])), [visibleEntries]);

  function existingNamesInDir(dirPath: string): ReadonlySet<string> {
    const listing = dirPath === project?.path ? root : children.get(dirPath);
    return new Set(Array.isArray(listing) ? listing.map((e) => e.name) : []);
  }

  // ---- Task 2/3: click = select (+ multi-select modifiers) ---------------
  function handleRowClick(e: React.MouseEvent, entry: DirEntry) {
    if (didDragRef.current) {
      // A real drag just ended on this row — suppress the trailing click
      // rather than also treating it as a select.
      didDragRef.current = false;
      return;
    }
    e.stopPropagation(); // don't also trigger the body's "clicked empty space -> clear selection"
    const result = resolveSelectionClick(selected, visibleOrder, entry.path, anchor, {
      shiftKey: e.shiftKey,
      metaKey: e.metaKey,
    });
    setSelected(result.selection);
    setAnchor(result.anchor);
  }

  function handleRowDoubleClick(entry: DirEntry) {
    const action = resolveRowDoubleClick(entry);
    if (action.type === "toggle") handleToggle(action.path);
    else void handleOpenFile(action.path);
  }

  // ---- Task 4: right-click context menu -----------------------------------
  function handleRowContextMenu(e: React.MouseEvent, entry: DirEntry) {
    e.preventDefault();
    e.stopPropagation();
    if (!selected.has(entry.path)) {
      setSelected(new Set([entry.path]));
      setAnchor(entry.path);
    }
    setContextMenu({ x: e.clientX, y: e.clientY, target: { path: entry.path, name: entry.name, is_dir: entry.is_dir } });
  }

  function handleEmptySpaceContextMenu(e: React.MouseEvent) {
    if (!project?.path) return;
    e.preventDefault();
    // Matches Finder: right-clicking empty pane background deselects
    // everything, so a subsequent New File/New Folder targets the project
    // root — not whatever happened to still be selected from an earlier
    // click (`resolveCreateTargetDir` falls back to the root exactly when
    // nothing is selected).
    setSelected(new Set());
    setAnchor(null);
    setContextMenu({ x: e.clientX, y: e.clientY, target: null });
  }

  async function handleMenuOpen() {
    const target = contextMenu?.target;
    if (!target) return;
    if (target.is_dir) {
      setExpanded((prev) => (isExpanded(prev, target.path) ? prev : toggleExpanded(prev, target.path)));
      if (!children.has(target.path)) {
        load(target.path, (state) => setChildren((prev) => new Map(prev).set(target.path, state)));
      }
    } else {
      await handleOpenFile(target.path);
    }
  }

  function handleMenuReveal() {
    if (contextMenu?.target) void handleReveal(contextMenu.target.path);
  }

  function handleMenuRename() {
    const target = contextMenu?.target;
    if (target) startRename(target.path, target.name);
  }

  async function handleMenuDuplicate() {
    const target = contextMenu?.target;
    if (!project?.path || !target) return;
    try {
      const newPath = await duplicatePath(project.path, target.path);
      refreshDir(parentDirOf(target.path));
      setSelected(new Set([newPath]));
      setAnchor(newPath);
    } catch (err) {
      setActionMessage(`Couldn't duplicate ${target.name}: ${err}`);
    }
  }

  async function handleMenuMoveToTrash() {
    const target = contextMenu?.target;
    if (!project?.path || !target) return;
    const targets = selected.size > 1 && selected.has(target.path) ? Array.from(selected) : [target.path];
    const parents = new Set(targets.map(parentDirOf));
    let lastError: string | null = null;
    // Bug 5: track which deletions actually succeeded (mirrors commitDrag's
    // own `movedPaths` pattern below) — a partial failure must only clear
    // the successfully-deleted paths from `selected`, leaving any that
    // failed still selected so the user can see what still needs attention.
    const deletedPaths: string[] = [];
    for (const p of targets) {
      try {
        await deleteToTrash(project.path, p);
        deletedPaths.push(p);
      } catch (err) {
        lastError = String(err);
      }
    }
    if (deletedPaths.length > 0) {
      // Bug 3: prune the deleted paths' (and their descendants') expanded/
      // children cache entries — otherwise a later create/rename landing on
      // the exact same path would inherit the deleted folder's stale cache.
      const pruned = prunePathKeys(deletedPaths, expanded, children);
      setExpanded(pruned.expanded);
      setChildren(pruned.children);
    }
    for (const dir of parents) refreshDir(dir);
    setSelected((prev) => {
      const next = new Set(prev);
      for (const p of deletedPaths) next.delete(p);
      return next;
    });
    if (lastError) setActionMessage(`Couldn't move to Trash: ${lastError}`);
  }

  async function handleMenuCopyPath() {
    const target = contextMenu?.target;
    if (!target) return;
    try {
      await navigator.clipboard.writeText(target.path);
    } catch (err) {
      setActionMessage(`Couldn't copy the path: ${err}`);
    }
  }

  // ---- Task 5: inline rename ------------------------------------------
  function startRename(path: string, currentName: string) {
    setRenamingPath(path);
    setRenameDraft(currentName);
  }

  async function commitRename() {
    const path = renamingPath;
    setRenamingPath(null);
    if (!path || !project?.path) return;
    const draft = renameDraft.trim();
    const currentName = entriesByPath.get(path)?.name;
    if (draft.length === 0 || draft === currentName) return; // Finder: no-op, keeps the old name
    try {
      const newPath = await renamePath(project.path, path, draft);
      // Bug 3: the `expanded`/`children` caches are keyed by absolute path —
      // migrate this item's (and any descendant's) entries to the new key
      // so a renamed, previously-expanded folder doesn't silently render
      // collapsed under a path nothing looks up anymore.
      const migrated = migratePathKeys(path, newPath, expanded, children);
      setExpanded(migrated.expanded);
      setChildren(migrated.children);
      refreshDir(parentDirOf(path));
      setSelected(new Set([newPath]));
      setAnchor(newPath);
    } catch (err) {
      setActionMessage(`Couldn't rename ${currentName ?? path}: ${err}`);
    }
  }

  function cancelRename() {
    setRenamingPath(null);
  }

  // ---- Task 7: New File / New Folder ------------------------------------
  async function handleCreate(kind: "file" | "folder") {
    if (!project?.path) return;
    const targetDir = resolveCreateTargetDir(selected, (p) => entriesByPath.get(p), project.path);
    const name = nextDefaultCreateName(kind, existingNamesInDir(targetDir));
    try {
      const newPath =
        kind === "folder" ? await createDir(project.path, targetDir, name) : await createFile(project.path, targetDir, name);
      if (targetDir !== project.path) {
        setExpanded((prev) => (isExpanded(prev, targetDir) ? prev : toggleExpanded(prev, targetDir)));
      }
      load(targetDir, (state) => {
        if (targetDir === project.path) setRoot(state);
        else setChildren((prev) => new Map(prev).set(targetDir, state));
      });
      setSelected(new Set([newPath]));
      setAnchor(newPath);
      setRenamingPath(newPath);
      setRenameDraft(name);
    } catch (err) {
      setActionMessage(`Couldn't create the new ${kind === "folder" ? "folder" : "file"}: ${err}`);
    }
  }

  // ---- Task 6: drag-and-drop-to-move (plain mouse events — see the module
  // doc for why not HTML5 DnD) --------------------------------------------
  async function commitDrag(paths: string[], hover: DragHover) {
    const projectPath = project?.path;
    if (!projectPath) return;
    const targetDir = hover?.kind === "root" ? projectPath : hover?.kind === "row" && hover.is_dir ? hover.path : null;
    if (targetDir === null || !isValidDropTarget(targetDir, paths)) return;

    // Bug 4: a shift-click range-select always orders parent before child in
    // visible tree order, so `paths` can legally contain both a folder AND
    // one of its own already-visible descendants. Moving the parent first
    // would invalidate the descendant's captured original path before its
    // own move_path call runs — filter down to top-level selected ancestors
    // only; their selected descendants come along automatically, nested
    // inside.
    const topLevelPaths = excludeSelectedDescendants(paths);
    const affectedDirs = new Set<string>([targetDir, ...topLevelPaths.map(parentDirOf)]);
    let lastError: string | null = null;
    const movedPaths: string[] = [];
    for (const p of topLevelPaths) {
      try {
        movedPaths.push(await movePath(projectPath, p, targetDir));
      } catch (err) {
        lastError = String(err);
      }
    }
    for (const dir of affectedDirs) refreshDir(dir);
    setSelected(new Set(movedPaths));
    setAnchor(movedPaths[movedPaths.length - 1] ?? null);
    if (lastError) setActionMessage(`Couldn't move: ${lastError}`);
  }

  // Pointer Capture, not raw `window` listeners (Bug 1/2 fix): a raw
  // `window.addEventListener("mousemove"/"mouseup", ...)` pair only ever got
  // torn down inside its own `onUp()` — if the button was released outside
  // the app window (entirely normal near a screen/window edge), the browser
  // never delivers that `mouseup` DOM event at all, so the listeners leaked
  // permanently and the NEXT unrelated mouseup anywhere in the app replayed
  // the stale drag using the originally-dragged paths + whatever hover
  // target that later, unrelated event happened to land on.
  //
  // `element.setPointerCapture(pointerId)` on `pointerdown`, with
  // `pointermove`/`pointerup`/`pointercancel` listeners on that SAME element
  // (never `window`), is the purpose-built fix: once captured, the element
  // keeps receiving that pointer's events even when the cursor leaves the
  // window bounds, and — critically — the capturing element is guaranteed to
  // receive either `pointerup` OR `pointercancel` (fired when the OS/browser
  // interrupts the gesture, e.g. dragging outside the window). There is no
  // third "silently vanished" case, so cleanup always runs exactly once.
  function beginPossibleDrag(e: React.PointerEvent<HTMLButtonElement>, entry: DirEntry) {
    if (e.button !== 0) return; // left button only
    const startX = e.clientX;
    const startY = e.clientY;
    const paths = resolveDragPayload(selected, entry.path);
    const el = e.currentTarget;
    const pointerId = e.pointerId;
    let active = false;
    let hover: DragHover = null;

    function cleanup() {
      el.removeEventListener("pointermove", onMove);
      el.removeEventListener("pointerup", onUp);
      el.removeEventListener("pointercancel", onCancel);
      try {
        el.releasePointerCapture?.(pointerId);
      } catch {
        // Already released (e.g. the pointer went away on its own) — fine.
      }
    }

    function onMove(ev: PointerEvent) {
      if (!active) {
        if (!hasCrossedDragThreshold(startX, startY, ev.clientX, ev.clientY)) return;
        active = true;
        didDragRef.current = true;
        setDraggedPaths(paths);
      }
      hover = resolveHoverAt(ev.clientX, ev.clientY);
      setDragHover(hover);
    }

    function onUp() {
      cleanup();
      if (active) void commitDrag(paths, hover);
      setDraggedPaths(null);
      setDragHover(null);
    }

    // A cancelled drag is an abort, not a commit — the gesture was
    // interrupted, not intentionally completed by the user.
    function onCancel() {
      cleanup();
      setDraggedPaths(null);
      setDragHover(null);
    }

    el.setPointerCapture?.(pointerId);
    el.addEventListener("pointermove", onMove);
    el.addEventListener("pointerup", onUp);
    el.addEventListener("pointercancel", onCancel);
  }

  const hoverTargetDir =
    dragHover?.kind === "root" ? (project?.path ?? null) : dragHover?.kind === "row" && dragHover.is_dir ? dragHover.path : null;
  const dropIsValid = draggedPaths !== null && hoverTargetDir !== null && isValidDropTarget(hoverTargetDir, draggedPaths);
  const isRootDropTarget = dropIsValid && dragHover?.kind === "root";

  // ---- Task 9: resizable panel -------------------------------------------
  // Same Pointer Capture fix as `beginPossibleDrag` above (Bug 1/2) — see
  // that function's comment for the full "why" (raw window listeners leak
  // when the button is released outside the window; Pointer Capture
  // guarantees pointerup/pointercancel on the SAME element instead).
  function beginResize(e: React.PointerEvent<HTMLDivElement>) {
    e.preventDefault();
    const startX = e.clientX;
    const startWidth = width;
    const el = e.currentTarget;
    const pointerId = e.pointerId;
    let latest = startWidth;

    function cleanup() {
      el.removeEventListener("pointermove", onMove);
      el.removeEventListener("pointerup", onUp);
      el.removeEventListener("pointercancel", onCancel);
      try {
        el.releasePointerCapture?.(pointerId);
      } catch {
        // Already released — fine.
      }
    }

    function onMove(ev: PointerEvent) {
      latest = widthFromDrag(startWidth, startX, ev.clientX);
      setWidth(latest);
    }
    function onUp() {
      cleanup();
      void settingsSet(FILE_TREE_WIDTH_SETTING_KEY, String(latest));
    }
    // A cancelled resize (e.g. released outside the window) must not
    // persist a width the user never intentionally committed to.
    function onCancel() {
      cleanup();
    }

    el.setPointerCapture?.(pointerId);
    el.addEventListener("pointermove", onMove);
    el.addEventListener("pointerup", onUp);
    el.addEventListener("pointercancel", onCancel);
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
    // Task 6: name-only filter over whatever's already loaded — dirs filter
    // by their own name exactly like files (no recursing into collapsed/
    // unfetched children to look for a match).
    // ponytail: name-only filter on loaded rows; deep search needs a walk command — add if asked
    const q = (filter ?? "").trim().toLowerCase();
    const visible = q.length === 0 ? entries : entries.filter((e) => e.name.toLowerCase().includes(q));
    return (
      <ul className="file-tree-list" role="group">
        {visible.map((entry) => {
          const open = entry.is_dir && isExpanded(expanded, entry.path);
          const isSelected = selected.has(entry.path);
          const isDragSource = draggedPaths?.includes(entry.path) ?? false;
          const isDropTarget = dropIsValid && !isRootDropTarget && hoverTargetDir === entry.path;
          const isRenaming = renamingPath === entry.path;
          const rowClassName = [
            "file-tree-row",
            isSelected && "is-selected",
            isDragSource && "is-drag-source",
            isDropTarget && "is-drop-target",
          ]
            .filter(Boolean)
            .join(" ");

          return (
            <li key={entry.path}>
              <div
                className={rowClassName}
                style={{ paddingLeft: BASE_PADDING_PX + depth * INDENT_PX }}
                data-file-tree-path={entry.path}
                data-file-tree-is-dir={entry.is_dir ? "true" : "false"}
                onContextMenu={(e) => handleRowContextMenu(e, entry)}
              >
                {entry.is_dir ? (
                  <span className={`file-tree-chevron${open ? " is-open" : ""}`} aria-hidden="true">
                    &#9656;
                  </span>
                ) : (
                  <span className="file-tree-chevron is-file" aria-hidden="true" />
                )}

                {isRenaming ? (
                  <input
                    className="file-tree-rename-input"
                    value={renameDraft}
                    autoFocus
                    draggable={false}
                    onMouseDown={(e) => e.stopPropagation()}
                    onChange={(e) => setRenameDraft(e.target.value)}
                    onBlur={() => void commitRename()}
                    onKeyDown={(e) => {
                      e.stopPropagation();
                      if (e.key === "Enter") {
                        e.preventDefault();
                        void commitRename();
                      } else if (e.key === "Escape") {
                        e.preventDefault();
                        cancelRename();
                      }
                    }}
                  />
                ) : (
                  <button
                    className="file-tree-row-main"
                    onPointerDown={(e) => beginPossibleDrag(e, entry)}
                    onClick={(e) => handleRowClick(e, entry)}
                    onDoubleClick={() => handleRowDoubleClick(entry)}
                    title={entry.path}
                  >
                    <FileIcon kind={iconKindForEntry(entry, open)} color={accentForEntry(entry)} />
                    <span className="file-tree-name">{entry.name}</span>
                  </button>
                )}

                {!entry.is_dir && activeTabId && !isRenaming && (
                  <button
                    className="file-tree-row-insert"
                    onMouseDown={(e) => e.stopPropagation()}
                    onClick={(e) => {
                      e.stopPropagation();
                      void handleInsert(entry.path);
                    }}
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
    <aside
      className={`file-tree${embedded ? " is-embedded" : ""}`}
      aria-label="Project files"
      style={embedded ? undefined : { width }}
    >
      {!embedded && (
        <div
          className="file-tree-resize-handle"
          onPointerDown={beginResize}
          role="separator"
          aria-orientation="vertical"
          aria-label="Resize file browser panel"
        />
      )}

      {!embedded && (
        <div className="file-tree-header">
          <span className="file-tree-title">FILES</span>
          <div className="file-tree-header-actions">
            {project?.path && (
              <>
                <button
                  className="file-tree-new"
                  onClick={() => void handleCreate("file")}
                  aria-label="New file"
                  title="New file"
                >
                  + file
                </button>
                <button
                  className="file-tree-new"
                  onClick={() => void handleCreate("folder")}
                  aria-label="New folder"
                  title="New folder"
                >
                  + folder
                </button>
                <button
                  className="file-tree-reveal"
                  onClick={() => void handleReveal(project.path as string)}
                  aria-label={`Reveal ${project.label} in Finder`}
                  title="Reveal in Finder"
                >
                  &#8689;
                </button>
              </>
            )}
            <button className="file-tree-close" onClick={onClose} aria-label="Hide file tree" title="Hide file tree">
              &times;
            </button>
          </div>
        </div>
      )}

      <div
        className={`file-tree-body${isRootDropTarget ? " is-drop-target" : ""}`}
        onClick={() => {
          setSelected(new Set());
          setAnchor(null);
        }}
        onContextMenu={handleEmptySpaceContextMenu}
      >
        {renderBody()}
      </div>

      {actionMessage && (
        <div className="file-tree-action-message">
          <span>{actionMessage}</span>
          <button onClick={() => setActionMessage(null)} aria-label="Dismiss">
            &times;
          </button>
        </div>
      )}

      {contextMenu && (
        <FileTreeContextMenu
          x={contextMenu.x}
          y={contextMenu.y}
          target={contextMenu.target}
          selectionCount={selected.size}
          onOpen={() => void handleMenuOpen()}
          onReveal={handleMenuReveal}
          onRename={handleMenuRename}
          onDuplicate={() => void handleMenuDuplicate()}
          onNewFile={() => void handleCreate("file")}
          onNewFolder={() => void handleCreate("folder")}
          onMoveToTrash={() => void handleMenuMoveToTrash()}
          onCopyPath={() => void handleMenuCopyPath()}
          onClose={() => setContextMenu(null)}
        />
      )}
    </aside>
  );
}
