// **The window's title bar.** Where you are on the left and notifications
// hard against the right edge. The account row lives in the sidebar.
//
// Notifications remain in the overlay title bar, level with the traffic
// lights, with their popover hanging from it.
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
//    stops at clickable elements, so the notifications <button> still
//    clicks instead of dragging (tauri 2.11.5, `src/window/scripts/drag.js`).
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
import type { NotificationEntry } from "../state/notifications";
import type { ReviewStatus } from "../lib/tauri";
import omniAgentLogo from "../assets/omniagent-logo.png";

interface AppChromeProps {
  projectLabel: string | null;
  sessionLabel: string | null;
  sessionTerminalCount?: number | null;
  /** Aggregate git status for the visible project — shown as a compact
   * `N files +added -removed` pill in the top-right corner, giving the
   * user a repo-level change count at a glance without opening the panel. */
  gitStatus?: ReviewStatus | null;
  notifications: NotificationEntry[];
  liveSessionIds: string[];
  knownProjectIds: string[];
  selectedProjectId: string | null;
  selectedProjectLabel: string | null;
  onNotificationsOpened: () => void;
  onSelectNotification: (entry: NotificationEntry) => void;
  onDismissNotification: (id: string) => void;
  onClearNotifications: () => void;
  /** Session ids whose **current** status is `awaiting_approval`. */
  awaitingSessionIds: string[];
  onApproveNotification: (entry: NotificationEntry) => void;
}

export default function AppChrome({
  projectLabel,
  sessionLabel,
  sessionTerminalCount = null,
  gitStatus = null,
  notifications,
  liveSessionIds,
  knownProjectIds,
  selectedProjectId,
  selectedProjectLabel,
  onNotificationsOpened,
  onSelectNotification,
  onDismissNotification,
  onClearNotifications,
  awaitingSessionIds,
  onApproveNotification,
}: AppChromeProps) {
  return (
    // `deep`: drag from anywhere in here that isn't a control — see this
    // file's module doc for why the bare attribute would leave most of the
    // bar dead.
    <header className="app-chrome" data-tauri-drag-region="deep">
      <div className="app-chrome-center">
        <div className="app-chrome-chip">
          <img src={omniAgentLogo} alt="" width="13" height="13" className="app-chrome-chip-logo" />
          <div className="app-chrome-breadcrumb">
            <span className="app-chrome-project">{projectLabel ?? "OmniAgent"}</span>
            {sessionLabel && (
              <>
                <span className="app-chrome-separator">/</span>
                <span className="app-chrome-session">{sessionLabel}</span>
              </>
            )}
            {typeof sessionTerminalCount === "number" && sessionTerminalCount > 0 && (
              <span className="app-chrome-terminal-count">
                {sessionTerminalCount} terminal{sessionTerminalCount === 1 ? "" : "s"}
              </span>
            )}
          </div>
        </div>
      </div>

      <div className="app-chrome-spacer" />
      <div className="app-chrome-actions">
        {gitStatus && gitStatus.file_count > 0 && (
          <span
            className="app-chrome-git-status"
            title={`${gitStatus.file_count} uncommitted change${gitStatus.file_count === 1 ? "" : "s"} on ${gitStatus.branch ?? "detached HEAD"}`}
          >
            <span className="app-chrome-git-files">{gitStatus.file_count}</span>
            <span className="app-chrome-git-add">+{gitStatus.added}</span>
            <span className="app-chrome-git-del">-{gitStatus.removed}</span>
          </span>
        )}
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
          awaitingSessionIds={awaitingSessionIds}
          onApprove={onApproveNotification}
        />
      </div>
    </header>
  );
}
