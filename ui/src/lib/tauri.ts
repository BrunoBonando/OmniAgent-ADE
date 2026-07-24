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
