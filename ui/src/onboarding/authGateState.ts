// Fake sign-in + personalization gate — pure, framework-free state (same
// split as `onboardingState.ts`/`state/addProjectState.ts`: a reducer with
// zero Tauri/React imports so the phase transitions are unit-testable
// without mounting `AuthGate.tsx` or mocking `invoke()`).
//
// Founder direction (Bruno, verbatim): "let's skip the Import but let's
// Focus on getting to know the user after a login, but they can use it
// without login for now while in development. Login must be fake for now,
// just to test the workflow." This is a SEPARATE, EARLIER gate than
// `onboardingState.ts`'s FirstRun — see `App.tsx`'s boot effect for where
// the two compose. Nothing here ever makes a network call or checks a real
// credential: "sign in" always succeeds, "skip" is an equally first-class
// exit, and the whole point is testing the shape of the workflow before any
// real auth exists.

export type AuthGatePhase = "login" | "personalize" | "resolved";

export interface AuthGateOutcome {
  /** Whether the user went through the fake "Continue" (true) or picked
   * "Continue without signing in" (false). */
  signedIn: boolean;
  /** The selected `PersonaOption.id`, or `null` if never signed in, or
   * signed in but the personalization question was skipped. */
  persona: string | null;
}

export interface AuthGateState {
  phase: AuthGatePhase;
  /** Non-null exactly when `phase === "resolved"`. */
  outcome: AuthGateOutcome | null;
}

export const initialAuthGateState: AuthGateState = { phase: "login", outcome: null };

export type AuthGateAction =
  | { type: "skip_login" }
  | { type: "sign_in" }
  | { type: "answer_selected"; persona: string }
  | { type: "skip_personalize" };

export function authGateReducer(state: AuthGateState, action: AuthGateAction): AuthGateState {
  switch (action.type) {
    case "skip_login":
      if (state.phase !== "login") return state;
      return { phase: "resolved", outcome: { signedIn: false, persona: null } };

    case "sign_in":
      if (state.phase !== "login") return state;
      return { phase: "personalize", outcome: null };

    case "answer_selected":
      if (state.phase !== "personalize") return state;
      return { phase: "resolved", outcome: { signedIn: true, persona: action.persona } };

    case "skip_personalize":
      if (state.phase !== "personalize") return state;
      return { phase: "resolved", outcome: { signedIn: true, persona: null } };

    default:
      return state;
  }
}

/** The "already resolved, don't show again" gating logic `App.tsx`'s boot
 * effect applies to the raw `AUTH_GATE_RESOLVED_SETTING_KEY` read — mirrors
 * `FILE_TREE_VISIBLE_SETTING_KEY`'s own "only an explicit string flips the
 * default" convention: anything other than the exact string `"true"`
 * (unset/null, `"false"`, garbage) means "show the gate". */
export function authGateAlreadyResolved(settingValue: string | null): boolean {
  return settingValue === "true";
}

// ------------------------------------------------------------- persistence
// Settings-table keys, same "string constant + plain string value"
// convention `FILE_TREE_VISIBLE_SETTING_KEY`/`REVIEW_MEMORY_SETTING_KEY`
// (`ui/src/lib/tauri.ts`) already established — read/written through the
// existing generic `settingsGet`/`settingsSet`, no dedicated commands.

/** `"true"` once the gate has been shown and resolved (either path) — the
 * one key `App.tsx`'s boot check reads via `authGateAlreadyResolved`.
 * Reset to anything else (AboutPanel's "Reset sign-in flow") to show the
 * gate again on the next check. */
export const AUTH_GATE_RESOLVED_SETTING_KEY = "auth_gate_resolved";

/** `"true"`/`"false"` — which exit the user took. Unset means "nobody has
 * said otherwise", which — see `FAKE_ACCOUNT_NAME`/`resolveSignedIn` below
 * — now reads as signed in. */
export const AUTH_SIGNED_IN_SETTING_KEY = "auth_signed_in";

/** The chosen `PersonaOption.id`, or `""` if signed in but skipped the
 * question (or never signed in at all). */
export const AUTH_PERSONA_SETTING_KEY = "auth_persona";

// ---------------------------------------------------- the fake identity
// Bruno, 2026-07-26, verbatim: "I know that we didn't implement the login
// part yet, so just make a fake one as if I was logged in as
// BrunoBonando."
//
// This is the WHOLE implementation of that: one exported constant, used as
// the display name wherever a signed-in user's name is shown, plus the
// "unset means signed in" default below. There is deliberately no fake
// account object, no fake token, no fake profile fetch and no fake backend
// — nothing here pretends a login happened; the app simply starts in its
// signed-in *state*, wearing a name that is obviously a constant in the
// source. When a real auth system lands, the name comes from it and this
// constant is deleted; nothing else has to be untangled.

/** The dev-mode placeholder identity. NOT a real account: no credential,
 * no server, no profile — see the block comment above. */
export const FAKE_ACCOUNT_NAME = "Bruno Bonando";

/**
 * Whether the app should behave as signed in, given the raw
 * `AUTH_SIGNED_IN_SETTING_KEY` value.
 *
 * **Unset defaults to signed in** — so a fresh install (and Bruno's own
 * machine, where nothing has written this key) shows the logged-in
 * experience without anyone having to click through a login that isn't
 * real. Only the explicit string `"false"` — which is exactly what "Log
 * out"/"Continue without signing in" write — means signed out, so both
 * flows stay fully testable: log out, and the badge really does go
 * anonymous until the next sign-in.
 *
 * Deliberately the mirror image of `authGateAlreadyResolved`'s "only an
 * explicit 'true' counts" convention, for the opposite default, and the
 * one place that asymmetry is written down.
 */
export function resolveSignedIn(settingValue: string | null): boolean {
  return settingValue !== "false";
}

// ------------------------------------------------------------ persona list
// Adapted from the ChatGPT Desktop reference Bruno shared — same PATTERN
// (one friendly, skippable personalization question) but dev-tool-relevant
// options instead of ChatGPT's generic business functions (Marketing/
// Sales/HR/Legal are meaningless for a coding ADE).

export interface PersonaOption {
  id: string;
  label: string;
}

export const PERSONA_OPTIONS: PersonaOption[] = [
  { id: "software-engineering", label: "Software Engineering" },
  { id: "data-ml", label: "Data & ML" },
  { id: "devops-infra", label: "DevOps & Infrastructure" },
  { id: "product-design", label: "Product & Design" },
  { id: "research", label: "Research" },
  { id: "student", label: "Student" },
  { id: "other", label: "Other" },
];

/** `null` for an unknown/empty id — callers treat that as "no answer". */
export function personaLabel(id: string | null): string | null {
  if (!id) return null;
  return PERSONA_OPTIONS.find((o) => o.id === id)?.label ?? null;
}

/** `AboutPanel.tsx`'s light-touch surfacing of the captured answer — the
 * one place outside the gate itself that reads these settings back. Takes
 * the two raw setting values as read (both `string | null`) so it stays
 * pure/testable without mocking `settingsGet`. */
export function describeAuthSummary(signedInRaw: string | null, personaRaw: string | null): string {
  if (!resolveSignedIn(signedInRaw)) return "Not signed in (dev mode).";
  const label = personaLabel(personaRaw);
  return label ? `${FAKE_ACCOUNT_NAME} — ${label}.` : `${FAKE_ACCOUNT_NAME} (dev mode).`;
}
