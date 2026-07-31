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
    private var readySessions: Set<String> = []
    /// Restoration runs exactly once, on the first `.connected` — a later
    /// reconnect must re-attach the panes that already exist, never read the
    /// `layout` row again and rebuild them on top.
    private var hasRestored = false
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
    /// apart from an unrelated status change.
    private var lastStatus: [String: RemoteSessionStatus] = [:]
    let notifier: SessionNotifier
    /// The notification feed is written back exactly like the layout row is,
    /// and refused for the same reason until it has been read.
    private var hasRestoredNotifications = false

    /// `panes` may be empty: the app delegate opens the window before the
    /// socket is up, and `start()` fills it from the `layout` row once the
    /// connection lands. A non-empty seed is for callers that already know
    /// their panes (tests, and the single-pane convenience below).
    init(
        connection: SessionConnection,
        panes: [RestoredPane],
        notifier: SessionNotifier = SessionNotifier(delivery: UserNotificationDelivery())
    ) {
        self.connection = connection
        self.notifier = notifier
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
        workspace.frame = window.contentLayoutRect
        window.contentView = workspace

        super.init(window: window)
        window.delegate = self
        window.onFirstResponderChange = { [weak self] responder in
            self?.workspace.adoptFocus(from: responder)
        }
        workspace.onFocusedPaneChanged = { [weak self] _ in self?.refreshTitle() }
        workspace.onRequestNewPane = { [weak self] in self?.newTerminalPane(nil) }
        workspace.onPanesChanged = { [weak self] in self?.persistLayout() }
        notifier.onEntriesChanged = { [weak self] entries in self?.persistNotifications(entries) }
        for pane in panes { addPane(pane, startSession: false) }
        window.initialFirstResponder = workspace.focusedPaneID
            .flatMap { workspace.surface(for: $0)?.terminalView }
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
        }
        connection.onError = { [weak self] error in
            self?.applyConnectionStatus(error.localizedDescription)
        }
        connection.connect()
    }

    func stop() {
        connection.disconnect()
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

    /// ⌘T — a brand-new pane on a brand-new session, joining the focused
    /// pane's session group and inheriting its project and working directory
    /// (the web build's "a new pane joins the session on screen"). With no
    /// focused pane it starts an ungrouped shell in the home directory.
    @objc func newTerminalPane(_ sender: Any?) {
        guard workspace.paneIDs.count < PaneGrid.maxPanes else { return }
        let sibling = workspace.focusedPaneID.flatMap { workspace.descriptor(for: $0) }
        let template = WorkspaceRestoration.bootstrapPane()
        addPane(
            RestoredPane(
                sessionID: template.sessionID,
                reattaches: false,
                project: sibling?.project ?? template.project,
                engine: .shell,
                cwd: sibling?.cwd.isEmpty == false ? sibling!.cwd : template.cwd,
                label: nil,
                themeId: sibling?.themeId,
                group: sibling?.group ?? template.group,
                groupLabel: sibling?.groupLabel
            ),
            startSession: true
        )
    }

    /// ⌘W — closes the focused pane and the session behind it. The window's own
    /// close is ⇧⌘W.
    @objc func closePane(_ sender: Any?) {
        guard let focused = workspace.focusedPaneID else { return }
        connection.kill(sessionID: focused)
        readySessions.remove(focused)
        sessionStatus.removeValue(forKey: focused)
        workspace.closePane(focused)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newTerminalPane(_:)):
            return workspace.paneIDs.count < PaneGrid.maxPanes
        case #selector(closePane(_:)):
            return workspace.focusedPaneID != nil
        default:
            return true
        }
    }

    // MARK: - Restoration

    /// Rebuilds the panes the `layout` row describes, once, on the first
    /// connection. A missing, empty or unreadable row falls back to the one
    /// bootstrap pane — never to a window with nothing in it.
    private func restoreWorkspaceIfNeeded() {
        restoreNotificationsIfNeeded()
        guard !hasRestored else {
            for id in workspace.paneIDs { ensureSession(id) }
            return
        }
        hasRestored = true
        connection.getSetting(key: SettingsKey.layout) { [weak self] result in
            let raw = (try? result.get()) ?? nil
            self?.applyRestoredPanes(WorkspaceRestoration.plan(fromLayout: raw))
        }
    }

    /// Adds every planned pane the window does not already have, then brings
    /// each pane's session up. Split out from `restoreWorkspaceIfNeeded` so a
    /// plan can be applied in a test without a socket.
    func applyRestoredPanes(_ panes: [RestoredPane]) {
        hasRestored = true
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
        // pane, a minted id) — the repair is what the next launch should see.
        persistLayout()
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

    /// Reads the persisted feed once, alongside the layout.
    private func restoreNotificationsIfNeeded() {
        guard !hasRestoredNotifications else { return }
        hasRestoredNotifications = true
        connection.getSetting(key: SettingsKey.notifications) { [weak self] result in
            let raw = (try? result.get()) ?? nil
            self?.notifier.restore(NotificationFeedCodec.deserialize(raw))
        }
    }

    private func persistNotifications(_ entries: [NotificationEntry]) {
        guard hasRestoredNotifications else { return }
        connection.setSetting(
            key: SettingsKey.notifications,
            value: NotificationFeedCodec.serialize(entries)
        )
    }

    /// Writes the live panes back to the shared `layout` row. Refused before
    /// restoration has run: a write from a window that has not yet read the
    /// row would overwrite the very panes it is about to restore.
    private func persistLayout() {
        guard hasRestored else { return }
        let descriptors = workspace.paneIDs.compactMap { workspace.descriptor(for: $0) }
        connection.setSetting(
            key: SettingsKey.layout,
            value: PersistedLayoutCodec.serialize(
                WorkspaceRestoration.persistedTabs(from: descriptors)
            )
        )
    }

    // MARK: - Panes and sessions

    private func addPane(_ pane: RestoredPane, startSession: Bool) {
        let sessionID = pane.sessionID
        guard workspace.addPane(PaneDescriptor(pane)) else { return }
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
