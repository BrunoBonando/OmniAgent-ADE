// Per-terminal color theme registry (founder ask, verbatim: "I really want
// the terminal background to be a bit darker, like almost black, but text
// can be original. We'll add themes later, or actually you can add some
// themes for each terminal already, like Matrix ... Standard, which is the
// current one, and maybe another example. The theme is applied to the
// terminal only"). Each entry is a complete `@xterm/xterm` `ITheme` object —
// `Terminal.tsx` is the only consumer, assigning one of these to its xterm
// instance's `theme` option (both at construction and live, via
// `term.options.theme = ...`, when the pane's chosen theme changes without
// tearing down the PTY). Deliberately does NOT touch App.css's app-chrome
// tokens (--void/--ink/--signal/etc.) — "applied to the terminal only" per
// the founder's own words; the sidebar/panels/pane-header chrome stays
// exactly as-is regardless of which terminal theme a pane has selected.
export interface XtermThemeColors {
  background: string;
  foreground: string;
  cursor: string;
  cursorAccent: string;
  selectionBackground: string;
  black: string;
  red: string;
  green: string;
  yellow: string;
  blue: string;
  magenta: string;
  cyan: string;
  white: string;
  brightBlack: string;
  brightRed: string;
  brightGreen: string;
  brightYellow: string;
  brightBlue: string;
  brightMagenta: string;
  brightCyan: string;
  brightWhite: string;
}

export const TERMINAL_THEME_IDS = ["standard", "matrix", "amber"] as const;
export type TerminalThemeId = (typeof TERMINAL_THEME_IDS)[number];

export function isTerminalThemeId(value: unknown): value is TerminalThemeId {
  return typeof value === "string" && (TERMINAL_THEME_IDS as readonly string[]).includes(value);
}

export const TERMINAL_THEME_LABELS: Record<TerminalThemeId, string> = {
  standard: "Standard",
  matrix: "Matrix",
  amber: "Amber CRT",
};

/** One-line pane-menu subtitle for each preset — same spirit as
 * `theme.ts`'s `ENGINE_HINT`. */
export const TERMINAL_THEME_HINT: Record<TerminalThemeId, string> = {
  standard: "Warp-matched palette, near-black background",
  matrix: "Green phosphor on black",
  amber: "Warm amber CRT, 1980s terminal",
};

// Standard: `Terminal.tsx`'s original `HUD_THEME`, sourced verbatim from
// Warp's own bundled dark theme (warp_bundled/warp_dark.yaml) — foreground
// and every ANSI slot are UNCHANGED (founder: "text can be original"), only
// `background`/`cursorAccent` are pushed toward near-black (founder: "a bit
// darker, like almost black") from the original `#16171c` to `#0a0a0c` —
// dark enough to read as "almost black" without being a literal `#000000`,
// which would remove the last bit of depth the terminal surface has against
// a pure-black pane header/void. `cursorAccent` is kept equal to
// `background` (same invariant the original theme already used) so the
// block cursor still renders foreground text legibly on top of it.
// `selectionBackground` is intentionally untouched — it's a highlight
// overlay, not "background," and stays visible against the darker base.
const STANDARD: XtermThemeColors = {
  background: "#0a0a0c",
  foreground: "#e8e9ec",
  cursor: "#9aa7e6",
  cursorAccent: "#0a0a0c",
  selectionBackground: "#2c2d34",
  black: "#616161",
  red: "#ff8272",
  green: "#b4fa72",
  yellow: "#fefdc2",
  blue: "#a5d5fe",
  magenta: "#ff8ffd",
  cyan: "#d0d1fe",
  white: "#f1f1f1",
  brightBlack: "#8e8e8e",
  brightRed: "#ffc4bd",
  brightGreen: "#d6fcb9",
  brightYellow: "#fefdd5",
  brightBlue: "#c1e3fe",
  brightMagenta: "#ffb1fe",
  brightCyan: "#e5e6fe",
  brightWhite: "#feffff",
};

// Matrix: classic green-phosphor terminal — pure black background, body
// text a soft phosphor green (not the most saturated possible green, which
// would fatigue the eyes over a real coding session). "Mostly green" (the
// founder's own phrasing) governs the default/white text and the
// black/white ANSI slots, which is where a real green-phosphor terminal's
// monochrome character actually comes from — but red is deliberately kept
// a real (if slightly softened) red rather than greenified: a huge amount
// of real CLI output (git status, linters, test failures) depends on
// red actually reading as "red = wrong", and collapsing it to green would
// make the theme a gimmick that hurts legibility for real work, which the
// brief explicitly warns against. Blue/magenta/cyan — which carry no
// consistent semantic meaning across tools — are shifted into the
// green/teal family to keep the overall look cohesively "Matrix" without
// sacrificing any real diagnostic signal.
const MATRIX: XtermThemeColors = {
  background: "#000000",
  foreground: "#39ff88",
  cursor: "#8dffba",
  cursorAccent: "#000000",
  selectionBackground: "#0f3d20",
  black: "#0c1f12",
  red: "#ff5f5f",
  green: "#33ff77",
  yellow: "#c8ff5c",
  blue: "#5cffc8",
  magenta: "#8dffb0",
  cyan: "#7dffef",
  white: "#c8ffdc",
  brightBlack: "#3a5a45",
  brightRed: "#ff8a8a",
  brightGreen: "#7dffb0",
  brightYellow: "#e2ff9c",
  brightBlue: "#9dffe0",
  brightMagenta: "#c0ffd6",
  brightCyan: "#c0fff2",
  brightWhite: "#eafff2",
};

// Amber CRT: the third preset — a warm amber monochrome look (IBM 5151 /
// VT220 amber-mode monitors), picked over a second green variant or a
// plain light theme because it's an equally well-known, equally iconic
// terminal aesthetic that reads as *unmistakably different* from both
// Standard (cool, violet-accented, near-black) and Matrix (green phosphor,
// true black) at a glance — real variety, not a reskin. Same "keep red
// legible for real diagnostics" call as Matrix; blue/cyan/green are folded
// into the amber/tan family so the monochrome character survives while
// still giving 16 visually distinct slots.
const AMBER: XtermThemeColors = {
  background: "#120b02",
  foreground: "#ffb347",
  cursor: "#ffcf7a",
  cursorAccent: "#120b02",
  selectionBackground: "#3d2405",
  black: "#2a1a08",
  red: "#ff6b4a",
  green: "#d9c15a",
  yellow: "#ffd35c",
  blue: "#e2a765",
  magenta: "#ffab6b",
  cyan: "#f3c98a",
  white: "#ffe3b3",
  brightBlack: "#5a4020",
  brightRed: "#ff9a7a",
  brightGreen: "#e8d585",
  brightYellow: "#ffe38a",
  brightBlue: "#f0c896",
  brightMagenta: "#ffcc9a",
  brightCyan: "#f8ddb0",
  brightWhite: "#fff2d9",
};

export const TERMINAL_THEMES: Record<TerminalThemeId, XtermThemeColors> = {
  standard: STANDARD,
  matrix: MATRIX,
  amber: AMBER,
};

/** The theme new panes get when nothing has ever overridden them — see
 * `sessions.ts`'s `TabInfo.themeId` doc for the global-default-with-
 * per-pane-override design this constant anchors. */
export const DEFAULT_TERMINAL_THEME: TerminalThemeId = "standard";

/** Resolves the effective xterm theme object for a pane: its own override
 * if it has one, else the app-wide default. The one place `Terminal.tsx`/
 * `PaneHeader.tsx` need to know about the fallback rule, so it can't drift
 * between call sites. */
export function resolveTerminalTheme(themeId: TerminalThemeId | undefined): XtermThemeColors {
  return TERMINAL_THEMES[themeId ?? DEFAULT_TERMINAL_THEME];
}

/** Cycles to the next theme in `TERMINAL_THEME_IDS` order — same shape as
 * `sessions.ts`'s `cycleEngine`, kept in case the pane menu ever grows
 * keyboard navigation; also handy for tests exercising "pick the next
 * theme" without hardcoding the registry order twice. */
export function cycleTerminalTheme(current: TerminalThemeId, direction: 1 | -1): TerminalThemeId {
  const idx = TERMINAL_THEME_IDS.indexOf(current);
  const next = (idx + direction + TERMINAL_THEME_IDS.length) % TERMINAL_THEME_IDS.length;
  return TERMINAL_THEME_IDS[next];
}
