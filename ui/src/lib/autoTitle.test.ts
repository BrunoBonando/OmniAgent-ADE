import { describe, expect, it } from "vitest";
import {
  AUTO_TITLE_MAX_LENGTH,
  engineTitleFromTerminalTitle,
  sanitizeForTitle,
  titleFromLine,
  truncateTitle,
} from "./autoTitle";

describe("truncateTitle", () => {
  it("returns the string unchanged when it fits", () => {
    expect(truncateTitle("fix the login bug", 40)).toBe("fix the login bug");
  });

  it("truncates long input to at most maxLen characters, ending in an ellipsis that is a real prefix of the input", () => {
    const long = "please refactor the entire authentication module to use JWT";
    const out = truncateTitle(long, 20);
    expect(out.length).toBeLessThanOrEqual(20);
    expect(out.endsWith("…")).toBe(true);
    expect(long.startsWith(out.slice(0, -1))).toBe(true);
  });

  it("trims trailing whitespace before appending the ellipsis", () => {
    // slice(0, maxLen - 1) lands exactly on the space in "hello world".
    expect(truncateTitle("hello world", 7)).toBe("hello…");
  });
});

describe("sanitizeForTitle", () => {
  it("passes plain text through, trimmed", () => {
    expect(sanitizeForTitle("  fix the deploy script  ")).toBe("fix the deploy script");
  });

  it("simulates backspace erasure (0x7f removes the previous char)", () => {
    expect(sanitizeForTitle("helol\x7f\x7flo")).toBe("hello");
  });

  it("simulates backspace via \\b too", () => {
    expect(sanitizeForTitle("helxx\b\blo")).toBe("hello");
  });

  it("strips ANSI CSI escape sequences (arrow keys, etc.)", () => {
    expect(sanitizeForTitle("fix\x1b[Athe bug")).toBe("fixthe bug");
  });

  it("strips other C0 control characters but keeps tabs", () => {
    expect(sanitizeForTitle("a\x07b\tc")).toBe("ab\tc");
  });

  it("returns empty string for input that is only control noise", () => {
    expect(sanitizeForTitle("\x1b[A\x1b[B")).toBe("");
  });
});

describe("titleFromLine", () => {
  it("produces a truncated, sanitized title for a real prompt line", () => {
    expect(titleFromLine("fix the login bug")).toBe("fix the login bug");
  });

  it("returns null for an empty/whitespace-only line (bare Enter)", () => {
    expect(titleFromLine("")).toBeNull();
    expect(titleFromLine("   ")).toBeNull();
    expect(titleFromLine("\x1b[A")).toBeNull();
  });

  it("truncates to AUTO_TITLE_MAX_LENGTH", () => {
    const long = "x".repeat(200);
    const title = titleFromLine(long);
    expect(title).not.toBeNull();
    expect(title!.length).toBe(AUTO_TITLE_MAX_LENGTH);
  });
});

describe("engineTitleFromTerminalTitle", () => {
  it("accepts a generated Claude title", () => {
    expect(engineTitleFromTerminalTitle("claude", "Fix login flow")).toBe("Fix login flow");
  });

  it("accepts a generated Copilot title", () => {
    expect(engineTitleFromTerminalTitle("copilot", "Add retry handling")).toBe("Add retry handling");
  });

  it("ignores generic engine and version titles", () => {
    expect(engineTitleFromTerminalTitle("claude", "2.1.220")).toBeNull();
    expect(engineTitleFromTerminalTitle("copilot", "GitHub Copilot")).toBeNull();
  });

  it("does not invent titles for engines without a generated title", () => {
    expect(engineTitleFromTerminalTitle("codex", "Fix login flow")).toBeNull();
    expect(engineTitleFromTerminalTitle("antigravity", "Fix login flow")).toBeNull();
  });
});
