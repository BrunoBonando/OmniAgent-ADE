// Pure expand/collapse + click-resolution logic for the file tree panel
// (founder feedback, 2026-07-25, verbatim: "nice to have a folder/file
// navigation on the right panel" — Part A backend, then Part B, verbatim:
// "make sure the file view works correctly, with it's own file
// visualization. It must work exactly like the Finder from Mac OS."
// Deliberately framework- and Tauri-free — same rationale as `sessions.ts`'s
// own module doc: trivial to unit test in isolation, and keeps `FileTree.tsx`
// a thin binding of this logic to the real `listDir`/`renamePath`/`movePath`/
// `openPath`/`revealItemInDir` calls and the DOM events that drive them
// (mousedown/mousemove for the custom drag — see the "drag & drop" section
// below for why this isn't the HTML5 Drag and Drop API).
import type { DirEntry } from "../lib/tauri";

// --------------------------------------------------------- expand/collapse

/** Which directory paths are currently expanded in the tree — keyed by
 * absolute path (unique across the whole tree, unlike `name`). */
export type ExpandedPaths = ReadonlySet<string>;

/** Returns a fresh set with `path` toggled — never mutates `expanded`. */
export function toggleExpanded(expanded: ExpandedPaths, path: string): ExpandedPaths {
  const next = new Set(expanded);
  if (next.has(path)) {
    next.delete(path);
  } else {
    next.add(path);
  }
  return next;
}

export function isExpanded(expanded: ExpandedPaths, path: string): boolean {
  return expanded.has(path);
}

// -------------------------------------------------------- double-click open
// Click = select (see "multi-select" below), double-click = open — matching
// Finder exactly (founder feedback, Part B, verbatim). This used to be
// `resolveRowClick`, wired to a single click; renamed to make the new
// trigger explicit now that a single click means something else entirely.

/** What double-clicking a row should do: a directory toggles expand/collapse
 * (there's no separate "window" to navigate into in a side-panel tree, so
 * "open" a folder means reveal its contents in place — lazily loaded the
 * first time, in `FileTree.tsx`); a file opens in its default app. Kept as
 * data rather than calling `openPath`/`listDir` directly from here, so this
 * stays a pure function with zero Tauri dependency. */
export type RowOpenAction = { type: "toggle"; path: string } | { type: "open"; path: string };

export function resolveRowDoubleClick(entry: Pick<DirEntry, "path" | "is_dir">): RowOpenAction {
  return entry.is_dir ? { type: "toggle", path: entry.path } : { type: "open", path: entry.path };
}

// ------------------------------------------------------- visible flattening
// Backs both shift-range multi-select (needs "the order rows are actually
// on screen right now") and a handful of by-path entry lookups (context
// menu target, drag payload, create-target resolution) — one traversal, one
// source of truth, rather than the tree walked separately for each need.
// Deliberately NOT recursing into a directory's children unless it's both
// expanded AND already loaded (`Array.isArray`) — a collapsed or
// still-loading subtree contributes nothing to "what's visible", exactly
// matching what's actually rendered.

/** Walks `root` + every expanded, loaded subtree in on-screen order.
 * `children` may hold loading/error states too (`FileTree.tsx`'s `DirState`
 * union) — anything that isn't a real `DirEntry[]` is treated as "no
 * children to show yet", never thrown on, so a still-loading directory
 * simply doesn't contribute rows below it. */
export function flattenVisibleEntries(
  root: readonly DirEntry[] | undefined,
  expanded: ExpandedPaths,
  children: ReadonlyMap<string, unknown>,
): DirEntry[] {
  const out: DirEntry[] = [];
  function walk(entries: readonly DirEntry[]) {
    for (const entry of entries) {
      out.push(entry);
      if (entry.is_dir && isExpanded(expanded, entry.path)) {
        const kids = children.get(entry.path);
        if (Array.isArray(kids)) walk(kids as DirEntry[]);
      }
    }
  }
  if (root) walk(root);
  return out;
}

// ------------------------------------------------------ path-keyed caches
// Bug 3: `expanded`/`children` are keyed by absolute path, but a successful
// rename/move/delete changes which path an item lives at (or removes it
// entirely) — only the parent directory's OWN listing gets refreshed by the
// caller, so nothing else ever rekeys/prunes these two caches on its own.
// Left alone: a renamed, previously-expanded folder renders collapsed (its
// `expanded` entry is still keyed by the old path) and, worse, if something
// new later occupies the exact path a deleted folder used to have, it
// inherits that deleted folder's stale `children` cache entry. Both helpers
// below are pure (`FileTree.tsx` supplies the actual `expanded`/`children`
// state and applies the result via `setExpanded`/`setChildren`) and treat a
// path's descendants (not just the path itself) the same way, since a
// renamed/moved/deleted directory's own expanded/cached subtree is exactly
// as stale as the directory itself.
//
// `${path}/` prefix matching (not a bare `startsWith(path)`) is deliberate —
// otherwise `/p/src` would wrongly swallow an unrelated sibling like
// `/p/src-old`.

function isPathOrDescendant(candidate: string, path: string): boolean {
  return candidate === path || candidate.startsWith(`${path}/`);
}

/** After a successful rename/move of `oldPath` -> `newPath`: rekeys
 * `oldPath`'s own `expanded`/`children` entries (and every descendant's) to
 * live under `newPath` instead, carrying whatever was cached forward rather
 * than dropping it — a moved-but-still-expanded folder stays expanded, at
 * its new path, showing the listing it already had (nothing is invalidated;
 * the parent directory's own refetch is a separate, existing concern). */
export function migratePathKeys<T>(
  oldPath: string,
  newPath: string,
  expanded: ExpandedPaths,
  children: ReadonlyMap<string, T>,
): { expanded: ExpandedPaths; children: Map<string, T> } {
  function rekey(path: string): string {
    if (path === oldPath) return newPath;
    if (path.startsWith(`${oldPath}/`)) return newPath + path.slice(oldPath.length);
    return path;
  }

  const nextExpanded = new Set<string>();
  for (const path of expanded) nextExpanded.add(rekey(path));

  const nextChildren = new Map<string, T>();
  for (const [path, value] of children) nextChildren.set(rekey(path), value);

  return { expanded: nextExpanded, children: nextChildren };
}

/** After a successful delete of `deletedPaths`: strips their own
 * `expanded`/`children` entries (and every descendant's) out entirely — a
 * deleted folder's cached listing must never resurface just because a later
 * create/rename happens to land something new at the exact same path. */
export function prunePathKeys<T>(
  deletedPaths: readonly string[],
  expanded: ExpandedPaths,
  children: ReadonlyMap<string, T>,
): { expanded: ExpandedPaths; children: Map<string, T> } {
  const isRemoved = (path: string) => deletedPaths.some((deleted) => isPathOrDescendant(path, deleted));

  const nextExpanded = new Set<string>();
  for (const path of expanded) if (!isRemoved(path)) nextExpanded.add(path);

  const nextChildren = new Map<string, T>();
  for (const [path, value] of children) if (!isRemoved(path)) nextChildren.set(path, value);

  return { expanded: nextExpanded, children: nextChildren };
}

// ------------------------------------------------------------ multi-select
// Cmd-click toggles one item in/out of the selection; Shift-click selects
// the contiguous range between the last plain/cmd click (the "anchor") and
// the clicked row, in current on-screen order; a plain click replaces the
// selection with just that row. This is a reasonable Finder-like
// approximation, deliberately not chasing Finder's full cross-level range
// semantics (brief: "don't over-engineer cross-level range selection edge
// cases") — `visibleOrder` (from `flattenVisibleEntries`) is the only
// concept of "range" this needs.

export interface SelectionModifiers {
  shiftKey: boolean;
  metaKey: boolean;
}

export interface SelectionResult {
  selection: ReadonlySet<string>;
  anchor: string | null;
}

export function resolveSelectionClick(
  current: ReadonlySet<string>,
  visibleOrder: readonly string[],
  clickedPath: string,
  anchor: string | null,
  modifiers: SelectionModifiers,
): SelectionResult {
  if (modifiers.metaKey) {
    const next = new Set(current);
    if (next.has(clickedPath)) {
      next.delete(clickedPath);
    } else {
      next.add(clickedPath);
    }
    return { selection: next, anchor: clickedPath };
  }

  if (modifiers.shiftKey && anchor !== null) {
    const from = visibleOrder.indexOf(anchor);
    const to = visibleOrder.indexOf(clickedPath);
    if (from === -1 || to === -1) {
      // Anchor or target has scrolled out of the currently-loaded tree
      // (e.g. its parent got collapsed) — fall back to a plain single-select
      // rather than silently selecting nothing or throwing.
      return { selection: new Set([clickedPath]), anchor: clickedPath };
    }
    const lo = Math.min(from, to);
    const hi = Math.max(from, to);
    return { selection: new Set(visibleOrder.slice(lo, hi + 1)), anchor };
  }

  return { selection: new Set([clickedPath]), anchor: clickedPath };
}

// ----------------------------------------------------------------- icons
// Curated by file extension, not fetched from the OS (VS Code's own file
// tree works exactly this way — disproportionate effort for a side panel
// otherwise). Grouped into the 4 shape families the brief itself names
// ("code files like .ts/.js/.py/.rs/.go, markup/docs like .md/.json/.yaml,
// images, a sensible generic-file fallback") rendered by `FileIcon.tsx`;
// `accentForEntry` layers a per-extension color on top of the shared shape
// so e.g. a `.ts` file and a `.py` file are still visually distinct at a
// glance, not just distinguishable by hovering for the tooltip — reuses this
// app's own established "a colored dot/accent encodes a sub-type" language
// (`ENGINE_COLOR` dots in `PaneHeader`/`theme.ts`, the stale/attention dots
// in `Sidebar`) rather than inventing a second visual vocabulary for it.

export type FileIconKind = "folder" | "folder-open" | "code" | "markup" | "image" | "generic";

const CODE_EXTENSIONS = new Set([
  "ts", "tsx", "js", "jsx", "mjs", "cjs",
  "py", "rs", "go",
  "java", "kt", "kts", "swift", "c", "h", "cc", "cpp", "hpp",
  "rb", "php", "cs", "sh", "bash", "zsh",
]);

const MARKUP_EXTENSIONS = new Set([
  "md", "mdx", "json", "yaml", "yml", "toml",
  "xml", "html", "htm", "css", "scss", "less",
  "txt", "csv", "ini", "conf", "lock",
]);

const IMAGE_EXTENSIONS = new Set(["png", "jpg", "jpeg", "gif", "svg", "webp", "bmp", "ico", "avif"]);

/** The extension used for icon/accent lookups — lowercased, no leading dot.
 * A dotfile with no further dot (`.gitignore`) has no extension by this
 * definition (matches `Path::extension`'s own "leading dot doesn't count"
 * behavior on the Rust side, `fileops.rs`'s `next_copy_name`). */
export function extensionOf(name: string): string {
  const idx = name.lastIndexOf(".");
  if (idx <= 0) return "";
  return name.slice(idx + 1).toLowerCase();
}

export function iconKindForEntry(entry: Pick<DirEntry, "name" | "is_dir">, expanded: boolean): FileIconKind {
  if (entry.is_dir) return expanded ? "folder-open" : "folder";
  const ext = extensionOf(entry.name);
  if (CODE_EXTENSIONS.has(ext)) return "code";
  if (MARKUP_EXTENSIONS.has(ext)) return "markup";
  if (IMAGE_EXTENSIONS.has(ext)) return "image";
  return "generic";
}

/** Per-extension accent color layered on top of the shape from
 * `iconKindForEntry` — real hex for curated "brand" colors that are
 * recognizable at a glance; a neutral fallback for everything else. */
const EXTENSION_ACCENT: Record<string, string> = {
  // TypeScript
  ts: "#4d8dff",
  tsx: "#4d8dff",
  // JavaScript
  js: "#e8c34d",
  jsx: "#e8c34d",
  mjs: "#e8c34d",
  cjs: "#e8c34d",
  // Python
  py: "#5fd4c8",
  // Rust
  rs: "#e0885f",
  // Go
  go: "#5fc9e8",
  // Web
  html: "#00bcd4",
  htm: "#00bcd4",
  css: "#5bc4e8",
  scss: "#e07cc0",
  less: "#5e9fd9",
  // Markup / data
  md: "#9a9ca6",
  mdx: "#9a9ca6",
  json: "#e8a23d",
  yaml: "#a996ff",
  yml: "#a996ff",
  toml: "#9c6cd9",
  xml: "#f0a050",
  // Images / graphics
  svg: "#e8c24d",
  png: "#e06070",
  jpg: "#e06070",
  jpeg: "#e06070",
  gif: "#e06070",
  webp: "#e06070",
  bmp: "#e06070",
  ico: "#e06070",
  avif: "#e06070",
  // Systems
  c: "#c0b040",
  h: "#c0b040",
  cc: "#659bd2",
  cpp: "#659bd2",
  hpp: "#659bd2",
  // JVM / CLR
  java: "#e8762d",
  kt: "#7f52ff",
  kts: "#7f52ff",
  cs: "#9b4f96",
  // Other languages
  rb: "#cc3a30",
  php: "#8892be",
  swift: "#f05138",
  sh: "#8bc34a",
  bash: "#8bc34a",
  zsh: "#8bc34a",
};

const DEFAULT_ACCENT = "#6a6a78";

export function accentForEntry(entry: Pick<DirEntry, "name" | "is_dir">): string {
  if (entry.is_dir) return "#3b82f6";
  return EXTENSION_ACCENT[extensionOf(entry.name)] ?? DEFAULT_ACCENT;
}

// ------------------------------------------------------------- drag & drop
// Deliberately NOT the HTML5 Drag and Drop API. Tauri's window-level native
// file-drop handling (`dragDropEnabled`, default on — what `Terminal.tsx`'s
// `onDragDropEvent` relies on for "drag a real file from Finder onto a
// terminal") and the browser's own HTML5 `dragstart`/`dragover`/`drop` DOM
// events are mutually exclusive in a Tauri webview on macOS: enabling one
// disables the other. Since Terminal.tsx's OS-file-drop feature must keep
// working unmodified (and `src-tauri/tauri.conf.json` is frozen — out of
// scope for this task), internal tree-to-tree dragging is implemented with
// plain `mousedown`/`mousemove`/`mouseup` tracking instead, which is just
// ordinary DOM events and never touches either drag system. The two
// features consequently can't conflict — different event mechanisms
// entirely, not just different drop targets.

/** Minimum pointer travel (px) before a mousedown-then-move becomes a real
 * drag rather than a click — small enough to feel immediate, large enough
 * that a normal click's few pixels of jitter never misfires into a drag. */
export const DRAG_START_THRESHOLD_PX = 4;

export function hasCrossedDragThreshold(
  startX: number,
  startY: number,
  currentX: number,
  currentY: number,
): boolean {
  return Math.hypot(currentX - startX, currentY - startY) >= DRAG_START_THRESHOLD_PX;
}

/** What actually gets dragged when the user starts a drag on `startedOnPath`:
 * the whole current multi-selection if that row is already part of a
 * multi-item selection (matches Finder — dragging any selected row drags
 * the group), otherwise just that one row (dragging an unselected row never
 * silently drags along an unrelated existing selection). */
export function resolveDragPayload(selected: ReadonlySet<string>, startedOnPath: string): string[] {
  if (selected.size > 1 && selected.has(startedOnPath)) return Array.from(selected);
  return [startedOnPath];
}

/** Parent directory of an absolute path — macOS-only app, POSIX separators
 * only, no need for a path library for this one string op. `path.lastIndexOf`
 * a slash rather than a regex split for a trivial perf/readability win on
 * something called on every row hover during a drag. */
export function parentDirOf(path: string): string {
  const idx = path.lastIndexOf("/");
  return idx <= 0 ? "/" : path.slice(0, idx);
}

/** Whether dropping `draggedPaths` onto `targetDirPath` is worth sending to
 * `move_path` at all — the client-side half of the "don't show a valid-drop
 * highlight (or fire a doomed request) for an operation that's guaranteed to
 * fail or do nothing" rule. Mirrors two of `move_path`'s own server-side
 * rejections (`fileops.rs`: onto itself, into its own descendant) so the
 * hover highlight never lies, plus one purely client-side convenience check
 * (dropping back onto the item's current parent is a no-op in Finder, not an
 * error — but `move_path` would surface it as a confusing "already exists"
 * collision, since the moved-to name is occupied by the item itself).
 * Every OTHER rejection (permissions, real collisions elsewhere, outside the
 * project root) is still `move_path`'s job to catch and report — this is
 * only ever a client-side pre-filter for UI feedback, never the source of
 * truth for safety. */
export function isValidDropTarget(targetDirPath: string, draggedPaths: readonly string[]): boolean {
  if (draggedPaths.length === 0) return false;
  for (const dragged of draggedPaths) {
    if (targetDirPath === dragged) return false;
    if (targetDirPath.startsWith(`${dragged}/`)) return false;
    if (targetDirPath === parentDirOf(dragged)) return false;
  }
  return true;
}

/** Bug 4: a shift-click range-select always orders parent before child in
 * the visible tree order, so a selection can legally contain both a folder
 * AND one of its own already-visible descendants. `commitDrag` issues one
 * `move_path` call per selected path sequentially — moving the parent first
 * invalidates the descendant's captured original path before its own call
 * runs, so that call fails even though the descendant DID move correctly
 * (nested inside its relocated parent). Filtering the selection down to just
 * its top-level ancestors before issuing any move calls avoids this
 * entirely: a selected descendant's move happens for free, as part of its
 * selected ancestor's own move, so it's never sent as a separate,
 * doomed-to-fail request. */
export function excludeSelectedDescendants(paths: readonly string[]): string[] {
  return paths.filter((path) => !paths.some((other) => other !== path && isPathOrDescendant(path, other)));
}

// --------------------------------------------------------- create (new)
// Finder's "New Folder" always succeeds immediately with a placeholder name
// ("untitled folder", auto-suffixed on collision) and drops straight into
// rename mode — but `create_file`/`create_dir` (`fileops.rs`) require a name
// up front and hard-error on collision (no server-side auto-naming, by
// design — see that module's "Collision policy"). `nextDefaultCreateName`
// is the client-side equivalent of Finder's own naming, tried against
// whatever this directory's listing is already loaded in the tree (best
// effort — if the target directory's children haven't been fetched yet, the
// caller passes an empty set, and a genuine collision simply surfaces
// through the normal create-error path instead of being pre-empted here).

export function nextDefaultCreateName(kind: "file" | "folder", existingNames: ReadonlySet<string>): string {
  const base = kind === "folder" ? "untitled folder" : "untitled file";
  if (!existingNames.has(base)) return base;
  let n = 2;
  while (existingNames.has(`${base} ${n}`)) n++;
  return `${base} ${n}`;
}

/** Where New File/New Folder should create: the single selected folder, if
 * exactly one folder (not a file, not zero, not several) is selected —
 * otherwise the project root. `entryLookup` is injected so this stays pure
 * (no direct dependency on `FileTree.tsx`'s state shape). */
export function resolveCreateTargetDir(
  selected: ReadonlySet<string>,
  entryLookup: (path: string) => Pick<DirEntry, "is_dir"> | undefined,
  projectRoot: string,
): string {
  if (selected.size === 1) {
    const [only] = selected;
    const entry = entryLookup(only);
    if (entry?.is_dir) return only;
  }
  return projectRoot;
}

// ------------------------------------------------------------- resize
// Persisted the same way `FILE_TREE_VISIBLE_SETTING_KEY` already is — see
// `lib/tauri.ts`'s `FILE_TREE_WIDTH_SETTING_KEY`. Bounds are generous but
// real: narrower than ~180px starts truncating filenames into uselessness,
// wider than ~560px starts eating the terminal grid's usable width for a
// panel that's meant to stay a side reference, not become half the window.

export const FILE_TREE_MIN_WIDTH = 180;
export const FILE_TREE_MAX_WIDTH = 560;
export const FILE_TREE_DEFAULT_WIDTH = 260; // matches the pre-resize fixed CSS width

export function clampFileTreeWidth(width: number): number {
  return Math.min(FILE_TREE_MAX_WIDTH, Math.max(FILE_TREE_MIN_WIDTH, width));
}

/** The panel is docked on the right edge of `app-body`, so its resize handle
 * lives on its LEFT edge — dragging the handle left (pointer X decreases)
 * widens the panel, dragging it right narrows it. Pure so the resize-drag
 * math is unit-testable without a real mousemove stream driving a real
 * layout. */
export function widthFromDrag(startWidth: number, startClientX: number, currentClientX: number): number {
  return clampFileTreeWidth(startWidth + (startClientX - currentClientX));
}
