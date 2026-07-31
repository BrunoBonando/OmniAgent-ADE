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
    private let connection: SessionConnection
    private let workspace: PaneWorkspaceView
    /// Every pane this window opens belongs to one session group, exactly as
    /// `TabInfo.group` carries it in the web build. The sidebar/session outline
    /// that lets a person create a second group is Task 6.
    private let sessionGroup = "sess-grp-1"
    private var readySessions: Set<String> = []
    private var observedFirstOutput = false
    /// Status text per session — an exited, erroring or thinking pane keeps its
    /// own line instead of one window-wide string every pane overwrites. The
    /// title shows the *focused* pane's entry, so switching panes tells the
    /// truth about the pane you are looking at.
    private var sessionStatus: [String: String] = [:]
    /// Status that belongs to the connection rather than to any one session
    /// (connecting, reconnecting, transport errors). Outranks session status.
    private var connectionStatus: String?

    init(connection: SessionConnection, sessionID: String) {
        self.connection = connection
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
        addPane(sessionID: sessionID, createSession: false)
        window.initialFirstResponder = workspace.surface(for: sessionID)?.terminalView
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
                for id in workspace.paneIDs { ensureSession(id) }
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
        }
        connection.onAttention = { [weak self] id in
            guard self?.workspace.container(for: id) != nil else { return }
            NSApp.requestUserAttention(.informationalRequest)
        }
        connection.onExit = { [weak self] event in
            guard let self, workspace.container(for: event.id) != nil else { return }
            readySessions.remove(event.id)
            applySessionStatus("Session ended", for: event.id)
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

    /// ⌘T — a brand-new pane on a brand-new session, using the same shell,
    /// environment and starting geometry the first pane was created with.
    @objc func newTerminalPane(_ sender: Any?) {
        guard workspace.paneIDs.count < PaneGrid.maxPanes else { return }
        addPane(sessionID: UUID().uuidString, createSession: true)
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

    // MARK: - Panes and sessions

    private func addPane(sessionID: String, createSession: Bool) {
        let descriptor = PaneDescriptor(
            sessionID: sessionID,
            group: sessionGroup,
            groupLabel: "Session 1",
            title: ""
        )
        guard workspace.addPane(descriptor) else { return }
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
        if createSession { ensureSession(sessionID) }
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

    private func createSession(_ sessionID: String) {
        let signpost = OSSignpostID(log: Instrumentation.log)
        os_signpost(
            .begin,
            log: Instrumentation.log,
            name: "Create Session",
            signpostID: signpost
        )
        connection.createSession(
            CreateSessionRequest(
                id: sessionID,
                command: ["/bin/zsh", "-l"],
                cwd: FileManager.default.homeDirectoryForCurrentUser.path,
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
