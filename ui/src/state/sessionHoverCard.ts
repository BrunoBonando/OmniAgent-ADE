// What the per-session hover card shows, as pure data (founder ask,
// 2026-07-26, verbatim: "for each session, have a hover with more info, like
// warp does" — reference screenshot at
// docs/reference/warp-session-hover-card.png).
//
// Warp's card carries: a status badge, the working path (`~`-collapsed), the
// branch, the session title, the agent name + avatar, and a diff stat. Every
// one of those except the diff stat is something this app genuinely knows,
// so the card renders those five and *omits* the sixth rather than
// fabricating a number — see `diff` below for the seam the later
// git-review dispatch fills in.
//
// Separated from `SessionHoverCard.tsx` for the same reason `sessionStatus.ts`
// is separated from the light: the derivation is where the decisions are
// (which title wins, how a path is shortened, what "no branch" looks like),
// and decisions get unit tests.

import { ENGINE_LABEL } from "../theme";
import { statusPresentation, type StatusPresentation } from "./sessionStatus";
import { tabDisplayLabel, type Engine, type TabInfo } from "./sessions";

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

export interface HoverCardInput {
  tab: TabInfo;
  projectLabel: string;
  /** From `useGitBranch(tab.cwd)` — `null` outside a git repo. */
  branch?: string | null;
}

export interface HoverCardModel {
  /** The session's own name: its custom/auto title, else the engine name. */
  title: string;
  projectLabel: string;
  /** `~`-collapsed working directory. */
  path: string;
  branch: string | null;
  engine: Engine;
  engineLabel: string;
  status: StatusPresentation;
  /** True when this tab reattached to an engine that outlived the app
   * closing (`SessionInfo.restored`) — worth one quiet line, because
   * "the same Claude conversation is still here" is the whole point of the
   * tmux persistence work and is otherwise invisible. */
  restored: boolean;
  /** Warp's `+12891`. Always `null` today: the git review data this needs is
   * a later dispatch, and a made-up number in a card whose entire job is to
   * tell you the truth about a session would be worse than an absent one.
   * The card leaves the slot empty; when `git_review`-style data lands, this
   * becomes `{ added, removed }` and only this file and the card's last row
   * change. */
  diff: null;
}

export function deriveHoverCard({ tab, projectLabel, branch }: HoverCardInput): HoverCardModel {
  return {
    title: tabDisplayLabel(tab),
    projectLabel,
    path: collapseHome(tab.cwd),
    branch: branch ?? null,
    engine: tab.engine,
    engineLabel: ENGINE_LABEL[tab.engine],
    status: statusPresentation(tab.status),
    restored: tab.restored === true,
    diff: null,
  };
}
