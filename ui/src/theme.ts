// Shared design tokens for the workspace shell (Task 5.2). One place so
// Sidebar/TabBar/Terminal/EnginePicker/CommandPalette agree on what an
// "engine" looks like — see App.css for the rest of the HUD token system
// (color/type/spacing custom properties).
import type { Engine } from "./state/sessions";

export const ENGINE_LABEL: Record<Engine, string> = {
  claude: "Claude Code",
  codex: "Codex",
  shell: "Shell",
};

export const ENGINE_COLOR: Record<Engine, string> = {
  claude: "#e8a23d",
  codex: "#8b7cf6",
  shell: "#43c98f",
};

export const ENGINE_HINT: Record<Engine, string> = {
  claude: "Pre-briefed from the brain, MCP-wired",
  codex: "Stock spawn, no ADE wiring",
  shell: "Your default $SHELL",
};
