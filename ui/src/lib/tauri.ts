// Thin, typed wrappers around `invoke()` — the only place in the UI that
// knows the exact Tauri command names/argument shapes (PLAN.md's own rule:
// "UI never queries the DB directly — always through Tauri commands", and
// keeping the invoke() call sites in one file makes the frozen backend
// contract easy to audit).
import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import type { Engine, ProjectInfo } from "../state/sessions";
import type { SessionStatusEvent } from "../state/sessionStatus";

type SessionWriteObserver = (id: string, data: string) => void;
const sessionWriteObservers = new Set<SessionWriteObserver>();

export interface SessionInfo {
  id: string;
  project: string;
  engine: string;
  cwd: string;
  created: number;
  /** `true` when this call attached to an engine that outlived the app
   * closing (a surviving tmux session) instead of starting a new one.
   *
   * Optional in the type on purpose: it is additive on the Rust side
   * (`sessions::SessionInfo`, 2026-07-26) and — more importantly — a
   * `restoreId` whose tmux session is gone comes back `false` with a
   * perfectly good fresh session. Nothing may branch on this being `true`;
   * it is display-only. */
  restored?: boolean;
  /** `true` when the session is tmux-backed and will therefore survive the
   * app closing. `false` = tmux wasn't available and this is a plain direct
   * spawn (see `sessions.rs`'s degradation ladder). */
  persistent?: boolean;
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

/** System-level desktop notification (Notification Center on macOS). */
export async function sendNativeNotification(title: string, body: string): Promise<void> {
  if (typeof window === "undefined" || !("Notification" in window)) return;
  if (Notification.permission === "default") {
    const permission = await Notification.requestPermission();
    if (permission !== "granted") return;
  } else if (Notification.permission !== "granted") {
    return;
  }
  new Notification(title, { body });
}

/** Spawns a session — or, with `restoreId`, *reattaches* to one.
 *
 * `restoreId` is the id a previous run of the app got back for this same
 * pane (persisted in `PersistedTab.id`). When the engine's tmux session
 * survived the app closing, the backend attaches to the still-running
 * `claude`/`codex`/shell instead of spawning a new one and the response
 * comes back with `restored: true`. When it didn't survive — first launch,
 * a reboot, tmux unavailable — the backend starts fresh under the same id
 * and returns `restored: false`; that is a normal outcome, not an error, so
 * no caller may assume a restore happened.
 *
 * Omitting it is byte-for-byte the old behaviour, which is what every path
 * except `App.tsx`'s boot restore does. */
export async function sessionCreate(
  project: string,
  engine: Engine,
  cwd: string,
  briefing?: string,
  restoreId?: string,
): Promise<SessionInfo> {
  return invoke<SessionInfo>("session_create", {
    project,
    engine,
    cwd,
    briefing: briefing ?? null,
    restoreId: restoreId ?? null,
  });
}

/** The five-state light for one session, pulled on demand — `null` when
 * there's no such live session.
 *
 * The push counterpart (`session-status:{id}`) only fires on a genuine
 * transition, so a pane that just mounted would otherwise show the neutral
 * "Starting" mark until the session's *next* change. `App.tsx` calls this
 * once per new session id and then lets the event stream drive it.
 * Same payload shape either way, `notify` included. */
export async function sessionStatus(id: string): Promise<SessionStatusEvent | null> {
  return invoke<SessionStatusEvent | null>("session_status", { id });
}

export async function sessionWrite(id: string, data: string): Promise<void> {
  for (const observer of sessionWriteObservers) {
    try {
      observer(id, data);
    } catch (err) {
      console.error("sessionWrite observer failed", err);
    }
  }
  await invoke("session_write", { id, data });
}

export function onSessionWrite(observer: SessionWriteObserver): () => void {
  sessionWriteObservers.add(observer);
  return () => {
    sessionWriteObservers.delete(observer);
  };
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

/** Reads one file's UTF-8 text content, scoped to `projectRoot`. */
export async function readTextFile(projectRoot: string, path: string): Promise<string> {
  return invoke<string>("read_text_file", { projectRoot, path });
}

/** Writes one file's UTF-8 text content, scoped to `projectRoot`. */
export async function writeTextFile(projectRoot: string, path: string, content: string): Promise<void> {
  await invoke("write_text_file", { projectRoot, path, content });
}

/** Settings-table key for the file tree panel's collapsed/expanded state
 * (same "true"/"false" string convention `REVIEW_MEMORY_SETTING_KEY`
 * already uses) — persisted so a hidden/shown choice survives relaunch,
 * same pattern as `LAYOUT_SETTING_KEY`.
 *
 * Unused since the left-pane redesign's Task 6 (2026-07-27): the file tree
 * is now permanently embedded in the sidebar's FILES section instead of a
 * collapsible dock, so there's no visibility to persist any more. Left in
 * place rather than deleted — dead but harmless, and removing it buys
 * nothing (no in-flight settings-table migration reads it either). */
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

/** What `folder_stats` reports about a folder — the New Workspace dialog's
 * "FOUND IN THIS FOLDER" strip (left-pane redesign, Task 12).
 *
 * `files` is the count the *ingestion* walker would walk (gitignore-aware,
 * vendor dirs and oversized files excluded), not a raw `find | wc -l`, so
 * the number the dialog promises is the work that will actually happen.
 * `languages` is the top 2 by file count, ties broken alphabetically.
 * `branches` is only meaningful when `git` is true. */
export interface FolderStats {
  files: number;
  languages: string[];
  git: boolean;
  branches: number;
}

export async function folderStats(path: string): Promise<FolderStats> {
  return invoke<FolderStats>("folder_stats", { path });
}

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

/** Renames a project's *display* label only (`id`/`project` — what every
 * session/setting/cwd lookup actually uses — never changes). The general
 * fix for a project's label defaulting to its folder basename forever
 * (`src-tauri/src/roots.rs::rename_project`'s own doc has the full story) —
 * `listProjects()` reflects the new label immediately afterward, so every
 * pane header for sessions in that project does too. Rejects (surfaced
 * inline by the caller) for an empty/whitespace-only name or an unknown
 * project id. */
export async function renameProject(id: string, newLabel: string): Promise<void> {
  await invoke("rename_project", { id, newLabel });
}

/** The map pane's "enrichment queued (N)" degradation badge. */
export async function enrichQueuePendingCount(): Promise<number> {
  return invoke<number>("enrich_queue_pending_count");
}

export interface SystemStats {
  cpuPercent: number | null;
  ramUsedBytes: number | null;
  ramTotalBytes: number | null;
  mcpWired: boolean;
}

export async function systemStats(): Promise<SystemStats> {
  return invoke<SystemStats>("system_stats");
}

// --------------------------------------------------------------- Task: import
// "Import projects from other tools" (Part A backend, `src-tauri/src/
// commands.rs`'s own doc comment, verbatim founder ask: "detect other dev
// tools already installed on the user's machine and offer to import their
// known project lists"). Read-only wrappers over a frozen, independently
// unit-tested (314 Rust tests) backend contract — same thin-wrapper house
// style as every other function in this file. Turning a selected
// `ImportCandidate` into a real project is `addProject` above; this file
// never combines the two, same read/write split the Rust side keeps.

export interface DetectedTool {
  id: string;
  name: string;
  detected: boolean;
  candidate_count: number;
}

export interface ImportCandidate {
  path: string;
  suggested_name: string;
}

/** Every dev tool this build knows how to detect, always `Ok` — a tool
 * that isn't installed simply reports `detected: false`, never an error. */
export async function detectImportableTools(): Promise<DetectedTool[]> {
  return invoke<DetectedTool[]>("detect_importable_tools");
}

/** `tool` must be one of the ids `detectImportableTools()` returned
 * (`"claude-code" | "vscode" | "cursor"`) — rejects only for an unrecognized
 * id; a known tool with nothing installed resolves to `[]`. */
export async function listImportCandidates(tool: string): Promise<ImportCandidate[]> {
  return invoke<ImportCandidate[]>("list_import_candidates", { tool });
}

// ------------------------------------------------- per-session code review
// Founder ask, 2026-07-26 (verbatim): "For each session, have a top right
// menu with three things: Code Review Panel info (number of changes within
// files that are uncommited) and if clicked, it should show a code review
// panel for that session ... as a new column, dedicated on the right", plus
// "Make sure that the code panel is for session, okay?".
//
// Every call takes `repoPath` — the cwd of the pane the panel was opened
// from — and the backend holds no state between calls, which is exactly what
// makes the panel per-session rather than app-global. Thin wrappers over
// `brain_ingest::gitreview` (via `src-tauri/src/commands.rs`), same
// one-invoke-per-function house style as everything above; every error these
// reject with is already user-facing and is shown directly, never re-wrapped.

/** How git classifies one changed file. `untracked` is deliberately distinct
 * from `added` (staged-new): both lack a committed version, but only one has
 * been `git add`ed, and reverting them differs. */
export type ChangeStatus = "modified" | "added" | "deleted" | "renamed" | "untracked";

export interface ChangedFile {
  /** Repo-relative, POSIX separators — the id every other call takes back. */
  path: string;
  status: ChangeStatus;
  /** Only set when `status === "renamed"`. */
  old_path: string | null;
  /** `null` for a binary file — deliberately absent rather than `0`, so the
   * badge can say "binary" instead of a truthful-looking `+0 · -0`. */
  added: number | null;
  removed: number | null;
  binary: boolean;
}

export interface ReviewStatus {
  repo_root: string;
  /** `null` on a detached HEAD or a repo with no commits yet. */
  branch: string | null;
  detached: boolean;
  has_head: boolean;
  files: ChangedFile[];
  /** The true total even when `files` was capped — the header never lies
   * about how many changes there are. */
  file_count: number;
  added: number;
  removed: number;
  /** How many of `file_count` are binary and therefore absent from the
   * aggregate above. */
  binary_count: number;
  truncated: boolean;
}

export type DiffLineKind = "context" | "added" | "removed";

export interface DiffLine {
  kind: DiffLineKind;
  /** `null` on an added line; `new_line` is `null` on a removed one. */
  old_line: number | null;
  new_line: number | null;
  /** Already stripped of the leading `+`/`-`/space. */
  text: string;
}

export interface DiffHunk {
  header: string;
  lines: DiffLine[];
}

export interface FileDiff {
  path: string;
  binary: boolean;
  hunks: DiffHunk[];
  truncated: boolean;
  line_count: number;
}

export interface CommitResult {
  sha: string;
  short_sha: string;
  files_committed: number;
}

export type RevertOutcome = "restored_from_head" | "moved_to_trash";

/** Everything uncommitted in the repo `repoPath` sits inside. Backs both the
 * pane menu's badge count and the panel header. Rejects for a path that
 * isn't a git repo or no longer exists — callers show that message as-is. */
export async function reviewStatus(repoPath: string): Promise<ReviewStatus> {
  return invoke<ReviewStatus>("review_status", { repoPath });
}

/** One file's diff, already parsed into hunks with both line-number gutters
 * resolved in Rust — the panel renders line numbers without re-deriving
 * them. A binary file comes back `binary: true` with no hunks. */
export async function reviewFileDiff(repoPath: string, path: string): Promise<FileDiff> {
  return invoke<FileDiff>("review_file_diff", { repoPath, path });
}

/** Stages and commits *every* uncommitted change in the repo — the exact set
 * the panel is listing, matching the reference's single Commit button. Never
 * amends, forces, skips hooks, or pushes. */
export async function reviewCommit(repoPath: string, message: string): Promise<CommitResult> {
  return invoke<CommitResult>("review_commit", { repoPath, message });
}

/** Throws away one file's uncommitted changes. **Destructive** — only ever
 * called from the panel's explicit two-step in-row confirmation, never from
 * a bare click. A file with no committed version goes to the macOS Trash
 * (recoverable); anything else is restored from HEAD. */
export async function reviewRevertFile(repoPath: string, path: string): Promise<RevertOutcome> {
  return invoke<RevertOutcome>("review_revert_file", { repoPath, path });
}

/** Settings-table key for the review panel's resized width (px, plain
 * decimal string) — same convention as `FILE_TREE_WIDTH_SETTING_KEY`, and
 * deliberately a *separate* key: the two right-hand panels want different
 * widths (a file tree is a narrow list, a diff needs room to breathe). */
export const CODE_REVIEW_WIDTH_SETTING_KEY = "code_review_width";

// ----------------------------------------------------- agent installation
// Agent manager: check installed agents, install agents, and listen for
// install progress events. Thin wrappers over `src-tauri/src/commands.rs`,
// same one-invoke-per-function house style.

/**
 * Check which agents are installed
 */
export async function agentCheckInstalled(): Promise<string[]> {
  return await invoke("agents_check_installed");
}

/**
 * Install an agent
 */
export async function agentInstall(agent: string): Promise<void> {
  return await invoke("agents_install", { agent });
}

/**
 * Listen for agent install progress events
 * Returns unlistener function (awaitable)
 */
export async function onAgentInstallProgress(
  agent: string,
  callback: (status: string) => void
): Promise<() => void> {
  const eventName = `agent-install-progress:${agent}`;
  const unlisten = await listen(eventName, (event: { payload: unknown }) => {
    callback(event.payload as string);
  });
  return unlisten;
}
