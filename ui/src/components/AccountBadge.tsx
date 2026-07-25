// The persistent, always-visible account affordance — founder direction,
// verbatim: "Somewhere should show the small logged user, since the user
// is not logged in yet, it should at least show a placeholder, with a
// menu for logout, or preferences, billing, etc." Lives in the sidebar
// header's action row (`Sidebar.tsx`'s `.sidebar-header-actions`, right
// alongside the "+"/import/files triggers) — the one piece of chrome
// that's on screen in every state of the app, unlike `AuthGate.tsx`
// (shown once, dismissible) or `AboutPanel.tsx` (opened on demand).
//
// A SECOND surface reading the SAME `onboarding/authGateState.ts` settings
// `AuthGate.tsx` itself drives — never a competing source of truth, never
// a second reducer. `App.tsx` owns the actual `settingsGet`/`settingsSet`
// calls (same split as every other piece of lifted state in this app,
// e.g. `fileTreeVisible`); this component is purely prop-driven, exactly
// like `PaneMenu.tsx`/`ProjectMenu.tsx` — it never touches Tauri itself,
// which is also why its own tests never need to mock `settingsGet`.
//
// "Sign in" (not signed in) and "Log out" (signed in) both call the exact
// same `onResetAuthGate` prop `App.tsx` already built for `AboutPanel`'s
// former reset control (see that component's module doc for why it lost
// its own copy of this action) — clearing the persisted fake-sign-in
// outcome and re-showing `AuthGate` is EXACTLY what both actions mean
// today, since there's no real account system behind either one yet.
import { useState } from "react";
import {
  accountBadgeInitial,
  accountMenuItems,
  deriveAccountBadgeState,
  type AccountMenuItemId,
} from "../state/accountBadgeState";
import { describeAuthSummary } from "../onboarding/authGateState";

interface AccountBadgeProps {
  signedInRaw: string | null;
  personaRaw: string | null;
  /** Reuses `App.tsx`'s existing reset-and-redo action — see module doc. */
  onResetAuthGate: () => void;
}

/** Generic person silhouette — the "clearly neutral 'not signed in'
 * placeholder" Bruno's own words call for, and (filled instead of
 * outlined) doubles as the signed-in-but-no-persona avatar too, since the
 * fake sign-in never captures a real name to initial from either way.
 * Inline SVG, same rationale as `FileIcon.tsx`'s own module doc: no asset
 * pipeline, crisp at any size, `currentColor` inherits whichever tone the
 * trigger button's own CSS state (`.is-signed-in` or not) sets. */
function PersonGlyph({ filled }: { filled: boolean }) {
  return (
    <svg width="14" height="14" viewBox="0 0 14 14" aria-hidden="true">
      <circle cx="7" cy="4.6" r="2.3" fill={filled ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.1" />
      <path
        d="M2.35 12.2c0-2.6 2.05-4.3 4.65-4.3s4.65 1.7 4.65 4.3"
        fill={filled ? "currentColor" : "none"}
        stroke="currentColor"
        strokeWidth="1.1"
        strokeLinecap="round"
      />
    </svg>
  );
}

export default function AccountBadge({ signedInRaw, personaRaw, onResetAuthGate }: AccountBadgeProps) {
  const [open, setOpen] = useState(false);
  // Preferences/Billing are explicitly out of scope as real surfaces (the
  // task's own framing) — an honest "Coming soon" note beats either a
  // silently dead button or a fake settings screen. Cleared whenever the
  // menu closes so it never survives to the next time it's opened.
  const [comingSoon, setComingSoon] = useState<AccountMenuItemId | null>(null);

  const state = deriveAccountBadgeState(signedInRaw, personaRaw);
  const initial = accountBadgeInitial(state);
  const items = accountMenuItems(state.signedIn);
  const summary = describeAuthSummary(signedInRaw, personaRaw);

  function close() {
    setOpen(false);
    setComingSoon(null);
  }

  function handleItemClick(id: AccountMenuItemId) {
    if (id === "sign-in" || id === "log-out") {
      onResetAuthGate();
      close();
      return;
    }
    setComingSoon(id);
  }

  return (
    <div className="account-badge-anchor">
      <button
        type="button"
        className={`account-badge-trigger${state.signedIn ? " is-signed-in" : ""}`}
        onClick={() => setOpen((o) => !o)}
        aria-haspopup="menu"
        aria-expanded={open}
        aria-label={summary}
        title={summary}
      >
        {initial ? (
          <span className="account-badge-initial" aria-hidden="true">
            {initial}
          </span>
        ) : (
          <PersonGlyph filled={state.signedIn} />
        )}
      </button>

      {open && (
        <>
          <div className="account-menu-backdrop" onMouseDown={close} />
          <div className="account-menu" role="menu" aria-label="Account" onMouseDown={(e) => e.stopPropagation()}>
            <div className="account-menu-summary">{summary}</div>
            <ul className="account-menu-list">
              {items.map((item) => (
                <li key={item.id}>
                  <button
                    type="button"
                    role="menuitem"
                    className="account-menu-row"
                    disabled={!item.enabled}
                    onClick={() => handleItemClick(item.id)}
                  >
                    <span className="account-menu-row-label">{item.label}</span>
                    {item.hint && <span className="account-menu-row-hint">{item.hint}</span>}
                  </button>
                  {comingSoon === item.id && <p className="account-menu-coming-soon">Coming soon.</p>}
                </li>
              ))}
            </ul>
          </div>
        </>
      )}
    </div>
  );
}
