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
        // (`SessionRowView`/`TerminalRowView` in `WorkspaceShell.swift`) and
        // the files tree's filter field (`WorkspaceFilesTreeView.filterField`,
        // same file) both call `window.makeFirstResponder` on a plain
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
    /// The design's two-level sidebar. It draws the sessions tree itself —
    /// the design's rows carry engine logos, per-pane status dots and a grid
    /// badge, none of which an `NSOutlineView` cell can lay out that way, so
    /// the old `SessionOutlineView` is gone. `SessionOutline`'s grouping rules
    /// live on and are what the tree is built from.
    let shellSidebar = WorkspaceSidebarView()
    /// The content half of the split: the pane workspace and the placeholder
    /// both live here permanently, and the destination only toggles which is
    /// hidden. Unmounting `PaneWorkspaceView` would tear down live SwiftTerm
    /// views and their PTY attachment along with it.
    private let contentContainer = NSView()
    private let placeholder = WorkspacePlaceholderView()
    /// Which destination is on screen. `applyDestination` is the only writer;
    /// ⌘↩ reads it because focus mode is about a terminal, and off Terminals the
    /// pane workspace is hidden entirely.
    private(set) var destination: WorkspaceDestination = .terminals
    /// Everything `listProjects` last returned — the picker's rows, and where
    /// a selected id is resolved back to a label and path.
    private(set) var workspaces: [BrainProjectSummary] = []
    /// The workspace Level 2 is about. `nil` means "none open", which pins the
    /// sidebar on the picker.
    private(set) var selectedProjectID: String?
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
    /// The window's frame the first time `adjustWindowForRowCount` ran —
    /// every row-count size is a scale of *this*, never of whatever the
    /// window currently measures, so toggling between one row and two
    /// across any number of pane changes lands on the same two sizes rather
    /// than compounding a little larger each round trip.
    ///
    /// ponytail: resets each launch, so a session quit mid-scale-up starts
    /// the next launch from an already-scaled frame — bounded by the
    /// `visibleFrame` clamp below, not unbounded, but worth a real
    /// persisted baseline if the drift ever gets noticed.
    private var rowScaleReferenceFrame: NSRect?
    private var lastGridRowCount: Int?
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

    // MARK: - Task 6b-2: settings/onboarding/usage/inspector

    let settingsStore: SettingsStore
    let usageRecorder = UsageAnalyticsRecorder()
    /// The shared project id -> label cache, built from `listProjects` —
    /// what fixes 6b-1 concern #3 ("project rows show ids, not labels") for
    /// the outline, the palette and the inspector alike, from one read.
    private(set) var projectLabels: [String: String] = [:]
    let authGateCoordinator: AuthGateCoordinator
    private let authGateWindow: AuthGateWindowController
    private let firstRunWindow: FirstRunWindowController
    private let settingsWindowController: SettingsWindowController
    let inspector: InspectorWindowController
    /// Guards the auth-gate/first-run presentation sequence to once per
    /// launch, the same one-shot-then-re-arm-on-failure shape
    /// `layoutReadDispatched` uses.
    private var onboardingDispatched = false
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
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OmniAgent"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(
            srgbRed: 8 / 255,
            green: 10 / 255,
            blue: 14 / 255,
            alpha: 1
        )
        window.minSize = NSSize(width: 520, height: 320)

        super.init(window: window)
        installSplitView(on: window)
        installToolbar(on: window)
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
            refreshTitle()
            reloadOutline()
            refreshInspectorIfVisible(for: paneID)
        }
        workspace.onRequestNewPane = { [weak self] in self?.newTerminalPane(nil) }
        workspace.onRequestNewBrowserPane = { [weak self] in self?.newBrowserPane(nil) }
        workspace.onRequestNewEditorPane = { [weak self] in self?.newEditorPane(nil) }
        workspace.onRequestClosePane = { [weak self] paneID in
            guard let self else { return }
            // Route through focus so the header's close button ends *that*
            // pane, not whichever one happened to be focused.
            workspace.focusPane(paneID)
            closePane(nil)
        }
        workspace.onRequestPaneMenu = { [weak self] _, anchor in
            guard let self else { return }
            // The header focuses the pane before asking, so the items can be
            // nil-targeted and travel the responder chain to *that* pane —
            // exactly the route their keystrokes take. Positioned in the
            // button's own flipped coordinates, so `maxY` is its bottom edge.
            paneOptionsMenu().popUp(
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
            self?.adjustWindowForRowCount()
        }
        notifier.onEntriesChanged = { [weak self] entries in self?.persistNotifications(entries) }
        usageRecorder.onStoreChanged = { [weak self] store in self?.persistUsageAnalytics(store) }
        shellSidebar.onSelectPane = { [weak self] id in self?.workspace.focusPane(id) }
        shellSidebar.onSelectSession = { [weak self] session in
            guard let first = session.paneIDs.first else { return }
            self?.workspace.focusPane(first)
        }
        shellSidebar.onRenameSession = { [weak self] session, name in
            self?.renameSession(session, to: name)
        }
        shellSidebar.onRenamePane = { [weak self] paneID, name in
            self?.renamePane(paneID, to: name)
        }
        shellSidebar.onNewSession = { [weak self] in self?.newSession(nil) }
        shellSidebar.onNewTerminal = { [weak self] in
            guard let self else { return }
            let panes = self.workspace.allPaneIDs.compactMap { self.workspace.descriptor(for: $0) }
            let current = SessionOutline.group(panes, focusedPaneID: self.workspace.focusedPaneID)
                .flatMap(\.sessions)
                .first(where: \.isCurrent)
            guard let current else { return }
            self.newPane(in: current)
        }
        shellSidebar.onNewBrowser = { [weak self] in
            guard let self else { return }
            // The same current-session lookup `onNewTerminal` uses: the row
            // lives under the session it adds to.
            let panes = self.workspace.allPaneIDs.compactMap { self.workspace.descriptor(for: $0) }
            let current = SessionOutline.group(panes, focusedPaneID: self.workspace.focusedPaneID)
                .flatMap(\.sessions)
                .first(where: \.isCurrent)
            guard let current else { return }
            self.newBrowser(in: current)
        }
        shellSidebar.onNewEditor = { [weak self] in
            guard let self else { return }
            // The same current-session lookup the two rows above use.
            let panes = self.workspace.allPaneIDs.compactMap { self.workspace.descriptor(for: $0) }
            let current = SessionOutline.group(panes, focusedPaneID: self.workspace.focusedPaneID)
                .flatMap(\.sessions)
                .first(where: \.isCurrent)
            guard let current else { return }
            self.newEditor(in: current)
        }
        shellSidebar.onOpenFile = { [weak self] url, pinned in
            self?.openFileInEditor(url, pinned: pinned)
        }
        shellSidebar.onOpenDiff = { [weak self] url in self?.openDiffInEditor(url) }
        shellSidebar.onOpenAllChanges = { [weak self] in self?.openChangesOverview() }
        // The sidebar owns the `git status`; the editor panes render it. Held
        // here as well so a pane created *later* can be seeded with it — see
        // the editor branch of `addPane`.
        shellSidebar.onGitStatusChanged = { [weak self] status in
            guard let self else { return }
            latestGitStatus = status
            for id in workspace.allPaneIDs {
                workspace.editorPane(for: id)?.setGitStatus(status)
            }
        }
        shellSidebar.onOpenSettings = { [weak self] in self?.showSettings(nil) }
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

    /// One entry per row count `PaneGridShape.ladder` can produce (it tops out
    /// at 4×3): a single row — one pane, or two side by side — reads short and
    /// wide for what's actually on screen, and two or three rows benefit from a
    /// little more room per terminal. All of them scale the reference frame
    /// uniformly, so the window keeps its own proportions rather than being
    /// reshaped.
    ///
    /// Two and three rows share a factor deliberately. Growing the window again
    /// on the eighth-to-ninth pane would shove it around the screen at the exact
    /// moment the user is placing a pane, and a uniform scale buys height only
    /// by also buying width the third row does not need. Crossing into the
    /// third row therefore leaves the window where it is.
    private static let rowWindowScale: [Int: CGFloat] = [1: 1.18, 2: 1.08, 3: 1.08]

    /// Called whenever the on-screen pane set changes. Only acts on an
    /// actual row-count change — not every rename or reorder `onPanesChanged`
    /// also fires for — so a manual resize the user makes while the row
    /// count is unchanged is never fought mid-session.
    private func adjustWindowForRowCount() {
        guard let window, let rows = workspace.grid?.rows, rows != lastGridRowCount else { return }
        lastGridRowCount = rows
        let reference = rowScaleReferenceFrame ?? window.frame
        rowScaleReferenceFrame = reference
        guard let scale = Self.rowWindowScale[rows] else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? reference
        let size = NSSize(
            width: min(reference.width * scale, visible.width).rounded(),
            height: min(reference.height * scale, visible.height).rounded()
        )
        let origin = NSPoint(x: (visible.midX - size.width / 2).rounded(), y: (visible.midY - size.height / 2).rounded())
        // Not animated under XCTest, the same reason `restoreWindowFrame` isn't:
        // a test reading `window.frame` right after this call needs the final
        // rect there, not whatever an in-flight animation last painted.
        let animate = window.isVisible && NSClassFromString("XCTestCase") == nil
        window.setFrame(NSRect(origin: origin, size: size), display: true, animate: animate)
    }

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

    /// The split: sidebar item on the left (kept, so the outline still gets
    /// the system's translucency, collapse animation, remembered width and the
    /// standard `toggleSidebar:` action), the destination container on the
    /// right. Only the sidebar's *content* changed in step 1 — the outline is
    /// now nested inside `WorkspaceSidebarView`'s Level 2 rather than being
    /// the whole pane.
    private func installSplitView(on window: NSWindow) {
        workspace.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(workspace)
        contentContainer.addSubview(placeholder)
        for view in [workspace, placeholder] as [NSView] {
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
                view.topAnchor.constraint(equalTo: contentContainer.topAnchor),
                view.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
            ])
        }

        shellSidebar.onSelectWorkspace = { [weak self] chosen in
            self?.selectWorkspace(id: chosen.id)
        }
        shellSidebar.onSelectDestination = { [weak self] destination in
            self?.applyDestination(destination)
        }
        // The design's "New workspace" opens a folder picker and starts there —
        // the one flow that still asks, because the folder is the new thing.
        shellSidebar.onNewWorkspace = { [weak self] in self?.openWorkspaceFolder(nil) }
        applyDestination(.terminals)

        let sidebar = NSViewController()
        sidebar.view = shellSidebar
        let content = NSViewController()
        content.view = contentContainer
        let split = NSSplitViewController()
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        // The design draws the sidebar at 238pt (`flex:none;width:238px`), and
        // that is where it opens — but it is a starting width, not a cage.
        // Both bounds used to be pinned to it, which made the divider
        // immovable: a sidebar holding session names and a file tree is
        // exactly the thing a user wants wider or narrower depending on what
        // they are doing.
        //
        // The floor is the design's own width less what the widest nav row can
        // give up; the ceiling keeps the pane grid the larger half on any
        // window this app opens at.
        sidebarItem.minimumThickness = ShellMetrics.sidebarMinimumWidth
        sidebarItem.maximumThickness = ShellMetrics.sidebarMaximumWidth
        sidebarItem.canCollapse = true
        // AppKit remembers the dragged position under this name, so the width
        // survives a relaunch without anything here persisting it.
        split.splitView.autosaveName = "OmniAgentWorkspaceSidebar"
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        window.contentViewController = split
    }

    /// Swaps the destination. `isHidden`, never add/remove: see
    /// `contentContainer`'s own doc for why the pane workspace must stay
    /// mounted.
    func applyDestination(_ destination: WorkspaceDestination) {
        self.destination = destination
        shellSidebar.applyDestination(destination)
        let isTerminals = destination == .terminals
        workspace.isHidden = !isTerminals
        placeholder.isHidden = isTerminals
        if !isTerminals { placeholder.show(destination) }
    }

    /// Opens a workspace in Level 2 and scopes the outline to it.
    func selectWorkspace(id: String, animated: Bool = true) {
        selectedProjectID = id
        let summary = workspaces.first { $0.id == id }
            ?? BrainProjectSummary(
                id: id,
                label: SessionOutline.projectLabel(id, labels: projectLabels),
                path: nil
            )
        shellSidebar.showWorkspace(summary, animated: animated)
        // The FILES tree follows the workspace. Prefer the brain's recorded
        // path; fall back to the cwd of a pane in this project, which is what
        // a session opened by folder picker will have.
        let paneCwd = workspace.allPaneIDs
            .compactMap { workspace.descriptor(for: $0) }
            .first { $0.project == id }?
            .cwd
        let directory = summary.path ?? paneCwd
        shellSidebar.setFilesRoot(directory.map { URL(fileURLWithPath: $0) })
        reloadOutline()
    }

    /// With panes already restored there is a workspace to be in, so the app
    /// opens on Level 2 rather than making the user pick what is already
    /// there. With no panes at all the picker stays up — the design's own
    /// first-run screen.
    private func selectInitialWorkspaceIfNeeded(animated: Bool) {
        guard selectedProjectID == nil else { return }
        let focused = workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0)?.project }
        let anyPane = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0)?.project }.first
        guard let project = focused ?? anyPane, !project.isEmpty else { return }
        selectWorkspace(id: project, animated: animated)
    }

    /// Sessions per project id — the picker's card meta line, and the count
    /// badge on the Terminals row.
    private func sessionCounts() -> [String: Int] {
        let panes = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        return SessionOutline.group(panes, focusedPaneID: nil)
            .reduce(into: [:]) { counts, node in counts[node.project] = node.sessions.count }
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
                refreshProjectLabels()
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
        let current = workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        chooseSessionDirectory(startingAt: workspaceRoot()) { [weak self] chosen in
            guard let self, let chosen else { return }
            startSession(inDirectory: chosen, project: current?.project ?? "")
        }
    }

    /// The session-creation half of `newSession(_:)`, without the chooser —
    /// so the naming and grouping rules are testable without a panel.
    @discardableResult
    func startSession(inDirectory cwd: String, project: String) -> String? {
        guard workspace.terminalPaneCount < PaneWorkspaceView.maxTerminals else { return nil }
        let group = SessionOutline.newSessionGroupID()
        let name = SessionOutline.nextSessionName(
            workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) },
            project: project
        )
        addPane(
            RestoredPane(
                sessionID: UUID().uuidString,
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
        workspace.closePane(focused)
    }

    /// The header's ⋯ menu. Nothing new lives here: it is the pane-scoped half
    /// of the main menu, so validation, titles and behaviour stay in one place
    /// and the button is a shortcut rather than a second implementation.
    func paneOptionsMenu() -> NSMenu {
        let menu = NSMenu()
        let engine = workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }?.engine
        // Interrupt / Kill / Reattach / Focus live in the main menu with the
        // keystrokes that are how anyone actually reaches them; repeating them
        // here made a six-item list you had to read to find the two things the
        // ⋯ is for.
        let items: [(String, Selector)] = [
            ("Rename Conversation…", #selector(renameConversation(_:))),
            ("Use Option as Meta", Selector(("toggleOptionAsMeta:"))),
        ]
        for (title, action) in items {
            menu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        // `/color` is Claude's slash command and nobody else's, so the item
        // only exists in front of a Claude terminal rather than being offered
        // and then greyed out. A submenu rather than a colour picker: the
        // command takes nine names and rejects everything else, `#ff00dd`
        // included.
        if engine == .claude {
            let colors = NSMenuItem(title: "Change Claude Color", action: nil, keyEquivalent: "")
            colors.submenu = claudeColorMenu()
            menu.addItem(colors)
        }
        menu.addItem(.separator())
        menu.addItem(
            NSMenuItem(title: "Close Pane", action: Selector(("closePane:")), keyEquivalent: "")
        )
        return menu
    }

    /// The ⋯ menu's "Rename Conversation…" — one name for both halves of a
    /// terminal: the pane the sidebar shows, and the agent's own conversation,
    /// which only hears about it if `/rename` is typed at it.
    @objc func renameConversation(_ sender: Any?) {
        guard let paneID = workspace.focusedPaneID,
              let descriptor = workspace.descriptor(for: paneID),
              descriptor.kind == .terminal
        else { return }
        askForConversationName(current: descriptor.label ?? descriptor.title) { [weak self] name in
            guard let self,
                  let named = name?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !named.isEmpty
            else { return }
            renamePane(paneID, to: named)
            // A plain shell has no `/rename`; typing one at it is just a
            // `command not found` in the user's scrollback.
            guard descriptor.engine != .shell else { return }
            workspace.terminalSurface(for: paneID)?.sendInput("/rename \(named)\r")
        }
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
                title: color.capitalized,
                action: #selector(changeClaudeColor(_:)),
                keyEquivalent: ""
            )
            item.representedObject = color
            item.image = Self.swatch(for: color)
            menu.addItem(item)
        }
        return menu
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
        return NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
    }

    /// One name off that submenu, typed at the terminal.
    @objc func changeClaudeColor(_ sender: Any?) {
        guard let color = (sender as? NSMenuItem)?.representedObject as? String,
              let paneID = workspace.focusedPaneID,
              workspace.descriptor(for: paneID)?.engine == .claude
        else { return }
        workspace.terminalSurface(for: paneID)?.sendInput("/color \(color)\r")
    }

    /// Where the new conversation name comes from. `nil` means "ask with an
    /// `NSAlert`"; a test substitutes an answer, exactly as `directoryChooser`
    /// does, so the rename can run without blocking on a modal.
    var conversationNamePrompt: ((String, @escaping (String?) -> Void) -> Void)?

    private func askForConversationName(current: String, completion: @escaping (String?) -> Void) {
        if let conversationNamePrompt {
            conversationNamePrompt(current, completion)
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
    @objc func showCommandPalette(_ sender: Any?) {
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
        case .showAllChanges:
            openChangesOverview()
        case .newSession:
            newSession(nil)
        // Interrupt and reattach are the focused terminal's own responder
        // actions (`TerminalSurfaceView`), reached here directly rather than
        // re-implemented, so the palette runs the identical code the ⌘. and
        // ⌘R menu items do.
        case .interruptFocusedPane:
            workspace.focusedPaneID.flatMap { workspace.terminalSurface(for: $0) }?.interruptSession(nil)
        case .reattachFocusedPane:
            workspace.focusedPaneID.flatMap { workspace.terminalSurface(for: $0) }?.reattachSession(nil)
        case .toggleSidebar:
            toggleSidebar(nil)
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
                        commands: [PaletteCommand(id: "search-error", title: "Brain search failed.", detail: nil, action: .noop)],
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
                    action: .noop
                ),
            ]
        } else {
            rows = hits.map { hit in
                PaletteCommand(
                    id: "hit:\(hit.id)",
                    title: "\(hit.label) — \(SessionOutline.projectLabel(hit.project, labels: projectLabels))",
                    detail: hit.kind,
                    action: .revealProjectContext(project: hit.project)
                )
            }
        }
        palette.present(commands: rows, over: window)
    }

    @objc func toggleSidebar(_ sender: Any?) {
        (window?.contentViewController as? NSSplitViewController)?
            .splitViewItems.first?
            .animator().isCollapsed.toggle()
    }

    // MARK: - Session outline

    /// Scoped to the open workspace since step 1: Level 2 is *about* one
    /// workspace, so its tree shows that workspace's sessions and no one
    /// else's. With none open (the picker is up) the unfiltered tree is kept
    /// — it is off-screen, and filtering it to nothing would only make the
    /// slide back reveal an empty pane for a frame.
    private func reloadOutline() {
        let all = workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) }
        shellSidebar.reloadSessions(
            panes: all,
            focusedPaneID: workspace.focusedPaneID,
            statuses: lastStatus,
            project: selectedProjectID
        )
        shellSidebar.setWorkspaces(workspaces, sessionCounts: sessionCounts())
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

    // MARK: - Notifications

    /// Brings one pane forward: the window to the front, the app to the
    /// foreground, focus onto that pane. What clicking a notification does,
    /// and what the session outline and the command palette both call.
    @discardableResult
    func revealPane(_ sessionID: String) -> Bool {
        guard workspace.descriptor(for: sessionID) != nil else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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

    /// Turns one status event into the feed's decision. The window is the
    /// only place that knows the two "is the user looking at this" facts, so
    /// it assembles the context and `NotificationFeed` owns the rule.
    func recordNotification(for event: SessionStatusEvent) {
        let previous = lastStatus[event.id]
        lastStatus[event.id] = event.status
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

    /// The launch-time sequence: the auth gate first (if unresolved), then
    /// FirstRun (if no project root has ever been picked) — the same order
    /// `App.tsx`'s boot effect enforces (`needsAuthGate` resolves before
    /// `needsOnboarding` is ever allowed to render anything). Dispatched
    /// once per launch; a reconnect does not re-ask.
    private func presentOnboardingIfNeeded() {
        guard !onboardingDispatched else { return }
        onboardingDispatched = true
        authGateWindow.presentIfNeeded(over: window) { [weak self] in
            self?.presentFirstRunIfNeeded()
        }
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

    /// ⌘, — the Settings screen, hosted fresh every time it opens.
    @objc func showSettings(_ sender: Any?) {
        settingsWindowController.present(over: window, usageRecorder: usageRecorder)
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

    /// Writes the live editor panes back to their own row. Refused until that
    /// row has actually been read — `persistLayout`'s reasoning again. Tab
    /// mutations already flow through `onStateChange` -> `updateDescriptor` ->
    /// `onPanesChanged`, the browser pane's `onURLChange` chain applied to
    /// tabs, so opening or closing a tab persists with no extra plumbing.
    private func persistEditorPanes() {
        guard editorPanesReadCompleted else { return }
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
        } else if let editor = workspace.editorPane(for: sessionID) {
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
            // A pane created after the status landed would otherwise render
            // "not a git repository" inside a repository.
            editor.setGitStatus(latestGitStatus)
            // `workspaceDirectory(for:)` already falls back to the open
            // workspace when the pane carries no project of its own.
            editor.workspaceRoot = workspaceDirectory(for: pane.project)
                .map { URL(fileURLWithPath: $0) }
        }
        return true
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
        if let path = workspaces.first(where: { $0.id == id })?.path, !path.isEmpty {
            return path
        }
        // Nothing recorded — fall back to a live pane in the same project.
        return workspace.allPaneIDs
            .compactMap { workspace.descriptor(for: $0) }
            .first { $0.project == id && !$0.cwd.isEmpty }?
            .cwd
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

    private func refreshTitle() {
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
