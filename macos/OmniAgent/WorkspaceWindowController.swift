import AppKit
import os.signpost
import SwiftTerm

final class WorkspaceWindow: NSWindow {
    /// Click-to-focus: whichever pane ends up holding the first responder
    /// becomes the focused pane, without the panes having to fight SwiftTerm
    /// for the mouse event.
    var onFirstResponderChange: ((NSResponder?) -> Void)?

    /// Returns true when the window consumed the key.
    var onEscape: (() -> Bool)?

    /// `NSEvent.keyCode` for the escape key — AppKit has no named constant.
    /// Not `private`: `isPlainEscape` below is exercised directly from
    /// tests, since a realistic key-down `NSEvent` paired with a real
    /// field-editor first responder is not something worth synthesising.
    static let escapeKeyCode: UInt16 = 53

    /// The pure predicate behind the interception below, kept free of
    /// `NSEvent`/first-responder so it is directly testable. `isEditingText`
    /// is the field-editor exclusion `sendEvent`'s comment explains: an
    /// active sidebar rename or the files-tree filter field already forwards
    /// a bare esc to its own `cancelOperation`, and must keep it.
    static func isPlainEscape(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isEditingText: Bool
    ) -> Bool {
        !isEditingText
            && keyCode == escapeKeyCode
            && modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
    }

    override func sendEvent(_ event: NSEvent) {
        // esc never reaches the responder chain as `cancelOperation(_:)`
        // here: the first responder is SwiftTerm's `TerminalView`, which
        // consumes the key itself and writes `\u{1b}` straight to the PTY.
        // Catching it one level up, in `sendEvent`, is the only place left
        // to ask before SwiftTerm does. `onEscape` returning false lets the
        // event fall through to the terminal exactly as before — a terminal
        // that cannot send escape is a broken terminal, and that is the
        // whole risk of this feature.
        //
        // But `sendEvent` runs *before* the responder chain, so left
        // unguarded it would just as happily steal esc from anything else
        // with focus — including an active field editor. A sidebar rename
        // (`SessionRowView` in `WorkspaceShell.swift`) and
        // the files tree's filter field (`WorkspaceFilesTreeView.filterField`,
        // `ReviewPanelFilesView.swift`) both call `window.makeFirstResponder` on a plain
        // `NSTextField`, which installs the shared field editor — a genuine
        // `NSTextView` with `isFieldEditor == true` — as `firstResponder` and
        // routes esc to their own `control(_:textView:doCommandBy:)` to
        // cancel the edit. Stolen here instead, the edit stays live and a
        // later click commits whatever the user tried to discard.
        // `TerminalView` never sets `isFieldEditor`, so this exclusion is
        // specific to real editors, not to any one view or file — the
        // command palette's own search field, for contrast, lives in its own
        // `NSPanel` and is never reached through this window's `sendEvent`
        // at all, so it was never at risk here.
        let isEditingText = (firstResponder as? NSTextView)?.isFieldEditor == true
        if event.type == .keyDown,
           Self.isPlainEscape(keyCode: event.keyCode, modifierFlags: event.modifierFlags, isEditingText: isEditingText),
           onEscape?() == true {
            return
        }
        if event.type == .keyDown,
           let terminal = firstResponder as? NativeTerminalView,
           terminal.interceptKeyDown(event) {
            return
        }
        if event.type == .keyDown, firstResponder is TerminalView {
            os_signpost(
                .event,
                log: Instrumentation.log,
                name: "Latency.KeyboardReceipt",
                "keyCode=%d",
                event.keyCode
            )
        }
        super.sendEvent(event)
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let accepted = super.makeFirstResponder(responder)
        if accepted { onFirstResponderChange?(firstResponder) }
        return accepted
    }
}

/// Owns the window, the connection, and the session lifecycle of every pane in
/// the workspace. Layout, pane identity and focus belong to `PaneWorkspaceView`;
/// creating, attaching and killing sessions belongs here.
final class WorkspaceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let connection: SessionConnection
    private let workspace: PaneWorkspaceView
    /// The pane rectangle. Reachable because the window's content view is now
    /// a split view — the workspace is one half of it, not the whole thing.
    var workspaceView: PaneWorkspaceView { workspace }
    /// The flat Copilot-style sidebar (the 2026-08-20 redesign). It draws the
    /// workspaces tree itself — the session rows carry per-pane status dots
    /// and inline rename, neither of which an `NSOutlineView` cell can lay
    /// out that way. `SessionOutline`'s grouping rules live on and are what
    /// the tree is built from.
    let shellSidebar = NavigationSidebarView()
    /// The content half of the split: the pane workspace and the placeholder
    /// both live here permanently, and the destination only toggles which is
    /// hidden. Unmounting `PaneWorkspaceView` would tear down live SwiftTerm
    /// views and their PTY attachment along with it.
    /// The column's ground as well as its container: a `PaneGroundView` paints
    /// the grey sheet behind the title-bar strip *and* the pane grid, so the
    /// two are one continuous surface (the title bar itself paints nothing).
    private let contentContainer = PaneGroundView()
    private let placeholder = WorkspacePlaceholderView()
    /// Home's real screen — the placeholder now only covers To Do List.
    /// Internal, not private: the tests assert its routing.
    let homeView = HomeSurfaceView()
    /// The in-window Settings page — the gear, ⌘, and the palette land here.
    let settingsView = SettingsSurfaceView()
    /// The window's drawn title bar — window buttons, the sidebar toggle, the
    /// review toggle. Replaced the `NSToolbar`, and paints nothing: it is a
    /// transparent overlay across the top of the split, so each column's own
    /// background reaches the window's top edge underneath it.
    let titleBar = WorkspaceTitleBarView()
    /// The running session's name. A subview of `contentContainer` rather than
    /// of the title bar, which is the whole trick: a sidebar collapse moves the
    /// content column, and a subview is carried by its superview's animation
    /// exactly, with nothing to keep in step.
    let sessionTitleField = ShellFont.label(
        "",
        font: ShellFont.ui(13, .medium),
        color: ShellPalette.inkSecondary
    )
    /// The split itself. `window.contentViewController` is a container that
    /// holds the title bar above it, so the old
    /// `contentViewController as? NSSplitViewController` no longer resolves —
    /// this is the way to it.
    private(set) var splitController: NSSplitViewController?
    /// The sidebar's split item, kept so its ceiling can follow the window —
    /// see `clampSidebarWidth`.
    private var sidebarWidthItem: NSSplitViewItem?

    /// Which destination is on screen. `applyDestination` is the only writer;
    /// ⌘↩ reads it because focus mode is about a terminal, and off Terminals the
    /// pane workspace is hidden entirely. Home, not Terminals: the first view
    /// after login must be Home.
    private(set) var destination: WorkspaceDestination = .home
    /// Everything `listProjects` last returned, and where a selected id is
    /// resolved back to a label and path.
    private(set) var workspaces: [BrainProjectSummary] = []
    /// The open workspace — what the sidebar's sessions tree is scoped to.
    /// `nil` means "none open".
    private(set) var selectedProjectID: String?
    /// What Home's own project/session dropdowns are pointed at. Starts
    /// empty on every launch — "Select workspace", nothing pre-picked —
    /// unless exactly one workspace is open, the only case where a default
    /// cannot be wrong. A pick from Home's own menu then sticks for as long
    /// as the app lives, and only ever touches this, never
    /// `selectedProjectID` itself: Home is for choosing what a session
    /// *would* start with, not for jumping to one — see
    /// `onRequestProjectMenu`'s own comment.
    private var homeSelectedProjectID: String?
    /// A folder picked from Home's own "Local folder or repository…" —
    /// pointed at, not added: no daemon root, no sidebar row, no session.
    /// The workspace becomes real only when Send creates a session in it
    /// (not wired yet — that step must call `addProject` + `startSession`
    /// and clear this). Until then it lists in Home's picker like any
    /// other workspace, and lives as long as the app does.
    private var homePendingFolder: BrainProjectSummary?
    let palette = CommandPaletteController()
    private var readySessions: Set<String> = []
    /// The `layout` read has been sent — a later reconnect must re-attach the
    /// panes that already exist rather than reading the row again and
    /// rebuilding them on top. Cleared again if the read *fails*, so the next
    /// reconnect retries rather than leaving the window degraded forever.
    private var layoutReadDispatched = false
    /// Orphan reaping is a once-per-launch cleanup, not a per-pane one.
    private var reapDispatched = false
    /// The `layout` read came back **successfully**. This, not
    /// `layoutReadDispatched`, is the write gate: the read is asynchronous,
    /// and a pane opened while it is in flight would otherwise derive a
    /// layout from a still-empty workspace and write `{"tabs":[]}` over a row
    /// nothing has read yet.
    private var layoutReadCompleted = false
    private var observedFirstOutput = false
    /// Status text per session — an exited, erroring or thinking pane keeps its
    /// own line instead of one window-wide string every pane overwrites. The
    /// title shows the *focused* pane's entry, so switching panes tells the
    /// truth about the pane you are looking at.
    private var sessionStatus: [String: String] = [:]
    /// Status that belongs to the connection rather than to any one session
    /// (connecting, reconnecting, transport errors). Outranks session status.
    private var connectionStatus: String?
    /// The last status each pane reported — what tells an approval's outcome
    /// apart from an unrelated status change. Cleared for a pane both when its
    /// session exits and when the user closes it (`closePane`), so it holds
    /// only live panes; `private(set)` so the test that pins that can see it.
    private(set) var lastStatus: [String: RemoteSessionStatus] = [:]
    /// When each pane last reported a status event (ms since epoch, the
    /// activity ledger's clock) — what the sidebar's "Last updated" grouping
    /// sorts by. Written and cleared strictly alongside `lastStatus`, so the
    /// pair can never disagree about which panes are live.
    private(set) var lastStatusEventAt: [String: Double] = [:]
    /// `lastStatus` remembers *what*; this remembers *when* and *how often* —
    /// when the current run of work began, how long a pane has been busy in
    /// total, how many tools it has run. The sidebar's hover card and the
    /// review panel's Insights header both read it.
    private(set) var activity = PaneActivityLedger()
    /// The ledger keeps totals; this keeps the *series* — every status hop
    /// with its timestamp, per pane, since launch — because the Insights
    /// timeline needs the when of each hop, not just the sums. Fed from the
    /// same `onStatus` fan-out (`recordNotification`), forgotten wherever
    /// the ledger forgets.
    private(set) var statusSeries = PaneStatusSeriesRecorder()
    /// Session groups, most-recently-focused first — the menu bar icon's
    /// "last active sessions" list. Fed from `onFocusedPaneChanged`, so it
    /// covers every way focus moves (click, sidebar, palette, notification),
    /// not just the ones this controller names. In-memory only: a natural
    /// order re-establishes itself within the first few clicks of a launch,
    /// and persisting it would be bookkeeping nobody asked for.
    private var recentSessionGroupIDs: [String] = []
    /// The card itself. Owned here rather than by the sidebar because it is a
    /// window, and a view cannot own one of those.
    let hoverCard = SessionHoverCardController()
    let notifier: SessionNotifier
    /// The notification feed's two flags, for exactly the reasons the layout's
    /// two above exist.
    private var notificationsReadDispatched = false
    private var notificationsReadCompleted = false
    /// The `browser_panes_native` row's two flags, same shape and same
    /// reasons as `layoutReadDispatched`/`layoutReadCompleted` — it is a
    /// separate row (see `SettingsKey.browserPanes`), read and armed
    /// independently of the shared `layout` row.
    private var browserPanesReadDispatched = false
    private var browserPanesReadCompleted = false
    /// The `editor_panes_native` row's two flags — same shape and same
    /// reasons as the browser pair above, and a separate row again (see
    /// `SettingsKey.editorPanes`): the web build rewrites the shared
    /// `layout` row and drops fields it does not know about.
    private var editorPanesReadDispatched = false
    private var editorPanesReadCompleted = false
    /// The pane that had focus when the app was last used, so a restart
    /// comes back to that session rather than to whichever pane happened to
    /// restore last. Native-local UI state the web build knows nothing about,
    /// so `UserDefaults` rather than a shared settings row — the same call
    /// `WorkspaceShell`'s divider position makes. Read once, at init: every
    /// pane a restore adds focuses itself on the way in, overwriting the
    /// stored value long before the restore is finished.
    static let lastFocusedPaneDefaultsKey = "LastFocusedPane"
    var lastFocusedPaneOnLaunch: String? = UserDefaults.standard
        .string(forKey: WorkspaceWindowController.lastFocusedPaneDefaultsKey)
    /// The last value written to each settings row — see `write(_:to:)`.
    private var lastPersisted: [String: String] = [:]
    /// Where settings writes go. `nil` means the daemon; a test substitutes a
    /// recorder so the write-suppression rule can be asserted without a
    /// socket, and without touching the developer's real `brain.db`.
    var settingsWriter: ((String, String) -> Void)?
    /// Test seams, `settingsWriter`'s pattern: nil means the real daemon
    /// call. What lets a test pin the lifecycle invariant — non-terminal
    /// pane ids never reach `ensureSession` (where a browser id would
    /// silently spawn a login shell) or `connection.kill` — without a socket.
    var sessionEnsurer: ((String) -> Void)?
    var sessionKiller: ((String) -> Void)?
    /// The context menu's Show in Finder. `nil` means the real
    /// `NSWorkspace` reveal; a test substitutes a recorder — the
    /// `externalLinkOpener` pattern for a filesystem path.
    var fileRevealer: ((String) -> Void)?
    /// The Remove-workspace confirmation, handed the workspace's display
    /// label and its session count. `nil` means "ask with an `NSAlert`"; a
    /// test substitutes an answer — `newSessionForLinkConfirmer`'s pattern.
    var workspaceRemovalConfirmer: ((String, Int, @escaping (Bool) -> Void) -> Void)?
    /// The Delete-session confirmation, handed the session's label and its
    /// pane count — `workspaceRemovalConfirmer`'s pattern.
    var sessionDeletionConfirmer: ((String, Int, @escaping (Bool) -> Void) -> Void)?
    /// The Open in… submenu's app detection (bundle id -> app URL) and
    /// launch (app URL, directory to open). `nil` means the real
    /// `NSWorkspace` on both — tests substitute a fixed catalogue and a
    /// recorder.
    var appLocator: ((String) -> URL?)?
    var appOpener: ((URL, String) -> Void)?

    // MARK: - Task 6b-2: settings/onboarding/usage/inspector

    let settingsStore: SettingsStore
    let usageRecorder = UsageAnalyticsRecorder()
    /// The shared project id -> label cache, built from `listProjects` —
    /// what fixes 6b-1 concern #3 ("project rows show ids, not labels") for
    /// the outline, the palette and the inspector alike, from one read.
    private(set) var projectLabels: [String: String] = [:]
    /// The `workspace_customizations_native` row, keyed by workspace path —
    /// the Customize… dialog's display names and folder colours.
    private(set) var workspaceCustomizations: [String: WorkspaceCustomization] = [:]
    /// The shared `closed_workspaces` row: the workspaces the user removed.
    /// Removal is the web build's close — sessions end, the row leaves the
    /// sidebar, the folder and the brain's graph stay untouched.
    private(set) var closedWorkspaceIDs: Set<String> = []
    /// Read/write gates for the two rows above — `layoutReadDispatched`'s
    /// shape and reasoning: a save before the read lands must not overwrite
    /// a row nothing has seen.
    private var customizationsReadDispatched = false
    private var customizationsReadCompleted = false
    private var closedWorkspacesReadDispatched = false
    private var closedWorkspacesReadCompleted = false
    /// The `session_meta_native` row, keyed by session group id — the
    /// session context menu's pins and nested-session parents.
    private(set) var sessionMeta: [String: SessionMeta] = [:]
    /// Its read/write gates, the pairs above's shape and reasoning.
    private var sessionMetaReadDispatched = false
    private var sessionMetaReadCompleted = false
    /// The `review_panel_native` row, keyed by session group id — the review
    /// panel's per-session state (open, tabs, active tab, width).
    private(set) var reviewPanelStates: [String: ReviewPanelSessionState] = [:]
    /// Its read/write gates, the pairs above's shape and reasoning.
    private var reviewPanelReadDispatched = false
    private var reviewPanelReadCompleted = false
    /// The panel view and its split item — the third `NSSplitViewItem`, on
    /// the right of the session content.
    let reviewPanel = ReviewPanelView()
    /// The Files tab's real content, mounted into the panel at init. One
    /// instance for the window; `syncReviewPanelFiles` re-points it at each
    /// session's own workspace and persisted state.
    let reviewPanelFiles = ReviewPanelFilesView()
    /// The Changes tab's real content — the same single-instance rule;
    /// `syncReviewPanelChanges` re-points it at each session's workspace and
    /// reloads its `git status` on every activation.
    let reviewPanelChanges = ReviewPanelChangesView()
    /// The Browser tab's real content — the same single-instance rule;
    /// `syncReviewPanelBrowser` rescans the showing session's terminals for
    /// dev-server ports on every activation.
    let reviewPanelBrowser = ReviewPanelBrowserView()
    /// The Insights tab's real content — the same single-instance rule;
    /// `syncReviewPanelInsights` re-reads the showing session's status
    /// series and ledger totals on activation and on every status event
    /// while the tab is showing.
    let reviewPanelInsights = ReviewPanelInsightsView()
    private(set) var reviewPanelItem: NSSplitViewItem?
    /// The session group whose state the panel is currently showing —
    /// updated on every `activeGroup` change, so a tab edit lands in the
    /// right session's entry even while the panel is closed.
    private var reviewPanelGroup: String?
    /// The width to give back when expand-to-full-width toggles off.
    /// Transient by design: the persisted `width` is the user's real one,
    /// and an expanded panel that survived a relaunch full-width would have
    /// swallowed the pane grid with no memory of why.
    private var reviewPanelWidthBeforeExpand: CGFloat?
    /// The Customize… card while one is up — window-scoped, so owned here.
    private(set) var customizeCard: WorkspaceCustomizeCard?
    /// A window-scoped `PaneAskOverlayView` while one is up — see
    /// `presentWindowAsk`.
    private(set) var windowAskOverlay: PaneAskOverlayView?
    let authGateCoordinator: AuthGateCoordinator
    private let authGateWindow: AuthGateWindowController
    private let firstRunWindow: FirstRunWindowController
    private let settingsWindowController: SettingsWindowController
    let inspector: InspectorWindowController
    /// Guards the auth-gate/first-run presentation sequence to once per
    /// launch, the same one-shot-then-re-arm-on-failure shape
    /// `layoutReadDispatched` uses.
    private var onboardingDispatched = false
    /// The two halves FirstRun waits on — see `presentOnboardingIfNeeded`.
    private var authGateResolved = false
    private var didConnect = false
    private var usageReadDispatched = false
    private var usageReadCompleted = false
    /// Task 6c: the `SMAppService`/degraded-mode mechanism and its status
    /// UI. Constructed by `AppDelegate` (which needs it before `connect()`
    /// even starts, to give a degraded-mode spawn a head start) and passed
    /// in here so `SettingsWindowController` — and, through
    /// `onReattachFailed` below, restart-loss reporting — can reach it.
    let daemonPersistence: DaemonPersistenceController

    /// `panes` may be empty: the app delegate opens the window before the
    /// socket is up, and `start()` fills it from the `layout` row once the
    /// connection lands. A non-empty seed is for callers that already know
    /// their panes (tests, and the single-pane convenience below).
    init(
        connection: SessionConnection,
        panes: [RestoredPane],
        notifier: SessionNotifier = SessionNotifier(delivery: UserNotificationDelivery()),
        daemonPersistence: DaemonPersistenceController = DaemonPersistenceController()
    ) {
        self.connection = connection
        self.notifier = notifier
        self.daemonPersistence = daemonPersistence
        let settingsStore = SettingsStore(client: connection)
        self.settingsStore = settingsStore
        let authGateCoordinator = AuthGateCoordinator(settings: settingsStore)
        self.authGateCoordinator = authGateCoordinator
        let authGateWindow = AuthGateWindowController(coordinator: authGateCoordinator)
        self.authGateWindow = authGateWindow
        firstRunWindow = FirstRunWindowController(ingestion: connection)
        inspector = InspectorWindowController(client: connection)
        settingsWindowController = SettingsWindowController(
            settings: settingsStore,
            authGate: authGateCoordinator,
            authGateWindow: authGateWindow,
            brainAdmin: connection,
            notifier: notifier,
            daemonStatus: daemonPersistence
        )
        workspace = PaneWorkspaceView { descriptor in
            switch descriptor.kind {
            case .terminal:
                return TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
            case .browser:
                return BrowserPaneView(initialURL: descriptor.browserURL)
            case .editor:
                return EditorPaneView(
                    initialTabs: descriptor.editorTabs,
                    activeIndex: descriptor.editorActiveIndex
                )
            }
        }

        let window = WorkspaceWindow(
            contentRect: WorkspaceWindowController.defaultContentRect(),
            // `.fullSizeContentView` is what removes the chrome row entirely:
            // the content starts at the window's top edge and
            // `WorkspaceTitleBarView` is the only bar there is. The other
            // three stay in the mask — close/minimize/resize still work, it is
            // only AppKit's *drawing* of the buttons that goes away below.
            // Same recipe `AuthGateWindowController` uses for the login window.
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "OmniAgent"
        // The title still exists (Cmd+`/Mission Control/menu bar want it),
        // it just doesn't reserve a row in the chrome — `refreshTitle()`
        // below keeps it current for those, not for display here.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // The three real buttons, hidden so the bar can draw its own in the
        // place its layout puts them. Hidden rather than dropped from the
        // style mask, which would also take the behaviours with them.
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        // Said rather than inherited: the bar's green button is the only route
        // into full screen this app has — the menus are hand-built and carry
        // no Enter Full Screen item — so it is worth one line to be certain
        // the window will go, instead of trusting a default.
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(
            srgbRed: 8 / 255,
            green: 10 / 255,
            blue: 14 / 255,
            alpha: 1
        )
        // Not a taste: below this the pane area cannot hold one terminal worth
        // reading, and every sizing rule in `PaneWorkspaceView` assumes it can.
        // The sidebar is counted at its own floor rather than at zero, so the
        // promise holds with the column open, which is how the app opens.
        window.contentMinSize = NSSize(
            width: ShellMetrics.sidebarMinimumWidth + PaneWorkspaceView.minimumContentSize.width,
            height: WorkspaceTitleBarView.height + PaneWorkspaceView.minimumContentSize.height
        )
        window.minSize = window.contentMinSize

        super.init(window: window)
        installSplitView(on: window)
        restoreWindowFrame(window)
        window.delegate = self
        window.onFirstResponderChange = { [weak self] responder in
            self?.workspace.adoptFocus(from: responder)
        }
        // esc leaves focus mode when something is zoomed; returning false
        // otherwise leaves the terminal receiving it exactly as before.
        window.onEscape = { [weak self] in
            guard let self, workspace.zoomedPaneID != nil else { return false }
            workspace.setZoomed(nil)
            return true
        }
        workspace.onFocusedPaneChanged = { [weak self] paneID in
            UserDefaults.standard.set(paneID, forKey: Self.lastFocusedPaneDefaultsKey)
            guard let self else { return }
            // Remembered here rather than derived on demand: once focus has
            // moved on to a terminal, nothing else in the workspace still
            // knows which editor the user was last looking at.
            if let paneID, workspace.descriptor(for: paneID)?.kind == .editor {
                lastFocusedEditorPaneID = paneID
            }
            if let paneID { noteSessionFocused(paneID) }
            refreshTitle()
            reloadOutline()
            refreshInspectorIfVisible(for: paneID)
        }
        workspace.onRequestNewPane = { [weak self] in self?.newTerminalPane(nil) }
        workspace.onRequestNewBrowserPane = { [weak self] in self?.newBrowserPane(nil) }
        workspace.onRequestNewEditorPane = { [weak self] in self?.newEditorPane(nil) }
        // Every tab drop lands in one of three broker methods, so the rules —
        // the save prompt, the `PaneGrid.maxPanes` cap, the pane wiring — are
        // written once rather than once per destination view.
        workspace.onEditorTabDropOnPane = { [weak self] payload, targetID, zone in
            guard let self else { return }
            if zone == .center {
                handleEditorTabDrop(payload, intoPane: targetID, at: Int.max)
            } else {
                handleEditorTabEdgeDrop(payload, target: targetID, zone: zone)
            }
        }
        workspace.onEditorTabDropOnHole = { [weak self] payload in
            self?.handleEditorTabHoleDrop(payload)
        }
        workspace.onRequestClosePane = { [weak self] paneID in
            guard let self else { return }
            // Route through focus so the header's close button ends *that*
            // pane, not whichever one happened to be focused.
            workspace.focusPane(paneID)
            closePane(nil)
        }
        workspace.onRequestRenamePane = { [weak self] _ in
            guard let self else { return }
            // The header focuses the pane before asking, so the rename prompt
            // goes to the right conversation.
            self.renameConversation(nil)
        }
        workspace.onRequestColorMenu = { [weak self] _, anchor in
            guard let self else { return }
            self.claudeColorMenu().popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: anchor.bounds.maxY + 4),
                in: anchor
            )
        }
        workspace.onRequestThemeMenu = { [weak self] _, anchor in
            guard let self else { return }
            self.copilotThemeMenu().popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: anchor.bounds.maxY + 4),
                in: anchor
            )
        }
        workspace.onRequestModelMenu = { [weak self] paneID, anchor in
            guard let self else { return }
            self.modelMenu(for: paneID).popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: anchor.bounds.maxY + 4),
                in: anchor
            )
        }
        workspace.onRequestEngineMenu = { [weak self] paneID, anchor in
            guard let self else { return }
            engineMenu(for: paneID).popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: anchor.bounds.maxY + 4),
                in: anchor
            )
        }
        workspace.onPanesChanged = { [weak self] in
            self?.persistLayout()
            self?.persistBrowserPanes()
            self?.persistEditorPanes()
            self?.reloadOutline()
        }
        workspace.onActiveGroupChanged = { [weak self] group in
            self?.reviewPanelSessionDidChange(to: group)
            // The bar names the session on screen, so switching sessions
            // renames it — and a session going away empties it.
            self?.refreshTitle()
        }
        reviewPanel.onTabsChanged = { [weak self] in self?.reviewPanelUIChanged() }
        reviewPanel.onToggleExpand = { [weak self] in self?.toggleReviewPanelExpansion() }
        reviewPanel.setContent(reviewPanelFiles, for: .files)
        reviewPanelFiles.onPreferencesChanged = { [weak self] in self?.reviewPanelFilesChanged() }
        reviewPanelFiles.onOpenFileChanged = { [weak self] _ in self?.reviewPanelFilesChanged() }
        // Badge and header clicks route to the same editor-pane flows the
        // old sidebar tree fed, so a diff always opens the same way.
        reviewPanelFiles.onOpenDiff = { [weak self] url in self?.openDiffInEditor(url) }
        reviewPanelFiles.onOpenAllChanges = { [weak self] in self?.openChangesOverview() }
        reviewPanel.setContent(reviewPanelChanges, for: .changes)
        // The overview's row activations route to the same editor-pane flows
        // the editor's own changes tab feeds — the panel itself stays
        // read-only.
        reviewPanelChanges.onOpenFileRequest = { [weak self] url in
            self?.openFileInEditor(url, pinned: true)
        }
        reviewPanelChanges.onOpenDiffRequest = { [weak self] url in self?.openDiffInEditor(url) }
        reviewPanel.setContent(reviewPanelBrowser, for: .browser)
        reviewPanel.setContent(reviewPanelInsights, for: .insights)
        notifier.onEntriesChanged = { [weak self] entries in self?.persistNotifications(entries) }
        usageRecorder.onStoreChanged = { [weak self] store in self?.persistUsageAnalytics(store) }
        shellSidebar.onSelectSession = { [weak self] session in
            guard let self else { return }
            // The tree lists every workspace, so a session row is allowed to
            // belong to a workspace that is not the open one: entering it
            // opens that workspace first, then activates the session — the
            // redesign's one click-through seam.
            if !session.project.isEmpty, session.project != selectedProjectID {
                selectWorkspace(id: session.project, animated: false)
            }
            // A session is pane content; from Home or To Do List the pane
            // workspace is hidden until the destination comes back.
            if destination != .terminals { applyDestination(.terminals) }
            // The one entry path, rather than `workspace.focusPane(first)`
            // directly.
            enterDeskSession(session.id)
        }
        shellSidebar.onRenameSession = { [weak self] session, name in
            self?.renameSession(session, to: name)
        }
        shellSidebar.onHoverTarget = { [weak self] target in
            guard let self else { return }
            hoverCard.hover(target, in: window)
        }
        hoverCard.provider = { [weak self] target in self?.hoverCardModel(for: target) }
        hoverCard.rowFrame = { [weak self] target in self?.shellSidebar.rowFrameOnScreen(for: target) }
        // The card's git tab offers one action, and this is all it is: the
        // session it is about, with its review panel open on the changes the
        // card was just counting.
        hoverCard.onReview = { [weak self] target in
            guard let self, case .session(let group) = target else { return }
            if destination != .terminals { applyDestination(.terminals) }
            enterDeskSession(group)
            if reviewPanelItem?.isCollapsed ?? true { toggleReviewPanel(nil) }
        }
        // Search fires the spotlight and is deliberately not a selection —
        // the same panel ⌃Space and ⌘K raise.
        shellSidebar.onSearch = { [weak self] in self?.showCommandPalette(nil) }
        shellSidebar.onOpenSettings = { [weak self] in self?.showSettings(nil) }
        // The header's plus menu: a session in any listed workspace, or a
        // brand new workspace from a folder (the one flow where a chooser is
        // the whole point).
        shellSidebar.onStartSession = { [weak self] projectID in
            guard let self else { return }
            startSession(
                inDirectory: workspaceDirectory(for: projectID) ?? "",
                project: projectID
            )
        }
        shellSidebar.onAddLocalFolder = { [weak self] in self?.openWorkspaceFolder(nil) }
        // Home's project/session dropdowns — `HomeDropdown`, the same
        // glass-and-icons look every other Home chip uses, not the
        // sidebar's stock `NSMenu`. Home only ever picks *what a session
        // would start with*, never starts one: clicking a workspace here
        // must not jump you off Home the way the sidebar's identically-
        // shaped "+" menu does, so this targets `homeSelectedProjectID`,
        // never `selectedProjectID`/`startSession` — see `homeSessions(for:)`
        // for the session list's source.
        homeView.onRequestProjectMenu = { [weak self] anchor in
            guard let self else { return }
            let current = homeSelectedProjectID
            let chatRow = HomeDropdown.Row(
                icon: HomeDropdown.symbol("bubble.left"), title: HomeChatWorkspace.label, isCurrent: current == HomeChatWorkspace.id
            ) { [weak self] in self?.selectHomeWorkspace(HomeChatWorkspace.id) }
            // Each row wears the sidebar's name and folder colour for the
            // workspace — closed folders, the chosen one open, as the tree.
            let workspaceRows = homeOpenWorkspaces().map { entry in
                let isCurrent = entry.id == current
                let folder = (isCurrent ? ShellGlyph.folderOpen : .folder)
                    .image(color: self.sidebarTint(for: entry.id) ?? ShellPalette.folderGlyph, size: 17)
                return HomeDropdown.Row(icon: folder, title: self.sidebarDisplayLabel(for: entry.id), isCurrent: isCurrent) { [weak self] in
                    self?.selectHomeWorkspace(entry.id)
                }
            }
            HomeDropdown.show([
                HomeDropdown.Section(rows: [chatRow]),
                HomeDropdown.Section(header: "Repositories", rows: workspaceRows),
                HomeDropdown.Section(header: "Add project from", rows: [
                    HomeDropdown.Row(icon: HomeDropdown.symbol("desktopcomputer"), title: "Local folder or repository…") { [weak self] in
                        self?.pickHomeFolder()
                    },
                    HomeDropdown.Row(icon: HomeDropdown.symbol("cloud"), title: "Resume remote session…", isEnabled: false) {},
                ]),
            ], searchPlaceholder: "Search repositories…", from: anchor)
        }
        homeView.onRequestSessionMenu = { [weak self] anchor in
            guard let self else { return }
            let project = homeSelectedProjectID
            let sessions = homeSessions(for: project)
            let sessionRows = sessions.map { session in
                HomeDropdown.Row(icon: HomeDropdown.symbol("terminal"), title: session.label) { [weak self] in
                    self?.homeView.updateSessionChip(label: session.label, branch: GitBranch.forDirectory(session.cwd))
                }
            }
            let newSessionRow = HomeDropdown.Row(icon: HomeDropdown.symbol("plus"), title: "Create new session") { [weak self] in
                guard let self else { return }
                homeView.updateSessionChip(label: "New session", branch: homeDirectory().flatMap(GitBranch.forDirectory))
            }
            HomeDropdown.show(
                [HomeDropdown.Section(rows: sessionRows + [newSessionRow])],
                searchPlaceholder: "Search sessions…",
                from: anchor
            )
        }
        // Every local branch, current one checked; typing a name no branch
        // has offers to create it off the one currently picked — so "from
        // any other branch" is: pick that branch first, then type the new
        // name. Creation itself is deferred to Send (nothing starts a
        // session from Home yet); the chip's "base → name" is the promise.
        //
        // Above the local branches: GitHub. Until the user connects — an
        // existing `gh` login or our GitHub App — the section says so and
        // offers "Set up GitHub…", the one thing a user without git can do.
        homeView.onRequestBranchMenu = { [weak self] anchor in
            guard let self else { return }
            let gitHub = HomeDropdown.Section(header: "GitHub · Not connected", rows: [
                // GitHub lives under Accounts; the page itself is still to come.
                HomeDropdown.Row(icon: HomeDropdown.symbol("link"), title: "\(HomeSurfaceView.setUpGitHubTitle)…") { [weak self] in
                    self?.showSettings(section: .accounts)
                },
            ])
            guard let directory = homeDirectory(),
                  let root = GitStatus.repoRoot(for: URL(fileURLWithPath: directory, isDirectory: true))
            else {
                HomeDropdown.show([gitHub], searchPlaceholder: "Search branches…", from: anchor)
                return
            }
            let base = homeView.selectedBranch ?? GitBranch.current(repoRoot: root) ?? "main"
            let branches = GitBranch.all(repoRoot: root)
            let isPendingNew = homeView.newBranchName != nil
            let rows = branches.map { name in
                HomeDropdown.Row(
                    icon: HomeDropdown.symbol("arrow.triangle.branch"), title: name, isCurrent: name == base && !isPendingNew
                ) { [weak self] in
                    self?.homeView.updateBranchChip(existing: name)
                }
            }
            let dropdown = HomeDropdown.show(
                [gitHub, HomeDropdown.Section(header: "Local branches", rows: rows)],
                searchPlaceholder: "Search branches…", from: anchor
            )
            dropdown.extraRows = { [weak self] query in
                guard !branches.contains(query) else { return [] }
                return [HomeDropdown.Row(icon: HomeDropdown.symbol("plus"), title: "Create “\(query)” from \(base)") {
                    self?.homeView.updateBranchChip(new: query, from: base)
                }]
            }
        }
        // A workspace row's right-click: the controller builds the menu
        // because only it can resolve the row to a directory, a GitHub
        // remote and a stored customization.
        shellSidebar.workspaceMenuProvider = { [weak self] id in self?.workspaceContextMenu(for: id) }
        // A session row's right-click, same reasoning: only the controller
        // holds the pin state, the installed-app catalogue and the delete
        // path.
        shellSidebar.sessionMenuProvider = { [weak self] session in
            self?.sessionContextMenu(for: session)
        }
        // Asking the login shell for its PATH spawns a shell; do it now, off
        // the main thread, so the first terminal does not wait for it.
        EngineLauncher.prewarm()
        for pane in panes { addPane(pane, startSession: false) }
        selectInitialWorkspaceIfNeeded(animated: false)
        reloadOutline()
        window.initialFirstResponder = workspace.focusedPaneID
            .flatMap { workspace.surface(for: $0)?.primaryResponderView }
    }

    // MARK: - Window frame

    static let frameAutosaveName = "OmniAgentWorkspaceWindow"

    /// The size the window opens at the very first time, before there is a
    /// remembered frame.
    ///
    /// This used to be a flat 1040x680, chosen when the window was a bare pane
    /// grid. With a 238pt sidebar taking a fifth of it, that leaves a four-pane
    /// grid about 400pt wide per terminal — narrower than most prompts — so the
    /// app opened looking cramped on every display it has ever run on. Asking
    /// the screen instead, with a ceiling so an ultra-wide does not get a
    /// 5000pt window, and a floor so a small laptop still gets a usable one.
    static func defaultContentRect(visibleFrame: NSRect? = NSScreen.main?.visibleFrame) -> NSRect {
        guard let visible = visibleFrame, visible.width > 0, visible.height > 0 else {
            return NSRect(x: 0, y: 0, width: 1440, height: 900)
        }
        // The outer `min` is the one that matters on a small display: the floor
        // below must never hand back a window larger than the screen it opens
        // on.
        let width = min(visible.width, min(1760, max(1040, visible.width * 0.86)))
        let height = min(visible.height, min(1100, max(680, visible.height * 0.88)))
        return NSRect(x: 0, y: 0, width: width.rounded(), height: height.rounded())
    }

    // ponytail: the window's size is the user's, full stop. Adding a pane
    // used to scale and re-centre it on every row-count change; it moved the
    // window out from under the cursor mid-placement, and the reference frame
    // it scaled from threw away any manual resize made since. The content
    // adapts to the window now (`PaneWorkspaceView.reflowForSize`), never the
    // other way round.

    /// Restores where the user last put the window, and centres the default on
    /// first launch. Skipped under XCTest, where an autosaved frame would make
    /// every window-controller test inherit whatever size the developer's own
    /// app happens to be at.
    private func restoreWindowFrame(_ window: NSWindow) {
        guard NSClassFromString("XCTestCase") == nil else { return }
        if !window.setFrameUsingName(Self.frameAutosaveName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameAutosaveName)
    }

    /// The split: the sidebar column on the left, the destination container on
    /// the right. The sidebar's *content* is `NavigationSidebarView`, the flat
    /// column of the 2026-08-20 redesign.
    private func installSplitView(on window: NSWindow) {
        workspace.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(workspace)
        contentContainer.addSubview(placeholder)
        contentContainer.addSubview(homeView)
        contentContainer.addSubview(settingsView)
        for view in [workspace, placeholder, homeView, settingsView] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentContainer.topAnchor, constant: WorkspaceTitleBarView.height),
                view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }

        shellSidebar.onSelectDestination = { [weak self] destination in
            self?.applyDestination(destination)
        }
        applyDestination(.home)

        let sidebar = NSViewController()
        sidebar.view = shellSidebar
        let content = NSViewController()
        content.view = contentContainer
        let split = NSSplitViewController()
        // A plain split item, NOT `sidebarWithViewController:`. macOS 26 draws
        // a `.sidebar` item as an inset, rounded, floating slab — the rounded
        // edges Bruno is looking at. Nothing here wanted that chrome: the
        // toggle below collapses `splitViewItems.first` itself and never calls
        // AppKit's `toggleSidebar:`, and the column paints its own flat
        // background, so the system material was only ever covered up.
        let sidebarItem = NSSplitViewItem(viewController: sidebar)
        // What the sidebar behavior gave for free: the column keeps its width
        // and the panes absorb the change. That means holding ABOVE the pane
        // grid's 250, not at AppKit's sidebar default of 200 — at 200 the
        // column is the most willing item to resize, so every layout pass
        // after a drag handed the width straight back to the grid and the
        // divider sprang home.
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        // A range, not a cage: a sidebar holding session names and a file tree
        // is exactly the thing a user wants wider or narrower depending on
        // what they are doing. See `ShellMetrics` for what each bound is for —
        // and note the floor doubles as the opening width, since the autosaved
        // divider position is clamped to it.
        sidebarItem.minimumThickness = ShellMetrics.sidebarMinimumWidth
        sidebarItem.maximumThickness = ShellMetrics.sidebarMaximumWidth
        sidebarWidthItem = sidebarItem
        clampSidebarWidth()
        sidebarItem.canCollapse = true
        // AppKit remembers the dragged position under this name, so the width
        // survives a relaunch without anything here persisting it.
        //
        // Not under XCTest: the test host IS the app, so it shares this
        // defaults domain. Every controller a test builds was writing its
        // throwaway window's geometry here — which is how a real sidebar ended
        // up 332pt wide, and then collapsed, from a test run.
        if NSClassFromString("XCTestCase") == nil {
            split.splitView.autosaveName = "OmniAgentWorkspaceSidebar"
        }
        split.addSplitViewItem(sidebarItem)
        // A floor of its own, and the reason the review panel's expansion can
        // ask for "everything" safely: the pane column is the lowest-holding
        // item here, so without this it is squeezed to a sliver and every
        // terminal in it wraps at six characters. One comfortable pane is what
        // the grid's own rules assume exists.
        let contentItem = NSSplitViewItem(viewController: content)
        contentItem.minimumThickness = PaneWorkspaceView.minimumPaneAreaWidth
        split.addSplitViewItem(contentItem)

        // The third item: the review panel, collapsed until a session's
        // state (or ⌥⌘B) opens it. Its divider rides the same autosave name.
        // The panel is wrapped in a container so it clears the window chrome.
        let reviewContainer = NSView()
        reviewContainer.addSubview(reviewPanel)
        reviewPanel.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            reviewPanel.leadingAnchor.constraint(equalTo: reviewContainer.leadingAnchor),
            reviewPanel.trailingAnchor.constraint(equalTo: reviewContainer.trailingAnchor),
            reviewPanel.bottomAnchor.constraint(equalTo: reviewContainer.bottomAnchor),
            reviewPanel.topAnchor.constraint(equalTo: reviewContainer.topAnchor, constant: WorkspaceTitleBarView.height),
        ])
        let review = NSViewController()
        review.view = reviewContainer
        let reviewItem = NSSplitViewItem(viewController: review)
        reviewItem.minimumThickness = ReviewPanelView.minimumWidth
        reviewItem.canCollapse = true
        reviewItem.isCollapsed = true
        // Above the default 250 the other two sit at, so opening the panel
        // squeezes the pane grid — the spec's word — rather than the sidebar.
        reviewItem.holdingPriority = NSLayoutConstraint.Priority(251)
        split.addSplitViewItem(reviewItem)
        reviewPanelItem = reviewItem
        splitController = split

        // The session's name, in the strip the title bar leaves clear at the top
        // of the content column. It sits in the column so the column's own
        // collapse animation carries it.
        contentContainer.addSubview(sessionTitleField)
        // Where it wants to be: just inside the column. Not required, because
        // with the sidebar collapsed the column reaches the window's left edge
        // and this alone would draw the name straight through the window
        // buttons. The clearance below outranks it, so the pair reads as "just
        // inside the column, but never under the buttons".
        let nameFollowsColumn = sessionTitleField.leadingAnchor.constraint(
            equalTo: contentContainer.leadingAnchor,
            constant: 12
        )
        nameFollowsColumn.priority = .init(999)
        NSLayoutConstraint.activate([
            nameFollowsColumn,
            sessionTitleField.centerYAnchor.constraint(
                equalTo: contentContainer.topAnchor,
                constant: WorkspaceTitleBarView.height / 2
            ),
        ])

        // The window's own bar, above the split as an overlay: pinned to top,
        // leading, trailing but added AFTER split.view so it is above it.
        // `contentViewController` is a plain container now — read the split
        // through `splitController`, never by casting it back.
        let container = NSViewController()
        container.view = NSView()
        container.addChild(split)
        split.view.translatesAutoresizingMaskIntoConstraints = false
        container.view.addSubview(split.view)
        container.view.addSubview(titleBar)
        NSLayoutConstraint.activate([
            split.view.topAnchor.constraint(equalTo: container.view.topAnchor),
            split.view.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            split.view.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
            split.view.bottomAnchor.constraint(equalTo: container.view.bottomAnchor),

            titleBar.topAnchor.constraint(equalTo: container.view.topAnchor),
            titleBar.leadingAnchor.constraint(equalTo: container.view.leadingAnchor),
            titleBar.trailingAnchor.constraint(equalTo: container.view.trailingAnchor),
        ])
        // AppKit pins its own split view inside `split.view` at priority 749,
        // which loses to the sizing chain a collapsed item leaves behind: the
        // split stops filling and hugs the trailing edge, and the strip it
        // gives up is bare window background. Required pins, so filling the
        // container is not negotiable.
        split.splitView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            split.splitView.leadingAnchor.constraint(equalTo: split.view.leadingAnchor),
            split.splitView.trailingAnchor.constraint(equalTo: split.view.trailingAnchor),
            split.splitView.topAnchor.constraint(equalTo: split.view.topAnchor),
            split.splitView.bottomAnchor.constraint(equalTo: split.view.bottomAnchor),
        ])
        window.contentViewController = container

        // Only now: the name is in the content column and the bar is the
        // overlay, so this is the first moment the two share an ancestor —
        // activating it any earlier throws for having none.
        NSLayoutConstraint.activate([
            sessionTitleField.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleBar.titleClearanceAnchor,
                constant: 12
            ),
        ])
    }

    /// Swaps the destination. `isHidden`, never add/remove: see
    /// `contentContainer`'s own doc for why the pane workspace must stay
    /// mounted.
    func applyDestination(_ destination: WorkspaceDestination) {
        self.destination = destination
        shellSidebar.applyDestination(destination)
        let isTerminals = destination == .terminals
        workspace.isHidden = !isTerminals
        // Home has a real screen now; the placeholder covers To Do List only.
        homeView.isHidden = destination != .home
        if destination == .home { refreshHomeChips() }
        settingsView.isHidden = destination != .settings
        placeholder.isHidden = destination != .todo
        if destination == .todo { placeholder.show(destination) }
        // Home and To Do List name no session, so the bar goes blank and its
        // review toggle goes away entirely.
        refreshTitle()
        // The review panel reviews the session on screen, and Home/To Do
        // List show no session — collapsed there, and back to the session's
        // own recorded state on the way back in.
        if !isTerminals {
            reviewPanelItem?.isCollapsed = true
        } else if reviewPanelReadCompleted, let group = workspace.activeGroup {
            reviewPanelItem?.isCollapsed = !reviewPanelState(for: group).open
        }
        // Leaving/entering the Desk moves which session row (if any) may show
        // as current — `reloadOutline`'s job, and its only other callers are
        // pane/status events, none of which fire on a plain destination
        // switch. Without this a session stays lit under Home/To Do until
        // something unrelated happens to refresh the tree.
        reloadOutline()
    }

    /// Opens a workspace: the git status, the repository the spotlight
    /// searches and the Desk's session commands all follow it. The sidebar's
    /// tree is NOT scoped to it any more — it lists every workspace — but it
    /// re-renders so the current-session highlight tracks the move.
    func selectWorkspace(id: String, animated: Bool = true) {
        selectedProjectID = id
        let summary = workspaces.first { $0.id == id }
            ?? BrainProjectSummary(
                id: id,
                label: SessionOutline.projectLabel(id, labels: projectLabels),
                path: nil
            )
        // The repository follows the workspace. Prefer the brain's recorded
        // path; fall back to the cwd of a pane in this project, which is what
        // a session opened by folder picker will have.
        let paneCwd = workspace.allPaneIDs
            .compactMap { workspace.descriptor(for: $0) }
            .first { $0.project == id }?
            .cwd
        refreshGitStatus(for: summary.path ?? paneCwd)
        reloadOutline()
    }

    /// The sidebar's FILES tree used to own the `git status` load; with the
    /// tree gone from the sidebar (it returns inside the review panel) the
    /// controller loads it directly when a workspace is selected. Off the
    /// main thread — a cold `git status` on a large repository is tens of
    /// milliseconds.
    private func refreshGitStatus(for directory: String?) {
        guard let directory, !directory.isEmpty else {
            applyGitStatus(nil)
            return
        }
        let url = URL(fileURLWithPath: directory)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let status = GitStatus.repoRoot(for: url).flatMap { GitStatus.load(repoRoot: $0) }
            DispatchQueue.main.async { self?.applyGitStatus(status) }
        }
    }

    /// Fans a fresh `git status` out to everything that renders it. Held in
    /// `latestGitStatus` as well so a pane created *later* can be seeded with
    /// it — see the editor branch of `addPane`. Internal so the tests can
    /// hand a status in without a repository.
    func applyGitStatus(_ status: GitStatus?) {
        latestGitStatus = status
        for id in workspace.allPaneIDs {
            workspace.editorPane(for: id)?.setGitStatus(status)
        }
        // The spotlight searches the repository's files, and this is the
        // one place that already knows when the repository changed.
        guard let root = status?.root else {
            repoFiles = []
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let files = GitStatus.trackedFiles(repoRoot: root)
            DispatchQueue.main.async { self.repoFiles = files }
        }
    }

    /// With panes already restored there is a workspace to be in, so the app
    /// opens scoped to it rather than making the user pick what is already
    /// there.
    private func selectInitialWorkspaceIfNeeded(animated: Bool) {
        guard selectedProjectID == nil else { return }
        let focused = workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0)?.project }
        let anyPane = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0)?.project }.first
        guard let project = focused ?? anyPane, !project.isEmpty else { return }
        selectWorkspace(id: project, animated: animated)
    }

    /// One pane, one fresh session — the Task 4/5 shape, kept for callers
    /// that want a window with a known pane in it without going through the
    /// `layout` row.
    convenience init(connection: SessionConnection, sessionID: String) {
        self.init(
            connection: connection,
            panes: [WorkspaceRestoration.bootstrapPane(sessionID: sessionID)]
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        window?.center()
        window?.makeKeyAndOrderFront(sender)
        focusTerminal(sender)
    }

    func start() {
        connection.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .connected:
                applyConnectionStatus(nil)
                restoreWorkspaceIfNeeded()
                restoreUsageAnalyticsIfNeeded()
                restoreWorkspaceCustomizationsIfNeeded()
                restoreClosedWorkspacesIfNeeded()
                refreshProjectLabels()
                didConnect = true
                presentOnboardingIfNeeded()
            case .connecting:
                applyConnectionStatus("Connecting")
            case .disconnected:
                applyConnectionStatus("Reconnecting")
                // Every "this session is up" belief died with the socket. If
                // the daemon is what went away, its sessions are gone too, and
                // `ensureSession` would blind-attach into nothing and leave the
                // pane blank forever. Forgetting them makes the next connect
                // prove liveness with `listSessions` instead.
                readySessions.removeAll()
            }
        }
        connection.onTerminalData = { [weak self] id, bytes, sequence, isSnapshot in
            guard let self, let surface = workspace.terminalSurface(for: id) else { return }
            if !observedFirstOutput {
                observedFirstOutput = true
                os_signpost(.event, log: Instrumentation.log, name: "First Terminal Output")
            }
            surface.feed(bytes, isSnapshot: isSnapshot, sequence: sequence)
            // A hand-typed `/model` changes the model without an API call or a
            // status event; its printed confirmation is the only signal. The
            // pane re-reads its transcript when the output settles.
            workspace.noteOutput(for: id)
        }
        connection.onStatus = { [weak self] event in
            // Every pane records its own status, focused or not, so switching to
            // a pane that went to "Needs approval" in the background shows it.
            guard let self, workspace.container(for: event.id) != nil else { return }
            applySessionStatus(event.status.title, for: event.id)
            recordNotification(for: event)
            // The pane's own header and the sidebar's session tree read the
            // same status, and both have to move the moment it changes — a
            // terminal that has stopped to ask something is useless if the
            // only place that says so is a window title.
            workspace.setStatus(event.status, for: event.id)
            reloadOutline()
            usageRecorder.recordStatus(
                sessionID: event.id,
                project: workspace.descriptor(for: event.id)?.project ?? "",
                status: event.status,
                at: Date().timeIntervalSince1970 * 1000
            )
        }
        // The Rust-side attention latch. Deliberately a dock bounce and not a
        // second notification: the moment it fires, the session also reports
        // `awaiting_approval` through `onStatus` above, which is what actually
        // becomes a banner — notifying from both would double every prompt.
        connection.onAttention = { [weak self] id in
            guard self?.workspace.container(for: id) != nil else { return }
            NSApp.requestUserAttention(.informationalRequest)
        }
        connection.onExit = { [weak self] event in
            guard let self, workspace.container(for: event.id) != nil else { return }
            // The `--resume` fallback: a conversation that no longer exists
            // makes `claude` exit non-zero almost immediately, which would
            // otherwise leave a dead pane where a working agent belongs.
            if Self.resumeFailed(
                spawnedAt: resumeSpawns.removeValue(forKey: event.id),
                exitCode: event.exitCode
            ) {
                readySessions.remove(event.id)
                createSession(event.id, stock: true)
                return
            }
            readySessions.remove(event.id)
            lastStatus.removeValue(forKey: event.id)
            lastStatusEventAt.removeValue(forKey: event.id)
            activity.forget(paneID: event.id)
            statusSeries.forget(paneID: event.id)
            applySessionStatus("Session ended", for: event.id)
            workspace.setStatus(nil, for: event.id)
            reloadOutline()
            notifier.recordExit(
                sessionID: event.id,
                paneTitle: workspace.descriptor(for: event.id)?.title ?? "",
                exitCode: event.exitCode
            )
            usageRecorder.recordExit(sessionID: event.id, at: Date().timeIntervalSince1970 * 1000)
        }
        connection.onError = { [weak self] error in
            self?.applyConnectionStatus(error.localizedDescription)
        }
        // Task 6c restart-loss reporting: a reconnect's automatic reattach
        // came back "session not found" — the daemon restarted and forgot
        // this session. Tell the pane (rather than leave its last status
        // showing) and add it to the aggregated report the Daemon settings
        // tab reads from `daemonPersistence`.
        connection.onReattachFailed = { [weak self] sessionID in
            self?.handleReattachFailure(sessionID)
        }
        connection.connect()
    }

    func stop() {
        connection.disconnect()
        daemonPersistence.stop()
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }

    /// Any unsaved editor buffer anywhere in this window. Asked before
    /// prompting, so a workspace with nothing to lose never delays a ⇧⌘W or
    /// a ⌘Q by so much as a run-loop turn.
    var hasDirtyEditorTabs: Bool {
        workspace.allPaneIDs.contains { workspace.editorPane(for: $0)?.hasDirtyTabs == true }
    }

    /// Whether this window holds any editor buffer at all — the question the
    /// close and quit paths ask, rather than `hasDirtyEditorTabs`.
    ///
    /// "Is anything dirty?" cannot be answered synchronously: the flags lag a
    /// keystroke, and answering "no" here is what lets the window or the app
    /// go away. So the cheap pre-check is deliberately the *conservative*
    /// one — a workspace with no editor buffers still closes and quits with
    /// no delay whatsoever, and anything else goes through the asynchronous
    /// walk, which reconciles with the page and prompts only if it must.
    var mayHaveUnsavedEditorWork: Bool {
        workspace.allPaneIDs.contains { workspace.editorPane(for: $0)?.hasLoadedBuffers == true }
    }

    /// Walks every editor pane's dirty tabs with save prompts, one pane after
    /// another. `true` means everything resolved (saved or deliberately
    /// discarded); `false` means the user cancelled — or a write failed — and
    /// the close or quit must stop.
    ///
    /// Chained rather than looped: each prompt answers on a callback, and the
    /// save behind a "Save" answer is a round trip to Monaco.
    ///
    /// **Cancel aborts the close, not the walk so far.** Each answer is acted
    /// on as it is given, so cancelling at pane N leaves panes 1..N-1 already
    /// drained (saved or discarded, exactly as the user asked) and their rows
    /// republished. That is what every multi-document macOS app does on quit —
    /// the alternative, collecting consent for the whole window before acting,
    /// cannot work here because "Save" *is* an action: the write has to happen
    /// before the answer means anything.
    func promptDirtyEditorTabs(completion: @escaping (Bool) -> Void) {
        // Held for the whole walk, including the cancelled case: a walk that
        // stopped half way has closed some tabs, and that half-drained state
        // is not what should be on disk either.
        editorPaneDrainInFlight = true
        let finish: (Bool) -> Void = { [weak self] proceed in
            self?.editorPaneDrainInFlight = false
            completion(proceed)
        }
        walkDirtyEditorPanes(in: workspace.allPaneIDs, completion: finish)
    }

    /// `promptDirtyEditorTabs` scoped to one set of panes — Delete-session's
    /// and Remove-workspace's share of ⌘W's gate. Their destroy loops dispose
    /// every Monaco buffer in the group, the only copy of any unsaved work,
    /// so the same drain runs first: `true` means every buffer resolved
    /// (saved or deliberately discarded) and the destroy may proceed; `false`
    /// means the user cancelled and nothing may be destroyed.
    ///
    /// A cancelled walk still resolved some tabs, so the row is republished —
    /// `closePane`'s rule for its own cancel, not the quit path's: the app
    /// keeps running with the half-drained pane on screen, and disk should
    /// say what the screen says.
    func drainEditorPanes(in paneIDs: [String], completion: @escaping (Bool) -> Void) {
        editorPaneDrainInFlight = true
        walkDirtyEditorPanes(in: paneIDs) { [weak self] proceed in
            self?.editorPaneDrainInFlight = false
            if !proceed { self?.persistEditorPanes() }
            completion(proceed)
        }
    }

    private func walkDirtyEditorPanes(in paneIDs: [String], completion: @escaping (Bool) -> Void) {
        // Every pane holding a buffer, not just those whose *flag* says dirty:
        // `closeAllTabsAfterConfirmation` reconciles with the page and
        // completes immediately when there is genuinely nothing to ask about.
        let editors = paneIDs
            .compactMap { workspace.editorPane(for: $0) }
            .filter(\.hasLoadedBuffers)
        func step(_ remaining: [EditorPaneView]) {
            guard let next = remaining.first else {
                completion(true)
                return
            }
            next.closeAllTabsAfterConfirmation { proceed in
                guard proceed else {
                    completion(false)
                    return
                }
                step(Array(remaining.dropFirst()))
            }
        }
        step(editors)
    }

    /// The red button and ⇧⌘W both just hide the window now: the app is
    /// menu-bar-resident (`applicationShouldTerminateAfterLastWindowClosed`
    /// is `false`), so nothing behind this window is going away — every pane
    /// and every unsaved editor buffer lives on exactly as it was, and the
    /// menu bar icon's session list keeps working. There is nothing left to
    /// prompt about here; the save prompt still runs, unconditionally, on a
    /// real quit (`AppDelegate.applicationShouldTerminate`).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    /// The sidebar's ceiling is a range on a wide window and a smaller number on
    /// a narrow one: `ShellMetrics.sidebarMaximumWidth` unless dragging that far
    /// would leave the pane area below `minimumContentSize`, in which case the
    /// pane area wins. The window minimum guarantees room for one comfortable
    /// pane; a draggable divider is the one thing that could take it away again.
    private func clampSidebarWidth() {
        guard let item = sidebarWidthItem, let width = window?.contentLayoutRect.width else {
            return
        }
        item.maximumThickness = max(
            ShellMetrics.sidebarMinimumWidth,
            min(ShellMetrics.sidebarMaximumWidth, width - PaneWorkspaceView.minimumContentSize.width)
        )
    }

    func windowDidResize(_ notification: Notification) {
        clampSidebarWidth()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        workspace.restoreFocus()
    }

    // MARK: - Responder-chain commands

    @objc func focusTerminal(_ sender: Any?) {
        workspace.restoreFocus()
    }

    /// ⌘↩ — focus *mode*, the pane blown up over the others, not
    /// `focusTerminal` above, which only moves keyboard focus into the
    /// terminal. Toggles zoom on whichever pane is focused; does nothing
    /// with no focused pane, and `toggleZoom` itself already refuses below
    /// two panes on screen.
    @objc func toggleFocusMode(_ sender: Any?) {
        // Guarded here as well as in validation, so the palette and any future
        // caller are held to the same rule: focus mode blows up a terminal, and
        // off the Terminals destination the terminals are not even on screen.
        guard destination == .terminals, let focused = workspace.focusedPaneID else { return }
        workspace.toggleZoom(focused)
    }

    /// ⌘T — a new pane on a new PTY, inside an existing session.
    ///
    /// The pane joins the focused pane's session group and inherits its
    /// project and working directory (the web build's "a new pane joins the
    /// session on screen"). With no focused pane it starts an ungrouped shell
    /// in the home directory. Starting a *second, independent* session is
    /// `newSession(_:)`, not this.
    @objc func newTerminalPane(_ sender: Any?) {
        newPane(in: nil)
    }

    /// The session a new pane should join: the one the project on screen is
    /// showing, not the one holding focus.
    ///
    /// Those are different answers more often than they look. Selecting a
    /// workspace deliberately does not move focus, so `focusedPaneID`
    /// routinely names a pane in another project;
    /// `SessionOutline.visibleSessionGroupID` falls back to the project's
    /// first-seen session there, where the strict "current" answer is `nil`.
    ///
    /// `nil` only when the project genuinely has no panes — which is what makes
    /// the callers' `?? SessionOutline.newSessionGroupID()` correct rather than
    /// a swallowed failure.
    private func visibleSession() -> SessionGroupNode? {
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        // A window that has not picked a workspace yet — the bootstrap pane,
        // whose project is `""`, never selects one — still has a project on
        // screen: the focused pane's own.
        let onScreen = selectedProjectID
            ?? workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0)?.project }
        guard
            let project = onScreen,
            let group = SessionOutline.visibleSessionGroupID(
                panes,
                project: project,
                focusedPaneID: workspace.focusedPaneID
            )
        else { return nil }
        return SessionOutline.group(panes, focusedPaneID: workspace.focusedPaneID)
            .first { $0.project == project }?
            .sessions
            .first { $0.id == group }
    }

    /// `visibleSession` is private; this is the same call the callers make.
    @discardableResult
    func newPaneInVisibleSessionForTesting() -> Bool { newPane(in: visibleSession()) }

    /// Adds one pane seeded from an explicit session, or — with `nil` — from
    /// whatever currently has focus.
    ///
    /// The explicit form is what the outline's per-row "+" calls: the target
    /// session is the row that was clicked, which is not necessarily the row
    /// holding the focused pane.
    @discardableResult
    func newPane(in session: SessionGroupNode?) -> Bool {
        let sibling = session.map { seed in
            seed.paneIDs.first.flatMap { workspace.descriptor(for: $0) }
        } ?? workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        let template = WorkspaceRestoration.bootstrapPane()
        let group = session?.id ?? sibling?.group ?? template.group
        // The eight-terminal cap belongs to the session this pane is joining,
        // not to the app: a session that is full must not stop a different one
        // from opening a terminal. `maxTerminals` is the app-wide backstop the
        // daemon agrees to, and nothing a user meets in normal use.
        guard
            workspace.paneCount(inGroup: group) < PaneGrid.maxPanes,
            workspace.terminalPaneCount < PaneWorkspaceView.maxTerminals
        else { return false }
        let project = sibling?.project ?? session?.project ?? template.project
        let inherited = sibling?.cwd.isEmpty == false ? sibling!.cwd : (session?.cwd ?? "")
        // A session's own root is the answer when it has one. This used to run
        // it back through `startingDirectory`, which re-derives the folder from
        // the *project* — and that fallback is "the first pane in this
        // project", so the outline's per-session "+" opened its new terminal in
        // whichever sibling session happened to come first.
        let cwd = inherited.isEmpty
            ? startingDirectory(for: workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) })
            : inherited
        return addPane(
            RestoredPane(
                sessionID: template.sessionID,
                reattaches: false,
                project: project,
                engine: EngineLauncher.defaultEngine(),
                cwd: cwd,
                label: nil,
                themeId: sibling?.themeId,
                group: group,
                groupLabel: sibling?.groupLabel ?? session?.name
            ),
            startSession: true
        )
    }

    /// ⇧⌘T — a browser pane in the focused pane's session. No PTY, no engine,
    /// no cwd; only the grid geometry can refuse it.
    @objc func newBrowserPane(_ sender: Any?) {
        newBrowser(in: nil)
    }

    /// `newPane(in:)` minus everything PTY-shaped: no cap against
    /// `maxTerminals` (a browser costs WebKit memory, not a daemon slot), no
    /// cwd derivation, and `startSession: false` so the id never reaches
    /// `ensureSession`. `url` is what a terminal's link click opens to; the
    /// toolbar/hole-tile callers leave it blank, same as always.
    @discardableResult
    func newBrowser(in session: SessionGroupNode?, url: String = "") -> Bool {
        let sibling = session.map { seed in
            seed.paneIDs.first.flatMap { workspace.descriptor(for: $0) }
        } ?? workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        let template = WorkspaceRestoration.bootstrapPane()
        let group = session?.id ?? sibling?.group ?? template.group
        guard workspace.paneCount(inGroup: group) < PaneGrid.maxPanes else { return false }
        return addPane(
            RestoredPane(
                sessionID: template.sessionID,
                reattaches: false,
                project: sibling?.project ?? session?.project ?? "",
                engine: .shell,
                cwd: "",
                label: nil,
                themeId: nil,
                group: group,
                groupLabel: sibling?.groupLabel ?? session?.name,
                kind: .browser,
                browserURL: url
            ),
            startSession: false
        )
    }

    /// ⇧⌘E — an editor pane in the focused pane's session. `newBrowser(in:)`
    /// minus the URL: no PTY, `startSession: false`, and only the grid
    /// geometry can refuse it.
    @objc func newEditorPane(_ sender: Any?) {
        newEditor(in: nil)
    }

    @discardableResult
    func newEditor(in session: SessionGroupNode?) -> Bool {
        let sibling = session.map { seed in
            seed.paneIDs.first.flatMap { workspace.descriptor(for: $0) }
        } ?? workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        let template = WorkspaceRestoration.bootstrapPane()
        let group = session?.id ?? sibling?.group ?? template.group
        guard workspace.paneCount(inGroup: group) < PaneGrid.maxPanes else { return false }
        return addPane(
            RestoredPane(
                sessionID: template.sessionID,
                reattaches: false,
                project: sibling?.project ?? session?.project ?? "",
                engine: .shell,
                cwd: "",
                label: nil,
                themeId: nil,
                group: group,
                groupLabel: sibling?.groupLabel ?? session?.name,
                kind: .editor
            ),
            startSession: false
        )
    }

    /// The editor pane the user was last looking at. Maintained by
    /// `onFocusedPaneChanged`, so it survives focus moving away to a terminal.
    private var lastFocusedEditorPaneID: String?

    /// The FILES tree's last `git status`. The palette asks it whether there
    /// is a repository at all, and every new editor pane is seeded from it.
    private var latestGitStatus: GitStatus?
    /// The repository's tracked files, repository-relative, for the spotlight.
    /// Refreshed with the git status rather than when the palette opens, so
    /// opening it never waits on a subprocess.
    private var repoFiles: [String] = []

    /// Where a file opens: the most recently focused editor pane, then any
    /// editor pane, then a freshly created one. `nil` only when the grid is
    /// full and none of it is an editor — the click is then a no-op, which is
    /// the same answer ⇧⌘E gives.
    private func targetEditorPane() -> (id: String, pane: EditorPaneView)? {
        if let id = lastFocusedEditorPaneID, let pane = workspace.editorPane(for: id) {
            return (id, pane)
        }
        for id in workspace.allPaneIDs where workspace.descriptor(for: id)?.kind == .editor {
            if let pane = workspace.editorPane(for: id) { return (id, pane) }
        }
        guard newEditor(in: nil), let id = workspace.focusedPaneID,
              let pane = workspace.editorPane(for: id)
        else { return nil }
        return (id, pane)
    }

    /// The FILES tree opened `url`: preview on a single click, pinned on a
    /// double.
    ///
    /// A file already open *anywhere* is focused rather than opened twice —
    /// the no-duplicates rule is workspace-wide, not per pane, which is why
    /// this scans every pane before choosing a target.
    func openFileInEditor(_ url: URL, pinned: Bool) {
        let kind = EditorFileClass.classify(url: url).tabKind
        for id in workspace.allPaneIDs {
            guard let pane = workspace.editorPane(for: id),
                  pane.model.index(of: url.path, kind: kind) != nil
            else { continue }
            workspace.focusPane(id)
            pane.openFile(url, pinned: pinned)
            return
        }
        guard let target = targetEditorPane() else { return }
        workspace.focusPane(target.id)
        target.pane.openFile(url, pinned: pinned)
    }

    /// ⌘N, and the "+" beside SESSIONS in the sidebar — a **second,
    /// independent session**: a new pane in a brand-new session group, named by
    /// the same lowest-free-number rule the web build uses
    /// (`SessionOutline.nextSessionName`).
    ///
    /// It starts in the open workspace's own folder, with no folder chooser.
    /// The chooser used to be here on the theory that a session picks its own
    /// directory, but a session belongs to the workspace that owns it: the
    /// answer was already known, the question was asked every single time, and
    /// on a workspace under `~/Documents` each panel was one more chance for
    /// macOS to ask about folder access. Choosing a *different* folder means
    /// opening a different workspace, which is `openWorkspaceFolder(_:)`.
    @objc func newSession(_ sender: Any?) {
        guard workspace.terminalPaneCount < PaneWorkspaceView.maxTerminals else { return }
        let current = workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        startSession(
            inDirectory: workspaceRoot(),
            project: current?.project ?? selectedProjectID ?? ""
        )
    }

    /// The folder a new session starts in: the open workspace's own directory,
    /// falling back to the focused pane's when no workspace is selected.
    func workspaceRoot() -> String {
        let current = workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        if let folder = workspaceDirectory(for: current?.project ?? selectedProjectID) {
            return folder
        }
        return startingDirectory(for: current)
    }

    /// The sidebar's "New workspace" — the one flow where a folder chooser is
    /// the whole point, because a new workspace *is* a folder the app has not
    /// been told about yet.
    @objc func openWorkspaceFolder(_ sender: Any?) {
        guard workspace.terminalPaneCount < PaneWorkspaceView.maxTerminals else { return }
        chooseSessionDirectory(startingAt: workspaceRoot()) { [weak self] chosen in
            guard let self, let chosen else { return }
            // The chosen folder *is* the workspace. This used to hand the new
            // session `current?.project` — the focused pane's workspace — so
            // picking a folder the app had never seen filed the session under
            // whatever was already on screen, which is the one thing this flow
            // exists not to do.
            //
            // The id is the folder's basename, the brain's own rule
            // (`roots::project_id_for`), and it is *passed* to `addProject`
            // rather than re-derived from its answer: that keeps the session
            // start synchronous (no round trip before the terminal appears)
            // with both sides agreeing by construction. A folder already
            // known keeps its recorded id, so re-picking it re-enters the
            // same workspace instead of minting a rename-losing twin.
            let project = workspaces.first { $0.path == chosen }?.id
                ?? (chosen as NSString).lastPathComponent
            connection.addProject(path: chosen, name: project) { [weak self] _ in
                // Whatever the brain now knows — the recorded path, the label,
                // the ingest it kicked off — reaches the sidebar the same way
                // every other project list change does.
                self?.refreshProjectLabels()
            }
            selectWorkspace(id: project, animated: false)
            startSession(inDirectory: chosen, project: project)
        }
    }

    /// The session-creation half of `newSession(_:)`, without the chooser —
    /// so the naming and grouping rules are testable without a panel.
    /// `parent` is Create-nested-session's one addition: the right-clicked
    /// group, recorded in the session-meta row so the sidebar renders the
    /// new session indented under it.
    @discardableResult
    func startSession(inDirectory cwd: String, project: String, parent: String? = nil) -> String? {
        guard workspace.terminalPaneCount < PaneWorkspaceView.maxTerminals else { return nil }
        // Starting a session in a closed workspace reopens it — the web
        // build's `reopenWorkspace` rule, so the row is back the moment the
        // workspace is in use again.
        if !project.isEmpty, closedWorkspaceIDs.contains(project) {
            closedWorkspaceIDs.remove(project)
            persistClosedWorkspaces()
        }
        let group = SessionOutline.newSessionGroupID()
        if let parent {
            sessionMeta[group] = SessionMeta(pinned: false, parent: parent)
            persistSessionMeta()
        }
        let name = SessionOutline.nextSessionName(
            workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) },
            project: project
        )
        let paneID = UUID().uuidString
        let added = addPane(
            RestoredPane(
                sessionID: paneID,
                reattaches: false,
                project: project,
                engine: EngineLauncher.defaultEngine(),
                cwd: cwd,
                label: nil,
                themeId: nil,
                group: group,
                groupLabel: name
            ),
            startSession: true
        )
        // A session you just created is the one you meant to be in. The pane
        // is already focused (`insertPane` does that), but focus alone leaves
        // the screen wherever it was — on Home or the To Do List the new
        // session would start behind the destination. `revealPane` is the
        // whole move: destination to the Desk, window front, focus, unzoom.
        if added { revealPane(paneID) }
        return group
    }

    /// `startSession(inDirectory:project:)`'s browser twin: the same
    /// fresh-group minting, but a `.browser`/`startSession: false` pane
    /// instead of a terminal — only reachable from a link click whose own
    /// session's grid was full and got confirmed for a new one.
    @discardableResult
    private func newBrowserSession(url: String, project: String) -> Bool {
        let group = SessionOutline.newSessionGroupID()
        let name = SessionOutline.nextSessionName(
            workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) },
            project: project
        )
        return addPane(
            RestoredPane(
                sessionID: UUID().uuidString,
                reattaches: false,
                project: project,
                engine: .shell,
                cwd: "",
                label: nil,
                themeId: nil,
                group: group,
                groupLabel: name,
                kind: .browser,
                browserURL: url
            ),
            startSession: false
        )
    }

    /// A terminal's link click: opens in the clicking pane's own session
    /// (`newBrowser(in: nil, ...)` reads the focused pane, and every visible
    /// pane belongs to the focused pane's session — see `workspace.paneIDs`).
    /// `PaneGrid.maxPanes` is the only thing that can refuse that, and unlike
    /// the toolbar/hole-tile (which just hide themselves before it happens),
    /// a click has nowhere silent to go, so it asks. Non-web links (mailto:,
    /// custom schemes) skip the pane grid entirely.
    private func openLinkInBrowserPane(_ url: URL, from sessionID: String) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            openExternally(url)
            return
        }
        if newBrowser(in: nil, url: url.absoluteString) { return }
        let project = workspace.descriptor(for: sessionID)?.project ?? ""
        confirmNewSessionForLink(url) { [weak self] confirmed in
            guard let self else { return }
            guard confirmed else {
                self.openExternally(url)
                return
            }
            self.newBrowserSession(url: url.absoluteString, project: project)
        }
    }

    /// Where a link that isn't (or wasn't confirmed as) an in-app browser
    /// pane goes instead. `nil` means the real `NSWorkspace`; a test
    /// substitutes a recorder rather than actually launching a browser.
    var externalLinkOpener: ((URL) -> Void)?

    private func openExternally(_ url: URL) {
        (externalLinkOpener ?? { NSWorkspace.shared.open($0) })(url)
    }

    /// Whether a full session's grid should get a fresh session for a
    /// clicked link's browser pane. `nil` means "ask with an `NSAlert`"; a
    /// test substitutes an answer so the link-click path can run without
    /// blocking on a modal.
    var newSessionForLinkConfirmer: ((URL, @escaping (Bool) -> Void) -> Void)?

    private func confirmNewSessionForLink(_ url: URL, completion: @escaping (Bool) -> Void) {
        if let newSessionForLinkConfirmer {
            newSessionForLinkConfirmer(url, completion)
            return
        }
        let alert = NSAlert()
        alert.messageText = "This session's pane grid is full."
        alert.informativeText = "Open \(url.host ?? url.absoluteString) in a new session?"
        alert.addButton(withTitle: "New Session")
        alert.addButton(withTitle: "Cancel")
        guard let window else {
            completion(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    /// Where a new session's directory comes from. `nil` means "ask with an
    /// `NSOpenPanel`"; a test substitutes an answer so `newSession(_:)` can
    /// run without blocking on a modal.
    var directoryChooser: ((String, @escaping (String?) -> Void) -> Void)?

    private func chooseSessionDirectory(
        startingAt path: String,
        completion: @escaping (String?) -> Void
    ) {
        if let directoryChooser {
            directoryChooser(path, completion)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Where should this session's terminals start?"
        panel.prompt = "Start Session"
        panel.directoryURL = URL(fileURLWithPath: path, isDirectory: true)
        guard let window else {
            completion(panel.runModal() == .OK ? panel.url?.path : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completion(response == .OK ? panel.url?.path : nil)
        }
    }

    /// ⌘W — closes the focused pane and the session behind it. The window's own
    /// close is ⇧⌘W.
    @objc func closePane(_ sender: Any?) {
        guard let focused = workspace.focusedPaneID else { return }
        // An editor pane can be holding unsaved work, and closing it disposes
        // every Monaco model in it — the only copy of that work. This is the
        // widest of the close gates (⌘W, the pane header's ×, the toolbar item
        // and the palette all arrive here), so it does not read `hasDirtyTabs`
        // directly: that flag lags the page by a message hop, and a stale
        // "clean" here destroys the pane with no prompt at all.
        // `closeAllTabsAfterConfirmation` reconciles with the page and
        // completes immediately when there is genuinely nothing to ask about.
        if let editor = workspace.editorPane(for: focused), editor.hasLoadedBuffers {
            editorPaneDrainInFlight = true
            editor.closeAllTabsAfterConfirmation { [weak self] proceed in
                guard let self else { return }
                editorPaneDrainInFlight = false
                guard proceed else {
                    // Cancelled: the pane stays, and the row is republished so
                    // whatever the walk did resolve before the cancel is on
                    // disk.
                    persistEditorPanes()
                    return
                }
                destroyPane(focused)
            }
            return
        }
        // A terminal that has been typed into is a conversation, and closing it
        // kills the session — the same loss the engine switch asks about, so it
        // asks the same way and by the same rule: one nobody has typed in has
        // nothing to lose and goes on the spot. A browser pane never asks; its
        // page is a URL away.
        if let descriptor = workspace.descriptor(for: focused),
           descriptor.kind == .terminal,
           workspace.terminalSurface(for: focused)?.hasUserInput == true,
           let container = workspace.container(for: focused) {
            container.presentAsk(
                title: "Close this terminal?",
                message: "The \(descriptor.engine.displayName) conversation running here ends with "
                    + "it, and so does anything the terminal is still doing.",
                icon: descriptor.engine.iconImage,
                options: [
                    PaneAskOption("Keep") { _ in },
                    PaneAskOption("Close Terminal", isPrimary: true) { [weak self] _ in
                        self?.destroyPane(focused)
                    },
                ]
            )
            return
        }
        destroyPane(focused)
    }

    /// The close itself, once nothing is left to ask about. Split out of
    /// `closePane` so the guarded and unguarded paths cannot drift.
    private func destroyPane(_ focused: String) {
        // Only a terminal has a daemon session to kill. The status cleanup
        // below stays unconditional: it is per-pane bookkeeping, and empty
        // for a pane kind that never reported any.
        if workspace.descriptor(for: focused)?.kind == .terminal {
            killSession(focused)
        }
        readySessions.remove(focused)
        sessionStatus.removeValue(forKey: focused)
        // `lastStatus` is per-pane too and was the one sibling this never
        // cleared, so a long-lived window accumulated one entry per pane it
        // ever opened (final whole-branch review, Minor #10). `onExit` already
        // clears it for a session that ends on its own; this is the path
        // where the *user* closes the pane.
        lastStatus.removeValue(forKey: focused)
        lastStatusEventAt.removeValue(forKey: focused)
        activity.forget(paneID: focused)
        statusSeries.forget(paneID: focused)
        workspace.closePane(focused)
    }

    /// ⌘S. Monaco has its own ⌘S while it holds focus, but that only fires
    /// when the keystroke reaches the web view — with focus anywhere else in
    /// the pane there was no way to save at all, and no menu item saying the
    /// command exists. Both routes end at the same `saveActiveTab`.
    @objc func saveActiveFile(_ sender: Any?) {
        focusedEditorPane()?.saveActiveTab()
    }

    /// ⌥⌘S — every unsaved buffer in every editor pane.
    @objc func saveAllFiles(_ sender: Any?) {
        for id in workspace.allPaneIDs {
            workspace.editorPane(for: id)?.saveAllDirty { _ in }
        }
    }

    private func focusedEditorPane() -> EditorPaneView? {
        workspace.focusedPaneID.flatMap { workspace.editorPane(for: $0) }
    }

    /// The engine badge's menu: every engine a terminal can be switched to,
    /// the one it runs now ticked, and the ones whose CLI is not on the `PATH`
    /// greyed rather than missing.
    ///
    /// `EngineLauncher.selectable` is the list — the single place engines are
    /// enumerated, so one added there (a custom engine, later) shows up here
    /// with nothing else to change. Items are targeted at this controller and
    /// carry the pane id rather than reading the focused one, so the menu
    /// answers for the badge that opened it even if focus has moved since.
    func engineMenu(for paneID: String) -> NSMenu {
        let menu = NSMenu()
        // Every item's enabled state is decided right here; letting AppKit
        // re-derive it would grey the lot, since `validateMenuItem` knows
        // nothing about `switchEngine(_:)`.
        menu.autoenablesItems = false
        let current = workspace.descriptor(for: paneID)?.engine
        for engine in EngineLauncher.selectable {
            let installed = EngineLauncher.isInstalled(engine)
            let item = NSMenuItem(
                title: installed ? engine.badgeTitle : "\(engine.badgeTitle) — not installed",
                action: #selector(switchEngine(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = EngineChoice(paneID: paneID, engine: engine)
            item.state = engine == current ? .on : .off
            item.isEnabled = installed && engine != current
            if let icon = engine.iconImage?.copy() as? NSImage {
                icon.size = NSSize(width: 14, height: 14)
                item.image = icon
            }
            menu.addItem(item)
        }
        return menu
    }

    /// What one row of that menu carries. A box rather than a tuple because
    /// `representedObject` is `Any?` and a struct survives the round trip with
    /// its names intact.
    final class EngineChoice: NSObject {
        let paneID: String
        let engine: Engine

        init(paneID: String, engine: Engine) {
            self.paneID = paneID
            self.engine = engine
        }
    }

    @objc func switchEngine(_ sender: Any?) {
        guard let choice = (sender as? NSMenuItem)?.representedObject as? EngineChoice else { return }
        requestEngineSwitch(choice.paneID, to: choice.engine)
    }

    /// Swapping a terminal's engine throws its conversation away: a different
    /// agent means a different process with its own history, not the old
    /// conversation under new management. So it asks first — in the pane
    /// itself, where the conversation it is about to lose is on screen —
    /// whenever there is anything to lose. A terminal nobody has typed in has
    /// nothing to lose and switches on the spot.
    func requestEngineSwitch(_ paneID: String, to engine: Engine) {
        guard let descriptor = workspace.descriptor(for: paneID),
              descriptor.kind == .terminal,
              descriptor.engine != engine
        else { return }
        let typed = workspace.terminalSurface(for: paneID)?.hasUserInput ?? false
        guard typed, let container = workspace.container(for: paneID) else {
            replaceEngine(paneID, with: engine)
            return
        }
        // A pane ask, not an alert — and its icon is the engine being switched
        // *to*, so the card shows you what you are choosing rather than
        // warning you about it (see `PaneAskOverlayView`).
        container.presentAsk(
            title: "Start over with \(engine.displayName)?",
            message: "This terminal's conversation with \(descriptor.engine.displayName) ends here. "
                + "\(engine.displayName) opens a fresh one in its place, in the same folder.",
            icon: engine.iconImage,
            options: [
                PaneAskOption("Stay") { _ in },
                PaneAskOption("Switch to \(engine.displayName)", isPrimary: true) { [weak self] _ in
                    self?.replaceEngine(paneID, with: engine)
                },
            ]
        )
    }

    /// The swap itself — the pane is *replaced*, not restarted in place.
    ///
    /// A terminal's session id is what its Claude conversation is derived from
    /// (`ClaudeConversation`), and an id that has already written one can
    /// never claim it again — so "a new conversation" has to mean a new
    /// session id, and a pane's id is its session id. The replacement is
    /// seated back into the cell the old one held, so nothing moves on screen.
    @discardableResult
    func replaceEngine(_ paneID: String, with engine: Engine) -> Bool {
        guard let old = workspace.descriptor(for: paneID), old.kind == .terminal else { return false }
        let order = workspace.paneIDs
        killSession(paneID)
        readySessions.remove(paneID)
        sessionStatus.removeValue(forKey: paneID)
        lastStatus.removeValue(forKey: paneID)
        lastStatusEventAt.removeValue(forKey: paneID)
        activity.forget(paneID: paneID)
        statusSeries.forget(paneID: paneID)
        workspace.closePane(paneID)
        let newID = UUID().uuidString
        guard addPane(
            RestoredPane(
                sessionID: newID,
                reattaches: false,
                project: old.project,
                engine: engine,
                cwd: old.cwd,
                // The name the user typed is theirs, not the old engine's, so
                // it carries over. A generated one is dropped by `addPane`.
                label: old.label,
                themeId: old.themeId,
                group: old.group,
                groupLabel: old.groupLabel
            ),
            startSession: true
        ) else { return false }
        workspace.reorderPanes(order.map { $0 == paneID ? newID : $0 })
        workspace.focusPane(newID)
        return true
    }

    /// The ⋯ menu's "Rename Conversation…" — one name for both halves of a
    /// terminal: the pane the sidebar shows, and the agent's own conversation,
    /// which only hears about it if `/rename` is typed at it.
    @objc func renameConversation(_ sender: Any?) {
        guard let paneID = workspace.focusedPaneID,
              let descriptor = workspace.descriptor(for: paneID),
              descriptor.kind == .terminal
        else { return }
        askForConversationName(
            current: descriptor.label ?? descriptor.title,
            paneID: paneID
        ) { [weak self] name in
            guard let self,
                  let named = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !named.isEmpty
            else { return }
            renamePane(paneID, to: named)
            // A plain shell has no `/rename`; typing one at it is just a
            // `command not found` in the user's scrollback.
            guard descriptor.engine != .shell else { return }
            workspace.terminalSurface(for: paneID)?.sendInput("/rename \(named)\r")
            lastSyncedName[paneID] = named
        }
    }

    /// The last name each pane's engine was told to use, so the title it
    /// reports back afterwards does not bounce another `/rename` at it.
    private(set) var lastSyncedName: [String: String] = [:]

    /// Half the sync: the pane header follows the agent's reported title on
    /// its own, and this tells the agent to call the conversation the same
    /// thing, so its `/resume` list reads like the sidebar does.
    func syncConversationName(_ paneID: String, to title: String) {
        guard let descriptor = workspace.descriptor(for: paneID),
              descriptor.engine != .shell,   // no `/rename` to type at a plain shell
              descriptor.label == nil,       // a hand-typed name is already the agreed one
              lastSyncedName[paneID] != title
        else { return }
        lastSyncedName[paneID] = title
        workspace.terminalSurface(for: paneID)?.sendInput("/rename \(title)\r")
    }

    /// The names `/color` accepts; anything else comes back as
    /// `Invalid color`, which is why this is a list and not a colour picker.
    static let claudeColors = [
        "red", "blue", "green", "yellow", "purple", "orange", "pink", "cyan", "default",
    ]

    func claudeColorMenu() -> NSMenu {
        let menu = NSMenu()
        for color in Self.claudeColors {
            let item = NSMenuItem(
                title: "",
                action: #selector(changeClaudeColor(_:)),
                keyEquivalent: ""
            )
            item.representedObject = color
            // `item.image` (the icon slot) never actually renders here, on
            // either a lazy or an eagerly-rasterized NSImage — so the dot
            // rides in the title itself, as an inline text attachment, a
            // rendering path AppKit can't silently drop the way it drops
            // the icon slot.
            item.attributedTitle = Self.swatchedTitle(for: color)
            menu.addItem(item)
        }
        return menu
    }

    static func swatchedTitle(for color: String) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = swatch(for: color)
        attachment.bounds = CGRect(x: 0, y: -2, width: 12, height: 12)
        let result = NSMutableAttributedString(attachment: attachment)
        result.append(NSAttributedString(string: "  \(color.capitalized)"))
        return result
    }

    /// The dot beside each name. The submenu is a list of colour *words*, and a
    /// word is a slow way to pick a colour; the swatch is what you actually
    /// read. `default` is the terminal's own colour rather than one of the
    /// nine, so it gets the label grey instead of a lie about which hue it is.
    static func swatch(for color: String) -> NSImage {
        let fill: NSColor
        switch color {
        case "red": fill = .systemRed
        case "blue": fill = .systemBlue
        case "green": fill = .systemGreen
        case "yellow": fill = .systemYellow
        case "purple": fill = .systemPurple
        case "orange": fill = .systemOrange
        case "pink": fill = .systemPink
        case "cyan": fill = .systemTeal
        default: fill = .secondaryLabelColor
        }
        // Rasterized into its own bitmap context up front — not a lazy
        // drawingHandler image (NSMenuItem's own image compositing never
        // calls it) and not lockFocus() either (it draws into whatever
        // context happens to be current, which is unset/inconsistent here
        // since this runs outside any view's draw pass — flaky: it drew once
        // and then came back blank). A dedicated NSBitmapImageRep has no
        // ambient context to depend on, so it renders the same every time.
        let size = NSSize(width: 12, height: 12)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return NSImage(size: size) }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        fill.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    /// One name off that submenu, typed at the terminal.
    @objc func changeClaudeColor(_ sender: Any?) {
        guard let color = (sender as? NSMenuItem)?.representedObject as? String,
              let paneID = workspace.focusedPaneID,
              workspace.descriptor(for: paneID)?.engine == .claude
        else { return }
        workspace.terminalSurface(for: paneID)?.sendCommandClearingInput("/color \(color)")
        // Reflect the choice back to the descriptor so the header badge updates.
        workspace.updateDescriptor(for: paneID) { $0.claudeColor = color }
    }

    /// This pane's model menu.
    ///
    /// Two of the four engines have to be *asked* what they accept, and one of
    /// those asks over the network — so the menu is allowed to open before it
    /// knows. It shows "Loading models…", goes and asks off the main thread,
    /// and rewrites itself in place when the answer lands; `NSMenu` tracks
    /// item changes while it is open, so nothing has to be reopened. The
    /// answer is then cached, and the next open is instant.
    func modelMenu(for paneID: String?) -> NSMenu {
        let menu = NSMenu()
        guard let paneID, let descriptor = workspace.descriptor(for: paneID),
              descriptor.engine != .shell
        else { return menu }
        let engine = descriptor.engine
        let current = descriptor.model
        if let choices = EngineModelList.cached(for: engine) {
            fill(menu, with: choices, current: current, engine: engine)
            return menu
        }
        let loading = NSMenuItem(title: "Loading models…", action: nil, keyEquivalent: "")
        loading.isEnabled = false
        menu.addItem(loading)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let choices = EngineModelList.fetch(for: engine)
            DispatchQueue.main.async {
                guard let self else { return }
                menu.removeAllItems()
                guard !choices.isEmpty else {
                    // Said out loud rather than left as an empty menu: a menu
                    // with nothing in it reads as a bug, and this is a
                    // network call that can simply have failed.
                    let failed = NSMenuItem(
                        title: "Could not reach \(engine.displayName)", action: nil, keyEquivalent: ""
                    )
                    failed.isEnabled = false
                    menu.addItem(failed)
                    return
                }
                self.fill(menu, with: choices, current: current, engine: engine)
            }
        }
        return menu
    }

    private func fill(
        _ menu: NSMenu, with choices: [ModelChoice], current: String?, engine: Engine
    ) {
        for choice in choices {
            let item = NSMenuItem(
                title: choice.label,
                action: #selector(changeModel(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = choice.id
            item.state = EngineModelList.choice(choice, isCurrent: current, engine: engine)
                ? .on : .off
            menu.addItem(item)
        }
    }

    /// One model off that menu, typed at the terminal and remembered.
    ///
    /// Remembered because for every engine but Claude the pick is the only
    /// per-pane answer there is: Codex's config is machine-wide, Copilot's
    /// list is in a database this app does not open, and AntiGravity writes
    /// nothing at all.
    ///
    /// The badge is a different question, and only moves here for the engines
    /// where the pick settles it. `/model` is a *request* to Claude — it can
    /// ask the user to confirm, and declining leaves the terminal on the model
    /// it was already running — so moving the badge on the pick would have it
    /// claim a switch that never happened, with nothing to correct it until
    /// the next reply landed. Instead the pane re-reads its transcript
    /// straight away and the badge lands on what is actually true: for a
    /// declined switch, the model it was already showing. See
    /// `EngineModel.pickIsAuthoritative`.
    @objc func changeModel(_ sender: Any?) {
        guard let model = (sender as? NSMenuItem)?.representedObject as? String,
              let paneID = workspace.focusedPaneID,
              let engine = workspace.descriptor(for: paneID)?.engine,
              let command = EngineModel.switchCommand(engine: engine, model: model)
        else { return }
        workspace.terminalSurface(for: paneID)?.sendCommandClearingInput(command)
        workspace.updateDescriptor(for: paneID) {
            $0.pickedModel = model
            if EngineModel.pickIsAuthoritative(for: engine) { $0.model = model }
        }
        // The badge, the menu's tick and the descriptor all read one value, so
        // this is the whole of keeping them in sync: put the true answer in it.
        workspace.refreshModel(for: paneID)
    }

    /// The `/settings theme` modes Copilot CLI accepts.
    static let copilotThemes = ["default", "github", "dim", "high-contrast", "colorblind"]

    func copilotThemeMenu() -> NSMenu {
        let menu = NSMenu()
        for theme in Self.copilotThemes {
            let item = NSMenuItem(
                title: theme.capitalized,
                action: #selector(changeCopilotTheme(_:)),
                keyEquivalent: ""
            )
            item.representedObject = theme
            item.image = PaneHeaderView.themeIcon(for: theme).copy() as? NSImage
            menu.addItem(item)
        }
        return menu
    }

    @objc func changeCopilotTheme(_ sender: Any?) {
        guard let theme = (sender as? NSMenuItem)?.representedObject as? String,
              let paneID = workspace.focusedPaneID,
              workspace.descriptor(for: paneID)?.engine == .copilot
        else { return }
        workspace.terminalSurface(for: paneID)?.sendCommandClearingInput("/settings theme \(theme)")
        workspace.updateDescriptor(for: paneID) { $0.copilotTheme = theme }
    }

    /// Where the new conversation name comes from. `nil` means "ask with an
    /// `NSAlert`"; a test substitutes an answer, exactly as `directoryChooser`
    /// does, so the rename can run without blocking on a modal.
    var conversationNamePrompt: ((String, @escaping (String?) -> Void) -> Void)?

    /// The rename prompt, on the pane being renamed. `paneID` is what makes it
    /// a pane ask rather than a sheet: the name being changed belongs to *that*
    /// terminal, and a sheet hanging off the window says nothing about which of
    /// twelve it means. Falls back to the sheet only when the pane has no
    /// container to draw on.
    private func askForConversationName(
        current: String,
        paneID: String?,
        completion: @escaping (String?) -> Void
    ) {
        if let conversationNamePrompt {
            conversationNamePrompt(current, completion)
            return
        }
        if let container = paneID.flatMap({ workspace.container(for: $0) }) {
            // No icon: a pencil said nothing the title had not, and a glyph
            // over a text field is one thing too many on a card this small.
            container.presentAsk(
                title: "Rename this conversation",
                input: current,
                options: [
                    PaneAskOption("Cancel") { _ in completion(nil) },
                    PaneAskOption("Rename", isPrimary: true) { name in completion(name) },
                ],
                onCancel: { completion(nil) }
            )
            return
        }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = current
        let alert = NSAlert()
        alert.messageText = "Rename Conversation"
        alert.informativeText = "Renames this pane and tells the agent, with /rename."
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let answer: (NSApplication.ModalResponse) -> Void = { response in
            completion(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
        guard let window else { return answer(alert.runModal()) }
        alert.beginSheetModal(for: window, completionHandler: answer)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newTerminalPane(_:)):
            // The session on screen is the one ⌘T adds to, so its own count
            // is what greys the item out.
            return workspace.paneIDs.count < PaneGrid.maxPanes
                && workspace.terminalPaneCount < PaneWorkspaceView.maxTerminals
        case #selector(newBrowserPane(_:)):
            // A browser pane costs no PTY, so only the on-screen session's
            // grid geometry can refuse one.
            return workspace.paneIDs.count < PaneGrid.maxPanes
        case #selector(newEditorPane(_:)):
            // An editor pane costs no PTY either — same single bound.
            return workspace.paneIDs.count < PaneGrid.maxPanes
        case #selector(newSession(_:)):
            // A new session starts empty — a full one cannot refuse it.
            return workspace.terminalPaneCount < PaneWorkspaceView.maxTerminals
        case #selector(closePane(_:)):
            return workspace.focusedPaneID != nil
        case #selector(saveActiveFile(_:)):
            // Only a file tab has anything to write. Disabled rather than
            // absent, and a disabled item does not swallow ⌘S — so the key
            // keeps reaching whatever else wants it.
            return focusedEditorPane()?.model.activeTab?.kind == .file
        case #selector(saveAllFiles(_:)):
            return workspace.allPaneIDs.contains { workspace.editorPane(for: $0)?.hasLoadedBuffers == true }
        case #selector(renameConversation(_:)):
            // A browser or editor pane has a label but no conversation.
            return workspace.focusedPaneID
                .flatMap { workspace.descriptor(for: $0) }?.kind == .terminal
        case #selector(toggleFocusMode(_:)):
            // `toggleZoom` already refuses below two panes; disabled here
            // too, since an item that visibly does nothing is worse than a
            // greyed-out one. The title flips so the menu tells the truth
            // about what ⌘↩ is about to do — which is decided by the *focused*
            // pane, not by whether anything is zoomed. With a card up and focus
            // moved off it (⌘1…⌘9, ⌥arrows), ⌘↩ hands the card to the focused
            // pane; an item reading "Exit Focus" there was describing the
            // opposite of what it does.
            menuItem.title = workspace.zoomedPaneID != nil
                && workspace.zoomedPaneID == workspace.focusedPaneID
                ? "Exit Focus" : "Focus This Terminal"
            return destination == .terminals
                && workspace.focusedPaneID != nil
                && workspace.paneIDs.count >= 2
        case #selector(enterFocusedSession(_:)):
            return destination == .terminals && currentDeskSessionGroup() != nil
        case #selector(nextSession(_:)):
            return destination == .terminals && stepTarget(by: 1) != nil
        case #selector(previousSession(_:)):
            return destination == .terminals && stepTarget(by: -1) != nil
        case #selector(cycleNextSession(_:)), #selector(cyclePreviousSession(_:)):
            // Cycling only means something with 2+ terminals to move between —
            // pane-granular, matching `wrappingStepTarget`, not `stepTarget`'s
            // session count.
            return destination == .terminals
                && selectedProjectID.map { projectTerminals($0).count > 1 } == true
        case #selector(selectSession(_:)):
            // Nine menu items, rarely nine sessions: the ones past the end are
            // greyed out rather than silently doing nothing.
            return destination == .terminals && deskSession(at: menuItem.tag) != nil
        case #selector(toggleReviewPanel(_:)):
            // Session-scoped: the panel reviews the session on screen, so
            // there has to be one for ⌥⌘B to mean anything.
            return destination == .terminals && workspace.activeGroup != nil
        default:
            return true
        }
    }

    // MARK: - Restoration

    /// Rebuilds the panes the `layout` row describes, once, on the first
    /// connection. An empty or corrupt row falls back to the one bootstrap
    /// pane — but a row that could not be *read* is a different thing
    /// entirely, see `layoutReadFailed`.
    private func restoreWorkspaceIfNeeded() {
        restoreNotificationsIfNeeded()
        guard !layoutReadDispatched else {
            for id in workspace.allPaneIDs where workspace.descriptor(for: id)?.kind == .terminal {
                ensureSession(id)
            }
            return
        }
        layoutReadDispatched = true
        connection.getSetting(key: SettingsKey.layout) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                applyRestoredPanes(WorkspaceRestoration.plan(fromLayout: raw))
            case let .failure(error):
                layoutReadFailed(error)
            }
        }
    }

    /// The `layout` row could not be read.
    ///
    /// This must never be collapsed into "there is no saved layout": that path
    /// bootstraps a pane and writes the resulting one-tab row back, so a
    /// single transient daemon or database error at launch would permanently
    /// destroy the user's saved tabs — in a row the web app also reads.
    ///
    /// So: no panes are invented, the write gate stays shut (⌘T still works,
    /// it just is not persisted), the failure is surfaced the same way
    /// `ensureSession`'s own `.failure` arm surfaces one, and the read is
    /// re-armed so the next reconnect retries instead of leaving the window
    /// degraded for the rest of the session.
    func layoutReadFailed(_ error: Error) {
        layoutReadDispatched = false
        applyConnectionStatus("Couldn't read the saved layout — \(error.localizedDescription)")
    }

    /// Adds every planned pane the window does not already have, then brings
    /// each pane's session up. Split out from `restoreWorkspaceIfNeeded` so a
    /// plan can be applied in a test without a socket.
    func applyRestoredPanes(_ panes: [RestoredPane]) {
        // Only here, with the row's contents actually in hand, does writing
        // back become safe.
        layoutReadCompleted = true
        let plan = panes.isEmpty && workspace.allPaneIDs.isEmpty
            ? [WorkspaceRestoration.bootstrapPane()]
            : panes
        for pane in plan where workspace.descriptor(for: pane.sessionID) == nil {
            addPane(pane, startSession: false)
        }
        // The saved order is the order, on every launch — see
        // `PaneWorkspaceView.reorderPanes`.
        workspace.reorderPanes(plan.map(\.sessionID))
        // Terminals only: an unfiltered browser pane id reaching
        // `ensureSession` would fall through to `createSession`, whose
        // missing-engine default is `.shell` — a silent login shell.
        for id in workspace.allPaneIDs where workspace.descriptor(for: id)?.kind == .terminal {
            ensureSession(id)
        }
        workspace.restoreFocus()
        // The plan came *from* the row, so re-writing it is normally a no-op;
        // it matters when restoration repaired something (a capped ninth
        // pane, a minted id) — the repair is what the next launch should see,
        // and when a pane was opened while the read was still in flight.
        persistLayout()
        // Terminals restore first, so the grid's fill order favors them —
        // browser and editor panes only ever land on the cells terminals
        // left empty.
        restoreBrowserPanesIfNeeded()
        restoreEditorPanesIfNeeded()
        // Dispatched from here rather than from `connect` because its apply
        // prunes against the restored groups — read before the panes exist,
        // every entry would look vanished.
        restoreSessionMetaIfNeeded()
        // Same reasoning: the review panel row prunes against the restored
        // groups, and its apply re-opens the panel for the session on screen.
        restoreReviewPanelIfNeeded()
    }

    /// Kills daemon sessions this window no longer references.
    ///
    /// The daemon outliving the app is the feature that keeps terminals
    /// running across a restart — but nothing ever cleaned up the sessions a
    /// restart left *behind*, and the daemon caps at `MAX_SESSIONS` (64, in
    /// `crates/omniagent-pty-daemon/src/session.rs`). Orphans accumulate one
    /// abandoned pane at a time until the cap is full, and from then on every
    /// new terminal is refused with "maximum of 8 sessions reached" — which
    /// this app rendered as a pane containing nothing but a blinking cursor.
    /// Observed in the wild at 8 live sessions against a 2-pane layout, one of
    /// the orphans five days old.
    ///
    /// Deliberately gated on a *successful* layout restore. The restored panes
    /// are the definition of "sessions this window owns", so reaping against a
    /// layout that failed to load would kill the user's live terminals — the
    /// same reasoning that gates the layout write.
    /// Runs once per launch, off the session list `ensureSession` already
    /// fetches — no extra round trip, and early enough to matter.
    private func reapOrphanedSessions(daemonSessions: [String]) {
        guard layoutReadCompleted, !reapDispatched else { return }
        reapDispatched = true
        let orphans = Self.orphanedSessions(
            daemonSessions: daemonSessions,
            owned: Set(workspace.allPaneIDs)
        )
        for id in orphans {
            killSession(id)
            readySessions.remove(id)
            lastStatus.removeValue(forKey: id)
            lastStatusEventAt.removeValue(forKey: id)
            activity.forget(paneID: id)
            statusSeries.forget(paneID: id)
        }
    }

    /// Every daemon kill funnels through here so `sessionKiller` sees them
    /// all — the seam the "a browser pane is never killed" test watches.
    private func killSession(_ id: String) {
        if let sessionKiller { sessionKiller(id) } else { connection.kill(sessionID: id) }
    }

    /// Which of the daemon's sessions belong to nobody. Pure, and separate
    /// from the call that kills them, because this is the decision that must
    /// not be wrong.
    ///
    /// An empty `owned` reaps nothing rather than everything. A restore always
    /// leaves at least one pane (it bootstraps when the layout is empty), so
    /// owning nothing means something went wrong upstream — and "the app knows
    /// about no sessions" is exactly the state in which killing every session
    /// on the machine would be the worst possible move.
    static func orphanedSessions(daemonSessions: [String], owned: Set<String>) -> [String] {
        guard !owned.isEmpty else { return [] }
        return daemonSessions.filter { !owned.contains($0) }
    }

    // MARK: - Command palette

    /// ⌘K. The list is rebuilt from the live workspace on every open, so it
    /// can never offer a pane that closed while the palette was shut.
    ///
    /// experiment (2026-08-26): dismisses any open hover card first. Hovering
    /// a session then opening search left the card's tick timer/resize
    /// machinery running while the palette's own presentation animated in —
    /// two windows animating at once, no guard between them — matching an
    /// "Invalid view geometry: y is NaN" crash in SessionHoverCard. Instant
    /// (fade: 0), not the card's usual 0.09s goodbye: this is a defensive
    /// clear-the-deck, not a UX-driven dismiss.
    @objc func showCommandPalette(_ sender: Any?) {
        hoverCard.dismiss(fade: 0)
        palette.onRun = { [weak self] action in self?.run(action) }
        palette.present(
            commands: CommandPaletteModel.build(
                panes: workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) },
                paneOrder: workspace.allPaneIDs,
                focusedPaneID: workspace.focusedPaneID,
                unreadNotifications: notifier.unreadCount,
                nextSessionName: SessionOutline.nextSessionName(
                    workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) },
                    project: workspace.focusedPaneID
                        .flatMap { workspace.descriptor(for: $0)?.project } ?? ""
                ),
                projectLabels: projectLabels,
                hasGitRepo: latestGitStatus != nil
            ),
            files: repoFiles,
            filesRoot: latestGitStatus?.root,
            over: window
        )
    }

    /// The one place a palette row becomes a workspace command — every arm
    /// calls the same method the menu item and the toolbar button call, so
    /// the three can never drift.
    func run(_ action: PaletteAction) {
        switch action {
        case let .focusPane(sessionID):
            revealPane(sessionID)
        case let .closePane(sessionID):
            workspace.focusPane(sessionID)
            closePane(nil)
        case .newPane:
            newTerminalPane(nil)
        case .newBrowserPane:
            newBrowserPane(nil)
        case .newEditorPane:
            newEditorPane(nil)
        case let .openDiffForCurrentFile(path):
            openDiffInEditor(URL(fileURLWithPath: path))
        case let .showDestination(destination):
            applyDestination(destination)
        case let .openFile(path):
            openFileInEditor(URL(fileURLWithPath: path), pinned: true)
            // `openFileInEditor` focuses the pane it landed in but knows
            // nothing about focus mode; without this a file in a second pane
            // of the *same* session opens behind the zoomed card.
            if let focused = workspace.focusedPaneID { _ = revealPane(focused) }
        case .showAllChanges:
            openChangesOverview()
        case .newSession:
            newSession(nil)
        case let .enterSession(group):
            enterDeskSession(group)
        // Interrupt and reattach are the focused terminal's own responder
        // actions (`TerminalSurfaceView`), reached here directly rather than
        // re-implemented, so the palette runs the identical code the ⌘. and
        // ⌘R menu items do.
        case .interruptFocusedPane:
            workspace.focusedPaneID.flatMap { workspace.terminalSurface(for: $0) }?.interruptSession(nil)
        case .reattachFocusedPane:
            workspace.focusedPaneID.flatMap { workspace.terminalSurface(for: $0) }?.reattachSession(nil)
        case .toggleSidebar:
            toggleWorkspaceSidebar(nil)
        case .clearNotifications:
            notifier.clear()
        case let .searchBrain(query):
            connection.search(query: query, scope: nil) { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(hits):
                    presentSearchResults(hits, for: query)
                case .failure:
                    palette.present(
                        commands: [PaletteCommand(id: "search-error", title: "Brain search failed.", detail: nil, action: .noop, section: .brain)],
                        over: window
                    )
                }
            }
        case let .revealProjectContext(project):
            showInspector(for: project)
        case .noop:
            break
        }
    }

    // MARK: - Desk canvas commands

    func enterDeskSession(_ group: String) {
        workspace.activateGroup(group)
        // The sidebar's current-session highlight is derived from the focused
        // pane, which the line above has just moved.
        reloadOutline()
    }

    /// Which session the Desk is about right now.
    ///
    /// Deliberately the *visible* session of the selected project first, and
    /// only then the one holding focus: selecting a workspace does not move
    /// focus, so focus routinely belongs to another project entirely, and
    /// "which session should this project show" is a different question from
    /// "which session has the cursor in it".
    func currentDeskSessionGroup() -> String? {
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        if let project = selectedProjectID,
           let visible = SessionOutline.visibleSessionGroupID(
               panes,
               project: project,
               focusedPaneID: workspace.focusedPaneID
           ) {
            return visible
        }
        return SessionOutline.currentSessionGroupID(panes, focusedPaneID: workspace.focusedPaneID)
    }

    /// Enter whichever session the Desk is currently about.
    @objc func enterFocusedSession(_ sender: Any?) {
        guard let group = currentDeskSessionGroup() else { return }
        enterDeskSession(group)
    }

    /// ⌃1…⌃9. The `selectPane:` precedent exactly — the digit rides on the
    /// menu item's tag — but scoped to the sessions of the *selected project*,
    /// because that is what the sidebar is showing rows for.
    @objc func selectSession(_ sender: Any?) {
        guard let index = (sender as? NSMenuItem)?.tag, index >= 1,
              let node = deskSession(at: index) else { return }
        enterDeskSession(node.id)
    }

    @objc func nextSession(_ sender: Any?) { stepSession(by: 1) }

    @objc func previousSession(_ sender: Any?) { stepSession(by: -1) }

    /// ⌃⇥ / ⌃⇧⇥ — same step, but wraps past either end, the shape Terminal.app
    /// and every tabbed browser use for tab-cycling chords. `⇧⌘]`/`⇧⌘[` stay
    /// non-wrapping on purpose (see `stepTarget`); this pair exists because a
    /// *cyclical* Tab chord is its own, separate ask.
    @objc func cycleNextSession(_ sender: Any?) { stepSession(by: 1, wrapping: true) }

    @objc func cyclePreviousSession(_ sender: Any?) { stepSession(by: -1, wrapping: true) }

    /// What `stepSession` would land on — split out so `validateMenuItem` greys
    /// the item out on exactly the condition the command refuses on.
    ///
    /// `adjacentSessionTab` answers with a *pane*, the web build's own shape,
    /// and both ends stop rather than wrap: index -1 and index >= count are
    /// both "nothing there", which is why nothing here is a modulo.
    private func stepTarget(by offset: Int) -> PaneDescriptor? {
        guard let project = selectedProjectID else { return nil }
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        return SessionOutline.adjacentSessionTab(
            panes,
            project: project,
            focusedPaneID: workspace.focusedPaneID,
            offset: offset
        )
    }

    /// Every terminal pane in `project`, in fill order — the flat list
    /// `⌃⇥`/`⌃⇧⇥` cycle over.
    private func projectTerminals(_ project: String) -> [PaneDescriptor] {
        workspace.allPaneIDs
            .compactMap { workspace.descriptor(for: $0) }
            .filter { $0.project == project && $0.kind == .terminal }
    }

    /// `stepTarget`'s wrapping cousin — but pane-granular, not session-granular.
    /// `adjacentSessionTab` (what `stepTarget` walks) only ever answers with a
    /// session's *first* pane, so a session holding more than one terminal
    /// (⌘T, "New Terminal Pane", joins the *current* session rather than
    /// minting a new one) left every terminal past the first unreachable by
    /// this chord. Walking `projectTerminals` directly instead visits every
    /// terminal that exists, including ones added after launch. Only ever
    /// called with `offset` ±1, so a single modulo step is all this needs.
    private func wrappingStepTarget(by offset: Int) -> PaneDescriptor? {
        guard let project = selectedProjectID else { return nil }
        let terminals = projectTerminals(project)
        guard !terminals.isEmpty else { return nil }
        let currentIndex = terminals.firstIndex { $0.sessionID == workspace.focusedPaneID } ?? -1
        let base = currentIndex == -1 ? 0 : currentIndex
        let wrapped = ((base + offset) % terminals.count + terminals.count) % terminals.count
        return terminals[wrapped]
    }

    /// ⇧⌘] / ⇧⌘[, and (wrapping) ⌃⇥ / ⌃⇧⇥.
    ///
    /// The two diverge past `wrappingStepTarget`/`stepTarget` themselves: the
    /// non-wrapping walk lands on a *session*, so entering it is enough — the
    /// wrapping walk can land on a second terminal *inside the already-active*
    /// session, where `enterDeskSession` would see no group change and leave
    /// focus exactly where it was. `focusPane` moves focus to that specific
    /// pane regardless of which session it is in.
    private func stepSession(by offset: Int, wrapping: Bool = false) {
        if wrapping {
            guard let target = wrappingStepTarget(by: offset) else { return }
            workspace.focusPane(target.sessionID)
            reloadOutline()
            return
        }
        guard let target = stepTarget(by: offset) else { return }
        enterDeskSession(target.group)
    }

    /// The 1-based Nth session of the selected project, or nil past the end.
    private func deskSession(at index: Int) -> SessionGroupNode? {
        guard let project = selectedProjectID else { return nil }
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        let sessions = SessionOutline.group(panes, focusedPaneID: workspace.focusedPaneID)
            .first { $0.project == project }?
            .sessions ?? []
        guard sessions.indices.contains(index - 1) else { return nil }
        return sessions[index - 1]
    }

    /// The palette's "results mode": the same panel, its rows swapped for
    /// what the search found — the native shape of the web palette's own
    /// `searchResults` view replacing its action list in place.
    private func presentSearchResults(_ hits: [BrainNodeView], for query: String) {
        let rows: [PaletteCommand]
        if hits.isEmpty {
            rows = [
                PaletteCommand(
                    id: "no-results",
                    title: "No matches in the brain for \u{201C}\(query)\u{201D}.",
                    detail: nil,
                    action: .noop,
                    section: .brain
                ),
            ]
        } else {
            rows = hits.map { hit in
                PaletteCommand(
                    id: "hit:\(hit.id)",
                    title: "\(hit.label) — \(SessionOutline.projectLabel(hit.project, labels: projectLabels))",
                    detail: hit.kind,
                    action: .revealProjectContext(project: hit.project),
                    section: .brain
                )
            }
        }
        palette.present(commands: rows, over: window)
    }

    /// Named away from AppKit's `toggleSidebar:` on purpose. Toolbar items and
    /// menu items here target `nil` and travel the responder chain, and
    /// `NSSplitViewController` — the content view controller, so *ahead* of
    /// this object in that chain — implements `toggleSidebar:` itself. It was
    /// swallowing both, and refusing to validate either, because the split has
    /// no `.sidebar`-behavior item to act on: the toolbar button greyed out
    /// and ⌃⌘S did nothing. Nothing answers this name but us.
    @objc func toggleWorkspaceSidebar(_ sender: Any?) {
        splitController?.splitViewItems.first?.animator().isCollapsed.toggle()
    }

    // MARK: - Session outline

    /// The sidebar's tree shows every workspace with its sessions inline —
    /// the 2026-08-20 redesign dropped the per-workspace scoping, so this
    /// hands over the whole picture: the brain's project list and every live
    /// pane.
    private func reloadOutline() {
        let all = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        shellSidebar.reloadWorkspaces(
            workspaces: Self.openWorkspaces(workspaces, closed: closedWorkspaceIDs),
            panes: all,
            // Only on the Desk is a session actually "on the screen" — off it,
            // no session row may claim to be current, the same rule that
            // already leaves every nav row unlit while a session is (see
            // `applyDestination`/`NavigationSidebarView.applyDestination`).
            // Otherwise a session stays lit under Home/To Do forever, since
            // nothing else ever un-focuses a pane.
            focusedPaneID: destination == .terminals ? workspace.focusedPaneID : nil,
            statuses: lastStatus,
            projectLabels: projectLabels,
            eventTimes: lastStatusEventAt,
            customizations: sidebarCustomizations(),
            sessionMeta: sessionMeta
        )
    }

    /// The web build's `openWorkspaces` (`ui/src/state/closedWorkspaces.ts`),
    /// shape-for-shape: the brain's project list minus the ids the user
    /// closed, order untouched. A closed workspace that still has live panes
    /// deliberately re-enters through the pane-derived path — a session on
    /// screen must stay reachable.
    static func openWorkspaces(
        _ workspaces: [BrainProjectSummary],
        closed: Set<String>
    ) -> [BrainProjectSummary] {
        guard !closed.isEmpty else { return workspaces }
        return workspaces.filter { !closed.contains($0.id) }
    }

    /// The stored customizations re-keyed by workspace *id* for the sidebar,
    /// which never sees paths. The row itself is keyed by path (stable
    /// across brain rebuilds, which can re-mint ids) — `customizationKey`.
    private func sidebarCustomizations() -> [String: WorkspaceCustomization] {
        guard !workspaceCustomizations.isEmpty else { return [:] }
        var ids = Set(workspaces.map(\.id))
        for paneID in workspace.allPaneIDs {
            if let project = workspace.descriptor(for: paneID)?.project, !project.isEmpty {
                ids.insert(project)
            }
        }
        var byID: [String: WorkspaceCustomization] = [:]
        for id in ids {
            if let custom = workspaceCustomizations[customizationKey(for: id)] {
                byID[id] = custom
            }
        }
        return byID
    }

    /// Where a workspace's customization is stored: its path (the brain's
    /// recorded folder, else a live pane's cwd), falling back to the id for
    /// a workspace with no known directory at all.
    func customizationKey(for id: String) -> String {
        workspaceDirectory(for: id) ?? id
    }

    /// What the sidebar prints for this workspace — the customization's
    /// display name when one is stored, the same override the tree applies.
    private func sidebarDisplayLabel(for id: String) -> String {
        workspaceCustomizations[customizationKey(for: id)]?.displayName
            ?? workspaces.first { $0.id == id }?.label
            ?? SessionOutline.projectLabel(id, labels: projectLabels)
    }

    /// The sidebar's folder colour for this workspace, `nil` for the default.
    private func sidebarTint(for id: String) -> NSColor? {
        workspaceCustomizations[customizationKey(for: id)]?.color?.tint
    }

    /// The project directory every project-label-aware surface
    /// (outline/palette/inspector) shares — refreshed on every connect
    /// (cheap, read-only, unlike the `layout` row there is no destructive
    /// write this could clobber, so no "read once" guard is needed).
    func refreshProjectLabels() {
        connection.listProjects { [weak self] result in
            guard let self, case let .success(projects) = result else { return }
            projectLabels = Dictionary(projects.map { ($0.id, $0.label) }, uniquingKeysWith: { _, newest in newest })
            workspaces = projects
            // A workspace already open keeps its back row, but now with the
            // real label and path this read just supplied instead of the id
            // `selectWorkspace` had to fall back to.
            if let selectedProjectID { selectWorkspace(id: selectedProjectID, animated: false) }
            selectInitialWorkspaceIfNeeded(animated: false)
            reloadOutline()
        }
    }

    /// Renames a session — the name is stored on every pane in the group,
    /// exactly as `session/renamed` does in the web build, which is what
    /// makes one array the whole restore story.
    /// A name the user typed for one terminal. Stored on the pane, which is
    /// what makes it outrank the summary the agent keeps reporting — the whole
    /// point of renaming one is that it stops moving.
    func renamePane(_ paneID: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        workspace.updateDescriptor(for: paneID) { $0.label = trimmed }
    }

    func renameSession(_ session: SessionGroupNode, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        for paneID in session.paneIDs {
            workspace.updateDescriptor(for: paneID) { $0.groupLabel = trimmed }
        }
    }

    // MARK: - Workspace context menu (2026-08-20 redesign §3)

    /// The workspace row's right-click menu, built fresh per click so the
    /// GitHub item reflects the remote as it is *now*.
    func workspaceContextMenu(for id: String) -> NSMenu {
        let directory = workspaceDirectory(for: id)
        return WorkspaceContextMenu.build(
            gitHubURL: directory.flatMap(WorkspaceContextMenu.gitHubRepositoryURL(inDirectory:)),
            newSession: { [weak self] in
                guard let self else { return }
                startSession(inDirectory: workspaceDirectory(for: id) ?? "", project: id)
            },
            showInFinder: { [weak self] in
                guard let self, let directory = workspaceDirectory(for: id) else { return }
                revealInFinder(directory)
            },
            openOnGitHub: { [weak self] url in self?.openExternally(url) },
            customize: { [weak self] in self?.presentCustomizeWorkspace(id) },
            remove: { [weak self] in self?.removeWorkspace(id) }
        )
    }

    private func revealInFinder(_ path: String) {
        if let fileRevealer {
            fileRevealer(path)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Customize…: the card over the whole window (the subject is a sidebar
    /// row, not a pane, so this is not a pane ask), seeded with what is
    /// stored for the workspace.
    func presentCustomizeWorkspace(_ id: String) {
        guard customizeCard == nil, let content = window?.contentView else { return }
        let card = WorkspaceCustomizeCard(
            folderName: customizationFolderName(for: id),
            current: workspaceCustomizations[customizationKey(for: id)]
        )
        card.onCancel = { [weak self] in self?.dismissCustomizeCard() }
        card.onSave = { [weak self] customization in
            guard let self else { return }
            saveWorkspaceCustomization(customization, forWorkspace: id)
            dismissCustomizeCard()
        }
        card.frame = content.bounds
        card.autoresizingMask = [.width, .height]
        content.addSubview(card)
        customizeCard = card
        window?.makeFirstResponder(card.firstResponderView)
        card.selectInput()
    }

    private func dismissCustomizeCard() {
        customizeCard?.removeFromSuperview()
        customizeCard = nil
    }

    /// A `PaneAskOverlayView` over the whole window instead of one pane —
    /// for a blocking question that is not about any single pane but still
    /// wants the same glass-and-card treatment as one, `presentAsk`'s pattern
    /// (`PaneAskOverlayView`) with `presentCustomizeWorkspace`'s mount point.
    /// Pass `severity: .critical` for a destructive question — deleting a
    /// session, say — and the card tints red instead of navy.
    func presentWindowAsk(
        title: String,
        message: String = "",
        icon: NSImage? = nil,
        severity: PaneAskOverlayView.Severity = .question,
        options: [PaneAskOption],
        onCancel: @escaping () -> Void = {}
    ) {
        guard windowAskOverlay == nil, let content = window?.contentView else { return }
        // The window and app come forward exactly as the `NSAlert` this
        // replaces would have — `PaneContainerView.presentAsk`'s reasoning:
        // a custom overlay does not get that for free.
        if let window {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate()
        let overlay = PaneAskOverlayView(
            title: title,
            message: message,
            icon: icon,
            input: nil,
            options: options.map { option in
                PaneAskOption(option.title, isPrimary: option.isPrimary) { [weak self] text in
                    self?.dismissWindowAsk()
                    option.action(text)
                }
            },
            severity: severity,
            cardWidth: 380
        )
        overlay.onCancel = { [weak self] in
            self?.dismissWindowAsk()
            onCancel()
        }
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        windowAskOverlay = overlay
        window?.makeFirstResponder(overlay.firstResponderView)
    }

    private func dismissWindowAsk() {
        windowAskOverlay?.removeFromSuperview()
        windowAskOverlay = nil
    }

    /// The field's placeholder and the caption's fallback: the folder's own
    /// name — what the row shows when nothing is customized.
    private func customizationFolderName(for id: String) -> String {
        if let directory = workspaceDirectory(for: id), !directory.isEmpty {
            return (directory as NSString).lastPathComponent
        }
        return workspaces.first { $0.id == id }?.label
            ?? SessionOutline.projectLabel(id, labels: projectLabels)
    }

    /// Stores (or, for an empty customization, clears) one workspace's
    /// customization and re-renders everywhere the label shows.
    func saveWorkspaceCustomization(
        _ customization: WorkspaceCustomization,
        forWorkspace id: String
    ) {
        let key = customizationKey(for: id)
        if customization.isEmpty {
            workspaceCustomizations.removeValue(forKey: key)
        } else {
            workspaceCustomizations[key] = customization
        }
        persistWorkspaceCustomizations()
        reloadOutline()
        if destination == .home { refreshHomeChips() }
    }

    /// Remove workspace: confirm — naming the workspace and how many
    /// sessions end with it — then close every one of its sessions and
    /// record the workspace closed.
    ///
    /// There is deliberately no daemon RPC behind this: the daemon's roots
    /// protocol has no removal (and the brain's graph should survive — an
    /// hour of ingestion must not be one click from destruction). This is
    /// the web build's close-workspace path, row for row: kill the daemon
    /// sessions, write the id into `closed_workspaces`, leave the folder and
    /// the graph alone. Re-adding the folder or starting a session in the
    /// workspace brings the row straight back.
    func removeWorkspace(_ id: String) {
        let panes = workspace.allPaneIDs
            .compactMap { workspace.descriptor(for: $0) }
            .filter { $0.project == id }
        confirmWorkspaceRemoval(
            label: sidebarDisplayLabel(for: id),
            sessionCount: Set(panes.map(\.group)).count
        ) { [weak self] confirmed in
            guard confirmed else { return }
            self?.performRemoveWorkspace(id)
        }
    }

    private func confirmWorkspaceRemoval(
        label: String,
        sessionCount: Int,
        completion: @escaping (Bool) -> Void
    ) {
        if let workspaceRemovalConfirmer {
            workspaceRemovalConfirmer(label, sessionCount, completion)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Remove \(label) from OmniAgent?"
        let sessions: String
        switch sessionCount {
        case 0: sessions = ""
        case 1: sessions = "Its session ends with it. "
        default: sessions = "Its \(sessionCount) sessions end with it. "
        }
        alert.informativeText = sessions
            + "The folder on disk is untouched, and adding it again brings the workspace back."
        alert.addButton(withTitle: "Remove Workspace")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard let window else {
            completion(alert.runModal() == .alertFirstButtonReturn)
            return
        }
        alert.beginSheetModal(for: window) { response in
            completion(response == .alertFirstButtonReturn)
        }
    }

    private func performRemoveWorkspace(_ id: String) {
        // ⌘W's gate before ⌘W's destroy: an editor pane in the workspace can
        // be holding the only copy of unsaved work, so every buffer is
        // drained with save prompts first, and a cancel there aborts the
        // whole removal with the panes intact.
        let paneIDs = workspace.allPaneIDs.filter { workspace.descriptor(for: $0)?.project == id }
        drainEditorPanes(in: paneIDs) { [weak self] proceed in
            guard proceed, let self else { return }
            // `destroyPane` kills each terminal's daemon session and does
            // the per-pane bookkeeping — one close path, not two that drift.
            for paneID in paneIDs {
                destroyPane(paneID)
            }
            closedWorkspaceIDs.insert(id)
            persistClosedWorkspaces()
            if selectedProjectID == id {
                selectedProjectID = nil
                selectInitialWorkspaceIfNeeded(animated: false)
            }
            reloadOutline()
        }
    }

    private func restoreWorkspaceCustomizationsIfNeeded() {
        guard !customizationsReadDispatched else { return }
        customizationsReadDispatched = true
        connection.getSetting(key: SettingsKey.workspaceCustomizations) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                applyRestoredWorkspaceCustomizations(raw)
            case .failure:
                // Re-armed for the next reconnect; the write gate stays
                // shut so a save cannot overwrite a row nothing has read —
                // `layoutReadFailed`'s reasoning.
                customizationsReadDispatched = false
            }
        }
    }

    private func restoreClosedWorkspacesIfNeeded() {
        guard !closedWorkspacesReadDispatched else { return }
        closedWorkspacesReadDispatched = true
        connection.getSetting(key: SettingsKey.closedWorkspaces) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                applyRestoredClosedWorkspaces(raw)
            case .failure:
                closedWorkspacesReadDispatched = false
            }
        }
    }

    /// Applies the `workspace_customizations_native` row and opens its write
    /// gate — split out of the read so a test can restore without a socket,
    /// `applyRestoredPanes`'s pattern.
    func applyRestoredWorkspaceCustomizations(_ raw: String?) {
        customizationsReadDispatched = true
        customizationsReadCompleted = true
        workspaceCustomizations = WorkspaceCustomizationsCodec.deserialize(raw)
        reloadOutline()
    }

    /// `applyRestoredWorkspaceCustomizations`'s twin for the shared
    /// `closed_workspaces` row.
    func applyRestoredClosedWorkspaces(_ raw: String?) {
        closedWorkspacesReadDispatched = true
        closedWorkspacesReadCompleted = true
        closedWorkspaceIDs = ClosedWorkspacesCodec.deserialize(raw)
        reloadOutline()
    }

    private func persistWorkspaceCustomizations() {
        guard customizationsReadCompleted else { return }
        write(
            WorkspaceCustomizationsCodec.serialize(workspaceCustomizations),
            to: SettingsKey.workspaceCustomizations
        )
    }

    private func persistClosedWorkspaces() {
        guard closedWorkspacesReadCompleted else { return }
        write(ClosedWorkspacesCodec.serialize(closedWorkspaceIDs), to: SettingsKey.closedWorkspaces)
    }

    // MARK: - Session context menu (2026-08-20 redesign §3)

    /// The session row's right-click menu, built fresh per click so the pin
    /// item and the installed-app submenu both read the world as it is now.
    func sessionContextMenu(for session: SessionGroupNode) -> NSMenu {
        SessionContextMenu.build(
            pinned: sessionMeta[session.id]?.pinned ?? false,
            openIn: SessionContextMenu.installedApps(
                locator: appLocator
                    ?? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            ),
            rename: { [weak self] in self?.beginSessionRename(session.id) },
            togglePin: { [weak self] in
                guard let self else { return }
                setSessionPinned(session.id, !(sessionMeta[session.id]?.pinned ?? false))
            },
            openInApp: { [weak self] target in self?.openSession(session, in: target) },
            createNested: { [weak self] in
                guard let self else { return }
                startSession(
                    inDirectory: workspaceDirectory(for: session.project) ?? session.cwd,
                    project: session.project,
                    parent: session.id
                )
            },
            delete: { [weak self] in self?.deleteSession(session) }
        )
    }

    /// Rename from the menu is the double-click affordance made findable —
    /// it puts the row's own inline editor up, not a dialog.
    func beginSessionRename(_ groupID: String) {
        (shellSidebar.workspacesTree.rowView(for: .session(groupID)) as? SessionRowView)?
            .beginRenaming()
    }

    /// Pins (or unpins) one session and re-sorts its workspace on the spot.
    func setSessionPinned(_ groupID: String, _ pinned: Bool) {
        var entry = sessionMeta[groupID] ?? SessionMeta()
        entry.pinned = pinned
        if entry.isEmpty {
            sessionMeta.removeValue(forKey: groupID)
        } else {
            sessionMeta[groupID] = entry
        }
        persistSessionMeta()
        reloadOutline()
    }

    /// Open in…: the session's own cwd, in the chosen app.
    private func openSession(_ session: SessionGroupNode, in target: SessionContextMenu.OpenTarget) {
        let directory = session.cwd.isEmpty
            ? (workspaceDirectory(for: session.project) ?? "")
            : session.cwd
        guard !directory.isEmpty else { return }
        if let appOpener {
            appOpener(target.url, directory)
            return
        }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: directory, isDirectory: true)],
            withApplicationAt: target.url,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    /// Delete session: confirm — naming the session and how many panes end
    /// with it — then destroy every pane in the group (and in every session
    /// nested under it) and prune its meta.
    func deleteSession(_ session: SessionGroupNode) {
        confirmSessionDeletion(
            label: session.label,
            paneCount: paneIDsToDelete(with: session.id).count
        ) { [weak self] confirmed in
            guard confirmed else { return }
            self?.performDeleteSession(session.id)
        }
    }

    /// Every pane a deletion takes: the session's own plus those of every
    /// session nested under it, transitively — a child created under the
    /// deleted session has no parent to live under. Read live from the
    /// workspace rather than the row's `paneIDs` snapshot, so a pane opened
    /// while the confirmation was up dies with the rest instead of keeping
    /// the "deleted" session alive in the sidebar.
    private func paneIDsToDelete(with root: String) -> [String] {
        var groups: Set<String> = [root]
        var grew = true
        while grew {
            grew = false
            for (group, entry) in sessionMeta where !groups.contains(group) {
                if let parent = entry.parent, groups.contains(parent) {
                    groups.insert(group)
                    grew = true
                }
            }
        }
        return workspace.allPaneIDs.filter { groups.contains(workspace.descriptor(for: $0)?.group ?? "") }
    }

    private func confirmSessionDeletion(
        label: String,
        paneCount: Int,
        completion: @escaping (Bool) -> Void
    ) {
        if let sessionDeletionConfirmer {
            sessionDeletionConfirmer(label, paneCount, completion)
            return
        }
        let panes = paneCount == 1
            ? "Its pane closes with it"
            : "Its \(paneCount) panes close with it"
        presentWindowAsk(
            title: "Delete \(label)?",
            message: panes + ", and every conversation running in them ends.",
            icon: NSImage(systemSymbolName: "trash", accessibilityDescription: nil),
            severity: .critical,
            options: [
                PaneAskOption("Cancel") { _ in completion(false) },
                PaneAskOption("Delete Session", isPrimary: true) { _ in completion(true) },
            ],
            onCancel: { completion(false) }
        )
    }

    private func performDeleteSession(_ root: String) {
        let paneIDs = paneIDsToDelete(with: root)
        // ⌘W's gate before ⌘W's destroy: an editor pane in the group can be
        // holding the only copy of unsaved work, so every buffer is drained
        // with save prompts first, and a cancel there aborts the whole
        // deletion with the panes intact.
        drainEditorPanes(in: paneIDs) { [weak self] proceed in
            guard proceed, let self else { return }
            // `destroyPane` is the one close path — daemon kills and per-pane
            // bookkeeping included, exactly as ⌘W's proceed branch and
            // Remove-workspace's.
            for paneID in paneIDs {
                destroyPane(paneID)
            }
            // Prune rather than a single removal: the group's own entry goes,
            // and so does any child's now-dangling parent pointer.
            sessionMeta = SessionMeta.pruned(sessionMeta, live: liveSessionGroups())
            persistSessionMeta()
            reloadOutline()
        }
    }

    /// Every group a live pane carries — what session-meta pruning trusts.
    private func liveSessionGroups() -> Set<String> {
        Set(workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0)?.group })
    }

    private func restoreSessionMetaIfNeeded() {
        guard !sessionMetaReadDispatched else { return }
        sessionMetaReadDispatched = true
        connection.getSetting(key: SettingsKey.sessionMeta) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                applyRestoredSessionMeta(raw)
            case .failure:
                // Re-armed for the next reconnect; the write gate stays
                // shut — `layoutReadFailed`'s reasoning.
                sessionMetaReadDispatched = false
            }
        }
    }

    /// Applies the `session_meta_native` row and opens its write gate —
    /// split out of the read so a test can restore without a socket,
    /// `applyRestoredPanes`'s pattern. Entries for groups no restored pane
    /// carries are pruned here, and a prune that changed anything is
    /// written straight back so the next launch reads the row clean.
    func applyRestoredSessionMeta(_ raw: String?) {
        sessionMetaReadDispatched = true
        sessionMetaReadCompleted = true
        let stored = SessionMetaCodec.deserialize(raw)
        sessionMeta = SessionMeta.pruned(stored, live: liveSessionGroups())
        if sessionMeta != stored { persistSessionMeta() }
        reloadOutline()
    }

    private func persistSessionMeta() {
        guard sessionMetaReadCompleted else { return }
        write(SessionMetaCodec.serialize(sessionMeta), to: SettingsKey.sessionMeta)
    }

    // MARK: - Review panel

    /// ⌥⌘B / the toolbar button. Open is a per-session fact: toggling
    /// records it for the session on screen, and switching sessions restores
    /// each one's own answer.
    @objc func toggleReviewPanel(_ sender: Any?) {
        guard destination == .terminals, let group = workspace.activeGroup else { return }
        let opening = reviewPanelItem?.isCollapsed ?? false
        reviewPanelGroup = group
        var state = reviewPanelState(for: group)
        state.open = opening
        if opening {
            reviewPanelStates[group] = state
            applyReviewPanelState(state)
        } else {
            // Closing keeps the dragged width, so reopening comes back at it
            // — the pre-expansion width when the panel is expanded, since
            // full-width is transient and must not become the stored one.
            if let width = reviewPanelWidthBeforeExpand ?? currentReviewPanelWidth() {
                state.width = Double(width)
            }
            reviewPanelStates[group] = state
            endReviewPanelExpansion()
            setReviewPanelCollapsed(true)
        }
        persistReviewPanel()
    }

    /// The stored state for one session group, or the default — closed, the
    /// spec's Changes + Files tab set.
    func reviewPanelState(for group: String) -> ReviewPanelSessionState {
        reviewPanelStates[group] ?? ReviewPanelSessionState()
    }

    /// `PaneWorkspaceView.onActiveGroupChanged` — the activateGroup path.
    /// Leaves the departing session's width behind in its entry, then shows
    /// the arriving session's own panel.
    private func reviewPanelSessionDidChange(to group: String?) {
        guard reviewPanelReadCompleted else {
            // Before the row has been read there is nothing to save or to
            // apply — but the pointer still moves, so the first edit after
            // the restore lands in the right session's entry.
            reviewPanelGroup = group
            return
        }
        if let previous = reviewPanelGroup, previous != group,
           reviewPanelItem?.isCollapsed == false,
           let width = reviewPanelWidthBeforeExpand ?? currentReviewPanelWidth() {
            var state = reviewPanelState(for: previous)
            state.width = Double(width)
            reviewPanelStates[previous] = state
        }
        reviewPanelGroup = group
        endReviewPanelExpansion()
        guard let group else {
            setReviewPanelCollapsed(true)
            persistReviewPanel()
            return
        }
        applyReviewPanelState(reviewPanelState(for: group))
        persistReviewPanel()
    }

    /// Puts one session's recorded state on screen: tabs, selection,
    /// open/closed, width.
    private func applyReviewPanelState(_ state: ReviewPanelSessionState) {
        reviewPanel.load(
            tabs: state.tabs.compactMap(ReviewPanelTab.init(rawValue:)),
            active: ReviewPanelTab(rawValue: state.activeTab)
        )
        let visible = destination == .terminals && state.open
        setReviewPanelCollapsed(!visible)
        if visible, let width = state.width { applyReviewPanelWidth(CGFloat(width)) }
        syncReviewPanelFiles()
        syncReviewPanelChanges()
        syncReviewPanelBrowser()
        syncReviewPanelInsights()
    }

    /// The panel's tab set or selection changed under the user's hands —
    /// recorded against the session the panel is showing.
    private func reviewPanelUIChanged() {
        guard let group = reviewPanelGroup else { return }
        var state = reviewPanelState(for: group)
        state.tabs = reviewPanel.openTabs.map(\.rawValue)
        state.activeTab = reviewPanel.activeTab?.rawValue ?? ""
        reviewPanelStates[group] = state
        persistReviewPanel()
        // Selecting the Files tab is what makes its content current — the
        // one moment its tree is worth (re)pointing at the session.
        syncReviewPanelFiles()
        syncReviewPanelChanges()
        syncReviewPanelBrowser()
        syncReviewPanelInsights()
    }

    /// Puts the showing session's persisted Files state into the tab —
    /// lazily: only while the panel is open on the Files tab, so a listing
    /// and a `git status` are never paid for a tab nobody is looking at.
    private func syncReviewPanelFiles() {
        guard
            reviewPanelItem?.isCollapsed == false,
            reviewPanel.activeTab == .files,
            let group = reviewPanelGroup
        else { return }
        let state = reviewPanelState(for: group)
        reviewPanelFiles.apply(
            root: reviewPanelRoot(for: group),
            openFile: state.openFile,
            treePosition: state.treePosition,
            showHidden: state.showHidden
        )
    }

    /// Points the Changes tab at the showing session's workspace and reloads
    /// its status — on *every* activation, not just the first: the working
    /// tree moves under the panel, and the spec's promise is that looking at
    /// the tab shows what git says now.
    private func syncReviewPanelChanges() {
        guard
            reviewPanelItem?.isCollapsed == false,
            reviewPanel.activeTab == .changes,
            let group = reviewPanelGroup
        else { return }
        reviewPanelChanges.setRoot(reviewPanelRoot(for: group))
        reviewPanelChanges.refresh()
    }

    /// Rescans the showing session's terminals for dev-server ports — on
    /// every Browser activation, the Changes reload's reasoning: the servers
    /// move under the panel, and looking at the tab shows what talks now.
    private func syncReviewPanelBrowser() {
        guard
            reviewPanelItem?.isCollapsed == false,
            reviewPanel.activeTab == .browser,
            let group = reviewPanelGroup
        else { return }
        reviewPanelBrowser.updatePortSuggestions(
            fromTerminalLines: sessionTerminalTail(for: group)
        )
    }

    /// Feeds the Insights tab the showing session's status series and ledger
    /// totals — on activation and on every status event while it shows, so
    /// the timeline is always the stream as of now. Guarded like its
    /// siblings: a tab nobody is looking at costs nothing.
    private func syncReviewPanelInsights() {
        guard
            reviewPanelItem?.isCollapsed == false,
            reviewPanel.activeTab == .insights,
            let group = reviewPanelGroup
        else { return }
        let now = Date().timeIntervalSince1970 * 1000
        // Terminal panes only: status events are a terminal session's
        // speech, and a browser or editor lane would sit forever blank.
        let paneIDs = workspace.allPaneIDs.filter {
            workspace.descriptor(for: $0)?.group == group
                && workspace.descriptor(for: $0)?.kind == .terminal
        }
        let lanes = paneIDs.map { id in
            ReviewPanelInsightsView.Lane(
                paneID: id,
                title: workspace.descriptor(for: id).map(SessionOutline.paneLabel) ?? id,
                segments: statusSeries.segments(for: id, until: now)
            )
        }
        reviewPanelInsights.apply(
            lanes: lanes,
            activities: paneIDs.compactMap { activity.activity(for: $0) },
            now: now
        )
    }

    /// The recent visible output of every terminal pane in one session group
    /// — what the Browser tab scans. `unwrappedTailLines`, not the approval
    /// bar's `visibleTailLines`: an address the terminal wrapped across two
    /// rows of a narrow pane must still read as one address.
    private func sessionTerminalTail(for group: String) -> [String] {
        workspace.allPaneIDs
            .filter { workspace.descriptor(for: $0)?.group == group }
            .compactMap { workspace.terminalSurface(for: $0) }
            .flatMap { $0.unwrappedTailLines() }
    }

    /// The Files tab's user-made changes (gear preferences, open file) —
    /// recorded against the session the panel is showing, like every other
    /// panel edit.
    private func reviewPanelFilesChanged() {
        guard let group = reviewPanelGroup else { return }
        var state = reviewPanelState(for: group)
        state.treePosition = reviewPanelFiles.treePosition.rawValue
        state.showHidden = reviewPanelFiles.showsHiddenFiles
        state.openFile = reviewPanelFiles.currentOpenFilePath
        reviewPanelStates[group] = state
        persistReviewPanel()
    }

    /// The workspace the Files tab lists for one session group: the group's
    /// project directory, or a live pane's cwd when nothing is recorded.
    private func reviewPanelRoot(for group: String) -> URL? {
        let descriptor = workspace.allPaneIDs
            .compactMap { workspace.descriptor(for: $0) }
            .first { $0.group == group }
        let path = workspaceDirectory(for: descriptor?.project)
            ?? descriptor.flatMap { $0.cwd.isEmpty ? nil : $0.cwd }
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The tab bar's expand-to-full-width toggle. Transient — see
    /// `reviewPanelWidthBeforeExpand`.
    private func toggleReviewPanelExpansion() {
        guard let item = reviewPanelItem, !item.isCollapsed else { return }
        if let restore = reviewPanelWidthBeforeExpand {
            reviewPanelWidthBeforeExpand = nil
            reviewPanel.setExpanded(false)
            applyReviewPanelWidth(restore)
        } else {
            reviewPanelWidthBeforeExpand = max(
                currentReviewPanelWidth() ?? ReviewPanelView.minimumWidth,
                ReviewPanelView.minimumWidth
            )
            reviewPanel.setExpanded(true)
            // Everything right of the sidebar; AppKit clamps at whatever the
            // other items refuse to give up.
            applyReviewPanelWidth(.greatestFiniteMagnitude)
        }
    }

    /// Un-expands without moving the divider — for the paths where the
    /// divider is about to be repositioned or hidden anyway.
    private func endReviewPanelExpansion() {
        reviewPanelWidthBeforeExpand = nil
        reviewPanel.setExpanded(false)
    }

    private func setReviewPanelCollapsed(_ collapsed: Bool) {
        guard let item = reviewPanelItem, item.isCollapsed != collapsed else { return }
        // Not animated under XCTest — `restoreWindowFrame`'s reasoning: a
        // test reading the item right after needs the final state there.
        let animate = window?.isVisible == true && NSClassFromString("XCTestCase") == nil
        (animate ? item.animator() : item).isCollapsed = collapsed
    }

    private func currentReviewPanelWidth() -> CGFloat? {
        guard reviewPanelItem?.isCollapsed == false else { return nil }
        let width = reviewPanel.frame.width
        return width > 0 ? width : nil
    }

    /// Moves the second divider so the panel measures `width` — the split
    /// view's own coordinate arithmetic, clamped by AppKit against the other
    /// items' minimums.
    private func applyReviewPanelWidth(_ width: CGFloat) {
        guard
            let split = splitController?.splitView,
            split.frame.width > 0
        else { return }
        let position = split.frame.width - min(width, split.frame.width) - split.dividerThickness
        split.setPosition(max(0, position), ofDividerAt: 1)
    }

    private func restoreReviewPanelIfNeeded() {
        guard !reviewPanelReadDispatched else { return }
        reviewPanelReadDispatched = true
        connection.getSetting(key: SettingsKey.reviewPanel) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                applyRestoredReviewPanel(raw)
            case .failure:
                // Re-armed for the next reconnect; the write gate stays
                // shut — `layoutReadFailed`'s reasoning.
                reviewPanelReadDispatched = false
            }
        }
    }

    /// Applies the `review_panel_native` row and opens its write gate —
    /// split out of the read so a test can restore without a socket,
    /// `applyRestoredPanes`'s pattern. Entries for groups no restored pane
    /// carries are pruned, and a prune that changed anything is written
    /// straight back so the next launch reads the row clean.
    func applyRestoredReviewPanel(_ raw: String?) {
        reviewPanelReadDispatched = true
        reviewPanelReadCompleted = true
        let stored = ReviewPanelStateCodec.deserialize(raw)
        let live = liveSessionGroups()
        reviewPanelStates = stored.filter { live.contains($0.key) }
        if reviewPanelStates != stored { persistReviewPanel() }
        reviewPanelGroup = workspace.activeGroup
        if let group = reviewPanelGroup {
            applyReviewPanelState(reviewPanelState(for: group))
        }
    }

    private func persistReviewPanel() {
        guard reviewPanelReadCompleted else { return }
        write(ReviewPanelStateCodec.serialize(reviewPanelStates), to: SettingsKey.reviewPanel)
    }

    // MARK: - Notifications

    /// Brings one pane forward: the window to the front, the app to the
    /// foreground, focus onto that pane. What clicking a notification does,
    /// and what the session outline and the command palette both call.
    @discardableResult
    func revealPane(_ sessionID: String) -> Bool {
        guard workspace.descriptor(for: sessionID) != nil else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        // A pane lives on the Desk. Revealing one from Home or the To Do List
        // used to focus it behind whichever destination was showing — the
        // caret moved, the screen did not.
        if destination != .terminals { applyDestination(.terminals) }
        workspace.focusPane(sessionID)
        // In focus mode the card is the only terminal the user can see, so
        // revealing another pane has to move the *card*, not just the caret.
        // Focusing behind the blur is how an approval typed in answer to a
        // notification ends up in a terminal nobody is looking at.
        //
        // After `focusPane`, not before: that is what brings the pane's session
        // to the screen, and a pane off screen is one `setZoomed` refuses. If its
        // session was a different one, `validateZoom` has already ended the zoom
        // by now — which is the same outcome by a shorter route, the revealed
        // pane visible and focused. And here rather than inside `focusPane`,
        // which `setZoomed` calls itself: that would recurse.
        if workspace.zoomedPaneID != nil { workspace.setZoomed(sessionID) }
        return true
    }

    /// Records a focus move in `recentSessionGroupIDs`, most-recent first.
    private func noteSessionFocused(_ paneID: String) {
        guard let group = workspace.descriptor(for: paneID)?.group else { return }
        recentSessionGroupIDs.removeAll { $0 == group }
        recentSessionGroupIDs.insert(group, at: 0)
        // Five is all the menu bar ever shows; keeping a little more than
        // that absorbs a session or two closing between focus and open.
        if recentSessionGroupIDs.count > 8 { recentSessionGroupIDs.removeLast() }
    }

    /// What the menu bar icon's dropdown shows, assembled fresh every time it
    /// opens — `hoverCardModel`'s pattern, no second copy to keep in sync.
    func menuBarSummary() -> MenuBarSummary {
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        let sessions = SessionOutline.group(panes, focusedPaneID: workspace.focusedPaneID).flatMap(\.sessions)
        let terminals = panes.filter { $0.kind == .terminal }
        let working = terminals.filter { PaneActivityLedger.isBusy(lastStatus[$0.sessionID]) }.count

        var byGroup: [String: SessionGroupNode] = [:]
        for session in sessions { byGroup[session.id] = session }
        let recent = recentSessionGroupIDs.compactMap { byGroup[$0] }

        var seenProjects = Set<String>()
        let recentWorkspaces = recent.compactMap { session -> MenuBarSummary.RecentWorkspace? in
            guard seenProjects.insert(session.project).inserted else { return nil }
            return MenuBarSummary.RecentWorkspace(
                project: session.project,
                label: SessionOutline.projectLabel(session.project, labels: projectLabels)
            )
        }

        return MenuBarSummary(
            sessionCount: sessions.count,
            terminalCount: terminals.count,
            workingCount: working,
            recentSessions: recent.prefix(5).map {
                MenuBarSummary.RecentSession(
                    id: $0.id,
                    label: $0.label,
                    project: $0.project,
                    projectLabel: SessionOutline.projectLabel($0.project, labels: projectLabels),
                    firstPaneID: $0.paneIDs.first ?? $0.id
                )
            },
            recentWorkspaces: Array(recentWorkspaces.prefix(5))
        )
    }

    /// What the sidebar's hover card shows for one row, assembled fresh every
    /// tick. The window is the only place that holds all four sources at once
    /// — the descriptor, the status, the activity ledger and the live pane —
    /// so it assembles, and `HoverCardModel` owns the wording.
    func hoverCardModel(for target: SessionHoverCardController.Target) -> HoverCardModel? {
        let now = Date().timeIntervalSince1970 * 1000
        switch target {
        case .pane(let paneID):
            guard let pane = workspace.descriptor(for: paneID) else { return nil }
            return .pane(
                pane,
                status: lastStatus[paneID],
                activity: activity.activity(for: paneID),
                editor: workspace.editorPane(for: paneID)?.model,
                tail: workspace.terminalSurface(for: paneID)?.lastOutputLine(),
                now: now
            )
        case .session(let sessionID):
            let all = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
            guard let node = SessionOutline.group(all, focusedPaneID: workspace.focusedPaneID)
                .flatMap(\.sessions)
                .first(where: { $0.id == sessionID })
            else { return nil }
            var byID: [String: PaneDescriptor] = [:]
            for pane in all { byID[pane.sessionID] = pane }
            let git = GitDiffStat.cached(forDirectory: node.cwd)
            return .session(
                node,
                panes: byID,
                statuses: lastStatus,
                ledger: activity,
                eventTimes: lastStatusEventAt,
                // Read lazily, per row the table actually draws: this runs ten
                // times a second, and scraping every pane's screen for a table
                // that shows four of them is work nobody sees.
                tails: { [weak self] paneID in
                    self?.workspace.terminalSurface(for: paneID)?.lastOutputLine()
                },
                git: git,
                branch: git?.branch,
                now: now
            )
        }
    }

    /// Turns one status event into the feed's decision. The window is the
    /// only place that knows the two "is the user looking at this" facts, so
    /// it assembles the context and `NotificationFeed` owns the rule.
    func recordNotification(for event: SessionStatusEvent) {
        let previous = lastStatus[event.id]
        lastStatus[event.id] = event.status
        lastStatusEventAt[event.id] = Date().timeIntervalSince1970 * 1000
        activity.record(
            paneID: event.id,
            status: event.status,
            at: Date().timeIntervalSince1970 * 1000
        )
        statusSeries.record(
            paneID: event.id,
            status: event.status,
            at: Date().timeIntervalSince1970 * 1000
        )
        // The Insights tab shows this very event stream: while it is on
        // screen, each event redraws it (guarded inside to visible+active,
        // so a closed panel costs nothing).
        syncReviewPanelInsights()
        notifier.record(
            NotificationContext(
                event: event,
                pane: workspace.descriptor(for: event.id),
                projectLabel: workspace.descriptor(for: event.id)?.project ?? "",
                focusedPaneID: workspace.focusedPaneID,
                windowVisible: window?.occlusionState.contains(.visible) ?? false,
                appActive: NSApp.isActive,
                previousStatus: previous,
                now: Date().timeIntervalSince1970 * 1000
            )
        )
        // Any status other than "still asking" means the prompt was answered
        // — from the pane, from the banner, anywhere.
        if event.status != .awaitingApproval {
            notifier.resolveApproval(sessionID: event.id)
        }
    }

    /// Reads the persisted feed once, alongside the layout. Same failure
    /// contract as `layoutReadFailed`: a feed that could not be read is not
    /// an empty feed, so the write gate stays shut and the read is re-armed.
    private func restoreNotificationsIfNeeded() {
        guard !notificationsReadDispatched else { return }
        notificationsReadDispatched = true
        connection.getSetting(key: SettingsKey.notifications) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                notificationsReadCompleted = true
                notifier.restore(NotificationFeedCodec.deserialize(raw))
            case .failure:
                notificationsReadDispatched = false
            }
        }
    }

    private func persistNotifications(_ entries: [NotificationEntry]) {
        guard notificationsReadCompleted else { return }
        write(NotificationFeedCodec.serialize(entries), to: SettingsKey.notifications)
    }

    // MARK: - Usage analytics (Task 6b-2)

    /// Reads the persisted `usage_analytics_v1` row once, alongside the
    /// layout/notifications reads — same failure contract as
    /// `restoreNotificationsIfNeeded`: a row that could not be read is not
    /// an empty store, so the write gate stays shut and the read re-arms.
    private func restoreUsageAnalyticsIfNeeded() {
        guard !usageReadDispatched else { return }
        usageReadDispatched = true
        connection.getSetting(key: SettingsKey.usageAnalytics) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                usageReadCompleted = true
                usageRecorder.restore(UsageAnalyticsCodec.deserialize(raw))
            case .failure:
                usageReadDispatched = false
            }
        }
    }

    private func persistUsageAnalytics(_ store: UsageAnalyticsStore) {
        guard usageReadCompleted else { return }
        write(UsageAnalyticsCodec.serialize(store), to: SettingsKey.usageAnalytics)
    }

    // MARK: - Onboarding (Task 6b-2)

    /// The login window, and the first thing the app puts on screen. Answered
    /// from `UserDefaults` rather than over the socket, so it is on screen
    /// before the daemon has been heard from at all — see
    /// `AuthGate.needsSignIn(_:)`.
    ///
    /// `completion` is what reveals the workspace window, so it must run on
    /// every path, including the one where nothing is shown.
    func presentLaunchGate(defaults: UserDefaults = .standard, completion: @escaping () -> Void) {
        guard AuthGate.needsSignIn(defaults) else {
            authGateDidResolve()
            completion()
            return
        }
        // `over: nil` — a window of its own, centred, with nothing behind it.
        // A sheet needs a parent window on screen, and the whole point here is
        // that there isn't one yet.
        authGateWindow.present(over: nil) { [weak self] in
            self?.authGateDidResolve()
            completion()
        }
    }

    /// The gate is answered — signed in, or "continue without signing in".
    private func authGateDidResolve() {
        authGateResolved = true
        presentOnboardingIfNeeded()
    }

    /// FirstRun (if no project root has ever been picked), once *both* the
    /// gate has been answered and the socket is up: it is a sheet on the
    /// workspace window, which the gate holds off screen, and asking the
    /// daemon what roots exist needs the socket. Whichever lands last runs
    /// it. Dispatched once per launch; a reconnect does not re-ask.
    private func presentOnboardingIfNeeded() {
        guard authGateResolved, didConnect, !onboardingDispatched else { return }
        onboardingDispatched = true
        presentFirstRunIfNeeded()
    }

    private func presentFirstRunIfNeeded() {
        FirstRunWindowController.needsPresenting(ingestion: connection) { [weak self] needed in
            guard let self, needed else { return }
            firstRunWindow.present(over: window) { [weak self] project in
                guard let self else { return }
                startSession(inDirectory: project.path ?? "", project: project.id)
                refreshProjectLabels()
            }
        }
    }

    /// ⌘, — the in-window Settings page, on whatever section it was last
    /// on. (`settingsWindowController`'s SwiftUI window is no longer reached
    /// from the UI; its content is what the sections will grow into.)
    @objc func showSettings(_ sender: Any?) {
        applyDestination(.settings)
    }

    /// Settings, opened on a particular section.
    func showSettings(section: SettingsSection) {
        settingsView.select(section)
        applyDestination(.settings)
    }

    // MARK: - Inspector (Task 6b-2)

    /// ⌘I — the per-project brain-context panel, scoped to the focused
    /// pane's project.
    @objc func showInspectorPanel(_ sender: Any?) {
        guard let project = workspace.focusedPaneID.flatMap({ workspace.descriptor(for: $0)?.project }) else { return }
        showInspector(for: project)
    }

    /// Also what a palette search hit and a future project-menu row open —
    /// one entry point regardless of what asked for it.
    func showInspector(for project: String) {
        inspector.show(
            project: project,
            label: SessionOutline.projectLabel(project, labels: projectLabels),
            over: window
        ) { [weak self] id, newLabel in
            guard let self else { return }
            projectLabels[id] = newLabel
            reloadOutline()
        }
    }

    private func refreshInspectorIfVisible(for paneID: String?) {
        guard let paneID, let project = workspace.descriptor(for: paneID)?.project,
              let visible = inspector.projectIfVisible, visible != project
        else { return }
        showInspector(for: project)
    }

    /// Writes the live panes back to the shared `layout` row. Refused until
    /// the row has actually been read: a write from a window that has not
    /// seen it would overwrite the very panes it is about to restore.
    private func persistLayout() {
        guard layoutReadCompleted else { return }
        let descriptors = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        write(
            PersistedLayoutCodec.serialize(WorkspaceRestoration.persistedTabs(from: descriptors)),
            to: SettingsKey.layout
        )
    }

    // MARK: - Browser pane persistence (Task 5)

    /// Reads the native-only `browser_panes_native` row once, alongside the
    /// `layout` row. Same one-shot/re-arm-on-failure shape as
    /// `restoreNotificationsIfNeeded`: a row that could not be read is not
    /// an empty one, so the write gate stays shut and the read re-arms for
    /// the next reconnect.
    private func restoreBrowserPanesIfNeeded() {
        guard !browserPanesReadDispatched else { return }
        browserPanesReadDispatched = true
        connection.getSetting(key: SettingsKey.browserPanes) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                applyRestoredBrowserPanes(BrowserPanesCodec.deserialize(raw))
            case .failure:
                browserPanesReadDispatched = false
            }
        }
    }

    /// Adds every restored browser pane the grid has room for. Split out
    /// from `restoreBrowserPanesIfNeeded` so a plan can be applied in a test
    /// without a socket — same shape as `applyRestoredPanes`. Browser panes
    /// never touch `ensureSession`: `addPane`'s kind branch (Task 2) is what
    /// keeps them off the daemon.
    func applyRestoredBrowserPanes(_ panes: [PersistedBrowserPane]) {
        browserPanesReadCompleted = true
        // Terminals are already seated in their saved order; each browser
        // pane joins the end of it rather than displacing one of them.
        var order = workspace.allPaneIDs
        for pane in panes
        where workspace.paneCount(inGroup: pane.group ?? WorkspaceRestoration.ungroupedSessionID) < PaneGrid.maxPanes {
            let sessionID = UUID().uuidString
            if addPane(
                RestoredPane(
                    sessionID: sessionID,
                    reattaches: false,
                    project: "",
                    engine: .shell,
                    cwd: "",
                    label: nil,
                    themeId: nil,
                    group: pane.group ?? WorkspaceRestoration.ungroupedSessionID,
                    groupLabel: pane.groupLabel,
                    kind: .browser,
                    browserURL: pane.url
                ),
                startSession: false
            ) {
                order.append(sessionID)
            }
        }
        workspace.reorderPanes(order)
        // Last step of the restore chain (layout -> browser panes -> here):
        // every pane exists, so the session you were last in can be the one
        // on screen. Cleared after use — a later reconnect must not yank
        // focus away from wherever you have since moved.
        if let last = lastFocusedPaneOnLaunch {
            lastFocusedPaneOnLaunch = nil
            workspace.focusPane(last)
        }
    }

    /// Writes the live browser panes back to their own row. Refused until
    /// that row has actually been read — `persistLayout`'s reasoning,
    /// applied to the other row. `browserURL` updates already flow through
    /// `updateDescriptor` -> `onPanesChanged` (Task 4's `onURLChange`
    /// wiring), so navigating a browser pane persists its new URL with zero
    /// extra plumbing.
    private func persistBrowserPanes() {
        guard browserPanesReadCompleted else { return }
        let panes = workspace.allPaneIDs
            .compactMap { workspace.descriptor(for: $0) }
            .filter { $0.kind == .browser }
            .map {
                PersistedBrowserPane(
                    url: $0.browserURL,
                    group: $0.group == WorkspaceRestoration.ungroupedSessionID ? nil : $0.group,
                    groupLabel: $0.groupLabel
                )
            }
        write(BrowserPanesCodec.serialize(panes), to: SettingsKey.browserPanes)
    }

    // MARK: - Editor pane persistence (Task 10)

    /// Reads the native-only `editor_panes_native` row once, alongside the
    /// `browser_panes_native` one — `restoreBrowserPanesIfNeeded`'s shape and
    /// its reasons: a row that could not be read is not an empty one, so the
    /// write gate stays shut and the read re-arms for the next reconnect.
    private func restoreEditorPanesIfNeeded() {
        guard !editorPanesReadDispatched else { return }
        editorPanesReadDispatched = true
        connection.getSetting(key: SettingsKey.editorPanes) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(raw):
                applyRestoredEditorPanes(EditorPanesCodec.deserialize(raw))
            case .failure:
                editorPanesReadDispatched = false
            }
        }
    }

    /// Adds every restored editor pane the grid has room for. Split out so a
    /// plan can be applied in a test without a socket, exactly as
    /// `applyRestoredBrowserPanes` is. Editor panes never touch
    /// `ensureSession` — `addPane`'s kind branch keeps them off the daemon.
    func applyRestoredEditorPanes(_ panes: [PersistedEditorPane]) {
        editorPanesReadCompleted = true
        // Terminals and browsers are already seated in their saved order;
        // each editor pane joins the end of it rather than displacing one.
        var order = workspace.allPaneIDs
        // `addPane` focuses every pane it adds, and by the time this runs the
        // browser step has already put focus back where the user left it
        // (`lastFocusedPaneOnLaunch`). Restoring a pane is not a focus change.
        let focused = workspace.focusedPaneID
        for pane in panes
        where workspace.paneCount(inGroup: pane.group ?? WorkspaceRestoration.ungroupedSessionID) < PaneGrid.maxPanes {
            let sessionID = UUID().uuidString
            if addPane(
                RestoredPane(
                    sessionID: sessionID,
                    reattaches: false,
                    project: "",
                    engine: .shell,
                    cwd: "",
                    label: nil,
                    themeId: nil,
                    group: pane.group ?? WorkspaceRestoration.ungroupedSessionID,
                    groupLabel: pane.groupLabel,
                    kind: .editor,
                    editorTabs: pane.tabs,
                    editorActiveIndex: pane.active
                ),
                startSession: false
            ) {
                order.append(sessionID)
            }
        }
        workspace.reorderPanes(order)
        if let focused { workspace.focusPane(focused) }
    }

    /// Closed while a drop is creating a pane and lifting the tab into it.
    /// Those are two synchronous steps of one move, and the write between them
    /// would persist the tab as open in both panes.
    private var editorPaneDropInFlight = false
    /// A close or quit is draining dirty editor tabs. The drain *closes* every
    /// tab it resolves, and `performClose` publishes — so without this the
    /// `editor_panes_native` row would be rewritten on the way out with
    /// precisely the files the user was editing removed, and next launch would
    /// restore everything except them (spec §5). Same shape as the drop gate
    /// above, for the same reason: a transient intermediate state must not be
    /// mistaken for the state to persist.
    private var editorPaneDrainInFlight = false

    /// Writes the live editor panes back to their own row. Refused until that
    /// row has actually been read — `persistLayout`'s reasoning again. Tab
    /// mutations already flow through `onStateChange` -> `updateDescriptor` ->
    /// `onPanesChanged`, the browser pane's `onURLChange` chain applied to
    /// tabs, so opening or closing a tab persists with no extra plumbing.
    private func persistEditorPanes() {
        guard editorPanesReadCompleted, !editorPaneDropInFlight, !editorPaneDrainInFlight else { return }
        let panes = workspace.allPaneIDs
            .compactMap { workspace.descriptor(for: $0) }
            .filter { $0.kind == .editor }
            .map {
                PersistedEditorPane(
                    tabs: $0.editorTabs,
                    active: $0.editorActiveIndex,
                    group: $0.group == WorkspaceRestoration.ungroupedSessionID ? nil : $0.group,
                    groupLabel: $0.groupLabel
                )
            }
        write(EditorPanesCodec.serialize(panes), to: SettingsKey.editorPanes)
    }

    /// Writes a settings row only when its value actually changed.
    ///
    /// Both rows are re-derived from live state on every mutation, and plenty
    /// of those mutations do not change what is stored — a shell that repaints
    /// its OSC title on every prompt would otherwise write an identical
    /// `layout` row several times a second, against the database the web app
    /// is also reading.
    private func write(_ value: String, to key: String) {
        guard lastPersisted[key] != value else { return }
        lastPersisted[key] = value
        if let settingsWriter {
            settingsWriter(key, value)
        } else {
            connection.setSetting(key: key, value: value)
        }
    }

    // MARK: - Panes and sessions

    /// Answers whether the pane was actually added. Callers loop on this —
    /// returning `true` unconditionally made "add until the cap" a loop that
    /// could never end once the cap stopped being a single global number.
    @discardableResult
    private func addPane(_ pane: RestoredPane, startSession: Bool) -> Bool {
        let sessionID = pane.sessionID
        var descriptor = PaneDescriptor(pane)
        // The one place a terminal gets its placeholder number, so a restored
        // pane and a brand-new one are numbered by the same rule. Panes arrive
        // one at a time, so each sees the ones already placed and takes the
        // next free number in its own session.
        descriptor.autoNumber = SessionOutline.nextPaneNumber(
            workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) },
            group: descriptor.group,
            engine: descriptor.engine,
            kind: descriptor.kind
        )
        // A label this app generated is not a name the user chose, and leaving
        // it stored would outrank the summary the agent reports for the rest
        // of the pane's life. Dropped on the way in, so layouts saved while
        // those names were being stored heal themselves on the next launch.
        if let stored = descriptor.label, SessionOutline.isGeneratedPaneName(stored) {
            descriptor.label = nil
        }
        guard workspace.addPane(descriptor) else { return false }
        // Everything below is PTY-shaped — conversation claim, usage
        // recording, OSC title/cwd wiring, and above all `ensureSession`,
        // which for an unknown id falls through to `createSession` and its
        // `.shell` default. A non-terminal pane must reach none of it.
        // (Browser-side wiring arrives with `BrowserPaneView`.)
        if descriptor.kind == .terminal {
            // A pane that did not come back from the persisted layout has a session
            // id minted moments ago, so the Claude conversation derived from it
            // cannot exist yet and is safe to claim. A restored one may already
            // have written its conversation, and re-claiming that kills the spawn.
            if !pane.reattaches { allowConversationClaim(for: sessionID) }
            usageRecorder.recordPaneOpened(
                paneID: sessionID,
                sessionKey: pane.group,
                project: pane.project,
                at: Date().timeIntervalSince1970 * 1000
            )
            let surface = workspace.terminalSurface(for: sessionID)
            surface?.onTitleChange = { [weak self] title in
                guard let self else { return }
                // Stripped here rather than at each place a title is shown: the
                // pane header, the sidebar row, the window title and the
                // session-ended notification all read this one stored value, and
                // nothing wants the spinner frame the engine sent with it.
                let title = SessionOutline.sanitizedPaneTitle(title)
                // A title that is only the engine's brand is not news about
                // this pane, and storing it is what made named terminals flip
                // back to "Claude Code" — see `isEngineBrandTitle`.
                guard !SessionOutline.isEngineBrandTitle(title) else { return }
                workspace.updateDescriptor(for: sessionID) { $0.title = title }
                if workspace.focusedPaneID == sessionID { refreshTitle() }
                syncConversationName(sessionID, to: title)
            }
            surface?.onClearCommand = { [weak self] in
                guard let self else { return }
                // `/clear` starts a new conversation, so the name the last one
                // earned is gone with it — back to "Claude 2" until the fresh
                // one says what it is doing.
                workspace.updateDescriptor(for: sessionID) {
                    $0.title = ""
                    $0.label = nil
                }
                lastSyncedName.removeValue(forKey: sessionID)
                if workspace.focusedPaneID == sessionID { refreshTitle() }
            }
            surface?.onDirectoryChange = { [weak self] directory in
                guard let self, workspace.focusedPaneID == sessionID else { return }
                window?.representedURL = directory.map(URL.init(fileURLWithPath:))
            }
            surface?.onLinkClick = { [weak self] url in
                self?.openLinkInBrowserPane(url, from: sessionID)
            }
            if startSession { ensureSession(sessionID) }
        } else if let browser = workspace.browserPane(for: sessionID) {
            // The browser's own title path, mirroring the OSC-title wiring
            // above: the page title is what the pane wears.
            browser.onTitleChange = { [weak self] title in
                guard let self else { return }
                workspace.updateDescriptor(for: sessionID) { $0.title = title }
                if workspace.focusedPaneID == sessionID { refreshTitle() }
            }
            // Every committed navigation keeps the descriptor's URL current —
            // `updateDescriptor` fires `onPanesChanged`, which is what the
            // last-URL persistence hangs off.
            browser.onURLChange = { [weak self] url in
                self?.workspace.updateDescriptor(for: sessionID) { $0.browserURL = url }
            }
        } else if workspace.editorPane(for: sessionID) != nil {
            wireEditorPane(sessionID, project: pane.project)
        }
        return true
    }

    /// Everything the controller hangs off an editor pane. Extracted from
    /// `addPane` because the edge/hole tab drops build their pane through
    /// `workspace.addPane(…)` directly — that path inserts rather than
    /// appends, which `addPane(_:startSession:)` cannot express — and a pane
    /// that skipped this wiring would never persist a tab, never close when
    /// its last one went, and never render a diff.
    private func wireEditorPane(_ sessionID: String, project: String) {
        guard let editor = workspace.editorPane(for: sessionID) else { return }
        // The pane's own id, for the payload a dragged tab carries.
        editor.paneID = sessionID
        // The active tab's name is what the pane wears — the browser's
        // page-title path, applied to tabs.
        editor.onTitleChange = { [weak self] title in
            guard let self else { return }
            workspace.updateDescriptor(for: sessionID) { $0.title = title }
            if workspace.focusedPaneID == sessionID { refreshTitle() }
        }
        // Tab mutations flow into the descriptor; `updateDescriptor` fires
        // `onPanesChanged`, which is what `persistEditorPanes` hangs off —
        // `onURLChange`'s pattern, applied to the tab list.
        editor.onStateChange = { [weak self] tabs, active in
            self?.workspace.updateDescriptor(for: sessionID) {
                $0.editorTabs = tabs
                $0.editorActiveIndex = active
            }
        }
        editor.onLastTabClosed = { [weak self] in
            self?.workspace.closePane(sessionID)
        }
        // The pane that asked travels with the request: the callback
        // carries only a URL, and by the time a ± toggle is pressed the
        // focused pane is often somewhere else entirely.
        editor.onOpenDiffRequest = { [weak self] url in
            self?.openDiffInEditor(url, from: sessionID)
        }
        // The Changes overview's "open file" is a deliberate open, so it
        // pins — the same rule a double click in the FILES tree follows.
        editor.onOpenFileRequest = { [weak self] url in
            self?.openFileInEditor(url, pinned: true)
        }
        // A tab dropped in this pane's strip: the strip knows *where*, this
        // knows *which pane*, and the broker below owns the rules.
        editor.onTabDroppedInStrip = { [weak self] payload, index in
            self?.handleEditorTabDrop(payload, intoPane: sessionID, at: index)
        }
        // Both of the editor's blocking questions are pane asks: they are about
        // *this* pane's buffer, and a window sheet would not say which pane
        // that is. The alert defaults stay as the fallback for a pane that has
        // no container yet — a question with nowhere to appear must still be
        // answerable.
        editor.confirmSave = { [weak self] name, decide in
            guard let container = self?.workspace.container(for: sessionID) else {
                EditorPaneView.defaultConfirmSave(name, decide)
                return
            }
            container.presentAsk(
                title: "Save changes to \(name)?",
                message: "This file has edits that are not on disk. "
                    + "Closing it without saving loses them.",
                icon: NSImage(systemSymbolName: "doc.badge.ellipsis", accessibilityDescription: nil),
                options: [
                    PaneAskOption("Don't Save") { _ in decide(.discard) },
                    PaneAskOption("Cancel") { _ in decide(.cancel) },
                    PaneAskOption("Save", isPrimary: true) { _ in decide(.save) },
                ],
                onCancel: { decide(.cancel) }
            )
        }
        editor.confirmConflict = { [weak self] name, decide in
            guard let container = self?.workspace.container(for: sessionID) else {
                EditorPaneView.defaultConfirmConflict(name, decide)
                return
            }
            container.presentAsk(
                title: "\(name) changed on disk",
                message: "You have unsaved edits, and the file was modified outside the editor "
                    + "(probably by an agent).",
                icon: NSImage(
                    systemSymbolName: "arrow.triangle.2.circlepath",
                    accessibilityDescription: nil
                ),
                // Dismissing keeps what is in front of you, which is the only
                // answer here that destroys nothing.
                options: [
                    PaneAskOption("Keep Mine") { _ in decide(false) },
                    PaneAskOption("Take Disk", isPrimary: true) { _ in decide(true) },
                ],
                onCancel: { decide(false) }
            )
        }
        // A pane created after the status landed would otherwise render
        // "not a git repository" inside a repository.
        editor.setGitStatus(latestGitStatus)
        // `workspaceDirectory(for:)` already falls back to the open
        // workspace when the pane carries no project of its own.
        editor.workspaceRoot = workspaceDirectory(for: project)
            .map { URL(fileURLWithPath: $0) }
    }

    /// The tab strip's ± toggle, a FILES-tree badge click or the ⌘K row asked
    /// for `url`'s diff against HEAD.
    ///
    /// Three rungs, in order:
    ///
    /// 1. A diff of this file already open **anywhere** is focused rather
    ///    than opened twice — Task 11's workspace-wide no-duplicates rule,
    ///    applied to diffs.
    /// 2. `origin`, the pane whose strip asked. Focus has usually moved on by
    ///    then, so "the focused pane" would be the wrong answer.
    /// 3. `targetEditorPane()`, the same routing a FILES-tree click uses —
    ///    last-focused editor, any editor, or a new one. `nil` only when the
    ///    grid is full and none of it is an editor, and then this does
    ///    nothing, exactly like ⇧⌘E.
    func openDiffInEditor(_ url: URL, from origin: String? = nil) {
        for id in workspace.allPaneIDs {
            guard let pane = workspace.editorPane(for: id),
                  pane.model.index(of: url.path, kind: .diff) != nil
            else { continue }
            workspace.focusPane(id)
            pane.openDiff(url)
            return
        }
        if let origin, let pane = workspace.editorPane(for: origin) {
            workspace.focusPane(origin)
            pane.openDiff(url)
            return
        }
        guard let target = targetEditorPane() else { return }
        workspace.focusPane(target.id)
        target.pane.openDiff(url)
    }

    /// The FILES header's counts, or the ⌘K row: the repo-wide overview, in
    /// the same pane a file click would use. Seeded on the way in, because the
    /// tab renders whatever status the pane is currently holding.
    func openChangesOverview() {
        guard let target = targetEditorPane() else { return }
        workspace.focusPane(target.id)
        target.pane.setGitStatus(latestGitStatus)
        target.pane.openChanges()
    }

    // MARK: - Tab drag and drop

    /// A reorder inside one strip, or a move between two editor panes.
    ///
    /// `insertIndex` is the index the strip's drop indicator was showing —
    /// measured over the tabs *as they stand*. For a move into another pane
    /// that is already the right slot; for a reorder inside the dragged tab's
    /// own strip it counts the dragged tab itself, so a rightward move is one
    /// too far and is corrected here. `Int.max` means "no position was
    /// indicated" — a drop on the pane body rather than on its strip.
    func handleEditorTabDrop(_ payload: EditorTabDragPayload, intoPane targetID: String, at insertIndex: Int) {
        guard let source = workspace.editorPane(for: payload.paneID),
              workspace.editorPane(for: targetID) != nil,
              source.model.tabs.indices.contains(payload.index)
        else { return }
        if payload.paneID == targetID {
            // A release on the pane's own body says nothing about where the
            // tab should sit, so it moves nothing — an accidental drop must
            // not silently reorder the strip.
            guard insertIndex != Int.max else { return }
            source.moveTab(
                from: payload.index,
                to: insertIndex > payload.index ? insertIndex - 1 : insertIndex
            )
            return
        }
        deliverAfterSavePrompt(payload) { [weak self] dragged in
            guard let self,
                  let source = workspace.editorPane(for: payload.paneID),
                  let target = workspace.editorPane(for: targetID),
                  let index = source.model.index(of: dragged.path, kind: dragged.kind),
                  let tab = source.removeTabForTransfer(at: index)
            else { return }
            target.receiveTransferredTab(
                tab,
                at: insertIndex == Int.max ? target.model.tabs.count : insertIndex
            )
            workspace.focusPane(targetID)
        }
    }

    /// The grid-faithful "edge split": a new editor pane inserted adjacent to
    /// `targetID` in grid order, holding the dragged tab.
    ///
    /// The pane is created **before** the tab is lifted out of its source.
    /// The other order has a hole in it: moving a pane's only tab away closes
    /// that pane, and if it was also the anchor there would be nothing left
    /// to insert beside — the tab would be gone with nowhere to land.
    func handleEditorTabEdgeDrop(_ payload: EditorTabDragPayload, target targetID: String, zone: EditorTabDropZone) {
        guard zone != .center,
              let source = workspace.editorPane(for: payload.paneID),
              source.model.tabs.indices.contains(payload.index),
              let anchor = workspace.descriptor(for: targetID),
              workspace.hasRoomForAnotherPane(inGroupOf: targetID)
        else { return }
        deliverAfterSavePrompt(payload) { [weak self] dragged in
            guard let self,
                  let source = workspace.editorPane(for: payload.paneID),
                  source.model.index(of: dragged.path, kind: dragged.kind) != nil,
                  workspace.descriptor(for: targetID) != nil,
                  workspace.hasRoomForAnotherPane(inGroupOf: targetID)
            else { return }
            let descriptor = editorPaneDescriptor(holding: dragged, group: anchor.group, like: anchor)
            createEditorPane(descriptor, liftingFrom: source, tab: dragged) {
                self.workspace.addPane(
                    descriptor,
                    inserting: zone == .insertBefore ? .before : .after,
                    of: targetID
                )
            }
        }
    }

    /// A drop on an empty grid cell. A plain append: the grid's hole *is* the
    /// next fill slot, so the new pane lands exactly where the drop happened.
    func handleEditorTabHoleDrop(_ payload: EditorTabDragPayload) {
        guard let source = workspace.editorPane(for: payload.paneID),
              source.model.tabs.indices.contains(payload.index),
              // The hole only ever exists in the session on screen, so that
              // is the session the new pane joins.
              let group = workspace.activeGroup,
              workspace.paneCount(inGroup: group) < PaneGrid.maxPanes
        else { return }
        let sibling = workspace.paneIDs.first.flatMap { workspace.descriptor(for: $0) }
        deliverAfterSavePrompt(payload) { [weak self] dragged in
            guard let self,
                  let source = workspace.editorPane(for: payload.paneID),
                  source.model.index(of: dragged.path, kind: dragged.kind) != nil,
                  workspace.paneCount(inGroup: group) < PaneGrid.maxPanes
            else { return }
            let descriptor = editorPaneDescriptor(holding: dragged, group: group, like: sibling)
            createEditorPane(descriptor, liftingFrom: source, tab: dragged) {
                self.workspace.addPane(descriptor)
            }
        }
    }

    /// The create-then-lift half both pane-creating drops share: build the
    /// pane holding the tab, wire it, and only then take the tab out of the
    /// pane it came from.
    ///
    /// The two steps are one move, so the persisted row must not be written
    /// between them — `addPane` fires `onPanesChanged` synchronously, and a
    /// snapshot taken there would show the same tab open in two panes. The
    /// gate is closed across the pair and the row written once at the end.
    private func createEditorPane(
        _ descriptor: PaneDescriptor,
        liftingFrom source: EditorPaneView,
        tab: EditorTab,
        add: () -> Bool
    ) {
        editorPaneDropInFlight = true
        defer {
            editorPaneDropInFlight = false
            persistEditorPanes()
        }
        guard add() else { return }
        wireEditorPane(descriptor.sessionID, project: descriptor.project)
        // Re-resolved by identity, never by the payload's index: the prompt
        // above can have handed control back to the run loop, and the strip
        // can have moved under it. Lifting the wrong tab here would discard
        // *its* unsaved buffer.
        guard let index = source.model.index(of: tab.path, kind: tab.kind),
              source.removeTabForTransfer(at: index) != nil
        else {
            assertionFailure("the tab vanished between the guard above and the lift")
            return
        }
        workspace.focusPane(descriptor.sessionID)
    }

    /// A dirty buffer cannot travel: each editor pane owns its own web view,
    /// and the destination reads the file from disk. So v1 resolves the edit
    /// first — save it, discard it, or call the whole drop off — and never
    /// moves a tab whose unsaved work would go quietly missing.
    ///
    /// A clean tab delivers straight through; nothing here is asynchronous
    /// unless there is genuinely something to ask about.
    /// `deliver` is handed the tab's **identity** — `(path, kind)`, resolved
    /// once here while the payload's index is still meaningful. Every caller
    /// must find the tab again by that identity rather than by
    /// `payload.index`: a prompt (or an async save) hands control back to the
    /// run loop, and a tab closed or dragged in that window shifts every index
    /// after it. Moving the wrong tab would also discard *its* buffer.
    private func deliverAfterSavePrompt(
        _ payload: EditorTabDragPayload,
        then deliver: @escaping (EditorTab) -> Void
    ) {
        guard let source = workspace.editorPane(for: payload.paneID),
              source.model.tabs.indices.contains(payload.index)
        else { return }
        resolveThenDeliver(paneID: payload.paneID, tab: source.model.tabs[payload.index], then: deliver)
    }

    /// The prompt itself, keyed on the tab's identity so it can ask again.
    ///
    /// A "Save" answer is **not** enough to let the tab travel: delivering it
    /// runs `removeTabForTransfer` -> `discardResources` -> `closeModel`,
    /// which disposes the Monaco model, and `receiveTransferredTab` then
    /// forces the arriving copy clean. That is every bit as final as a close,
    /// so it is held to the same rule the close path is: `save`'s `true` means
    /// the bytes reached disk, not that the buffer is clean, and a keystroke
    /// typed inside the write is (correctly) refused by the version-scoped
    /// `markSaved`. Delivering on `true` alone would drop it silently.
    /// `.stillDirty` therefore asks again, about the content that is now
    /// there.
    private func resolveThenDeliver(
        paneID: String,
        tab: EditorTab,
        then deliver: @escaping (EditorTab) -> Void
    ) {
        guard let source = workspace.editorPane(for: paneID),
              source.model.index(of: tab.path, kind: tab.kind) != nil
        else { return }
        // Ask the page before deciding there is nothing to ask the *user*.
        // Swift's dirty flag is written only by the posted `dirtyChanged`, so
        // a keystroke typed a moment before the drop still reads clean — and
        // delivering disposes the source's Monaco model, which is where that
        // keystroke lives. This gate is the difference between "prompted and
        // saved" and "gone without a word".
        source.reconcileDirtyFlags { [weak self] in
            guard let source = self?.workspace.editorPane(for: paneID),
                  let index = source.model.index(of: tab.path, kind: tab.kind)
            else { return }
            guard source.model.tabs[index].isDirty else {
                deliver(tab)
                return
            }
            self?.promptThenDeliver(paneID: paneID, tab: tab, then: deliver)
        }
    }

    private func promptThenDeliver(
        paneID: String,
        tab: EditorTab,
        then deliver: @escaping (EditorTab) -> Void
    ) {
        guard let source = workspace.editorPane(for: paneID) else { return }
        source.confirmSave((tab.path as NSString).lastPathComponent) { [weak self] decision in
            switch decision {
            case .cancel:
                break
            case .discard:
                deliver(tab)
            case .save:
                guard let source = self?.workspace.editorPane(for: paneID),
                      let index = source.model.index(of: tab.path, kind: tab.kind)
                else { return }
                source.saveAndConfirmClean(at: index) { [weak self] acknowledgement in
                    switch acknowledgement {
                    case .clean:
                        deliver(tab)
                    case .failed:
                        // `save` already put the error on screen; the tab
                        // stays where it is, still dirty, and the drop is off.
                        break
                    case .stillDirty:
                        self?.resolveThenDeliver(paneID: paneID, tab: tab, then: deliver)
                    }
                }
            }
        }
    }

    /// The descriptor for a pane created by a tab drop. Numbered by the same
    /// rule `addPane(_:startSession:)` uses, so the sidebar does not show two
    /// "Editor 1"s, and seeded with the tab already pinned — a tab you
    /// deliberately dragged somewhere is not a preview.
    private func editorPaneDescriptor(
        holding tab: EditorTab,
        group: String,
        like sibling: PaneDescriptor?
    ) -> PaneDescriptor {
        var descriptor = PaneDescriptor(
            sessionID: WorkspaceRestoration.bootstrapPane().sessionID,
            group: group,
            groupLabel: sibling?.groupLabel,
            project: sibling?.project ?? "",
            kind: .editor,
            editorTabs: [PersistedEditorTab(path: tab.path, kind: tab.kind.rawValue, pinned: true)],
            editorActiveIndex: 0
        )
        descriptor.autoNumber = SessionOutline.nextPaneNumber(
            workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) },
            group: group,
            engine: descriptor.engine,
            kind: .editor
        )
        return descriptor
    }

    /// The daemon restarted and forgot this session.
    ///
    /// Reported *and* rebuilt. Reporting alone (the original Task 6c
    /// behaviour) left a dead terminal behind every daemon restart, and the
    /// pane's conversation is not lost with the daemon — it is on disk, keyed
    /// by the uuid the pane derives. So the pane goes back through
    /// `ensureSession`, which reaps the daemon's orphans and lands on
    /// `createSession`'s `--resume` rung: the same agent, its own history,
    /// rather than a fresh blank Claude per pane.
    func handleReattachFailure(_ sessionID: String) {
        guard workspace.container(for: sessionID) != nil else { return }
        readySessions.remove(sessionID)
        applySessionStatus("Session lost — daemon restarted", for: sessionID)
        daemonPersistence.recordReattachFailure(sessionID: sessionID)
        // Terminals only: a browser pane has no PTY, and `ensureSession` would
        // silently start a login shell under its id.
        guard workspace.descriptor(for: sessionID)?.kind == .terminal else { return }
        ensureSession(sessionID)
    }

    /// Sessions with an `ensureSession` round trip in flight. Two callers can
    /// legitimately ask for the same pane at once — a reconnect's restore
    /// sweep and that pane's own reattach failure — and without this both see
    /// "not in the daemon's list" and create it, so the loser gets `session
    /// already exists` painted into a pane whose agent just started fine.
    private var ensuringSessions: Set<String> = []

    /// `true` if this caller owns the round trip; `false` if one is already
    /// running for the same pane.
    func beginEnsure(_ sessionID: String) -> Bool {
        ensuringSessions.insert(sessionID).inserted
    }

    func endEnsure(_ sessionID: String) {
        ensuringSessions.remove(sessionID)
    }

    private func ensureSession(_ sessionID: String) {
        if let sessionEnsurer { sessionEnsurer(sessionID); return }
        guard !readySessions.contains(sessionID) else {
            attach(sessionID)
            return
        }
        guard beginEnsure(sessionID) else { return }
        connection.listSessions { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(sessions):
                // Free the daemon's abandoned slots *before* asking it for a
                // new one. This is why the reap lives here rather than after
                // the restore loop: the daemon caps at `MAX_SESSIONS`, so an
                // orphan holding the last slot makes the very session being
                // started here fail.
                // Frames are written FIFO on one connection, so the kills below
                // reach the daemon ahead of this pane's `createSession`.
                reapOrphanedSessions(daemonSessions: sessions)
                if sessions.contains(sessionID) {
                    endEnsure(sessionID)
                    attach(sessionID)
                } else {
                    // Held until the spawn itself answers — `createSession`
                    // releases it — so a second caller cannot slip past the
                    // list check while this one is still starting the session.
                    createSession(sessionID)
                }
            case let .failure(error):
                endEnsure(sessionID)
                applySessionStatus(error.localizedDescription, for: sessionID)
                reportSessionFailure(error.localizedDescription, for: sessionID)
            }
        }
    }

    /// Starts the PTY behind one pane.
    ///
    /// Every engine launches here now. The daemon has always taken an
    /// arbitrary argv, cwd and environment; what was missing was the half that
    /// builds them, which `EngineLauncher` now ports from
    /// `src-tauri/src/sessions.rs`. An engine whose CLI is not installed says
    /// so, rather than quietly starting a login shell under that engine's name.
    /// Terminals whose Claude conversation is provably unclaimed — freshly
    /// minted session ids, whose derived conversation uuid therefore names
    /// nothing yet. See `claimConversation(for:)`.
    private var claimableConversations: Set<String> = []

    /// The conversation id this spawn may claim, consuming the claim.
    ///
    /// One claim per terminal, ever. `--session-id` for a conversation that
    /// already exists kills the spawn outright, so a second attempt for the
    /// same terminal — a reconnect after the daemon lost its session, say —
    /// must fall back to a stock `claude` rather than re-claim an id it has
    /// already written a conversation under.
    func claimConversation(for sessionID: String) -> String? {
        guard claimableConversations.remove(sessionID) != nil else { return nil }
        return ClaudeConversation.uuid(forSessionID: sessionID)
    }

    /// Only a session id minted this run can claim a conversation: one
    /// restored from the persisted layout may already have written one, and
    /// claiming it again would kill the terminal.
    func allowConversationClaim(for sessionID: String) {
        claimableConversations.insert(sessionID)
    }

    /// Terminals spawned with `--resume`, and when — see `onExit`'s fallback.
    private var resumeSpawns: [String: Date] = [:]

    /// How long after a `--resume` spawn an exit still counts as "that
    /// conversation does not exist" rather than "the user quit". Sized off the
    /// measurement in `src-tauri/src/sessions.rs`: `claude --resume <uuid>`
    /// naming nothing exits 1 after ~1.25 s.
    /// ponytail: a wall-clock window, not a liveness probe — the daemon owns
    /// the child, so an exit event is all we get, and 4× the observed failure
    /// latency separates it from a real quit well enough.
    static let resumeFallbackWindow: TimeInterval = 5

    /// Whether an exit means the resumed conversation was not there, rather
    /// than the user quitting an agent that resumed fine. `nil` `spawnedAt` is
    /// a session that never carried `--resume` at all.
    static func resumeFailed(
        spawnedAt: Date?,
        exitCode: UInt32?,
        now: Date = Date()
    ) -> Bool {
        guard let spawnedAt, exitCode != 0 else { return false }
        return now.timeIntervalSince(spawnedAt) < resumeFallbackWindow
    }

    /// `stock` skips both identity flags — the fallback after a `--resume`
    /// found no conversation to resume.
    private func createSession(_ sessionID: String, stock: Bool = false) {
        let descriptor = workspace.descriptor(for: sessionID)
        let engine = descriptor?.engine ?? .shell
        // A pane that may claim its conversation is a fresh one: `--session-id`.
        // One that may not is a restore whose daemon session is gone — the
        // daemon was killed, or the app reopened after it was — so it reopens
        // its own conversation with `--resume` instead of starting blank.
        let claimed = stock ? nil : claimConversation(for: sessionID)
        let resuming = !stock && claimed == nil
        guard
            let command = EngineLauncher.command(
                for: engine,
                conversationID: resuming ? ClaudeConversation.uuid(forSessionID: sessionID) : claimed,
                resuming: resuming
            )
        else {
            let message = "\(engine.rawValue) is not installed — \(EngineLauncher.binaryName(for: engine)) is not on your PATH"
            endEnsure(sessionID)
            applySessionStatus(message, for: sessionID)
            reportSessionFailure(message, for: sessionID)
            return
        }
        let signpost = OSSignpostID(log: Instrumentation.log)
        os_signpost(
            .begin,
            log: Instrumentation.log,
            name: "Create Session",
            signpostID: signpost
        )
        // Read off the built argv rather than off `engine`, so engines that
        // ignore the conversation id never arm the fallback.
        if command.contains("--resume") { resumeSpawns[sessionID] = Date() }
        let cwd = startingDirectory(for: descriptor)
        connection.createSession(
            CreateSessionRequest(
                id: sessionID,
                command: command,
                cwd: cwd,
                environment: EngineLauncher.environment(),
                cols: 80,
                rows: 24,
                transcriptPath: nil
            )
        ) { [weak self] result in
            os_signpost(
                .end,
                log: Instrumentation.log,
                name: "Create Session",
                signpostID: signpost
            )
            guard let self else { return }
            endEnsure(sessionID)
            switch result {
            case .success:
                attach(sessionID)
            case let .failure(error):
                applySessionStatus(error.localizedDescription, for: sessionID)
                reportSessionFailure(error.localizedDescription, for: sessionID)
            }
        }
    }

    /// Puts the reason a terminal never started into the terminal itself.
    ///
    /// `applySessionStatus` reaches the window title and nothing else, and
    /// only while that pane holds focus — so a refused session looked exactly
    /// like a working one that had not printed yet: an empty pane with a
    /// blinking cursor. Now the pane's border goes red and the pane says what
    /// happened, in the one place the user is already looking.
    func reportSessionFailure(_ message: String, for sessionID: String) {
        workspace.setStatus(.error, for: sessionID)
        guard let surface = workspace.terminalSurface(for: sessionID) else { return }
        let text = "\r\n\u{1B}[1;31m▲ This terminal could not start\u{1B}[0m\r\n  \(message)\r\n"
        surface.feed(Data(text.utf8), isSnapshot: false)
    }

    /// The directory a pane's process starts in.
    ///
    /// A terminal belongs to its workspace, so the workspace's folder is the
    /// answer unless the pane already sits *inside* it — a pane that was in
    /// `…/OmniAgent-ADE/macos` keeps that, a pane carrying a stale `~` from an
    /// older layout does not. Without that rule a workspace opened today
    /// inherits last week's home directory and every agent starts in the wrong
    /// tree.
    func startingDirectory(for descriptor: PaneDescriptor?) -> String {
        let carried = descriptor?.cwd ?? ""
        guard let folder = workspaceDirectory(for: descriptor?.project) else {
            return carried.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.path
                : carried
        }
        return WorkspaceWindowController.isInside(carried, folder) ? carried : folder
    }

    /// `true` when `path` is the folder itself or below it.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        guard !path.isEmpty, !folder.isEmpty else { return false }
        let a = (path as NSString).standardizingPath
        let b = (folder as NSString).standardizingPath
        return a == b || a.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }

    /// A project id resolved to the folder the brain recorded for it.
    func workspaceDirectory(for project: String?) -> String? {
        let id = (project?.isEmpty == false) ? project : selectedProjectID
        guard let id else { return nil }
        // Home's Chat scratch workspace is not in the brain — it is a fixed
        // folder under Documents, resolved here so anything asking "where
        // would this run?" gets a real answer for it too.
        if id == HomeChatWorkspace.id { return HomeChatWorkspace.directory }
        if let path = workspaces.first(where: { $0.id == id })?.path, !path.isEmpty {
            return path
        }
        if let pending = homePendingFolder, pending.id == id, let path = pending.path { return path }
        // Nothing recorded — fall back to a live pane in the same project.
        return workspace.allPaneIDs
            .compactMap { workspace.descriptor(for: $0) }
            .first { $0.project == id && !$0.cwd.isEmpty }?
            .cwd
    }

    /// A workspace's sessions, first-created-first — Home's session picker
    /// and its default ("the first session") both read this, and it is
    /// deliberately the same grouping `reloadOutline()` feeds the sidebar,
    /// so the two never disagree about what a workspace's sessions are.
    func homeSessions(for project: String?) -> [SessionGroupNode] {
        guard let project else { return [] }
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        return SessionOutline.group(panes, focusedPaneID: nil).first { $0.project == project }?.sessions ?? []
    }

    /// Home's workspace on a visit: the user's own pick, as long as it is
    /// still open (Chat always is); otherwise the sole open workspace, or
    /// nothing at all — never a guess between several.
    static func homeWorkspace(keeping current: String?, open: [BrainProjectSummary]) -> String? {
        if let current, current == HomeChatWorkspace.id || open.contains(where: { $0.id == current }) {
            return current
        }
        return open.count == 1 ? open[0].id : nil
    }

    /// Home's chips for its current workspace — on every visit, and again
    /// whenever the sidebar's name or colour for that workspace changes
    /// while Home is on screen, so the chip never lags the tree.
    private func refreshHomeChips() {
        homeSelectedProjectID = Self.homeWorkspace(keeping: homeSelectedProjectID, open: homeOpenWorkspaces())
        let sessions = homeSessions(for: homeSelectedProjectID)
        let branchDirectory = sessions.first?.cwd ?? homeDirectory()
        homeView.refresh(
            workspaceID: homeSelectedProjectID,
            workspaceName: homeSelectedProjectID.map(homeWorkspaceLabel),
            tint: homeSelectedProjectID.flatMap(sidebarTint),
            sessionLabel: sessions.first?.label ?? "New session",
            branch: branchDirectory.flatMap(GitBranch.forDirectory)
        )
    }

    /// What Home's chip calls a workspace: the sidebar's name for it, or
    /// "Chat" for the scratch one the sidebar does not list.
    private func homeWorkspaceLabel(_ id: String) -> String {
        id == HomeChatWorkspace.id ? HomeChatWorkspace.label : sidebarDisplayLabel(for: id)
    }

    /// What Home's picker offers: the open workspaces plus the pending
    /// folder, when there is one the sidebar does not already list.
    static func homeWorkspaces(open: [BrainProjectSummary], pending: BrainProjectSummary?) -> [BrainProjectSummary] {
        guard let pending, !open.contains(where: { $0.id == pending.id }) else { return open }
        return open + [pending]
    }

    private func homeOpenWorkspaces() -> [BrainProjectSummary] {
        Self.homeWorkspaces(open: Self.openWorkspaces(workspaces, closed: closedWorkspaceIDs), pending: homePendingFolder)
    }

    /// Where Home's chosen workspace lives — `nil` when none is chosen.
    /// Never `workspaceDirectory(for: nil)`, which answers for the Desk's
    /// workspace: "Select workspace" must not borrow the Desk's branch.
    private func homeDirectory() -> String? {
        homeSelectedProjectID.flatMap { workspaceDirectory(for: $0) }
    }

    /// Home's "Local folder or repository…": point the chip at the folder
    /// and nothing else — no root added, no session started. A folder the
    /// brain already knows keeps its recorded id, so it is the same
    /// workspace, not a twin; an unknown one takes the id the brain would
    /// mint for it (`roots::project_id_for`: the basename).
    private func pickHomeFolder() {
        chooseSessionDirectory(startingAt: homeDirectory() ?? workspaceRoot()) { [weak self] chosen in
            guard let self, let chosen else { return }
            let id = workspaces.first { $0.path == chosen }?.id ?? (chosen as NSString).lastPathComponent
            homePendingFolder = BrainProjectSummary(id: id, label: id, path: chosen)
            selectHomeWorkspace(id)
        }
    }

    /// A pick from Home's own project menu — updates the chips and the
    /// session/branch that go with the new workspace, and nothing else: no
    /// `startSession`, no touching `selectedProjectID`, no leaving Home.
    private func selectHomeWorkspace(_ id: String) {
        homeSelectedProjectID = id
        let sessions = homeSessions(for: id)
        let branchDirectory = sessions.first?.cwd ?? workspaceDirectory(for: id)
        homeView.refresh(
            workspaceID: id,
            workspaceName: homeWorkspaceLabel(id),
            tint: sidebarTint(for: id),
            sessionLabel: sessions.first?.label ?? "New session",
            branch: branchDirectory.flatMap(GitBranch.forDirectory)
        )
    }

    private func attach(_ sessionID: String) {
        guard let surface = workspace.terminalSurface(for: sessionID) else { return }
        readySessions.insert(sessionID)
        connection.attach(sessionID: sessionID, afterSequence: nil)
        surface.syncSize()
        // Only this session's status clears — another pane's error stays on its
        // own pane.
        applySessionStatus(nil, for: sessionID)
        os_signpost(.event, log: Instrumentation.log, name: "Attach Session")
    }

    /// The single writer for one session's status line. `nil` clears it.
    func applySessionStatus(_ status: String?, for sessionID: String) {
        sessionStatus[sessionID] = status
        refreshTitle()
    }

    /// The single writer for connection-wide status.
    func applyConnectionStatus(_ status: String?) {
        connectionStatus = status
        refreshTitle()
    }

    /// The bar shows the running session's name and nothing else — no app
    /// name, no status suffix, and nothing at all away from the Desk, where
    /// there is no session to name.
    ///
    /// `window.title` is deliberately left alone below. Nothing draws it any
    /// more, but Mission Control, ⌘` and the Window menu all still read it,
    /// and "OmniAgent — Reconnecting" identifies a window in those lists where
    /// a bare "Session 1" would not.
    func refreshTitle() {
        sessionTitleField.stringValue = currentSessionName()
        titleBar.isReviewToggleVisible = destination == .terminals && workspace.activeGroup != nil

        if let connectionStatus {
            window?.title = "OmniAgent — \(connectionStatus)"
            return
        }
        if let focused = workspace.focusedPaneID, let status = sessionStatus[focused] {
            window?.title = "OmniAgent — \(status)"
            return
        }
        let paneTitle = workspace.focusedPaneID
            .flatMap { workspace.descriptor(for: $0)?.title } ?? ""
        window?.title = paneTitle.isEmpty ? "OmniAgent" : paneTitle
    }

    /// What the sidebar calls the session on screen — the same
    /// `SessionOutline` naming rule, so the bar and the tree can never print
    /// two different names for one session (including the derived
    /// `Session N` a session nobody has named gets).
    private func currentSessionName() -> String {
        guard destination == .terminals, let group = workspace.activeGroup else { return "" }
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        return SessionOutline.group(panes, focusedPaneID: workspace.focusedPaneID)
            .flatMap(\.sessions)
            .first { $0.id == group }?
            .label ?? ""
    }
}

private extension RemoteSessionStatus {
    var title: String {
        switch self {
        case .ready: return "Ready"
        case .thinking: return "Thinking"
        case .toolExecution: return "Running tool"
        case .awaitingApproval: return "Needs approval"
        case .error: return "Error"
        }
    }
}
