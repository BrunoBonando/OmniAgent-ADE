// **The window's title bar.** Where you are on the left, notifications and
// the account badge hard against the right edge.
//
// Founder, 2026-07-26, verbatim: *"The user and notification menu must be
// on the title of the application, just like warp does."* Both of his
// reference screenshots (docs/reference/warp-notifications-panel.png,
// warp-user-menu.png) show the same far-right cluster living in Warp's own
// title bar, level with the traffic lights, with both popovers hanging from
// it.
//
// ## This is a window-decoration change, not CSS
//
// A web page cannot draw into a native title bar by asking nicely.
// `tauri.conf.json` sets **`titleBarStyle: "Overlay"`** on the main window,
// which is `titlebarAppearsTransparent + fullSizeContentView` underneath
// (tauri-runtime-wry 2.11.4): the webview extends to the very top of the
// window, and AppKit paints the traffic lights and the window title over
// it. So this component *is* the title bar — everything below it starts at
// y=28.
//
// Three consequences that are all load-bearing:
//
// 1. **The strip stopped costing anything.** It used to be a 30px row
//    *underneath* an opaque 28px native title bar — 58px of chrome before
//    the app began. Now it occupies the title bar itself, so the whole 30px
//    goes back to the workspace. This is why the height below is pinned to
//    the native title bar's own 28px rather than being a number of our
//    choosing: match it and the traffic lights sit naturally centred in our
//    row, with no `trafficLightPosition` fiddling to go wrong.
// 2. **`data-tauri-drag-region="deep"` is the only thing that still moves
//    the window**, since our content now covers the area AppKit used to
//    handle. "deep" rather than the bare attribute on purpose: bare means
//    "only clicks landing on this exact element", which would leave every
//    click on the breadcrumb — the widest part of the bar — doing nothing.
//    `deep` drags from anywhere in the subtree, and Tauri's own handler
//    stops at clickable elements, so the two <button> triggers below still
//    click instead of dragging (tauri 2.11.5, `src/window/scripts/drag.js`).
//    The matching `core:window:allow-start-dragging` grant is *not* part of
//    `core:window:default` and had to be added explicitly — see the Rust
//    test that locks it.
// 3. **The centre of the bar is not ours.** AppKit draws the window title
//    (`OmniAgent — v0.1.0`, set at runtime — see `lib.rs`'s `window_title`)
//    centred across the full window width, on top of this row. The
//    breadcrumb is therefore held to the left with a hard `max-width` so a
//    long workspace name can never run into it, and nothing of ours is
//    allowed in the middle.
//
// DESIGN.md's rule that chrome must not compete with the terminal workspace
// still holds, and is easier to keep now: this is one quiet row on the app
// background, no panel fill, no shadow, a hairline underneath, holding
// exactly three things — not a toolbar that will accumulate buttons.
//
// The left-hand breadcrumb is the smallest honest use of the space that
// would otherwise be empty: the project and session you're currently in,
// derived in `App.tsx` from `visibleSessionGroupId` — the same answer the
// sidebar's accent rail and the pane grid use, so all three name the same
// session. It answers "which session am I on" from anywhere on screen,
// including the map view.
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
    // `deep`: drag from anywhere in here that isn't a control — see this
    // file's module doc for why the bare attribute would leave most of the
    // bar dead.
    <header className="app-chrome" data-tauri-drag-region="deep">
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
