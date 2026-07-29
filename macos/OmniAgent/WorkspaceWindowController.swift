import AppKit
import os.signpost
import SwiftTerm

final class WorkspaceWindow: NSWindow {
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
}

final class WorkspaceWindowController: NSWindowController, NSWindowDelegate {
    private let connection: SessionConnection
    private let sessionID: String
    private let terminalSurface: TerminalSurfaceView
    private var sessionReady = false
    private var observedFirstOutput = false

    init(connection: SessionConnection, sessionID: String) {
        self.connection = connection
        self.sessionID = sessionID
        terminalSurface = TerminalSurfaceView(connection: connection, sessionID: sessionID)

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

        let content = NSView(frame: window.contentLayoutRect)
        terminalSurface.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(terminalSurface)
        NSLayoutConstraint.activate([
            terminalSurface.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            terminalSurface.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            terminalSurface.topAnchor.constraint(equalTo: content.topAnchor),
            terminalSurface.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.initialFirstResponder = terminalSurface.terminalView

        super.init(window: window)
        window.delegate = self
        terminalSurface.onTitleChange = { [weak window] title in
            window?.title = title.isEmpty ? "OmniAgent" : title
        }
        terminalSurface.onDirectoryChange = { [weak window] directory in
            window?.representedURL = directory.map(URL.init(fileURLWithPath:))
        }
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
                if sessionReady {
                    window?.title = "OmniAgent"
                    terminalSurface.syncSize()
                } else {
                    ensureSession()
                }
            case .connecting:
                window?.title = "OmniAgent — Connecting"
            case .disconnected:
                window?.title = "OmniAgent — Reconnecting"
            }
        }
        connection.onTerminalData = { [weak self] id, bytes, sequence, isSnapshot in
            guard let self, id == sessionID else { return }
            if !observedFirstOutput {
                observedFirstOutput = true
                os_signpost(.event, log: Instrumentation.log, name: "First Terminal Output")
            }
            terminalSurface.feed(bytes, isSnapshot: isSnapshot, sequence: sequence)
        }
        connection.onStatus = { [weak self] event in
            guard let self, event.id == sessionID else { return }
            window?.title = "OmniAgent — \(event.status.title)"
        }
        connection.onAttention = { [weak self] id in
            guard id == self?.sessionID else { return }
            NSApp.requestUserAttention(.informationalRequest)
        }
        connection.onExit = { [weak self] event in
            guard let self, event.id == sessionID else { return }
            sessionReady = false
            window?.title = "OmniAgent — Session ended"
        }
        connection.onError = { [weak self] error in
            self?.window?.title = "OmniAgent — \(error.localizedDescription)"
        }
        connection.connect()
    }

    func stop() {
        connection.disconnect()
    }

    @objc func focusTerminal(_ sender: Any?) {
        terminalSurface.focus()
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }

    private func ensureSession() {
        connection.listSessions { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(sessions) where sessions.contains(sessionID):
                attach()
            case .success:
                createSession()
            case let .failure(error):
                window?.title = "OmniAgent — \(error.localizedDescription)"
            }
        }
    }

    private func createSession() {
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
                attach()
            case let .failure(error):
                window?.title = "OmniAgent — \(error.localizedDescription)"
            }
        }
    }

    private func attach() {
        sessionReady = true
        connection.attach(sessionID: sessionID, afterSequence: nil)
        terminalSurface.syncSize()
        window?.title = "OmniAgent"
        os_signpost(.event, log: Instrumentation.log, name: "Attach Session")
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
