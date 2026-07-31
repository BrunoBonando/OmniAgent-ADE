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
    private let paneWorkspace: PaneWorkspaceView
    private var readySessions: Set<String> = []
    private var observedOutput: Set<String> = []
    private var nextPaneNumber = 2
    private var creatingPane = false

    init(connection: SessionConnection, sessionID: String) {
        self.connection = connection
        self.sessionID = sessionID
        paneWorkspace = try! PaneWorkspaceView(
            connection: connection,
            panes: [PaneDescriptor(id: sessionID, sessionID: sessionID)]
        )

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
        paneWorkspace.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(paneWorkspace)
        NSLayoutConstraint.activate([
            paneWorkspace.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            paneWorkspace.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            paneWorkspace.topAnchor.constraint(equalTo: content.topAnchor),
            paneWorkspace.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.initialFirstResponder = paneWorkspace.surface(forPaneID: sessionID)?.terminalView

        super.init(window: window)
        window.delegate = self
        configureSurface(forPaneID: sessionID)
        paneWorkspace.onAddPane = { [weak self] in self?.requestNewPane() }
        paneWorkspace.onClosePane = { [weak self] pane in self?.closePane(pane) }
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
                if !readySessions.isEmpty {
                    window?.title = "OmniAgent"
                    for id in readySessions {
                        paneWorkspace.surface(forSessionID: id)?.syncSize()
                    }
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
            guard let self, let surface = paneWorkspace.surface(forSessionID: id) else { return }
            if observedOutput.insert(id).inserted {
                os_signpost(.event, log: Instrumentation.log, name: "First Terminal Output")
            }
            surface.feed(bytes, isSnapshot: isSnapshot, sequence: sequence)
        }
        connection.onStatus = { [weak self] event in
            guard
                let self,
                paneWorkspace.paneLayout.panes[paneWorkspace.paneLayout.focusedPaneID ?? ""]?
                    .sessionID == event.id
            else { return }
            window?.title = "OmniAgent — \(event.status.title)"
        }
        connection.onAttention = { [weak self] id in
            guard self?.paneWorkspace.surface(forSessionID: id) != nil else { return }
            NSApp.requestUserAttention(.informationalRequest)
        }
        connection.onExit = { [weak self] event in
            guard let self, paneWorkspace.surface(forSessionID: event.id) != nil else { return }
            readySessions.remove(event.id)
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
        paneWorkspace.focusCurrentPane()
    }

    func windowWillClose(_ notification: Notification) {
        stop()
    }

    private func ensureSession() {
        connection.listSessions { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(sessions) where sessions.contains(sessionID):
                attach(sessionID)
            case .success:
                createSession(sessionID) { [weak self] created in
                    guard let self, created else { return }
                    attach(sessionID)
                }
            case let .failure(error):
                window?.title = "OmniAgent — \(error.localizedDescription)"
            }
        }
    }

    private func createSession(_ id: String, completion: @escaping (Bool) -> Void) {
        let signpost = OSSignpostID(log: Instrumentation.log)
        os_signpost(
            .begin,
            log: Instrumentation.log,
            name: "Create Session",
            signpostID: signpost
        )
        connection.createSession(
            CreateSessionRequest(
                id: id,
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
                completion(true)
            case let .failure(error):
                window?.title = "OmniAgent — \(error.localizedDescription)"
                completion(false)
            }
        }
    }

    private func attach(_ id: String) {
        readySessions.insert(id)
        connection.attach(sessionID: id, afterSequence: nil)
        paneWorkspace.surface(forSessionID: id)?.syncSize()
        window?.title = "OmniAgent"
        os_signpost(.event, log: Instrumentation.log, name: "Attach Session")
    }

    private func requestNewPane() {
        guard
            !creatingPane,
            paneWorkspace.paneLayout.panes.count < PaneLayout.maximumPanes
        else { return }
        creatingPane = true
        var id: String
        repeat {
            id = "\(sessionID)-\(nextPaneNumber)"
            nextPaneNumber += 1
        } while paneWorkspace.paneLayout.panes[id] != nil
        createSession(id) { [weak self] created in
            guard let self else { return }
            creatingPane = false
            guard created else { return }
            do {
                try paneWorkspace.addPane(PaneDescriptor(id: id, sessionID: id))
                configureSurface(forPaneID: id)
                attach(id)
            } catch {
                window?.title = "OmniAgent — \(error.localizedDescription)"
            }
        }
    }

    private func closePane(_ pane: PaneDescriptor) {
        connection.kill(sessionID: pane.sessionID) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                readySessions.remove(pane.sessionID)
                _ = paneWorkspace.removePane(pane.id)
            case let .failure(error):
                window?.title = "OmniAgent — \(error.localizedDescription)"
            }
        }
    }

    private func configureSurface(forPaneID id: String) {
        guard let surface = paneWorkspace.surface(forPaneID: id) else { return }
        surface.onTitleChange = { [weak self] title in
            guard self?.paneWorkspace.paneLayout.focusedPaneID == id else { return }
            self?.window?.title = title.isEmpty ? "OmniAgent" : title
        }
        surface.onDirectoryChange = { [weak self] directory in
            guard self?.paneWorkspace.paneLayout.focusedPaneID == id else { return }
            self?.window?.representedURL = directory.map(URL.init(fileURLWithPath:))
        }
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
