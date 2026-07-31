import AppKit
import MetalKit
import os.signpost
import SwiftTerm

final class NativeTerminalView: TerminalView, NSMenuItemValidation {
    var onCommandDrag: ((NSEvent) -> Void)?
    var onFocus: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        paneWasFocused()
        super.mouseDown(with: event)
    }

    func paneWasFocused() {
        onFocus?()
    }

    override func mouseDragged(with event: NSEvent) {
        if event.modifierFlags.contains(.command), let onCommandDrag {
            onCommandDrag(event)
        } else {
            super.mouseDragged(with: event)
        }
    }

    override func accessibilityPerformPress() -> Bool {
        paneWasFocused()
        window?.makeFirstResponder(self)
        return true
    }

    override func accessibilityValue() -> Any? {
        String(data: terminal.getBufferAsData(), encoding: .utf8) ?? ""
    }

    @objc func toggleOptionAsMeta(_ sender: Any?) {
        optionAsMetaKey.toggle()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(toggleOptionAsMeta(_:)) else { return true }
        menuItem.state = optionAsMetaKey ? .on : .off
        return true
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
    private var drawMarkerScheduled = false
    private var pendingDrawSequence: UInt64 = 0
    private var coalescesResize = false
    private lazy var resizeCoalescer = TerminalResizeCoalescer { [weak self] size in
        guard let self else { return }
        connection.resize(
            sessionID: sessionID,
            cols: size.cols,
            rows: size.rows,
            pixelWidth: size.pixelWidth,
            pixelHeight: size.pixelHeight
        )
    }

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
        guard !terminalView.isHidden else { return }
        pendingDrawSequence = sequence
        guard !drawMarkerScheduled else { return }
        drawMarkerScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let attemptedMetal = requestRendererDraw()
            os_signpost(
                .event,
                log: Instrumentation.log,
                name: "Latency.RendererDrawAttempted",
                "sequence=%llu renderer=%{public}s",
                pendingDrawSequence,
                attemptedMetal ? "metal" : "core-graphics"
            )
            drawMarkerScheduled = false
        }
    }

    @discardableResult
    func requestRendererDraw() -> Bool {
        if let metalView = terminalView.firstDescendant(of: MTKView.self) {
            // draw() may return without a drawable or while a frame is in flight.
            // SwiftTerm's optional Metal.Commit signpost is the submit boundary.
            metalView.draw()
            return true
        }
        terminalView.displayIfNeeded()
        return false
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
        resizeCoalescer.submit(
            TerminalSize(
                cols: clampedUInt16(newCols),
                rows: clampedUInt16(newRows),
                pixelWidth: clampedUInt16(Int(backing.width.rounded())),
                pixelHeight: clampedUInt16(Int(backing.height.rounded()))
            )
        )
        if !coalescesResize { resizeCoalescer.flush() }
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

    func setResizeCoalescing(_ enabled: Bool) {
        coalescesResize = enabled
    }

    func flushPendingResize() {
        resizeCoalescer.flush()
    }

    func setDrawingSuspended(_ suspended: Bool) {
        guard terminalView.isHidden != suspended else { return }
        terminalView.isHidden = suspended
        if !suspended { _ = requestRendererDraw() }
    }

    func describePane(index: Int, count: Int, descriptor: PaneDescriptor) {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        let details = [descriptor.label, descriptor.groupLabel].compactMap { $0 }
        setAccessibilityLabel(
            (["Pane \(index) of \(count)"] + details).joined(separator: ", ")
        )
        terminalView.setAccessibilityLabel(
            ["Terminal", descriptor.label].compactMap { $0 }.joined(separator: ", ")
        )
    }
}

struct TerminalSize: Equatable {
    let cols: UInt16
    let rows: UInt16
    let pixelWidth: UInt16
    let pixelHeight: UInt16
}

struct TerminalResizeCoalescer {
    private let send: (TerminalSize) -> Void
    private var pending: TerminalSize?

    init(send: @escaping (TerminalSize) -> Void) {
        self.send = send
    }

    mutating func submit(_ size: TerminalSize) {
        pending = size
    }

    mutating func flush() {
        guard let pending else { return }
        self.pending = nil
        send(pending)
    }
}

private func clampedUInt16(_ value: Int) -> UInt16 {
    UInt16(max(1, min(value, Int(UInt16.max))))
}

private extension NSView {
    func firstDescendant<View: NSView>(of type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View {
                return match
            }
            if let match = subview.firstDescendant(of: type) {
                return match
            }
        }
        return nil
    }
}
