import { describe, expect, it } from "vitest";
import {
  AUTO_TITLE_MAX_LENGTH,
  feedFirstInputChunk,
  initialFirstInputCapture,
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

describe("first-input capture (feedFirstInputChunk / initialFirstInputCapture)", () => {
  it("does nothing until a newline arrives", () => {
    let state = initialFirstInputCapture();
    const r1 = feedFirstInputChunk(state, "fix the ");
    expect(r1.title).toBeNull();
    state = r1.next;
    const r2 = feedFirstInputChunk(state, "login bug");
    expect(r2.title).toBeNull();
  });

  it("fires with the accumulated line once a carriage return arrives (Enter in a PTY)", () => {
    let state = initialFirstInputCapture();
    state = feedFirstInputChunk(state, "fix the ").next;
    const result = feedFirstInputChunk(state, "login bug\r");
    expect(result.title).toBe("fix the login bug");
    expect(result.next.captured).toBe(true);
  });

  it("also recognizes a bare \\n as the line terminator", () => {
    const result = feedFirstInputChunk(initialFirstInputCapture(), "hello\n");
    expect(result.title).toBe("hello");
  });

  it("stops capturing after the first real line — further chunks never produce another title", () => {
    let state = initialFirstInputCapture();
    const first = feedFirstInputChunk(state, "first prompt\r");
    expect(first.title).toBe("first prompt");
    state = first.next;

    const second = feedFirstInputChunk(state, "second prompt\r");
    expect(second.title).toBeNull();
    expect(second.next).toBe(state); // no-op once captured, stable reference
  });

  it("keeps watching if the first line is empty (bare Enter) rather than capturing a blank title", () => {
    let state = initialFirstInputCapture();
    const bareEnter = feedFirstInputChunk(state, "\r");
    expect(bareEnter.title).toBeNull();
    expect(bareEnter.next.captured).toBe(false);

    const realLine = feedFirstInputChunk(bareEnter.next, "now type something\r");
    expect(realLine.title).toBe("now type something");
  });

  it("handles a line arriving split across many small onData chunks (real keystroke-by-keystroke typing)", () => {
    let state = initialFirstInputCapture();
    let title: string | null = null;
    for (const chunk of ["f", "i", "x", " ", "t", "h", "e", " ", "b", "u", "g", "\r"]) {
      const r = feedFirstInputChunk(state, chunk);
      state = r.next;
      if (r.title) title = r.title;
    }
    expect(title).toBe("fix the bug");
  });

  it("handles a full line pasted as a single onData chunk", () => {
    const r = feedFirstInputChunk(initialFirstInputCapture(), "npm run build\r");
    expect(r.title).toBe("npm run build");
  });

  it("truncates a very long first line", () => {
    const long = "a".repeat(100) + "\r";
    const r = feedFirstInputChunk(initialFirstInputCapture(), long);
    expect(r.title).not.toBeNull();
    expect(r.title!.length).toBe(AUTO_TITLE_MAX_LENGTH);
  });

  it("bounds unterminated buffer growth so a huge paste with no newline never grows unbounded", () => {
    let state = initialFirstInputCapture();
    for (let i = 0; i < 50; i++) {
      state = feedFirstInputChunk(state, "x".repeat(100)).next;
    }
    expect(state.buffer.length).toBeLessThan(1000);
  });
});
