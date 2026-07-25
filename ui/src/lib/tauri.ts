// Thin, typed wrappers around `invoke()` — the only place in the UI that
// knows the exact Tauri command names/argument shapes (PLAN.md's own rule:
// "UI never queries the DB directly — always through Tauri commands", and
// keeping the invoke() call sites in one file makes the frozen backend
// contract easy to audit).
import { invoke } from "@tauri-apps/api/core";
import type { Engine, ProjectInfo } from "../state/sessions";

export interface SessionInfo {
  id: string;
  project: string;
  engine: string;
  cwd: string;
  created: number;
}

export interface BrainSearchHit {
  id: string;
  kind: string;
  project: string;
  label: string;
  path?: string;
  summary?: string;
}

export async function listProjects(): Promise<ProjectInfo[]> {
  return invoke<ProjectInfo[]>("brain_query", { kind: "list_projects" });
}

export async function searchBrain(query: string, scope?: string): Promise<BrainSearchHit[]> {
  return invoke<BrainSearchHit[]>("brain_query", { kind: "search", query, scope: scope ?? null });
}

export async function getBriefing(project: string): Promise<string | undefined> {
  try {
    return await invoke<string>("brain_briefing", { project });
  } catch (err) {
    console.error(`brain_briefing(${project}) failed, opening claude without a briefing`, err);
    return undefined;
  }
}

export async function settingsGet(key: string): Promise<string | null> {
  return invoke<string | null>("settings_get", { key });
}

export async function settingsSet(key: string, value: string): Promise<void> {
  await invoke("settings_set", { key, value });
}

export async function sessionCreate(
  project: string,
  engine: Engine,
  cwd: string,
  briefing?: string,
): Promise<SessionInfo> {
  return invoke<SessionInfo>("session_create", { project, engine, cwd, briefing: briefing ?? null });
}

export async function sessionWrite(id: string, data: string): Promise<void> {
  await invoke("session_write", { id, data });
}

export async function sessionResize(id: string, cols: number, rows: number): Promise<void> {
  await invoke("session_resize", { id, cols, rows });
}

export async function sessionKill(id: string): Promise<void> {
  await invoke("session_kill", { id });
}

// ------------------------------------------------------------- file tree
// Founder feedback, 2026-07-25 (verbatim): "nice to have a folder/file
// navigation on the right panel." `list_dir` (src-tauri/src/commands.rs,
// thin wrapper over brain_ingest::walk::list_dir) lists exactly one
// directory level, gitignore-aware — `FileTree.tsx` calls it lazily, once
// per expand, never eagerly recursing a whole project tree.

export interface DirEntry {
  name: string;
  path: string;
  is_dir: boolean;
}

export async function listDir(path: string): Promise<DirEntry[]> {
  return invoke<DirEntry[]>("list_dir", { path });
}

/** Settings-table key for the file tree panel's collapsed/expanded state
 * (same "true"/"false" string convention `REVIEW_MEMORY_SETTING_KEY`
 * already uses) — persisted so a hidden/shown choice survives relaunch,
 * same pattern as `LAYOUT_SETTING_KEY`. */
export const FILE_TREE_VISIBLE_SETTING_KEY = "file_tree_visible";

/** Settings-table key for the file tree panel's resized width (px, stored as
 * a plain decimal string — same "one flat string per key" convention every
 * other settings-table entry here uses). Read/written through the generic
 * `settingsGet`/`settingsSet` above, exactly like `FILE_TREE_VISIBLE_SETTING_KEY` —
 * no dedicated command needed. */
export const FILE_TREE_WIDTH_SETTING_KEY = "file_tree_width";

// ------------------------------------------------- file tree write side
// Founder feedback, 2026-07-25 (Part B, verbatim): "make sure the file view
// works correctly, with it's own file visualization. It must work exactly
// like the Finder from Mac OS." Thin wrappers over Part A's frozen backend
// contract (`src-tauri/src/commands.rs`) — same one-invoke-call-per-function
// house style as every other wrapper in this file. Every error string these
// reject with is already user-facing (see `brain_ingest::fileops`'s module
// doc) — callers show it directly, never re-wrap it.

/** Renames a file/folder in place. `newName` must be a bare filename (no
 * path separator — that's a move, see `movePath`). Resolves to the new full
 * path. */
export async function renamePath(projectRoot: string, path: string, newName: string): Promise<string> {
  return invoke<string>("rename_path", { projectRoot, path, newName });
}

/** Moves a file/folder into a different directory (same basename, new
 * parent) — what drag-and-drop-to-reparent in the tree calls. Resolves to
 * the new full path. */
export async function movePath(projectRoot: string, path: string, newParentDir: string): Promise<string> {
  return invoke<string>("move_path", { projectRoot, path, newParentDir });
}

/** Copies a file, or recursively copies a directory, into the same parent
 * with the next free Finder-style " copy"/" copy N" name. Resolves to the
 * new full path. */
export async function duplicatePath(projectRoot: string, path: string): Promise<string> {
  return invoke<string>("duplicate_path", { projectRoot, path });
}

/** Moves the file/folder to the macOS system Trash — never a permanent
 * delete. */
export async function deleteToTrash(projectRoot: string, path: string): Promise<void> {
  await invoke("delete_to_trash", { projectRoot, path });
}

/** Creates a new empty file named `name` inside `parentDir`. Errors on a
 * name collision. Resolves to the new full path. */
export async function createFile(projectRoot: string, parentDir: string, name: string): Promise<string> {
  return invoke<string>("create_file", { projectRoot, parentDir, name });
}

/** Creates a new empty folder named `name` inside `parentDir`. Same
 * collision policy as `createFile`. Resolves to the new full path. */
export async function createDir(projectRoot: string, parentDir: string, name: string): Promise<string> {
  return invoke<string>("create_dir", { projectRoot, parentDir, name });
}

/** Starts watching `path` (one directory level, non-recursive) for external
 * changes — idempotent, a no-op if already watched. Emits
 * `dir-changed:{path}` (listen for it directly via `@tauri-apps/api/event`)
 * on any change within that directory. Call on expand; pair with
 * `unwatchDir` on collapse/unmount so watchers never leak (see
 * `brain_ingest::dirwatch`'s module doc for the full lifecycle design). */
export async function watchDir(path: string): Promise<void> {
  await invoke("watch_dir", { path });
}

/** Stops watching `path` — a no-op (not an error) if it wasn't being
 * watched. */
export async function unwatchDir(path: string): Promise<void> {
  await invoke("unwatch_dir", { path });
}

/** The pane header's git-branch pill (Task: BridgeSpace pane-grid rebuild).
 * `null` when `path` isn't inside a git repo, or `git` itself isn't
 * available — never throws, so one pane's missing branch never breaks the
 * grid (see `src-tauri/src/commands.rs::git_branch`'s own doc comment). */
export async function gitBranch(path: string): Promise<string | null> {
  return invoke<string | null>("git_branch", { path });
}

// ---------------------------------------------------------------- brain map
// Task 6.1's frozen `map_graph` wire contract, verbatim (see
// `src-tauri/src/map_feed.rs`'s module doc): `kind` is lowercase
// snake_case, `size` is a member count for collapsed `"community"` hubs and
// `1` for everything else.
export interface MapNode {
  id: string;
  kind: string;
  label: string;
  project: string;
  size: number;
}

export interface MapLink {
  src: string;
  dst: string;
  kind: string;
  weight: number;
}

export interface MapGraph {
  nodes: MapNode[];
  links: MapLink[];
}

/** `project: null` = whole-brain view (every ingested project) — the brain
 * map's default; `expanded` lists community node ids to show expanded;
 * `filter` is an ALLOW-list of `NodeKind` wire-strings (empty = everything). */
export async function mapGraph(
  project: string | null,
  expanded: string[],
  filter: string[],
): Promise<MapGraph> {
  return invoke<MapGraph>("map_graph", { project, expanded, filter });
}

export interface MapNodeBacklink {
  edge_kind: string;
  id: string;
  kind: string;
  label: string;
  project: string;
}

export interface MapNodeDetail {
  id: string;
  kind: string;
  label: string;
  project: string;
  path?: string;
  summary?: string;
  backlinks: MapNodeBacklink[];
}

/** `null` when the id doesn't exist (e.g. a stale click after re-ingest) —
 * not an error, so the detail panel can render "not found" cleanly. */
export async function mapNodeDetail(id: string): Promise<MapNodeDetail | null> {
  return invoke<MapNodeDetail | null>("map_node_detail", { id });
}

// --------------------------------------------------------------- Task 7.1
// Review-mode: the `review_memory` setting itself is read/written through
// the generic `settingsGet`/`settingsSet` above (same as any other
// settings-table entry) — only the pending-notes list/approve/discard need
// their own commands, backed by `src-tauri/src/feedback.rs`.

export interface PendingNote {
  node_id: string;
  project: string;
  title: string;
  path?: string;
  created: number;
}

/** `project: null` lists pending notes across every project. */
export async function pendingNotesList(project: string | null): Promise<PendingNote[]> {
  return invoke<PendingNote[]>("pending_notes_list", { project });
}

export async function pendingNotesApprove(nodeId: string): Promise<void> {
  await invoke("pending_notes_approve", { nodeId });
}

export async function pendingNotesDiscard(nodeId: string): Promise<void> {
  await invoke("pending_notes_discard", { nodeId });
}

export const REVIEW_MEMORY_SETTING_KEY = "review_memory";

// --------------------------------------------------------------- Task 8.1
// Onboarding (FirstRun) + degradation surfaces (Sidebar's stale/pause menu,
// the map pane's enrichment-backlog badge, AboutPanel's "Rebuild brain").
// `src-tauri/src/roots.rs` is the single Rust module behind every command
// here.

export interface IngestionStatus {
  running: boolean;
  projects_total: number;
  projects_done: number;
  current_project?: string;
  total_nodes: number;
  error?: string;
}

/** Persists `path` as a known project root and starts ingesting every
 * project discovered under it, in the background (poll `ingestionStatus`). */
export async function rootsStartIngest(path: string): Promise<void> {
  await invoke("roots_start_ingest", { path });
}

export async function ingestionStatus(): Promise<IngestionStatus> {
  return invoke<IngestionStatus>("ingestion_status");
}

/** Every project root the user has ever picked. Empty = true first run. */
export async function rootsList(): Promise<string[]> {
  return invoke<string[]>("roots_list");
}

/** The project with the most nodes — the first-tab-to-offer target once
 * onboarding ingestion completes. `null` if the brain is still empty. */
export async function rootsBiggestProject(): Promise<ProjectInfo | null> {
  return invoke<ProjectInfo | null>("roots_biggest_project");
}

export async function rootsPausedProjects(): Promise<string[]> {
  return invoke<string[]>("roots_paused_projects");
}

export async function rootsSetPaused(project: string, paused: boolean): Promise<void> {
  await invoke("roots_set_paused", { project, paused });
}

export interface ProjectStaleness {
  project: string;
  last_ingested?: number;
  stale: boolean;
}

export async function rootsStaleness(): Promise<ProjectStaleness[]> {
  return invoke<ProjectStaleness[]>("roots_staleness");
}

/** Manual "re-check" action for one project (sidebar context menu). */
export async function rootsReingestProject(project: string): Promise<void> {
  await invoke("roots_reingest_project", { project });
}

/** The sidebar's persistent "+": adds exactly one project at `path`
 * (`name` optional, defaults server-side to the folder basename). Creates
 * the project node immediately — returns as soon as it's queryable via
 * `listProjects`, never waits for ingestion, which continues in the
 * background (poll `ingestionStatus`, same channel as onboarding/rebuild). */
export async function addProject(path: string, name?: string): Promise<ProjectInfo> {
  return invoke<ProjectInfo>("add_project", { path, name: name ?? null });
}

/** "Rebuild brain": deletes brain.db and re-ingests every known root from
 * scratch (Markdown memory is untouched). Returns immediately; watch
 * `ingestionStatus` for progress, same as onboarding. */
export async function rootsRebuild(): Promise<void> {
  await invoke("roots_rebuild");
}

/** The map pane's "enrichment queued (N)" degradation badge. */
export async function enrichQueuePendingCount(): Promise<number> {
  return invoke<number>("enrich_queue_pending_count");
}
