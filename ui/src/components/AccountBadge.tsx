// The persistent, always-visible account affordance — founder direction,
// verbatim: "Somewhere should show the small logged user, since the user is
// not logged in yet, it should at least show a placeholder, with a menu for
// logout, or preferences, billing, etc.", then on 2026-07-26: "and here's
// the user menu: [screenshot]" (docs/reference/warp-user-menu.png) and "I
// know that we didn't implement the login part yet, so just make a fake one
// as if I was logged in as BrunoBonando."
//
// Lives in the app's top-right chrome (`AppChrome.tsx`) beside the
// notifications badge — the position both reference screenshots show, and
// the one piece of chrome on screen in every state of the app, unlike
// `AuthGate.tsx` (shown once) or `AboutPanel.tsx` (opened on demand). It
// moved there from the sidebar header when the notifications badge arrived:
// the two belong together, and a 240px sidebar header already carried five
// controls.
//
// A SECOND surface reading the SAME `onboarding/authGateState.ts` settings
// `AuthGate.tsx` drives — never a competing source of truth, never a second
// reducer. `App.tsx` owns the `settingsGet`/`settingsSet` calls; this
// component is prop-driven for its auth state, exactly like `PaneMenu.tsx`/
// `ProjectMenu.tsx`.
//
// ## What its rows actually do
//
// `state/accountBadgeState.ts` owns that contract as data (`kind:
// "action" | "placeholder" | "auth"`) and its module doc explains which of
// the reference's rows were wired, which stayed honest placeholders, and
// which were omitted rather than faked. The two real ones are handled here:
//
// - **Keyboard shortcuts** opens `KeyboardShortcutsSheet` — real bindings,
//   listed from the one pure module that holds them.
// - **View session logs** reveals the transcripts folder in Finder through
//   the same `revealItemInDir` the file tree already uses. The path is
//   derived in the frontend (`~/Library/Application Support/OmniAgent-ADE/
//   transcripts`, per `brain_core::Store::default_data_dir`) because no
//   command exposes the data dir; the one case that misses is a dev run
//   with `OMNIAGENT_ADE_DATA_DIR` overridden, which surfaces as an honest
//   "couldn't open" line rather than a silent no-op.
import { useState } from "react";
import { homeDir, join } from "@tauri-apps/api/path";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import {
  accountBadgeInitial,
  accountBadgeSubtitle,
  accountMenuItems,
  deriveAccountBadgeState,
  type AccountMenuItemId,
} from "../state/accountBadgeState";
import KeyboardShortcutsSheet from "./KeyboardShortcutsSheet";

interface AccountBadgeProps {
  signedInRaw: string | null;
  personaRaw: string | null;
  /** Reuses `App.tsx`'s existing reset-and-redo action — the fake sign-in's
   * only real mutation, shared by the "Sign in" and "Log out" rows. */
  onResetAuthGate: () => void;
}

/** `Store::default_data_dir`'s macOS location, mirrored — see the module
 * doc for why this is derived here and what that costs. */
const TRANSCRIPTS_RELATIVE_PATH = ["Library", "Application Support", "OmniAgent-ADE", "transcripts"];

/** Generic person silhouette — the "clearly neutral 'not signed in'
 * placeholder" Bruno's own words call for. Inline SVG, same rationale as
 * `FileIcon.tsx`: no asset pipeline, crisp at any size, `currentColor`
 * inherits whichever tone the trigger's CSS state sets. */
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
  // Preferences/Billing have no real surface behind them yet — an honest
  // "Coming soon" note beats a silently dead button or a fake settings
  // screen. Cleared whenever the menu closes.
  const [comingSoon, setComingSoon] = useState<AccountMenuItemId | null>(null);
  const [shortcutsOpen, setShortcutsOpen] = useState(false);
  const [revealError, setRevealError] = useState<string | null>(null);

  const state = deriveAccountBadgeState(signedInRaw, personaRaw);
  const initial = accountBadgeInitial(state);
  const items = accountMenuItems(state.signedIn);
  const subtitle = accountBadgeSubtitle(state);
  const name = state.displayName ?? "Not signed in";

  function close() {
    setOpen(false);
    setComingSoon(null);
    setRevealError(null);
  }

  async function revealTranscripts() {
    try {
      const home = await homeDir();
      const path = await join(home, ...TRANSCRIPTS_RELATIVE_PATH);
      await revealItemInDir(path);
      close();
    } catch (err) {
      console.error("failed to reveal the transcripts folder", err);
      setRevealError("No session logs on this machine yet.");
    }
  }

  function handleItemClick(id: AccountMenuItemId) {
    setRevealError(null);
    if (id === "sign-in" || id === "log-out") {
      onResetAuthGate();
      close();
      return;
    }
    if (id === "keyboard-shortcuts") {
      setShortcutsOpen(true);
      close();
      return;
    }
    if (id === "view-logs") {
      void revealTranscripts();
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
        aria-label={`${name} — account menu`}
        title={name}
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
            <div className="account-menu-identity">
              <span className="account-menu-name">{name}</span>
              <span className="account-menu-summary">{subtitle}</span>
            </div>
            <ul className="account-menu-list">
              {items.map((item) => (
                <li key={item.id} className={item.separatorBefore ? "has-separator" : undefined}>
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
                  {revealError && item.id === "view-logs" && (
                    <p className="account-menu-coming-soon">{revealError}</p>
                  )}
                </li>
              ))}
            </ul>
          </div>
        </>
      )}

      {shortcutsOpen && <KeyboardShortcutsSheet onClose={() => setShortcutsOpen(false)} />}
    </div>
  );
}
