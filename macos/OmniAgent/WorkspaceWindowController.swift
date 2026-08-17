import AppKit
import os.signpost
import SwiftTerm

final class WorkspaceWindow: NSWindow {
    /// Click-to-focus: whichever pane ends up holding the first responder
    /// becomes the focused pane, without the panes having to fight SwiftTerm
    /// for the mouse event.
    var onFirstResponderChange: ((NSResponder?) -> Void)?

    override func sendEvent(_ event: NSEvent) {
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
    /// The last value written to each settings row — see `write(_:to:)`.
    private var lastPersisted: [String: String] = [:]
    /// Where settings writes go. `nil` means the daemon; a test substitutes a
    /// recorder so the write-suppression rule can be asserted without a
    /// socket, and without touching the developer's real `brain.db`.
    var settingsWriter: ((String, String) -> Void)?

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
        workspace = PaneWorkspaceView { id in
            TerminalSurfaceView(connection: connection, sessionID: id)
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
        workspace.onFocusedPaneChanged = { [weak self] paneID in
            self?.refreshTitle()
            self?.reloadOutline()
            self?.refreshInspectorIfVisible(for: paneID)
        }
        workspace.onRequestNewPane = { [weak self] in self?.newTerminalPane(nil) }
        workspace.onRequestClosePane = { [weak self] paneID in
            guard let self else { return }
            // Route through focus so the header's close button ends *that*
            // pane, not whichever one happened to be focused.
            workspace.focusPane(paneID)
            closePane(nil)
        }
        workspace.onPanesChanged = { [weak self] in
            self?.persistLayout()
            self?.reloadOutline()
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
        shellSidebar.onOpenSettings = { [weak self] in self?.showSettings(nil) }
        // Asking the login shell for its PATH spawns a shell; do it now, off
        // the main thread, so the first terminal does not wait for it.
        EngineLauncher.prewarm()
        for pane in panes { addPane(pane, startSession: false) }
        selectInitialWorkspaceIfNeeded(animated: false)
        reloadOutline()
        window.initialFirstResponder = workspace.focusedPaneID
            .flatMap { workspace.surface(for: $0)?.terminalView }
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
        // The design fixes the sidebar at 238pt (`flex:none;width:238px`), and
        // every inset inside it is measured against that. Pinning both bounds
        // is what makes the drawing and the app agree; the pane grid takes all
        // the resizing.
        sidebarItem.minimumThickness = ShellMetrics.sidebarWidth
        sidebarItem.maximumThickness = ShellMetrics.sidebarWidth
        sidebarItem.canCollapse = true
        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(NSSplitViewItem(viewController: content))
        window.contentViewController = split
    }

    /// Swaps the destination. `isHidden`, never add/remove: see
    /// `contentContainer`'s own doc for why the pane workspace must stay
    /// mounted.
    func applyDestination(_ destination: WorkspaceDestination) {
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
            }
        }
        connection.onTerminalData = { [weak self] id, bytes, sequence, isSnapshot in
            guard let self, let surface = workspace.surface(for: id) else { return }
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
            guard let self else { return }
            readySessions.remove(sessionID)
            applySessionStatus("Session lost — daemon restarted", for: sessionID)
            daemonPersistence.recordReattachFailure(sessionID: sessionID)
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
        guard workspace.allPaneIDs.count < PaneGrid.maxPanes else { return false }
        let sibling = session.map { seed in
            seed.paneIDs.first.flatMap { workspace.descriptor(for: $0) }
        } ?? workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        let template = WorkspaceRestoration.bootstrapPane()
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
        addPane(
            RestoredPane(
                sessionID: template.sessionID,
                reattaches: false,
                project: project,
                engine: EngineLauncher.defaultEngine(),
                cwd: cwd,
                label: nil,
                themeId: sibling?.themeId,
                group: session?.id ?? sibling?.group ?? template.group,
                groupLabel: sibling?.groupLabel ?? session?.name
            ),
            startSession: true
        )
        return true
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
        guard workspace.allPaneIDs.count < PaneGrid.maxPanes else { return }
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
        guard workspace.allPaneIDs.count < PaneGrid.maxPanes else { return }
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
        guard workspace.allPaneIDs.count < PaneGrid.maxPanes else { return nil }
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
        connection.kill(sessionID: focused)
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

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newTerminalPane(_:)), #selector(newSession(_:)):
            return workspace.allPaneIDs.count < PaneGrid.maxPanes
        case #selector(closePane(_:)):
            return workspace.focusedPaneID != nil
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
            for id in workspace.allPaneIDs { ensureSession(id) }
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
        for id in workspace.allPaneIDs { ensureSession(id) }
        workspace.restoreFocus()
        // The plan came *from* the row, so re-writing it is normally a no-op;
        // it matters when restoration repaired something (a capped ninth
        // pane, a minted id) — the repair is what the next launch should see,
        // and when a pane was opened while the read was still in flight.
        persistLayout()
    }

    /// Kills daemon sessions this window no longer references.
    ///
    /// The daemon outliving the app is the feature that keeps terminals
    /// running across a restart — but nothing ever cleaned up the sessions a
    /// restart left *behind*, and the daemon caps at `MAX_SESSIONS` (8, in
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
            connection.kill(sessionID: id)
            readySessions.remove(id)
            lastStatus.removeValue(forKey: id)
        }
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
                projectLabels: projectLabels
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
        case .newSession:
            newSession(nil)
        // Interrupt and reattach are the focused terminal's own responder
        // actions (`TerminalSurfaceView`), reached here directly rather than
        // re-implemented, so the palette runs the identical code the ⌘. and
        // ⌘R menu items do.
        case .interruptFocusedPane:
            workspace.focusedPaneID.flatMap { workspace.surface(for: $0) }?.interruptSession(nil)
        case .reattachFocusedPane:
            workspace.focusedPaneID.flatMap { workspace.surface(for: $0) }?.reattachSession(nil)
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

    private func addPane(_ pane: RestoredPane, startSession: Bool) {
        let sessionID = pane.sessionID
        var descriptor = PaneDescriptor(pane)
        // The one place a terminal gets its name, so a restored pane and a
        // brand-new one are named by the same rule. Restored panes from before
        // panes were named have no stored label and would otherwise keep
        // rendering the engine's raw name — every Claude terminal reading
        // `claude` is exactly the collision this fixes. Restoration adds panes
        // one at a time, so each sees the ones already placed and takes the
        // next free number in its own session.
        if (descriptor.label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty {
            descriptor.label = SessionOutline.nextPaneName(
                workspace.allPaneIDs.compactMap { workspace.descriptor(for: $0) },
                group: descriptor.group,
                engine: descriptor.engine
            )
        }
        guard workspace.addPane(descriptor) else { return }
        usageRecorder.recordPaneOpened(
            paneID: sessionID,
            sessionKey: pane.group,
            project: pane.project,
            at: Date().timeIntervalSince1970 * 1000
        )
        let surface = workspace.surface(for: sessionID)
        surface?.onTitleChange = { [weak self] title in
            guard let self else { return }
            workspace.updateDescriptor(for: sessionID) { $0.title = title }
            if workspace.focusedPaneID == sessionID { refreshTitle() }
        }
        surface?.onDirectoryChange = { [weak self] directory in
            guard let self, workspace.focusedPaneID == sessionID else { return }
            window?.representedURL = directory.map(URL.init(fileURLWithPath:))
        }
        if startSession { ensureSession(sessionID) }
    }

    private func ensureSession(_ sessionID: String) {
        guard !readySessions.contains(sessionID) else {
            attach(sessionID)
            return
        }
        connection.listSessions { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(sessions):
                // Free the daemon's abandoned slots *before* asking it for a
                // new one. This is why the reap lives here rather than after
                // the restore loop: the daemon caps at 8, so an orphan holding
                // the last slot makes the very session being started here fail.
                // Frames are written FIFO on one connection, so the kills below
                // reach the daemon ahead of this pane's `createSession`.
                reapOrphanedSessions(daemonSessions: sessions)
                if sessions.contains(sessionID) {
                    attach(sessionID)
                } else {
                    createSession(sessionID)
                }
            case let .failure(error):
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
    private func createSession(_ sessionID: String) {
        let descriptor = workspace.descriptor(for: sessionID)
        let engine = descriptor?.engine ?? .shell
        guard let command = EngineLauncher.command(for: engine) else {
            let message = "\(engine.rawValue) is not installed — \(EngineLauncher.binaryName(for: engine)) is not on your PATH"
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
        guard let surface = workspace.surface(for: sessionID) else { return }
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
        guard let surface = workspace.surface(for: sessionID) else { return }
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
