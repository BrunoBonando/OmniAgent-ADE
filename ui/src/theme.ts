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
//
// Warp *exact*-color pass (2026-07-25): App.css's --signal (the app's
// general-purpose accent — focus rings, links, buttons) moved to a muted
// blue-lavender/periwinkle per Bruno's Warp screenshot, which put it only
// ~31deg of hue away from claude's violet dot (was ~43deg from the old
// blue --signal) — close enough to blur "which engine is this" at a
// glance. Nudged claude to #cc96f2 (same saturation/lightness, hue shifted
// 261deg -> 275deg, more magenta-violet) to restore ~45deg of separation;
// left codex/shell untouched since neither was ever close to --signal's
// hue family and nothing about this pass put them at risk. Deliberately
// NOT collapsed onto Warp's own single accent color — these dots encode
// real functional meaning (which engine a pane is running), not theme
// decoration, per the brief's own instruction to preserve that signal.
export const ENGINE_COLOR: Record<Engine, string> = {
  claude: "#cc96f2",
  codex: "#a2e7f9",
  shell: "#9a9ca6",
};

export const ENGINE_HINT: Record<Engine, string> = {
  claude: "Pre-briefed from the brain, MCP-wired",
  codex: "Stock spawn, no ADE wiring",
  shell: "Your default $SHELL",
};
