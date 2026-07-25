// Pure, framework-free state for the persistent account badge in the
// sidebar header (founder direction, verbatim: "Somewhere should show the
// small logged user, since the user is not logged in yet, it should at
// least show a placeholder, with a menu for logout, or preferences,
// billing, etc."). This is a SECOND, always-visible surface reading the
// SAME settings-table state `onboarding/authGateState.ts` already owns and
// persists (`AuthGate.tsx`'s fake sign-in) — it never duplicates that
// module's reducer/persistence logic, only adds the two small derivations
// this always-on chrome needs on top of it: what the badge's avatar shows,
// and which menu rows are enabled. See `components/AccountBadge.tsx` for
// the component this backs.
import { personaLabel } from "../onboarding/authGateState";

/** The badge's display-relevant slice of auth state, derived from the same
 * two raw settings values `describeAuthSummary` already reads
 * (`AUTH_SIGNED_IN_SETTING_KEY`/`AUTH_PERSONA_SETTING_KEY`) — kept as its
 * own small struct here rather than reusing that function's plain-string
 * output, since the badge needs the persona label as data (to derive the
 * avatar's initial), not just baked into a sentence. */
export interface AccountBadgeState {
  signedIn: boolean;
  /** Non-null only when signed in AND a persona was actually captured —
   * `null` covers both "not signed in" and "signed in but skipped the
   * personalize question", same as `personaLabel`'s own "no answer"
   * convention. */
  personaLabel: string | null;
}

export function deriveAccountBadgeState(signedInRaw: string | null, personaRaw: string | null): AccountBadgeState {
  const signedIn = signedInRaw === "true";
  return { signedIn, personaLabel: signedIn ? personaLabel(personaRaw) : null };
}

/** The one-letter "avatar" the badge shows when there's a real persona to
 * initial from; `null` tells `AccountBadge.tsx` to fall back to the
 * generic person-silhouette glyph instead — the not-signed-in placeholder
 * Bruno's own words call for, and (styled filled rather than outlined) the
 * same glyph's reuse for a signed-in user who skipped the personalize
 * question, since the fake sign-in never captures a real name to initial
 * from either way. */
export function accountBadgeInitial(state: AccountBadgeState): string | null {
  if (!state.personaLabel) return null;
  return state.personaLabel.charAt(0).toUpperCase();
}

// ------------------------------------------------------------ menu items

export type AccountMenuItemId = "preferences" | "billing" | "sign-in" | "log-out";

export interface AccountMenuItem {
  id: AccountMenuItemId;
  label: string;
  enabled: boolean;
  /** Shown next to a disabled row — the not-signed-in gating hint a real
   * app would show ("Preferences"/"Billing" stay visible but inert until
   * there's an account behind them, matching the task's own framing). */
  hint?: string;
}

const GATED_HINT = "Sign in to access";

/** The account menu's contents for each auth state — the same three
 * "realistic account menu" rows either way (Preferences, Billing, plus a
 * sign-in/out row), just with Preferences/Billing disabled-and-hinted and
 * "Log out" swapped for "Sign in" when nobody's signed in. Row order is
 * stable across both states so the menu doesn't visually reshuffle the
 * instant a fake sign-in resolves. */
export function accountMenuItems(signedIn: boolean): AccountMenuItem[] {
  return [
    { id: "preferences", label: "Preferences", enabled: signedIn, hint: signedIn ? undefined : GATED_HINT },
    { id: "billing", label: "Billing", enabled: signedIn, hint: signedIn ? undefined : GATED_HINT },
    signedIn
      ? { id: "log-out", label: "Log out", enabled: true }
      : { id: "sign-in", label: "Sign in", enabled: true },
  ];
}
