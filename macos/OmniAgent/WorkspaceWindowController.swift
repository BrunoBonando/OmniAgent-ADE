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
    /// The design's two-level sidebar. It draws the sessions tree itself now
    /// rather than hosting `SessionOutlineView` — the design's rows carry
    /// engine logos, per-pane status dots and a grid badge, none of which an
    /// `NSOutlineView` cell can lay out the way the drawing does.
    ///
    /// `SessionOutlineView` is consequently no longer part of the shell. It is
    /// left in the tree with its own tests until a follow-up removes it, so
    /// this change stays a UI change.
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
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
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
            let panes = self.workspace.paneIDs.compactMap { self.workspace.descriptor(for: $0) }
            let current = SessionOutline.group(panes, focusedPaneID: self.workspace.focusedPaneID)
                .flatMap(\.sessions)
                .first(where: \.isCurrent)
            guard let current else { return }
            self.newPane(in: current)
        }
        shellSidebar.onOpenSettings = { [weak self] in self?.showSettings(nil) }
        for pane in panes { addPane(pane, startSession: false) }
        selectInitialWorkspaceIfNeeded(animated: false)
        reloadOutline()
        window.initialFirstResponder = workspace.focusedPaneID
            .flatMap { workspace.surface(for: $0)?.terminalView }
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
        // The design's "New workspace" opens a folder picker and starts there.
        // `newSession` is exactly that flow natively (choose a directory, open
        // a session in it); a separate new-workspace dialog is not part of the
        // foundation step.
        shellSidebar.onNewWorkspace = { [weak self] in self?.newSession(nil) }
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
        let paneCwd = workspace.paneIDs
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
        let anyPane = workspace.paneIDs.compactMap { workspace.descriptor(for: $0)?.project }.first
        guard let project = focused ?? anyPane, !project.isEmpty else { return }
        selectWorkspace(id: project, animated: animated)
    }

    /// Sessions per project id — the picker's card meta line, and the count
    /// badge on the Terminals row.
    private func sessionCounts() -> [String: Int] {
        let panes = workspace.paneIDs.compactMap { workspace.descriptor(for: $0) }
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
        guard workspace.paneIDs.count < PaneGrid.maxPanes else { return false }
        let sibling = session.map { seed in
            seed.paneIDs.first.flatMap { workspace.descriptor(for: $0) }
        } ?? workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        let template = WorkspaceRestoration.bootstrapPane()
        addPane(
            RestoredPane(
                sessionID: template.sessionID,
                reattaches: false,
                project: sibling?.project ?? session?.project ?? template.project,
                engine: .shell,
                cwd: sibling?.cwd.isEmpty == false ? sibling!.cwd : (session?.cwd ?? template.cwd),
                label: nil,
                themeId: sibling?.themeId,
                group: session?.id ?? sibling?.group ?? template.group,
                groupLabel: sibling?.groupLabel ?? session?.name
            ),
            startSession: true
        )
        return true
    }

    /// ⌘N — a **second, independent session**: a new pane in a brand-new
    /// session group, named by the same lowest-free-number rule the web build
    /// uses (`SessionOutline.nextSessionName`).
    ///
    /// The web's `NewSessionModal` asks for the session's own directory,
    /// validated as the project folder or a subfolder of it. The native
    /// equivalent of that one real decision is a directory chooser seeded
    /// with the current session's own root; everything else about the session
    /// (its project, a shell pane to start it) follows from where it lands,
    /// because this build has no project picker or engine launcher yet.
    @objc func newSession(_ sender: Any?) {
        guard workspace.paneIDs.count < PaneGrid.maxPanes else { return }
        let current = workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        let seedDirectory = current?.cwd.isEmpty == false
            ? current!.cwd
            : FileManager.default.homeDirectoryForCurrentUser.path
        chooseSessionDirectory(startingAt: seedDirectory) { [weak self] chosen in
            guard let self, let chosen else { return }
            startSession(inDirectory: chosen, project: current?.project ?? "")
        }
    }

    /// The session-creation half of `newSession(_:)`, without the chooser —
    /// so the naming and grouping rules are testable without a panel.
    @discardableResult
    func startSession(inDirectory cwd: String, project: String) -> String? {
        guard workspace.paneIDs.count < PaneGrid.maxPanes else { return nil }
        let group = SessionOutline.newSessionGroupID()
        let name = SessionOutline.nextSessionName(
            workspace.paneIDs.compactMap { workspace.descriptor(for: $0) },
            project: project
        )
        addPane(
            RestoredPane(
                sessionID: UUID().uuidString,
                reattaches: false,
                project: project,
                engine: .shell,
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
            return workspace.paneIDs.count < PaneGrid.maxPanes
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
            for id in workspace.paneIDs { ensureSession(id) }
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
        let plan = panes.isEmpty && workspace.paneIDs.isEmpty
            ? [WorkspaceRestoration.bootstrapPane()]
            : panes
        for pane in plan where workspace.descriptor(for: pane.sessionID) == nil {
            addPane(pane, startSession: false)
        }
        for id in workspace.paneIDs { ensureSession(id) }
        workspace.restoreFocus()
        // The plan came *from* the row, so re-writing it is normally a no-op;
        // it matters when restoration repaired something (a capped ninth
        // pane, a minted id) — the repair is what the next launch should see,
        // and when a pane was opened while the read was still in flight.
        persistLayout()
    }

    // MARK: - Command palette

    /// ⌘K. The list is rebuilt from the live workspace on every open, so it
    /// can never offer a pane that closed while the palette was shut.
    @objc func showCommandPalette(_ sender: Any?) {
        palette.onRun = { [weak self] action in self?.run(action) }
        palette.present(
            commands: CommandPaletteModel.build(
                panes: workspace.paneIDs.compactMap { workspace.descriptor(for: $0) },
                paneOrder: workspace.paneIDs,
                focusedPaneID: workspace.focusedPaneID,
                unreadNotifications: notifier.unreadCount,
                nextSessionName: SessionOutline.nextSessionName(
                    workspace.paneIDs.compactMap { workspace.descriptor(for: $0) },
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
        let all = workspace.paneIDs.compactMap { workspace.descriptor(for: $0) }
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
        let descriptors = workspace.paneIDs.compactMap { workspace.descriptor(for: $0) }
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
        guard workspace.addPane(PaneDescriptor(pane)) else { return }
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
            case let .success(sessions) where sessions.contains(sessionID):
                attach(sessionID)
            case .success:
                createSession(sessionID)
            case let .failure(error):
                applySessionStatus(error.localizedDescription, for: sessionID)
            }
        }
    }

    /// Starts the PTY behind one pane.
    ///
    /// **Only a `shell` pane can be started here.** Everything a non-shell
    /// engine needs to launch — `PATH` resolution, MCP wiring, pre-briefing —
    /// lives in `src-tauri/src/sessions.rs`'s `build_command`, which no
    /// protocol message exposes; the daemon takes an already-built argv. A
    /// restored `claude`/`codex` pane whose daemon session is still alive
    /// therefore reattaches normally (the common case — the daemon outlives
    /// the app, which is the whole point of the persistent protocol), and one
    /// whose session is gone says so instead of quietly starting a login
    /// shell under the other engine's name.
    private func createSession(_ sessionID: String) {
        let descriptor = workspace.descriptor(for: sessionID)
        let engine = descriptor?.engine ?? .shell
        guard engine == .shell else {
            applySessionStatus(
                "\(engine.rawValue) session ended — start it from the web app",
                for: sessionID
            )
            return
        }
        let signpost = OSSignpostID(log: Instrumentation.log)
        os_signpost(
            .begin,
            log: Instrumentation.log,
            name: "Create Session",
            signpostID: signpost
        )
        let cwd = descriptor?.cwd.isEmpty == false
            ? descriptor!.cwd
            : FileManager.default.homeDirectoryForCurrentUser.path
        connection.createSession(
            CreateSessionRequest(
                id: sessionID,
                command: ["/bin/zsh", "-l"],
                cwd: cwd,
                environment: [
                    "TERM": "xterm-256color",
                    "COLORTERM": "truecolor",
                ],
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
            }
        }
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
