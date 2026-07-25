// Pure logic behind auto-titling a tab from its first real input line
// (founder ask, verbatim: "The title for each terminal can be renamed or
// it's simply automatically given a name based on the first prompt").
// `Terminal.tsx` is the only caller — it feeds every raw chunk from
// xterm's `onData` (real user keystrokes going into `sessionWrite`, never
// anything the app itself writes, e.g. a Claude briefing) through
// `feedFirstInputChunk`. Framework-free by design (same house style as
// `sessions.ts`/`paneGrid.ts`) so the whole extraction/truncation/
// stop-condition algorithm is unit-testable without xterm.js or a DOM.
//
// Kept deliberately separate from `sessions.ts`'s `tab/autoTitled` reducer
// action: this module only ever answers "what should the title be, and
// have we already decided one for this session" from the raw keystroke
// stream — whether that title actually gets applied to a `TabInfo` (it
// doesn't, if the tab already has a label — manual rename or a carried-
// over label always wins, see that action's own doc) is the reducer's
// call, not this module's.

/** Truncated title length ("~40-50 chars" per the brief) — long enough to
 * stay recognizable, short enough that a pane header never wraps/crowds
 * out the branch pill and buttons next to it. */
export const AUTO_TITLE_MAX_LENGTH = 48;

/** Truncates `s` to at most `maxLen` characters, trimming any trailing
 * whitespace the cut would otherwise leave right before the ellipsis. */
export function truncateTitle(s: string, maxLen: number): string {
  if (s.length <= maxLen) return s;
  return `${s.slice(0, maxLen - 1).trimEnd()}…`;
}

/**
 * Turns a raw slice of terminal INPUT bytes (literally whatever was sent to
 * `sessionWrite`, not what the shell/engine echoed back) into readable
 * text: strips ANSI CSI escape sequences (arrow keys, etc. — a raw
 * keystroke stream includes these verbatim, xterm.js doesn't pre-parse
 * `onData`), replays backspace (`\x7f`/`\b`) against the text accumulated
 * so far (an approximation — the PTY's own line discipline is what
 * "really" applies a backspace, but replaying it here reconstructs the
 * common case of typing-then-fixing-a-typo well enough for a title), drops
 * remaining C0 control characters (tab excepted), and trims the result.
 */
export function sanitizeForTitle(raw: string): string {
  let out = "";
  let i = 0;
  while (i < raw.length) {
    const ch = raw[i];
    if (ch === "\x1b") {
      // CSI (ESC '[' ... final-byte) or a bare two-byte escape — skip it
      // entirely rather than let it leak literal escape junk into a title.
      if (raw[i + 1] === "[") {
        let j = i + 2;
        while (j < raw.length && !/[a-zA-Z~]/.test(raw[j])) j++;
        i = Math.min(j + 1, raw.length);
      } else {
        i += 2;
      }
      continue;
    }
    if (ch === "\x7f" || ch === "\b") {
      out = out.slice(0, -1);
      i++;
      continue;
    }
    if (ch.charCodeAt(0) < 0x20 && ch !== "\t") {
      i++;
      continue;
    }
    out += ch;
    i++;
  }
  return out.trim();
}

/** `null` for a line that sanitizes down to nothing (bare Enter, an
 * arrow-key-only line, ...) — the caller should keep watching for the next
 * real line rather than lock in a blank title. */
export function titleFromLine(rawLine: string): string | null {
  const clean = sanitizeForTitle(rawLine);
  if (clean.length === 0) return null;
  return truncateTitle(clean, AUTO_TITLE_MAX_LENGTH);
}

export interface FirstInputCapture {
  /** Bytes seen so far since the last line terminator, not yet resolved
   * into a title. */
  buffer: string;
  /** Once true, a title has already been decided for this session (or the
   * caller gave up watching) — `feedFirstInputChunk` becomes a permanent
   * no-op, matching "capture once, from the first real input line, then
   * stop watching" from the brief. */
  captured: boolean;
}

export function initialFirstInputCapture(): FirstInputCapture {
  return { buffer: "", captured: false };
}

/** A pathological unterminated paste (no `\r`/`\n` at all) must not grow
 * this buffer without bound for the lifetime of a long-running session —
 * only the tail end could ever matter for "the first line" anyway. */
const MAX_UNTERMINATED_BUFFER = 512;

/**
 * Feeds one more raw chunk of user keystrokes into the capture state.
 * Returns the next state plus a `title` — non-null exactly once, the
 * moment a line terminator (`\r` or `\n`, however the chunk boundaries
 * happen to fall) completes the first non-blank line ever seen. Every call
 * after that (`state.captured === true`) is a stable no-op: same state
 * reference back, `title: null` — `Terminal.tsx` can keep piping every
 * keystroke through this for the rest of the session with no extra guard
 * of its own.
 */
export function feedFirstInputChunk(
  state: FirstInputCapture,
  chunk: string,
): { next: FirstInputCapture; title: string | null } {
  if (state.captured) return { next: state, title: null };

  const combined = state.buffer + chunk;
  const idx = combined.search(/[\r\n]/);
  if (idx === -1) {
    const bounded = combined.length > MAX_UNTERMINATED_BUFFER ? combined.slice(-MAX_UNTERMINATED_BUFFER) : combined;
    if (bounded === state.buffer) return { next: state, title: null };
    return { next: { buffer: bounded, captured: false }, title: null };
  }

  const rawLine = combined.slice(0, idx);
  const rest = combined.slice(idx + 1);
  const title = titleFromLine(rawLine);
  if (title === null) {
    // Bare Enter (or a line that sanitizes to nothing) — keep watching for
    // the next real line rather than lock in a blank title.
    return { next: { buffer: rest, captured: false }, title: null };
  }
  return { next: { buffer: "", captured: true }, title };
}
