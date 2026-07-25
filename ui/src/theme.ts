// Shared design tokens for the workspace shell (Task 5.2). One place so
// Sidebar/PaneHeader/Terminal/EnginePicker/CommandPalette agree on what an
// "engine" looks like — see App.css for the rest of the HUD token system
// (color/type/spacing custom properties).
import type { Engine } from "./state/sessions";

export const ENGINE_LABEL: Record<Engine, string> = {
  claude: "Claude Code",
  codex: "Codex",
  shell: "Shell",
};

// Sampled directly from the founder's reference screenshot (BridgeSpace),
// docs/reference/bridgespace-pane-grid-reference.png — the per-engine dot
// color in each pane header. claude-code's dot ~(0.217, 0.128) is a violet
// #b696f2, codex's ~(0.605, 0.128) is a cyan #a2e7f9, and the plain-shell
// dot (that screenshot's "zsh" pane) ~(0.605, 0.556) is a neutral gray
// #979a9b rather than an engine-branded hue — "shell" isn't an agent here
// either, so it keeps that same neutral treatment instead of the old green.
export const ENGINE_COLOR: Record<Engine, string> = {
  claude: "#b696f2",
  codex: "#a2e7f9",
  shell: "#9a9ca6",
};

export const ENGINE_HINT: Record<Engine, string> = {
  claude: "Pre-briefed from the brain, MCP-wired",
  codex: "Stock spawn, no ADE wiring",
  shell: "Your default $SHELL",
};
