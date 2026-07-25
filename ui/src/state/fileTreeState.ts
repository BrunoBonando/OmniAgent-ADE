// Pure expand/collapse + click-resolution logic for the file tree panel
// (founder feedback, 2026-07-25, verbatim: "nice to have a folder/file
// navigation on the right panel"). Deliberately framework- and
// Tauri-free — same rationale as `sessions.ts`'s own module doc: trivial to
// unit test in isolation, and keeps `FileTree.tsx` a thin binding of this
// logic to the real `listDir`/`openPath`/`revealItemInDir` calls.
import type { DirEntry } from "../lib/tauri";

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

/** What clicking a row should do: a directory toggles expand/collapse
 * (lazily loading its children the first time, in `FileTree.tsx`); a file
 * opens. Kept as data rather than calling `openPath`/`listDir` directly from
 * here, so this stays a pure function with zero Tauri dependency. */
export type RowClickAction = { type: "toggle"; path: string } | { type: "open"; path: string };

export function resolveRowClick(entry: Pick<DirEntry, "path" | "is_dir">): RowClickAction {
  return entry.is_dir ? { type: "toggle", path: entry.path } : { type: "open", path: entry.path };
}
