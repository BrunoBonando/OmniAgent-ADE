// The app's top chrome strip: where you are on the left, notifications and
// the account badge on the right.
//
// Both of Bruno's 2026-07-26 reference screenshots
// (docs/reference/warp-notifications-panel.png, warp-user-menu.png) put the
// notifications badge and the user avatar together in the window's top
// right, and both popovers hang from there. This app had no top-right
// chrome at all — the account badge was squeezed into the 240px sidebar
// header next to the "+"/import/files/pressure controls — so this strip is
// that missing surface, and the badge moved here rather than the two
// related controls being split across two corners.
//
// It costs 30px of height, which is the one real trade-off: DESIGN.md's
// principle that chrome must not compete with the terminal workspace is why
// this is a single quiet row on the app background (no panel fill, no
// shadow, hairline underneath) holding exactly three things and nothing
// else — not a toolbar that will accumulate buttons.
//
// The left-hand breadcrumb is the smallest honest use of the space that
// would otherwise be empty: the project and session you're currently in,
// derived in `App.tsx` from the same `groupTabsBySession` the sidebar
// renders its tree from. It answers "which session am I on" from anywhere
// on screen, including the map view.
import NotificationsPanel from "./NotificationsPanel";
import AccountBadge from "./AccountBadge";
import type { NotificationEntry } from "../state/notifications";

interface AppChromeProps {
  projectLabel: string | null;
  sessionLabel: string | null;
  notifications: NotificationEntry[];
  liveSessionIds: string[];
  knownProjectIds: string[];
  selectedProjectId: string | null;
  selectedProjectLabel: string | null;
  onNotificationsOpened: () => void;
  onSelectNotification: (entry: NotificationEntry) => void;
  onDismissNotification: (id: string) => void;
  onClearNotifications: () => void;
  authSignedIn: string | null;
  authPersona: string | null;
  onResetAuthGate: () => void;
}

export default function AppChrome({
  projectLabel,
  sessionLabel,
  notifications,
  liveSessionIds,
  knownProjectIds,
  selectedProjectId,
  selectedProjectLabel,
  onNotificationsOpened,
  onSelectNotification,
  onDismissNotification,
  onClearNotifications,
  authSignedIn,
  authPersona,
  onResetAuthGate,
}: AppChromeProps) {
  return (
    <header className="app-chrome">
      <div className="app-chrome-breadcrumb">
        {projectLabel && (
          <>
            <span className="app-chrome-project">{projectLabel}</span>
            {sessionLabel && (
              <>
                <span className="app-chrome-separator" aria-hidden="true">
                  ·
                </span>
                <span className="app-chrome-session">{sessionLabel}</span>
              </>
            )}
          </>
        )}
      </div>
      <div className="app-chrome-actions">
        <NotificationsPanel
          entries={notifications}
          liveSessionIds={liveSessionIds}
          knownProjectIds={knownProjectIds}
          selectedProjectId={selectedProjectId}
          selectedProjectLabel={selectedProjectLabel}
          onOpened={onNotificationsOpened}
          onSelect={onSelectNotification}
          onDismiss={onDismissNotification}
          onClearAll={onClearNotifications}
        />
        <AccountBadge signedInRaw={authSignedIn} personaRaw={authPersona} onResetAuthGate={onResetAuthGate} />
      </div>
    </header>
  );
}
