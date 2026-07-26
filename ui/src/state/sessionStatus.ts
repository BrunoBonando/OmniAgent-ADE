// The five-state session light, as pure data (founder brief, 2026-07-26).
// Zero React/Tauri imports so the whole status -> colour/motion/wording
// mapping is unit-testable on its own, exactly like `fileTreeState.ts` /
// `accountBadgeState.ts` — `SessionStatusLight.tsx` is then a thin renderer
// that only turns this into two data attributes and a `<span>`.
//
// Bruno's spec, verbatim (his colours, his motions, his meanings):
//
// > White / Blue: Pulsing gradient. Shows the agent is thinking, reasoning,
// > or generating tokens.
// > Green: Solid steady light. Shows a task completed successfully and
// > results are ready or just waiting for input.
// > Amber / Yellow: Breathing slow rhythm. Shows the agent is paused,
// > waiting for your approval.
// > Red / Magenta: Rapid flashing. Shows an error occurred, a process
// > failed, or a block exists.
// > Cyan / Teal: Rapid chasing pattern. Shows active tool execution, like
// > terminal commands or file writes.
//
// The backend (`src-tauri/src/sessions.rs`) owns the *taxonomy* and emits it
// as snake_case wire strings; the colour and the motion are deliberately a
// frontend decision (its own doc comment: "a backend that emitted `amber`
// would freeze it"). This module is where that decision lives, once.
//
// `notify` is NOT re-derived here. It rides along on every
// `session-status:{id}` payload precomputed by `SessionStatus::notifies`,
// which the Rust side documents as the single source of truth for Bruno's
// "only green, yellow or red generate a notification" rule. The
// notifications panel a later dispatch builds consumes that flag directly;
// duplicating the rule here would create a second, driftable copy.

/** The wire strings, verbatim from `SessionStatus`'s serde rename. */
export const SESSION_STATUSES = [
  "ready",
  "thinking",
  "tool_execution",
  "awaiting_approval",
  "error",
] as const;
export type SessionStatus = (typeof SESSION_STATUSES)[number];

export function isSessionStatus(value: unknown): value is SessionStatus {
  return typeof value === "string" && (SESSION_STATUSES as readonly string[]).includes(value);
}

/** The `session-status:{id}` event payload / `session_status` return shape
 * (`sessions::SessionStatusEvent`). One type for push and pull, same as the
 * Rust side. */
export interface SessionStatusEvent {
  id: string;
  status: SessionStatus;
  /** Precomputed `SessionStatus::notifies()` — carried, never recomputed. */
  notify: boolean;
  engine: string;
}

/** Five distinct *rhythms*, not five fades of the same shape — the whole
 * point is that a glance at a 15px mark tells you which state it is without
 * reading the colour:
 *
 * | motion   | what it does                        | period | feel |
 * |----------|-------------------------------------|--------|------|
 * | `steady` | nothing at all                      | —      | at rest, the only motionless state |
 * | `sweep`  | gradient traverses the mark + swells | 1.9s  | smooth, continuous, soft |
 * | `breathe`| deep opacity+scale dip               | 3.4s  | slow, organic, unmistakably the slowest |
 * | `flash`  | hard on/off square wave             | 0.44s | discontinuous — the only one that *jumps* |
 * | `chase`  | conic highlight rotating round the ring | 0.85s | continuous rotation — the only one that *travels* |
 *
 * The four moving ones differ on axis (opacity vs translate vs rotate),
 * timing function (ease vs linear vs step) and period (3.4s down to 0.44s),
 * so no two read alike even at dot size. Every one of them is CSS-only (see
 * App.css) — nothing here drives a frame from JS, because a busy workspace
 * renders one of these per pane. */
export type StatusMotion = "steady" | "sweep" | "breathe" | "flash" | "chase";

/** `"unknown"` is not a backend state: it's the honest render for a pane
 * whose first `session_status` pull hasn't landed yet. Deliberately NOT
 * defaulted to `ready` — green claims "your task finished successfully",
 * which is a lie to tell about a session that has said nothing at all. */
export type StatusKey = SessionStatus | "unknown";

export interface StatusPresentation {
  key: StatusKey;
  /** The backend status, or `undefined` for the pre-signal `unknown` state. */
  status?: SessionStatus;
  /** Badge text — short enough to sit in a pill. */
  label: string;
  /** One plain sentence, written for the person looking at the pane, not for
   * whoever wrote the state machine. This is the "on hover, it explains"
   * text Bruno asked for. */
  explanation: string;
  /** The App.css custom property holding this state's colour. Named rather
   * than hex'd so there is exactly one definition of each colour (in
   * `:root`), and the animations can key off the same token. */
  colorVar: string;
  motion: StatusMotion;
  /** What a screen reader gets — the light is decorative-looking but carries
   * real information, so it is `role="img"` with this as its label. */
  ariaLabel: string;
}

function presentation(
  key: StatusKey,
  label: string,
  explanation: string,
  colorVar: string,
  motion: StatusMotion,
): StatusPresentation {
  return {
    key,
    status: key === "unknown" ? undefined : key,
    label,
    explanation,
    colorVar,
    motion,
    ariaLabel: `${label} — ${explanation}`,
  };
}

export const UNKNOWN_PRESENTATION: StatusPresentation = presentation(
  "unknown",
  "Starting",
  "No signal from this session yet.",
  "--status-unknown",
  "steady",
);

export const STATUS_PRESENTATION: Record<SessionStatus, StatusPresentation> = {
  ready: presentation(
    "ready",
    "Ready",
    "Finished — results are up and it's waiting for your next instruction.",
    "--status-ready",
    "steady",
  ),
  thinking: presentation(
    "thinking",
    "Thinking",
    "Working on it — reasoning and writing a reply.",
    "--status-thinking",
    "sweep",
  ),
  tool_execution: presentation(
    "tool_execution",
    "Running tools",
    "Running a command or writing files right now.",
    "--status-tool",
    "chase",
  ),
  awaiting_approval: presentation(
    "awaiting_approval",
    "Needs approval",
    "Paused until you approve the action it wants to take.",
    "--status-approval",
    "breathe",
  ),
  error: presentation(
    "error",
    "Error",
    "Something failed — a command exited badly, or it's blocked.",
    "--status-error",
    "flash",
  ),
};

/** Total: an absent status, or a string this build doesn't know (a sixth
 * state added backend-side later), both render as `unknown` rather than
 * throwing or guessing. */
export function statusPresentation(status: SessionStatus | undefined | null): StatusPresentation {
  return isSessionStatus(status) ? STATUS_PRESENTATION[status] : UNKNOWN_PRESENTATION;
}

/** Severity order for rolling several terminals up into one light — the
 * sidebar shows one row per session, and a session is one-or-more terminals
 * (founder brief: "inside it we have a session that contains multiple
 * terminals").
 *
 * Read top-down, the rule is "what would you want to be told first": a
 * failure, then a session paused on your approval, then whatever is
 * actively moving, then rest. It deliberately outranks *blocked* over
 * *busy* — a session running tools is fine on its own, one waiting for you
 * is not going anywhere until you look.
 */
const STATUS_SEVERITY: Record<SessionStatus, number> = {
  error: 5,
  awaiting_approval: 4,
  tool_execution: 3,
  thinking: 2,
  ready: 1,
};

/** The one status that speaks for a whole session. `undefined` when nothing
 * in it has reported yet — which renders as the neutral "Starting" mark,
 * never a guess (see `statusPresentation`). */
export function mostSignificantStatus(
  statuses: ReadonlyArray<SessionStatus | undefined>,
): SessionStatus | undefined {
  let best: SessionStatus | undefined;
  for (const status of statuses) {
    if (!isSessionStatus(status)) continue;
    if (best === undefined || STATUS_SEVERITY[status] > STATUS_SEVERITY[best]) best = status;
  }
  return best;
}

/** "This session is blocked on the person, right now" — the single
 * definition of what used to be `TabInfo.needsAttention`'s latched red dot
 * (2026-07-26; see that field's removal note in `sessions.ts`).
 *
 * Deliberately NARROWER than the backend's `notify` flag, which is also
 * true for `ready`: a finished task is worth a notification ("your thing is
 * done") but is not something the sidebar should mark as *wanting* you —
 * `awaiting_approval` (paused for your approval) and `error` (failed or
 * blocked) are. Derived from the live status on every render rather than
 * stored, so a session that resolves itself while you were elsewhere stops
 * asking for you the instant it does, instead of holding a stale badge
 * until someone clicks the pane. */
export function statusNeedsAttention(status: SessionStatus | undefined | null): boolean {
  return status === "awaiting_approval" || status === "error";
}
