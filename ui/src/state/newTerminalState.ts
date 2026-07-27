// ⌘T modal state (design §3 "New terminal modal"): tiny enough that a
// reducer would be ceremony — two fields plus the keyboard map.
import type { Engine } from "./sessions";
import type { AgentsState } from "./agents";

export interface NewTerminalState { name: string; engine: Engine; }

export function defaultTerminalName(existingCount: number): string {
  return `Terminal #${existingCount + 1}`;
}

export function initialNewTerminalState(existingCount: number, agents: AgentsState): NewTerminalState {
  return {
    name: defaultTerminalName(existingCount),
    engine: agents.installed.has("claude") ? "claude" : "shell",
  };
}

const KEY_ENGINE: Record<string, Engine> = { "1": "claude", "2": "codex", "3": "antigravity", "0": "shell" };

export type NewTerminalKeyAction =
  | { type: "engine"; engine: Engine }
  | { type: "confirm" } | { type: "cancel" } | null;

export function terminalKeyAction(e: { key: string; metaKey: boolean }): NewTerminalKeyAction {
  if (e.metaKey && KEY_ENGINE[e.key]) return { type: "engine", engine: KEY_ENGINE[e.key] };
  if (e.key === "Enter") return { type: "confirm" };
  if (e.key === "Escape") return { type: "cancel" };
  return null;
}
