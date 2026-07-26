// What the session hover card shows, as pure data (founder ask, 2026-07-26,
// verbatim: "for each session, have a hover with more info, like warp does" —
// reference screenshot at docs/reference/warp-session-hover-card.png).
//
// Warp's card carries: a status badge, the working path (`~`-collapsed), the
// branch, the session title, the agent name + avatar, and a diff stat. Every
// one of those except the diff stat is something this app genuinely knows,
// so the card renders those five and *omits* the sixth rather than
// fabricating a number — see `diff` below for the seam the later
// git-review dispatch fills in.
//
// ## Re-scoped from one terminal to the whole session (2026-07-26, later
// ## the same day)
//
// This first shipped scoped to a single pane, opened from the pane header.
// Bruno: *"The hover part is currently wrong: it's not on the terminal
// itself, but on session menu on the left."* So the input is now a
// `SessionGroup` — the same derivation the sidebar renders its rows from —
// and every field answers "what is this session", not "what is this pane":
// the session's name instead of a pane title, its root folder instead of one
// pane's cwd, how many terminals and which engines instead of one engine,
// and one aggregate light (`mostSignificantStatus`) instead of one pane's.
//
// Separated from `SessionHoverCard.tsx` for the same reason `sessionStatus.ts`
// is separated from the light: the derivation is where the decisions are
// (which status speaks for a session, how a path is shortened, what "no
// branch" looks like), and decisions get unit tests.

import { ENGINE_LABEL } from "../theme";
import { mostSignificantStatus, statusPresentation, type StatusPresentation } from "./sessionStatus";
import { sessionEngineBreakdown, type SessionGroup } from "./sessionGroups";
import type { Engine } from "./sessions";

/** Home directories on the two platforms a path here can come from. macOS is
 * the only supported platform (see README), but a `/home/<user>` cwd costs
 * one alternation to handle and avoids a surprising raw path if this ever
 * runs anywhere else. Deliberately pattern-based rather than read from an
 * env var: the UI runs in a WebView with no `$HOME`, and asking the backend
 * for it would mean an extra command and an async dependency for a purely
 * cosmetic shortening. */
const HOME_PATTERN = /^(\/Users\/[^/]+|\/home\/[^/]+)(\/.*)?$/;

/** `/Users/bonando/Documents/x` -> `~/Documents/x`; anything not under a home
 * directory is returned untouched. Never throws. */
export function collapseHome(path: string): string {
  const match = HOME_PATTERN.exec(path);
  if (!match) return path;
  const rest = match[2] ?? "";
  if (rest === "" || rest === "/") return "~";
  return `~${rest}`;
}

export interface SessionCardInput {
  session: SessionGroup;
  projectLabel: string;
  /** From `useGitBranch(session.cwd)` — `null` outside a git repo. */
  branch?: string | null;
}

export interface SessionCardModel {
  /** The session's name — stored, or its derived `Session N` default. */
  name: string;
  projectLabel: string;
  /** `~`-collapsed session root (`SessionGroup.cwd`). */
  path: string;
  branch: string | null;
  /** How many terminals are in this session. */
  terminals: number;
  /** Which engines are running in it, with a tally each, first-seen order. */
  engines: Array<{ engine: Engine; label: string; count: number }>;
  /** The session's aggregate light — its most significant terminal's state
   * (see `mostSignificantStatus`). */
  status: StatusPresentation;
  /** True when *any* terminal in the session reattached to an engine that
   * outlived the app closing (`SessionInfo.restored`) — worth one quiet
   * chip, because "the same Claude conversation is still here" is the whole
   * point of the tmux persistence work and is otherwise invisible. */
  restored: boolean;
  /** Warp's `+12891`. Always `null` today: the git review data this needs is
   * a later dispatch, and a made-up number in a card whose entire job is to
   * tell you the truth about a session would be worse than an absent one.
   * The card leaves the slot empty; when `git_review`-style data lands, this
   * becomes `{ added, removed }` and only this file and the card's last row
   * change. */
  diff: null;
}

export function deriveSessionCard({ session, projectLabel, branch }: SessionCardInput): SessionCardModel {
  return {
    name: session.label,
    projectLabel,
    path: collapseHome(session.cwd),
    branch: branch ?? null,
    terminals: session.tabs.length,
    engines: sessionEngineBreakdown(session).map(({ engine, count }) => ({
      engine,
      label: ENGINE_LABEL[engine],
      count,
    })),
    status: statusPresentation(mostSignificantStatus(session.tabs.map((t) => t.status))),
    restored: session.tabs.some((t) => t.restored === true),
    diff: null,
  };
}
