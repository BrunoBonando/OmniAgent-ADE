import AppKit
import MetalKit
import os.signpost
import SwiftTerm

final class NativeTerminalView: TerminalView, NSMenuItemValidation {
    /// AppKit does not hand the first responder to a clicked view on its own,
    /// and SwiftTerm's `mouseDown` only starts a selection — so without this a
    /// click in the terminal body left focus wherever it was, and only the
    /// pane header (which focuses on `mouseUp`) activated a pane.
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    /// A click into a background window activates its pane in the same click
    /// rather than being spent on raising the window.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
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

    /// When set, PTY resizes are batched here instead of being sent on every
    /// size change — one send per display refresh during a live divider drag.
    weak var resizeCoalescer: PaneResizeCoalescer?

    /// A fully occluded pane keeps parsing output into SwiftTerm's bounded
    /// buffer but stops asking the renderer to draw it.
    var suspendsDrawing = false {
        didSet {
            guard oldValue, !suspendsDrawing else { return }
            terminalView.needsDisplay = true
        }
    }

    /// Whether this is the selected pane. Only the selected one blinks its
    /// cursor: SwiftTerm already draws an unfocused caret hollow, but its blink
    /// timer runs off the cursor *style* alone, so every open pane sat there
    /// flashing an outline at you — and, under Metal, woke a frame each to do
    /// it. Deselecting swaps the style for its steady twin; selecting puts back
    /// exactly what was swapped out.
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            wash.isHidden = isSelected
            applyCursorBlink()
        }
    }

    /// The unselected pane's washed-out background, as a top-most sibling
    /// rather than a swapped `nativeBackgroundColor`: SwiftTerm caches the
    /// default background inside its per-attribute run cache, and only its own
    /// internal `colorsChanged()` clears that.
    let wash = TerminalWashOverlayView()

    /// The blinking style deselection replaced, or `nil` when nothing is
    /// currently overridden.
    private var suppressedBlinkStyle: CursorStyle?

    private(set) var resizeSendCount = 0
    private(set) var drawRequestCount = 0

    private struct PendingResize {
        let cols: UInt16
        let rows: UInt16
        let pixelWidth: UInt16
        let pixelHeight: UInt16
    }

    private let connection: SessionConnection
    private let sessionID: String
    private var attemptedMetal = false
    private var drawMarkerScheduled = false
    private var pendingDrawSequence: UInt64 = 0
    private var pendingResize: PendingResize?

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
        addSubview(terminalView)
        terminalView.frame = bounds
        addSubview(wash, positioned: .above, relativeTo: nil)
        wash.frame = bounds
        wash.isHidden = isSelected
        // A pane is born unselected, and `isSelected`'s didSet cannot fire for
        // the value it already holds — so the newest pane would have been the
        // one blinking on its own until it lost focus once.
        applyCursorBlink()
    }

    private func applyCursorBlink() {
        // Annotated because `TerminalView.terminal` is implicitly unwrapped, and
        // binding it plain would infer `Terminal?`.
        let terminal: Terminal = terminalView.terminal
        if isSelected {
            guard let restored = suppressedBlinkStyle else { return }
            suppressedBlinkStyle = nil
            // Only if nothing else moved it meanwhile: a DECSCUSR the program
            // sent while this pane was in the background outranks our override.
            guard terminal.options.cursorStyle == Self.steadyTwin(of: restored) else { return }
            terminal.setCursorStyle(restored)
        } else {
            let current = terminal.options.cursorStyle
            let steady = Self.steadyTwin(of: current)
            guard steady != current else { return }
            suppressedBlinkStyle = current
            terminal.setCursorStyle(steady)
        }
    }

    /// The non-blinking cursor of the same shape, or the style itself when it
    /// already stands still.
    private static func steadyTwin(of style: CursorStyle) -> CursorStyle {
        switch style {
        case .blinkBlock: return .steadyBlock
        case .blinkBar: return .steadyBar
        case .blinkUnderline: return .steadyUnderline
        case .steadyBlock, .steadyBar, .steadyUnderline: return style
        }
    }

    /// Direct frame propagation rather than Auto Layout: the pane workspace
    /// calculates frames itself, and a live divider drag must resize the
    /// terminal in the same turn the pointer moved, not on the next layout pass.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        terminalView.frame = bounds
        wash.frame = bounds
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
        pendingDrawSequence = sequence
        guard !suspendsDrawing, !drawMarkerScheduled else { return }
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
        drawRequestCount += 1
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
        scheduleResize()
    }

    /// Records the terminal's current geometry and hands it to the coalescer —
    /// or sends it straight away when this surface stands alone (no workspace).
    func scheduleResize() {
        let backing = terminalView.convertToBacking(terminalView.bounds)
        pendingResize = PendingResize(
            cols: clampedUInt16(terminalView.terminal.cols),
            rows: clampedUInt16(terminalView.terminal.rows),
            pixelWidth: clampedUInt16(Int(backing.width.rounded())),
            pixelHeight: clampedUInt16(Int(backing.height.rounded()))
        )
        if let resizeCoalescer {
            resizeCoalescer.schedule(sessionID)
        } else {
            flushResize()
        }
    }

    /// Sends the most recent geometry, once. Intermediate sizes a drag passed
    /// through are never sent — the PTY only needs where the divider landed.
    func flushResize() {
        guard let resize = pendingResize else { return }
        pendingResize = nil
        resizeSendCount += 1
        connection.resize(
            sessionID: sessionID,
            cols: resize.cols,
            rows: resize.rows,
            pixelWidth: resize.pixelWidth,
            pixelHeight: resize.pixelHeight
        )
        os_signpost(
            .event,
            log: Instrumentation.log,
            name: "Terminal Resize",
            "%d x %d",
            Int(resize.cols),
            Int(resize.rows)
        )
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        os_signpost(.event, log: Instrumentation.log, name: "Terminal Input")
        connection.write(sessionID: sessionID, bytes: Data(data))
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        scheduleResize()
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

extension TerminalSurfaceView: PaneContentView {
    var primaryResponderView: NSView { terminalView }
}

/// A pane you are not typing into sits behind a veil that starts as its own
/// status colour at the top and falls away to a neutral wash by the bottom —
/// so a glance across the grid says both "not this one" and what each pane is
/// doing, without reading a single header. It never takes a click meant for
/// the terminal under it.
final class TerminalWashOverlayView: NSView {
    /// What the veil settles to at the bottom: the plain wash, no hue left.
    static let base = NSColor(white: 1, alpha: 0.05)
    /// The status colour's strength at the very top. Weak enough that white
    /// terminal text stays white through it.
    static let tintAlpha: CGFloat = 0.18

    /// The pane's live agent status, which the top of the gradient takes its
    /// colour from — the sidebar's mapping, not a second one.
    var status: RemoteSessionStatus? {
        didSet {
            guard status != oldValue else { return }
            apply()
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func makeBackingLayer() -> CALayer { CAGradientLayer() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func apply() {
        guard let gradient = layer as? CAGradientLayer else { return }
        let tint = ShellDotsView.color(for: status).withAlphaComponent(Self.tintAlpha)
        gradient.colors = [tint.cgColor, Self.base.cgColor]
        // Unit coordinates, y up: `1` is the top edge. The flipped pane
        // container does *not* reach in here — a layer's `geometryFlipped`
        // moves its sublayers, it does not turn a gradient upside down — so
        // this reads backwards next to the frames set above and is pinned by a
        // render in `testTheWashRunsTheStatusColourFromTheTopDown`.
        gradient.startPoint = CGPoint(x: 0.5, y: 1)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
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
