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
