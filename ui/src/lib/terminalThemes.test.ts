import { describe, expect, it } from "vitest";
import {
  cycleTerminalTheme,
  DEFAULT_TERMINAL_THEME,
  isTerminalThemeId,
  resolveTerminalTheme,
  TERMINAL_THEME_HINT,
  TERMINAL_THEME_IDS,
  TERMINAL_THEME_LABELS,
  TERMINAL_THEMES,
  type XtermThemeColors,
} from "./terminalThemes";

const REQUIRED_KEYS: (keyof XtermThemeColors)[] = [
  "background",
  "foreground",
  "cursor",
  "cursorAccent",
  "selectionBackground",
  "black",
  "red",
  "green",
  "yellow",
  "blue",
  "magenta",
  "cyan",
  "white",
  "brightBlack",
  "brightRed",
  "brightGreen",
  "brightYellow",
  "brightBlue",
  "brightMagenta",
  "brightCyan",
  "brightWhite",
];

const HEX_RE = /^#[0-9a-fA-F]{6}$/;

describe("TERMINAL_THEME_IDS / TERMINAL_THEMES registry", () => {
  it("lists exactly the three presets", () => {
    expect(TERMINAL_THEME_IDS).toEqual(["standard", "matrix", "amber"]);
  });

  it("every preset defines a complete xterm theme (all 21 fields, valid hex)", () => {
    for (const id of TERMINAL_THEME_IDS) {
      const theme = TERMINAL_THEMES[id];
      for (const key of REQUIRED_KEYS) {
        expect(theme[key], `${id}.${key}`).toMatch(HEX_RE);
      }
    }
  });

  it("every preset has a label and a hint", () => {
    for (const id of TERMINAL_THEME_IDS) {
      expect(TERMINAL_THEME_LABELS[id].length).toBeGreaterThan(0);
      expect(TERMINAL_THEME_HINT[id].length).toBeGreaterThan(0);
    }
  });

  it("the three presets have distinct backgrounds and foregrounds (real variety, not a reskin)", () => {
    const backgrounds = new Set(TERMINAL_THEME_IDS.map((id) => TERMINAL_THEMES[id].background));
    const foregrounds = new Set(TERMINAL_THEME_IDS.map((id) => TERMINAL_THEMES[id].foreground));
    expect(backgrounds.size).toBe(3);
    expect(foregrounds.size).toBe(3);
  });

  it("standard keeps the original Warp-sourced foreground/ANSI palette, only deepening background/cursorAccent", () => {
    const standard = TERMINAL_THEMES.standard;
    // Original HUD_THEME values (Terminal.tsx, pre-this-change) — pinned
    // here so a future edit can't accidentally "fix" the background back
    // to the old, lighter value or silently touch the ANSI palette.
    expect(standard.foreground).toBe("#e8e9ec");
    expect(standard.green).toBe("#b4fa72");
    expect(standard.red).toBe("#ff8272");
    expect(standard.selectionBackground).toBe("#2c2d34");
    // Darker than the original #16171c, and cursorAccent tracks it.
    expect(standard.background).toBe("#0a0a0c");
    expect(standard.cursorAccent).toBe(standard.background);
    expect(standard.background).not.toBe("#16171c");
    expect(standard.background).not.toBe("#000000"); // "almost black", not literal black
  });

  it("matrix is a black background with a green-dominant foreground", () => {
    const matrix = TERMINAL_THEMES.matrix;
    expect(matrix.background).toBe("#000000");
    expect(matrix.foreground.toLowerCase()).not.toBe("#ffffff");
    // Green channel dominant in the foreground color.
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(matrix.foreground.slice(i, i + 2), 16));
    expect(g).toBeGreaterThan(r);
    expect(g).toBeGreaterThan(b);
  });

  it("matrix keeps red a real red (legible error output, not gimmicked away)", () => {
    const [r, g, b] = [1, 3, 5].map((i) => parseInt(TERMINAL_THEMES.matrix.red.slice(i, i + 2), 16));
    expect(r).toBeGreaterThan(g);
    expect(r).toBeGreaterThan(b);
  });

  it("amber is a warm, dark palette distinct from both standard and matrix", () => {
    const amber = TERMINAL_THEMES.amber;
    expect(amber.background).not.toBe(TERMINAL_THEMES.standard.background);
    expect(amber.background).not.toBe(TERMINAL_THEMES.matrix.background);
    const [r, , b] = [1, 3, 5].map((i) => parseInt(amber.foreground.slice(i, i + 2), 16));
    expect(r).toBeGreaterThan(b); // warm (red channel > blue channel)
  });
});

describe("isTerminalThemeId", () => {
  it("accepts every real preset id", () => {
    for (const id of TERMINAL_THEME_IDS) expect(isTerminalThemeId(id)).toBe(true);
  });

  it("rejects unknown strings and non-strings", () => {
    expect(isTerminalThemeId("dracula")).toBe(false);
    expect(isTerminalThemeId("")).toBe(false);
    expect(isTerminalThemeId(undefined)).toBe(false);
    expect(isTerminalThemeId(null)).toBe(false);
    expect(isTerminalThemeId(42)).toBe(false);
  });
});

describe("resolveTerminalTheme", () => {
  it("returns the pane's own override when set", () => {
    expect(resolveTerminalTheme("matrix")).toBe(TERMINAL_THEMES.matrix);
  });

  it("falls back to DEFAULT_TERMINAL_THEME when unset", () => {
    expect(resolveTerminalTheme(undefined)).toBe(TERMINAL_THEMES[DEFAULT_TERMINAL_THEME]);
  });

  it("DEFAULT_TERMINAL_THEME is standard", () => {
    expect(DEFAULT_TERMINAL_THEME).toBe("standard");
  });
});

describe("cycleTerminalTheme", () => {
  it("wraps forward through every preset in registry order", () => {
    expect(cycleTerminalTheme("standard", 1)).toBe("matrix");
    expect(cycleTerminalTheme("matrix", 1)).toBe("amber");
    expect(cycleTerminalTheme("amber", 1)).toBe("standard");
  });

  it("wraps backward", () => {
    expect(cycleTerminalTheme("standard", -1)).toBe("amber");
    expect(cycleTerminalTheme("amber", -1)).toBe("matrix");
  });
});
