// Pure, framework-free state for the account badge + its menu (founder
// direction: "Somewhere should show the small logged user… with a menu for
// logout, or preferences, billing, etc.", then 2026-07-26: "and here's the
// user menu: [Warp screenshot]" + "I know that we didn't implement the login
// part yet, so just make a fake one as if I was logged in as
// BrunoBonando."). This is a SECOND, always-visible surface reading the SAME
// settings-table state `onboarding/authGateState.ts` owns and persists — it
// never duplicates that module's reducer/persistence logic, only adds the
// derivations this chrome needs: who the badge says you are, and which menu
// rows do something.
//
// ## What's in the menu, and what deliberately isn't
//
// The reference (docs/reference/warp-user-menu.png) lists: name · update and
// relaunch · what's new · settings · keyboard shortcuts · documentation ·
// feedback · view logs · community · upgrade · invite a friend · log out.
// Most of those describe a shipped commercial product with a website, a
// release channel and a paid tier. OmniAgent ADE is a local-first beta with
// none of those, and this codebase's standing rule is that a control either
// does the thing it says or says it doesn't do it yet — so the menu adapts
// rather than mimics:
//
// - **Wired, genuinely** — "Keyboard shortcuts" (this app has real ⌘T/⌘K/⌘N
//   bindings and a sheet listing them is useful today), "View logs" (session
//   transcripts are real files on disk under the app's data dir; the row
//   reveals that folder in Finder through the same `revealItemInDir` the
//   file tree already uses), and "Log out" (the existing fake-auth reset).
// - **Honest placeholder** — "Preferences" and "Billing", which were already
//   handled this way ("Coming soon") before this menu grew.
// - **Omitted, not faked** — update/relaunch (no updater), what's new (no
//   changelog surface), documentation (no docs site), feedback (no channel),
//   community (no community), upgrade + invite a friend (DESIGN.md §1: "v1
//   monetization: none"). A row that opened nothing, or worse a fabricated
//   page, would be exactly the fake functionality this project refuses.
import { FAKE_ACCOUNT_NAME, personaLabel, resolveSignedIn } from "../onboarding/authGateState";
import type { IngestionStatus } from "../lib/tauri";

/** The badge's display-relevant slice of auth state, derived from the same
 * two raw settings values `describeAuthSummary` reads
 * (`AUTH_SIGNED_IN_SETTING_KEY`/`AUTH_PERSONA_SETTING_KEY`). */
export interface AccountBadgeState {
  signedIn: boolean;
  /** Non-null only when signed in AND a persona was actually captured —
   * `null` covers both "not signed in" and "signed in but skipped the
   * personalize question", same as `personaLabel`'s own convention. */
  personaLabel: string | null;
  /** Who the menu's header row names. The fake dev identity while signed
   * in (see `FAKE_ACCOUNT_NAME`), `null` when not — never a guess. */
  displayName: string | null;
}

export function deriveAccountBadgeState(signedInRaw: string | null, personaRaw: string | null): AccountBadgeState {
  const signedIn = resolveSignedIn(signedInRaw);
  return {
    signedIn,
    personaLabel: signedIn ? personaLabel(personaRaw) : null,
    displayName: signedIn ? FAKE_ACCOUNT_NAME : null,
  };
}

/** The one-letter "avatar": the signed-in user's initial (B for Bruno
 * Bonando), `null` when signed out — which tells `AccountBadge.tsx` to fall
 * back to the generic person-silhouette placeholder instead. */
export function accountBadgeInitial(state: AccountBadgeState): string | null {
  if (!state.displayName) return null;
  return state.displayName.charAt(0).toUpperCase();
}

/** The line under the name in the menu header: the captured persona while
 * we have one, else an honest note that this identity isn't real yet. */
export function accountBadgeSubtitle(state: AccountBadgeState): string {
  if (!state.signedIn) return "Not signed in (dev mode).";
  return state.personaLabel ?? "Signed in (dev mode).";
}

// -------------------------------------------------------------- brain line

/** The account row's other sub-line (design §2 "Brain indexed · 8m ago") —
 * a SECOND, independent status under the name, alongside `accountBadgeSubtitle`
 * above. Reads `IngestionStatus` (`lib/tauri.ts`, polled by `App.tsx`) plus
 * `lastIndexedAt`, which `Sidebar.tsx` tracks itself (session-local, see its
 * own comment) since no backend surface persists "when did ingestion last
 * finish cleanly" today. */
export interface BrainLine {
  text: string;
  tone: "good" | "busy" | "idle" | "error";
}

/** `lastIndexedAt`/`now` are epoch ms; `now` is injected rather than read
 * from `Date.now()` here so this stays a pure, deterministic function to
 * test. Precedence: a running ingest or a surfaced error always wins over
 * whatever `lastIndexedAt` says, since those are the current truth. */
export function brainLine(
  ingestion: IngestionStatus | null,
  lastIndexedAt: number | null,
  now: number,
): BrainLine {
  if (ingestion?.error) return { text: "Ingest failed — open About to rebuild", tone: "error" };
  if (ingestion?.running) {
    return { text: `Ingesting · ${ingestion.projects_done} of ${ingestion.projects_total} projects`, tone: "busy" };
  }
  if (lastIndexedAt == null) return { text: "Nothing indexed yet", tone: "idle" };
  const mins = Math.max(0, Math.floor((now - lastIndexedAt) / 60_000));
  const rel = mins < 1 ? "just now" : mins < 60 ? `${mins}m ago` : `${Math.floor(mins / 60)}h ago`;
  return { text: `Brain indexed · ${rel}`, tone: "good" };
}

// ------------------------------------------------------------ menu items

export type AccountMenuItemId =
  | "preferences"
  | "keyboard-shortcuts"
  | "view-logs"
  | "review"
  | "about"
  | "billing"
  | "sign-in"
  | "log-out";

/** What a row actually does when clicked — the honesty contract, as data:
 * `action` rows do a real thing, `placeholder` rows say "Coming soon", and
 * `auth` rows run the fake sign-in/out reset. Nothing else exists. */
export type AccountMenuItemKind = "action" | "placeholder" | "auth";

export interface AccountMenuItem {
  id: AccountMenuItemId;
  label: string;
  kind: AccountMenuItemKind;
  enabled: boolean;
  /** Shown next to a disabled row — why it's inert. */
  hint?: string;
  /** Draw a divider above this row (the reference groups its items). */
  separatorBefore?: boolean;
}

const GATED_HINT = "Sign in to access";

/**
 * The menu's contents for each auth state. Row order is stable across both
 * states so the menu doesn't visually reshuffle the instant a sign-in
 * resolves; only the account-gated rows' enablement and the final
 * sign-in/log-out row change.
 *
 * "Keyboard shortcuts" and "View logs" are enabled in BOTH states on
 * purpose: they're facts about this machine's app, not about an account,
 * and gating them behind a sign-in that doesn't exist yet would be theatre.
 */
export function accountMenuItems(signedIn: boolean): AccountMenuItem[] {
  return [
    {
      id: "preferences",
      label: "Preferences",
      kind: "placeholder",
      enabled: signedIn,
      hint: signedIn ? undefined : GATED_HINT,
    },
    { id: "keyboard-shortcuts", label: "Keyboard shortcuts", kind: "action", enabled: true },
    { id: "view-logs", label: "View session logs", kind: "action", enabled: true },
    { id: "review", label: "Review session summaries", kind: "action", enabled: true },
    { id: "about", label: "About OmniAgent ADE", kind: "action", enabled: true },
    {
      id: "billing",
      label: "Billing",
      kind: "placeholder",
      enabled: signedIn,
      hint: signedIn ? undefined : GATED_HINT,
      separatorBefore: true,
    },
    signedIn
      ? { id: "log-out", label: "Log out", kind: "auth", enabled: true, separatorBefore: true }
      : { id: "sign-in", label: "Sign in", kind: "auth", enabled: true, separatorBefore: true },
  ];
}
