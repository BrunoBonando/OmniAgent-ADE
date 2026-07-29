import AppKit
import os.signpost
import SwiftTerm

final class NativeTerminalView: TerminalView {
    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    override func accessibilityValue() -> Any? {
        String(data: terminal.getBufferAsData(), encoding: .utf8) ?? ""
    }
}

final class TerminalSurfaceView: NSView, TerminalViewDelegate {
    let terminalView = NativeTerminalView(
        frame: .zero,
        font: .monospacedSystemFont(ofSize: 13, weight: .regular)
    )
    var onTitleChange: ((String) -> Void)?
    var onDirectoryChange: ((String?) -> Void)?

    private let connection: SessionConnection
    private let sessionID: String
    private var attemptedMetal = false
    private var paintMarkerScheduled = false
    private var pendingPaintSequence: UInt64 = 0

    init(connection: SessionConnection, sessionID: String) {
        self.connection = connection
        self.sessionID = sessionID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(
            srgbRed: 8 / 255,
            green: 10 / 255,
            blue: 14 / 255,
            alpha: 1
        ).cgColor

        let omniBlue = NSColor(
            srgbRed: 65 / 255,
            green: 132 / 255,
            blue: 255 / 255,
            alpha: 1
        )
        terminalView.nativeBackgroundColor = NSColor(
            srgbRed: 8 / 255,
            green: 10 / 255,
            blue: 14 / 255,
            alpha: 1
        )
        terminalView.nativeForegroundColor = NSColor(
            srgbRed: 224 / 255,
            green: 229 / 255,
            blue: 237 / 255,
            alpha: 1
        )
        terminalView.caretColor = omniBlue
        terminalView.selectedTextBackgroundColor = omniBlue.withAlphaComponent(0.72)
        terminalView.optionAsMetaKey = false
        terminalView.setAccessibilityElement(true)
        terminalView.setAccessibilityRole(.textArea)
        terminalView.setAccessibilityLabel("Terminal")
        terminalView.terminalDelegate = self
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(terminalView)
        NSLayoutConstraint.activate([
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !attemptedMetal else { return }
        attemptedMetal = true
        do {
            try terminalView.setUseMetal(true)
            os_signpost(.event, log: Instrumentation.log, name: "Metal Enabled")
        } catch {
            os_log(
                "Metal unavailable; continuing with CoreGraphics: %{public}@",
                log: Instrumentation.log,
                type: .info,
                error.localizedDescription
            )
        }
    }

    func feed(_ bytes: Data, isSnapshot: Bool, sequence: UInt64 = 0) {
        os_signpost(
            .event,
            log: Instrumentation.log,
            name: "Latency.TerminalFeed",
            "%{public}s sequence=%llu bytes=%lu",
            isSnapshot ? "snapshot" : "output",
            sequence,
            bytes.count
        )
        terminalView.feed(byteArray: Array(bytes)[...])
        // This is the end of the application-side AppKit display pass. Metal command
        // submission is included; WindowServer presentation and physical scanout are not.
        pendingPaintSequence = sequence
        guard !paintMarkerScheduled else { return }
        paintMarkerScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            terminalView.displayIfNeeded()
            os_signpost(
                .event,
                log: Instrumentation.log,
                name: "Latency.AppKitDisplayPassComplete",
                "sequence=%llu",
                pendingPaintSequence
            )
            paintMarkerScheduled = false
        }
    }

    func focus() {
        window?.makeFirstResponder(terminalView)
    }

    func syncSize() {
        sizeChanged(
            source: terminalView,
            newCols: terminalView.terminal.cols,
            newRows: terminalView.terminal.rows
        )
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        os_signpost(.event, log: Instrumentation.log, name: "Terminal Input")
        connection.write(sessionID: sessionID, bytes: Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        let backing = source.convertToBacking(source.bounds)
        connection.resize(
            sessionID: sessionID,
            cols: clampedUInt16(newCols),
            rows: clampedUInt16(newRows),
            pixelWidth: clampedUInt16(Int(backing.width.rounded())),
            pixelHeight: clampedUInt16(Int(backing.height.rounded()))
        )
        os_signpost(
            .event,
            log: Instrumentation.log,
            name: "Terminal Resize",
            "%d x %d",
            newCols,
            newRows
        )
    }

    func setTerminalTitle(source: TerminalView, title: String) {
        onTitleChange?(title)
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        onDirectoryChange?(directory)
    }

    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    @objc func interruptSession(_ sender: Any?) {
        connection.interrupt(sessionID: sessionID)
    }

    @objc func killSession(_ sender: Any?) {
        connection.kill(sessionID: sessionID)
    }

    @objc func reattachSession(_ sender: Any?) {
        connection.reattach(sessionID: sessionID)
    }

    @objc func focusTerminal(_ sender: Any?) {
        focus()
    }
}

private func clampedUInt16(_ value: Int) -> UInt16 {
    UInt16(max(1, min(value, Int(UInt16.max))))
}
