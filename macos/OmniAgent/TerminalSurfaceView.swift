import AppKit
import MetalKit
import os.signpost
import SwiftTerm

final class NativeTerminalView: TerminalView {
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

    /// ⇧⏎ must insert a newline in a coding agent's prompt, not submit it.
    /// AppKit maps ⏎ and ⇧⏎ to the same `insertNewline:` command, so SwiftTerm
    /// sent a bare CR for both and every agent read ⇧⏎ as "send".
    /// Taken here rather than in `keyDown`, which SwiftTerm declares `public`
    /// (not `open`) and so cannot be overridden from this module.
    /// `performKeyEquivalent` runs before the key event is delivered to the
    /// first responder, and reaches every view in the window — hence the
    /// focus check.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // SwiftTerm's own ⌘⌥O flips `optionAsMetaKey` off inside `keyDown`,
        // which this module cannot override — so the keystroke is swallowed
        // here instead, before it ever reaches the terminal. ⌥ is always Meta.
        if window?.firstResponder === self,
           event.modifierFlags.contains([.command, .option]),
           event.charactersIgnoringModifiers == "o" {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// AppKit offers `performKeyEquivalent` only for ⌘ chords: a bare ⌥ or ⇧
    /// chord is delivered straight to `keyDown`, which SwiftTerm declares
    /// `public` (not `open`) and so cannot be overridden from this module.
    /// `WorkspaceWindow.sendEvent` — already the interception point for esc,
    /// for the same reason — calls this before the event reaches SwiftTerm.
    /// Returns true when the keystroke was consumed here.
    func interceptKeyDown(_ event: NSEvent) -> Bool {
        if let composed = Self.composedOptionText(
            modifiers: event.modifierFlags,
            characters: event.characters
        ) {
            send(Array(composed.utf8))
            return true
        }
        guard let bytes = Self.overrideBytes(
            keyCode: event.keyCode,
            modifiers: event.modifierFlags,
            kittyActive: !(terminal?.keyboardEnhancementFlags.isEmpty ?? true)
        ) else { return false }
        send(bytes)
        return true
    }

    /// ESC CR is what Claude Code's own `/terminal-setup` writes into iTerm2
    /// and VS Code for ⇧⏎, and it is byte-identical to ⌥⏎, which already
    /// works here — so one sequence covers every agent that accepts either.
    ///
    /// When the app has switched on the kitty keyboard protocol it asked to
    /// see modifiers itself, and SwiftTerm already encodes ⇧⏎ as CSI 13;2u.
    static func overrideBytes(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        kittyActive: Bool
    ) -> [UInt8]? {
        let returnKeys: Set<UInt16> = [36, 76]  // ⏎ and the keypad's enter
        guard returnKeys.contains(keyCode), !kittyActive else { return nil }
        // Only the four modifiers that change what a key means: caps lock and
        // the numeric-pad/function bits ride along on a real event and would
        // break an equality test against `.shift` alone.
        guard modifiers.intersection([.shift, .control, .option, .command]) == .shift else {
            return nil
        }
        return [0x1b, 0x0d]
    }

    /// ⌥ is Meta here, which on a non-US layout eats the only way to type a
    /// bracket: on the Portuguese layout ⌥8/⌥9 are `[`/`]` and ⌥⇧8/⌥⇧9 are
    /// `{`/`}`, and as Meta they went out as ESC 8 / ESC 9. A ⌥ chord that
    /// AppKit already composed into ASCII punctuation is such a layout key,
    /// not a Meta chord — the Meta chords worth keeping (⌥⌫, ⌥←/→, ⌥b/⌥f)
    /// compose either nothing or a letter, so they still fall through to
    /// SwiftTerm. The cost is Meta-punctuation chords on layouts that do
    /// compose ASCII there — Meta-. (yank-last-arg) being the one anybody
    /// misses.
    static func composedOptionText(
        modifiers: NSEvent.ModifierFlags,
        characters: String?
    ) -> String? {
        // ⇧ rides along on the brace half of the pair, so only ⌃/⌘ disqualify.
        guard modifiers.intersection([.control, .command, .option]) == .option,
              let characters,
              characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first,
              // Printable ASCII, minus space, minus anything alphanumeric.
              (0x21...0x7e).contains(scalar.value),
              !CharacterSet.alphanumerics.contains(scalar)
        else { return nil }
        return characters
    }

    override func accessibilityPerformPress() -> Bool {
        window?.makeFirstResponder(self)
        return true
    }

    override func accessibilityValue() -> Any? {
        String(data: terminal.getBufferAsData(), encoding: .utf8) ?? ""
    }

}

final class TerminalSurfaceView: NSView, TerminalViewDelegate, NSMenuItemValidation {
    let terminalView = NativeTerminalView(
        frame: .zero,
        font: .monospacedSystemFont(ofSize: 13, weight: .regular)
    )
    var onTitleChange: ((String) -> Void)?
    var onDirectoryChange: ((String?) -> Void)?
    var onLinkClick: ((URL) -> Void)?
    /// The user submitted `/clear` — a new conversation, so whatever the pane
    /// was called is about nothing now.
    var onClearCommand: (() -> Void)?

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

    /// Mosh-style local echo for remote panes, whose real echo is a relay
    /// round-trip away: keystrokes are predicted at the cursor and painted by
    /// `echoOverlay` above the terminal — never written into its buffer —
    /// until the real bytes confirm or contradict them. Off by default, so a
    /// local pane does not change at all; a later task turns it on for
    /// relayed connections.
    var predictiveEchoEnabled = false {
        didSet {
            guard predictiveEchoEnabled != oldValue, !predictiveEchoEnabled else { return }
            echo = PredictiveEchoModel()
            renderPredictions()
        }
    }
    private var echo = PredictiveEchoModel()
    let echoOverlay = PredictiveEchoOverlayView()

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

    /// The container a remote pane's terminal is scaled by; `nil` for a local
    /// pane, which is the flag every branch below tests. See "The host's grid".
    private let scaleHost: NSView?

    init(connection: SessionConnection, sessionID: String) {
        self.connection = connection
        self.sessionID = sessionID
        self.scaleHost = connection.isRemote ? NSView(frame: .zero) : nil
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
        // ⌥ is Meta, not a compose key: ⌥⌫ must send ESC DEL so readline
        // kills a word (and ⌥←/→ move by word). Standing decision
        // (2026-08-19) — this is a coding terminal first and standard
        // behaviour, so there is no toggle: ⌥-composed characters
        // (é, ã, ç) are the accepted cost.
        terminalView.optionAsMetaKey = true
        // The default `.hoverWithModifier` requires ⌘ before a click matches
        // a link. `.hover` matches the identical set (explicit or implicit,
        // whatever's under the pointer) minus that requirement, so a plain
        // click opens a link — `mouseUp` re-hovers the release point right
        // before checking, so a cold click (no prior mouse movement) still
        // matches.
        terminalView.linkHighlightMode = .hover
        terminalView.setAccessibilityElement(true)
        terminalView.setAccessibilityRole(.textArea)
        terminalView.setAccessibilityLabel("Terminal")
        terminalView.terminalDelegate = self
        addSubview(terminalView)
        terminalView.frame = bounds
        addSubview(echoOverlay, positioned: .above, relativeTo: terminalView)
        echoOverlay.frame = bounds
        addSubview(wash, positioned: .above, relativeTo: nil)
        wash.frame = bounds
        wash.isHidden = isSelected
        // A pane is born unselected, and `isSelected`'s didSet cannot fire for
        // the value it already holds — so the newest pane would have been the
        // one blinking on its own until it lost focus once.
        applyCursorBlink()
        if let scaleHost {
            // A remote pane draws the host's grid scaled (§1): the terminal and
            // the echo overlay above it move into a container whose *bounds*
            // are that grid at its true size and whose *frame* is the box it is
            // drawn in. AppKit's own scale, not a raw layer transform: a
            // transform is invisible to `hitTest` and to `convert(_:from:)`, so
            // every click and drag selection would land in the wrong cell.
            // The wash stays on the pane so it covers the letterbox too.
            scaleHost.addSubview(terminalView)
            scaleHost.addSubview(echoOverlay, positioned: .above, relativeTo: terminalView)
            addSubview(scaleHost, positioned: .below, relativeTo: wash)
            // Zoomed past the fit the grid is bigger than the pane; the
            // overflow belongs to this pane and stops at its edge.
            layer?.masksToBounds = true
            listenForHostGrid()
        }
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
        // A remote pane's terminal is the host's grid, not this pane's: only
        // the scale it is drawn at changes when the pane resizes.
        guard scaleHost == nil else {
            wash.frame = bounds
            applyRemoteFit()
            return
        }
        terminalView.frame = bounds
        echoOverlay.frame = bounds
        wash.frame = bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // The rasterization scale is `fit.scale × backingScaleFactor`, and the
        // window is where the second half comes from.
        if scaleHost != nil, window != nil { applyRemoteFit() }
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

    /// A move between displays of different scales changes what
    /// `metalScaleFactorOverride` has to be. No-op for a local pane.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if scaleHost != nil { applyRemoteFit() }
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
        reconcilePredictions()
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
        // A viewer never resizes the shared grid (phase 2 §1, "The viewer
        // never sends `Resize`"): the session belongs to the host, one grid
        // exists, and a second Mac's smaller window collapsing the host's
        // terminal into a column is the defect this closes. Defence in depth —
        // `authorize_remote` refuses `Resize` from a remote client too — and
        // the reason this is the *only* caller of `connection.resize`.
        guard !connection.isRemote else { return }
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

    // MARK: The host's grid

    /// The host's `cols × rows` for this session, from a `SessionResized`
    /// push — `nil` until the first one lands, which the daemon sends on
    /// attach, just before the snapshot.
    ///
    /// A local pane ignores it: the daemon pushes the size to local
    /// connections too, and there the view drives the grid, not the other way
    /// around.
    var remoteGrid: (cols: UInt16, rows: UInt16)? {
        didSet {
            guard scaleHost != nil else { return }
            guard remoteGrid?.cols != oldValue?.cols || remoteGrid?.rows != oldValue?.rows else { return }
            applyRemoteFit()
        }
    }

    /// What this pane is drawing right now: the host's grid at its true size,
    /// the scale it is shown at, and where it sits. `nil` on a local pane.
    private(set) var remoteFit: RemoteTerminalScaler.Fit?

    private var scaler = RemoteTerminalScaler()

    /// Pins the terminal to the host's grid and scales the container around it
    /// into whatever space the pane has (§1, "Rendering mechanics").
    ///
    /// The terminal view's own frame stays the grid's *true* size, because
    /// SwiftTerm re-derives `cols`/`rows` from `bounds ÷ cell` on every
    /// `setFrameSize` and there is no fixed-grid mode to ask for: the way to
    /// pin a grid is to hand the view the frame whose arithmetic yields the
    /// host's numbers. The container's bounds/frame ratio does the scaling.
    private func applyRemoteFit() {
        guard let scaleHost, bounds.width > 0, bounds.height > 0 else { return }
        // Until the host's grid lands — the daemon sends it on attach, just
        // before the snapshot — the pane is laid out like any other terminal.
        // Nothing is sent to the host either way; `flushResize` sees to that.
        guard let grid = remoteGrid, let cell = swiftTermCellSize else {
            remoteFit = nil
            scaleHost.frame = bounds
            scaleHost.bounds = CGRect(origin: .zero, size: bounds.size)
            terminalView.frame = scaleHost.bounds
            echoOverlay.frame = scaleHost.bounds
            terminalView.metalScaleFactorOverride = nil
            return
        }
        // SwiftTerm keeps `reservedScrollerWidth` for its scroll indicator
        // *inside* the terminal's frame (`getEffectiveWidth`), so it is not
        // part of the grid: the fit is computed on the pane minus that strip
        // and the strip is added back onto the frame. It draws nothing, so the
        // grid still reads as centred with it hanging off the trailing edge.
        let chrome = reservedScrollerWidth
        let fit = RemoteTerminalScaler.fit(
            hostCols: Int(grid.cols),
            hostRows: Int(grid.rows),
            cell: cell,
            pane: CGSize(width: max(0, bounds.width - chrome), height: bounds.height),
            zoom: scaler.zoom
        )
        remoteFit = fit
        // Half a point of slack: SwiftTerm divides the frame by the cell and
        // truncates, and `cols × cell ÷ cell` does not always round-trip in
        // binary floating point — a grid short by one column is the whole
        // failure this task exists to prevent.
        let unscaled = CGSize(
            width: fit.terminalSize.width + chrome + 0.5,
            height: fit.terminalSize.height + 0.5
        )
        let drawn = CGSize(width: unscaled.width * fit.scale, height: unscaled.height * fit.scale)
        // `fit.origin` centres the grid at its true size; once `scale` has
        // shrunk it, the leftover is letterboxed here so the host's screen
        // sits in the middle of the pane rather than in a corner — never
        // above where the fit put it, which is where a zoom past the fit
        // (drawn wider than the pane) pins it.
        scaleHost.frame = CGRect(
            origin: CGPoint(
                x: max(fit.origin.x, (bounds.width - drawn.width) / 2),
                y: max(fit.origin.y, (bounds.height - drawn.height) / 2)
            ),
            size: drawn
        )
        // Set after the frame, and deliberately: the bounds size against a
        // smaller frame *is* the scale, and setting the frame would otherwise
        // rewrite it.
        scaleHost.bounds = CGRect(origin: .zero, size: unscaled)
        terminalView.frame = scaleHost.bounds
        echoOverlay.frame = scaleHost.bounds
        // This fork exposes the override for exactly this case — "client
        // applications that apply their own view transforms" — so Metal
        // rasterizes glyphs at the pixels they are shown at instead of
        // rendering the grid full size and letting the compositor squash it.
        terminalView.metalScaleFactorOverride = fit.scale * (window?.backingScaleFactor ?? 2)
    }

    /// SwiftTerm's cell, in points, read back out of the frame it says its
    /// current grid wants: `cellDimension` is internal, but
    /// `getOptimalFrameSize` is `cell × grid` plus the scroller strip.
    private var swiftTermCellSize: CGSize? {
        let terminal: Terminal = terminalView.terminal
        let cols = CGFloat(terminal.cols)
        let rows = CGFloat(terminal.rows)
        guard cols > 0, rows > 0 else { return nil }
        let optimal = terminalView.getOptimalFrameSize().size
        let cell = CGSize(
            width: (optimal.width - reservedScrollerWidth) / cols,
            height: optimal.height / rows
        )
        guard cell.width > 0, cell.height > 0 else { return nil }
        return cell
    }

    /// The width SwiftTerm holds back for its scroll indicator inside the
    /// terminal's own frame — the same arithmetic as its private
    /// `reservedScrollerWidth`, which the grid must not be charged for.
    private var reservedScrollerWidth: CGFloat {
        NSScroller.scrollerWidth(for: .regular, scrollerStyle: terminalView.scrollerStyle)
    }

    /// Takes `SessionResized` off the machine's connection.
    ///
    /// `onSessionSize` is one closure and a machine's connection is shared by
    /// every pane open on it, so the surfaces register against the connection
    /// and the closure — reinstalled by each registration, identical every
    /// time — hands each push to whichever pane owns that session id. Held
    /// weakly, so a closed pane drops out on its own. `remoteGrid` stays
    /// settable from outside for the day the window controller routes this
    /// push the way it routes `onTerminalData`.
    private func listenForHostGrid() {
        let key = ObjectIdentifier(connection)
        var listeners = (Self.hostGridListeners[key] ?? []).filter { $0.surface != nil }
        listeners.append(WeakSurface(surface: self))
        Self.hostGridListeners[key] = listeners
        // Captures the key — a bare address — and not the connection, which
        // owns this closure.
        connection.onSessionSize = { id, cols, rows in
            let live = (Self.hostGridListeners[key] ?? []).filter { $0.surface != nil }
            Self.hostGridListeners[key] = live
            for entry in live where entry.surface?.sessionID == id {
                entry.surface?.remoteGrid = (cols: cols, rows: rows)
            }
        }
    }

    private struct WeakSurface {
        weak var surface: TerminalSurfaceView?
    }

    /// Main-thread only, like every callback `SessionConnection` delivers.
    private static var hostGridListeners: [ObjectIdentifier: [WeakSurface]] = [:]

    // MARK: Zoom (remote panes only)

    /// ⌘+ — magnify past the fit. Never a resize: the grid is the host's
    /// whatever this pane shows it at.
    @objc func zoomInRemoteTerminal(_ sender: Any?) {
        stepRemoteZoom(by: Self.zoomStep)
    }

    /// ⌘−
    @objc func zoomOutRemoteTerminal(_ sender: Any?) {
        stepRemoteZoom(by: 1 / Self.zoomStep)
    }

    /// ⌘0 — back to the whole screen, fitted.
    @objc func resetRemoteTerminalZoom(_ sender: Any?) {
        guard scaleHost != nil else { return }
        scaler.resetZoom()
        applyRemoteFit()
    }

    private static let zoomStep: CGFloat = 1.25

    private func stepRemoteZoom(by factor: CGFloat) {
        guard scaleHost != nil else { return }
        scaler.stepZoom(by: factor, from: remoteFit?.scale ?? 1)
        applyRemoteFit()
    }

    /// The zoom chords, taken here rather than from a menu: nothing in the
    /// main menu binds ⌘+ / ⌘− and ⌘0 is Pane 10, and a remote pane that has
    /// focus wants all three for the screen it is showing. Only ever for a
    /// focused remote pane — a local pane never sees this and keeps ⌘0.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard scaleHost != nil,
              window?.firstResponder === terminalView,
              event.modifierFlags.intersection([.command, .option, .control]) == .command,
              let action = Self.zoomAction(for: event.charactersIgnoringModifiers)
        else { return super.performKeyEquivalent(with: event) }
        action(self)
        return true
    }

    private static func zoomAction(for characters: String?) -> ((TerminalSurfaceView) -> Void)? {
        switch characters {
        case "+", "=": return { $0.zoomInRemoteTerminal(nil) }
        case "-", "_": return { $0.zoomOutRemoteTerminal(nil) }
        case "0": return { $0.resetRemoteTerminalZoom(nil) }
        default: return nil
        }
    }

    /// Whether anything has been typed at this terminal. What decides if
    /// swapping the pane's engine has to ask first — a terminal nobody has
    /// typed in has no conversation to lose. Deliberately keystrokes only:
    /// `sendInput` below is this app writing to the PTY (an approval button,
    /// a `/rename`), which is not the user starting a conversation.
    private(set) var hasUserInput = false

    /// What has been typed since the last Enter. Only ever long enough to
    /// recognise a `/clear`; anything that is not a plain printable character
    /// throws it away rather than guessing at the line the engine sees.
    private var typedLine = ""

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        hasUserInput = true
        trackTypedLine(data)
        os_signpost(.event, log: Instrumentation.log, name: "Terminal Input")
        connection.write(sessionID: sessionID, bytes: Data(data))
        predictLocalEcho(data)
    }

    // MARK: Predictive echo

    /// SwiftTerm scrolls the caret into view before it calls `send`
    /// (`ensureCaretIsVisible` in `TerminalView.send(data:)`), so the buffer
    /// cursor it reports here is the viewport cursor the overlay draws in.
    private func predictLocalEcho(_ data: ArraySlice<UInt8>) {
        guard predictiveEchoEnabled else { return }
        let terminal: Terminal = terminalView.terminal
        let cursor = terminal.getCursorLocation()
        echo.syncCursor(row: cursor.y, col: cursor.x)
        echo.predict(Array(data), now: CACurrentMediaTime(), cols: terminal.cols)
        renderPredictions()
    }

    /// After every real feed: compare each prediction with the cell it was
    /// made for. `getCharacter(col:row:)` is viewport-relative (it adds
    /// `yDisp` itself); an empty cell is NUL in SwiftTerm, which the model
    /// must see as "no echo yet" rather than as a character that disagrees.
    private func reconcilePredictions() {
        guard predictiveEchoEnabled else { return }
        let terminal: Terminal = terminalView.terminal
        echo.reconcile(now: CACurrentMediaTime()) { row, col in
            guard let character = terminal.getCharacter(col: col, row: row), character != "\0" else { return nil }
            return character
        }
        renderPredictions()
    }

    private func renderPredictions() {
        let terminal: Terminal = terminalView.terminal
        echoOverlay.render(
            echo.drawn,
            cols: terminal.cols,
            rows: terminal.rows,
            font: terminalView.font,
            color: terminalView.nativeForegroundColor.withAlphaComponent(0.72),
            cellSize: terminalCellSize
        )
    }

    /// SwiftTerm's real cell geometry, in points. Its `cellSizeInPixels`
    /// scales by the window's backing factor and rounds, and the cell it
    /// computed was snapped to that same pixel grid, so dividing back is
    /// exact — but only with a window; without one it rounds to whole points,
    /// so the overlay falls back to dividing its bounds.
    private var terminalCellSize: CGSize? {
        guard let scale = terminalView.window?.backingScaleFactor,
              let pixels = terminalView.cellSizeInPixels(source: terminalView.terminal)
        else { return nil }
        return CGSize(width: CGFloat(pixels.width) / scale, height: CGFloat(pixels.height) / scale)
    }

    /// Watches the keystroke stream for `/clear` and nothing else.
    private func trackTypedLine(_ data: ArraySlice<UInt8>) {
        for byte in data {
            switch byte {
            case 0x0D, 0x0A:
                if typedLine.trimmingCharacters(in: .whitespaces) == "/clear" { onClearCommand?() }
                typedLine = ""
            case 0x7F, 0x08:
                if !typedLine.isEmpty { typedLine.removeLast() }
            case 0x20...0x7E:
                typedLine.append(Character(UnicodeScalar(byte)))
            default:
                // An escape sequence, a paste, anything non-ASCII: this is a
                // spelling check, not a shell parser. Start over.
                typedLine = ""
            }
        }
    }

    /// Writes to the PTY exactly as typing would — the approval bar's buttons
    /// answer a dialog through the same door as the keyboard.
    func sendInput(_ text: String) {
        connection.write(sessionID: sessionID, bytes: Data(text.utf8))
    }

    /// Sends a command to the PTY without corrupting whatever the user has
    /// half-typed on the current input line.
    ///
    /// Sequence:
    ///  1. Read the cursor line to capture the typed text.
    ///  2. Ctrl+E  — move to end of line (handles mid-line cursor positions).
    ///  3. Ctrl+U  — kill from end back to the start, clearing the input.
    ///  4. Send the command.
    ///  5. After 100 ms — retype the saved text so the user's draft is back.
    ///
    /// 100 ms is comfortably longer than any built-in agent slash-command
    /// (`/color`, `/settings theme`) needs to print its one-line confirmation
    /// and return to the prompt, so the restore lands on a clean input line.
    func sendCommandClearingInput(_ command: String) {
        let saved = typedInput()
        // Ctrl+E (end of line) then Ctrl+U (kill to beginning) — covers both
        // readline and TUI input handlers used by Claude and Copilot.
        sendInput("\u{05}\u{15}")
        sendInput(Self.framed(command) + "\r")
        guard !saved.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.sendInput(saved)
        }
    }

    /// How a command reaches the TUI: as-is when it is one line, wrapped in
    /// bracketed paste when it is several.
    ///
    /// Without the wrapper each embedded newline *submits* — a five-line
    /// message would arrive as five separate prompts. `ESC[200~ … ESC[201~`
    /// is what a terminal sends around a real paste, and a TUI that
    /// understands it inserts the whole run as one multi-line draft instead.
    ///
    /// Safe to send unconditionally? No — a TUI that has not enabled
    /// bracketed paste receives the escape as literal text, so it is applied
    /// only where it is needed and a single-line command keeps the exact
    /// bytes it has always been sent. Claude's TUI does enable it: it emits
    /// `ESC[?2004h` on startup, verified against a real `claude` in a PTY
    /// rather than assumed from the fact that most TUIs do.
    static func framed(_ command: String) -> String {
        guard command.contains(where: \.isNewline) else { return command }
        return "\u{1b}[200~" + command + "\u{1b}[201~"
    }

    /// The text currently typed on the cursor's input line, with the prompt
    /// prefix stripped. Returns `""` when nothing is typed or the cursor row
    /// contains no recognisable prompt.
    ///
    /// Reads the rendered screen rather than an internal buffer — robust
    /// against every shell and TUI that renders its own prompt.
    private func typedInput() -> String {
        let terminal: Terminal = terminalView.terminal
        let (_, cursorY) = terminal.getCursorLocation()
        guard let line = terminal.getLine(row: cursorY) else { return "" }
        let full = line.translateToString(trimRight: true)
            .replacingOccurrences(of: "\0", with: " ")
        guard !full.isEmpty else { return "" }
        if let match = full.range(of: #"[›❯>$#%]\s+"#,
                                   options: [.regularExpression],
                                   range: full.startIndex..<full.endIndex) {
            return String(full[match.upperBound...])
        }
        return ""
    }

    /// The tail of the terminal's text, trailing blank rows dropped — what
    /// `ApprovalPrompt.parse` reads the on-screen dialog out of.
    func visibleTailLines(limit: Int = 40) -> [String] {
        Self.tailLines(of: terminalView.terminal, limit: limit)
    }

    /// Free of the view so it can be driven by a bare `Terminal` in tests —
    /// which is the only way to see what the parser is really handed.
    ///
    /// Trailing blanks go first because a fresh screen pads to the viewport
    /// height below the dialog, and a plain suffix would be all padding.
    ///
    /// The NUL substitution is not cosmetic. Claude's TUI paints a line by
    /// jumping to absolute columns instead of writing the spaces between the
    /// words (`Esc\u{1b}[24Gto\u{1b}[27Gcancel` — the same rendering the
    /// daemon's marker matching documents), and SwiftTerm returns a cell
    /// nobody ever wrote as U+0000 rather than a space. Left alone, the tail
    /// reads `Esc\0to\0cancel`: the daemon lights the pane amber (its `vt100`
    /// screen renders those cells as spaces) while every dialog the bar tried
    /// to parse came back empty, so the buttons were always the Approve/Deny
    /// fallback.
    static func tailLines(of terminal: Terminal, limit: Int = 40) -> [String] {
        let data = terminal.getBufferAsData()
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "\0", with: " ") }
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return Array(lines.suffix(limit))
    }

    /// The visible screen with the terminal's wrapping undone: rows the
    /// terminal broke only because the pane was narrow are joined back into
    /// the line the program actually printed — what the review panel's
    /// Browser tab scans for dev-server addresses, where `localhost:5173`
    /// split across two rows must still read as one address.
    func unwrappedTailLines(limit: Int = 40) -> [String] {
        Self.unwrappedTailLines(of: terminalView.terminal, limit: limit)
    }

    /// Free of the view — `tailLines`'s reasoning, and its NUL substitution.
    /// A row whose `isWrapped` flag is set is a continuation of the row above
    /// (SwiftTerm's reflow rule), so it is appended rather than started anew.
    static func unwrappedTailLines(of terminal: Terminal, limit: Int = 40) -> [String] {
        var lines: [String] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            let text = line.translateToString(trimRight: true)
                .replacingOccurrences(of: "\0", with: " ")
            if line.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += text
            } else {
                lines.append(text)
            }
        }
        while let last = lines.last, last.isEmpty {
            lines.removeLast()
        }
        return Array(lines.suffix(limit))
    }

    /// Keeps the last line the screen gave rather than letting a blank read
    /// wipe it.
    ///
    /// The screen is read ten times a second, and a repaint is not atomic: a
    /// poll can land on a frame the agent has cleared and not finished drawing,
    /// where there is no bullet to find. Answering `nil` there is momentarily
    /// true and useless — the card drops the line and shows the status word
    /// instead, and at ten reads a second what that looks like is the line
    /// flickering against `Working`. The line is only ever replaced by another
    /// line.
    struct OutputLineHold {
        private(set) var line: String?

        mutating func update(_ next: String?) -> String? {
            if let next { line = next }
            return line
        }
    }

    /// What this terminal is *doing*, as one line — what the sidebar's hover
    /// card types out.
    ///
    /// Reads the visible rows directly instead of going through `tailLines`,
    /// which serialises the whole buffer: this is polled ten times a second for
    /// as long as a card is open, and the scrollback is thousands of lines.
    func lastOutputLine() -> String? {
        outputLineHold.update(Self.lastOutputLine(of: terminalView.terminal))
    }

    private var outputLineHold = OutputLineHold()

    /// Free of the view, like `tailLines`, so a bare `Terminal` can drive it.
    ///
    /// Not literally the last line: on a screen an agent owns, the last line is
    /// its own furniture. Claude's is `auto mode on (shift+tab to cycle)`,
    /// under a context meter, under a working directory, under an empty input
    /// box — none of which changes when the agent does something.
    ///
    /// What it wants is the line the agent's own blinking bullet is on: `⏺`,
    /// the mark it puts beside whatever it is doing right now. That bullet is
    /// *blinking*, so half the time it is not on the screen to be found — which
    /// is why `bulletLine` looks for the bullet's column as well as the bullet.
    ///
    /// With no bullet and no agent furniture anywhere — a plain shell — three
    /// rules stand in, and they cost a shell nothing, having none of what they
    /// skip:
    ///
    /// 1. **Everything at and below the input box is chrome.** The box is the
    ///    bottom-most `›`/`❯` prompt line. This one applies either way.
    /// 2. **A command echo is one block.** A line opening with `└`/`⎿`/`$`
    ///    starts it and its indented body continues it — the card should say
    ///    what the tool is *for*, which is the line above, not the shell it
    ///    spawned or the heredoc it is feeding.
    /// 3. **A spinner frame is an animation, not news.** `✳ Crystallizing…`
    ///    says only that the agent is busy, which the card's own status already
    ///    says, in a colour.
    ///
    /// What survives is the lowest line that actually reports something.
    static func lastOutputLine(of terminal: Terminal) -> String? {
        let rows = visibleRows(of: terminal)
        // A screen with bullets on it is an agent's, and its bullets are the
        // answer.
        if rows.contains(where: { isBullet($0.body) }) { return bulletLine(in: rows) }
        // An agent that has just compacted its transcript is the one screen
        // wearing an agent's furniture with not a single bullet left on it, and
        // the honest answer there is none: the action it is about to report has
        // not been printed yet. The shell rules below would answer regardless,
        // out of the furniture underneath — the separator the terminal hangs
        // its tab name on, or the `/compact` the user typed to get here. The
        // `\u{23BF}` a tool result hangs from is what gives the screen away; a
        // shell has no reason to draw one.
        if rows.contains(where: { $0.body.first == "\u{23BF}" }) { return nil }
        // Neither bullets nor that: a shell, and the rules below stand in.
        return reportingLine(in: rows)
    }

    /// The lowest line carrying the agent's bullet — its current action.
    ///
    /// Two kinds of line qualify, and *only* these two, which is what keeps the
    /// answer off everything else an agent paints. A visible bullet, flush at
    /// the margin. And a line whose text starts exactly where a bullet's text
    /// starts, `bulletTextColumn` in: that is the running line, whose bullet is
    /// blinked off this frame. Everything else on the screen fails both tests —
    /// a wrapped continuation of a bullet's own line is flush but has no
    /// bullet, a tool's output is indented further, a tool's own echo opens
    /// with `⎿`, and the separator the terminal hangs its tab name on is flush
    /// with no bullet either. That separator is why this is a whitelist: it is
    /// the lowest line on the screen with words in it, and it never changes.
    private static func bulletLine(in rows: [(indent: Int, body: String)]) -> String? {
        var best: String?
        for row in rows where isBullet(row.body) || isBlinkedOffBullet(row) {
            let text = display(row.body)
            if !text.isEmpty { best = text }
        }
        return best
    }

    /// Where a bullet's text begins: the bullet, one blank cell, then words.
    static let bulletTextColumn = 2

    /// A bullet line caught mid-blink — text in the bullet's column with no
    /// bullet in front of it.
    private static func isBlinkedOffBullet(_ row: (indent: Int, body: String)) -> Bool {
        guard row.indent == bulletTextColumn,
              !isEcho(row.body),
              !isSpinner(row.body),
              !isHint(row.body)
        else { return false }
        return row.body.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
    }

    private static func isBullet(_ body: String) -> Bool {
        guard let first = body.first else { return false }
        return "⏺●".contains(first)
    }

    /// The body with its margin mark taken off — the glyph is a mark, not a
    /// word.
    private static func display(_ body: String) -> String {
        String(body.drop { $0.unicodeScalars.allSatisfy(leadingMarker.contains) })
            .trimmingCharacters(in: .whitespaces)
    }

    private static func reportingLine(in allRows: [(indent: Int, body: String)]) -> String? {
        var rows = allRows
        // Top down, so a block is met at its header rather than in its middle,
        // and so the last survivor is the lowest one.
        var best: String?
        var echoIndent: Int?
        for row in rows {
            if row.body.isEmpty {
                echoIndent = nil
                continue
            }
            // Rule 2, continued: still inside the echo block.
            if let echoIndent, row.indent > echoIndent { continue }
            echoIndent = nil
            if isEcho(row.body) {
                echoIndent = row.indent
                continue
            }
            // Rule 3, plus the hint lines an agent parks under its tool calls
            // (`(ctrl+b to run in background)`), plus anything with no words in
            // it at all — a box's own bottom edge is not output.
            if isSpinner(row.body) || isHint(row.body) || isFrame(row.body) { continue }
            guard row.body.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains)
            else { continue }
            best = display(row.body)
        }
        return best?.isEmpty == false ? best : nil
    }

    /// The visible screen, each row reduced to what these rules read: how far
    /// in its text starts, and that text with the box it sits in trimmed off.
    /// Everything at and below the input box is dropped — the status bar lives
    /// under it by construction, whatever it happens to say today, and the
    /// *last* prompt line is the box (the submitted messages above wear the
    /// same glyph, and they are transcript).
    private static func visibleRows(of terminal: Terminal) -> [(indent: Int, body: String)] {
        var rows: [(indent: Int, body: String)] = []
        for row in 0..<terminal.rows {
            guard let line = terminal.getLine(row: row) else { continue }
            // Same NUL substitution `tailLines` documents: SwiftTerm returns
            // U+0000 for a cell nobody wrote, and a TUI paints by jumping
            // columns rather than writing the spaces between words.
            let raw = line.translateToString(trimRight: true)
                .replacingOccurrences(of: "\0", with: " ")
            let indent = raw.prefix { $0.unicodeScalars.allSatisfy(borderAndSpace.contains) }.count
            rows.append((indent, raw.trimmingCharacters(in: borderAndSpace)))
        }
        guard let box = rows.lastIndex(where: { isPrompt($0.body) }) else { return rows }
        return Array(rows.prefix(box))
    }

    private static func isPrompt(_ body: String) -> Bool {
        guard let first = body.first, "›❯>".contains(first) else { return false }
        return body.count == 1 || body.dropFirst().first == " "
    }

    private static func isEcho(_ body: String) -> Bool {
        guard let first = body.first else { return false }
        return "└⎿$".contains(first)
    }

    private static func isHint(_ body: String) -> Bool {
        body.hasPrefix("(") && body.hasSuffix(")")
    }

    private static func isSpinner(_ body: String) -> Bool {
        guard let first = body.unicodeScalars.first else { return false }
        return spinner.contains(first)
    }

    /// Pure box-drawing chrome (corners, edges, whitespace) is layout, not
    /// output. Keep this separate from `borderAndSpace` so command content that
    /// begins with "-" is never trimmed as if it were frame glyphs.
    private static func isFrame(_ body: String) -> Bool {
        let visible = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !visible.isEmpty else { return false }
        return visible.unicodeScalars.allSatisfy(frameChrome.contains)
    }

    /// The box-drawing verticals a TUI wraps its lines in, plus whitespace.
    /// Trimmed off both ends so the card shows the sentence rather than the
    /// frame it happens to be sitting inside.
    private static let borderAndSpace = CharacterSet(charactersIn: "│┃║|╎┆┊╵ \t")
        .union(.whitespacesAndNewlines)

    /// Box-drawing glyphs that are pure frame chrome when a row contains only
    /// these symbols and no text content.
    private static let frameChrome = CharacterSet(charactersIn: "│┃║|╎┆┊╵╷╴╶┌┐└┘├┤┬┴┼╭╮╰╯─━═╞╡╪╫╬")

    /// The bullets an agent prefixes its own lines with. Taken off the front of
    /// what the card shows — the glyph is a margin mark, not a word.
    private static let leadingMarker = CharacterSet(charactersIn: "●⏺◉◆▪▸▶►→⇒✓✔✗✘·-• \t")

    /// Spinner frames, the ones `SessionOutline.sanitizedPaneTitle` strips off a
    /// reported title for the same reason. Deliberately *not* that set: it
    /// includes the whole ◯–◿ block, and U+25CF ● in the middle of it is
    /// Claude's transcript bullet — the mark on the lines most worth showing.
    private static let spinner: CharacterSet = {
        var set = CharacterSet()
        set.insert(charactersIn: "*\u{00B7}\u{2217}")
        set.insert(charactersIn: "\u{2722}"..."\u{2727}")
        set.insert(charactersIn: "\u{2731}"..."\u{2736}")
        set.insert(charactersIn: "\u{273A}"..."\u{273D}")
        // The arc spinners ◐◑◒◓ only, not the filled circles beside them.
        set.insert(charactersIn: "\u{25D0}"..."\u{25D3}")
        // Braille spinners, the other common CLI idiom.
        set.insert(charactersIn: "\u{2800}"..."\u{28FF}")
        return set
    }()

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

    /// Overrides SwiftTerm's own default (`NSWorkspace.shared.open`, see the
    /// `TerminalViewDelegate` extension in `MacTerminalView.swift`) — a
    /// forwarder like `setTerminalTitle`/`hostCurrentDirectoryUpdate` above,
    /// not a decision-maker: what a clicked link becomes is
    /// `WorkspaceWindowController`'s call, same as every other pane-routing
    /// decision.
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
        guard let url = URL(string: link) else { return }
        onLinkClick?(url)
    }

    @objc func interruptSession(_ sender: Any?) {
        connection.interrupt(sessionID: sessionID)
    }

    /// Session › Kill Session (⌃⌘K). Never for a remote pane: the session
    /// belongs to the other Mac and `Kill` is off the remote allowlist
    /// (spec §2/§4, "remote panes hide Kill"). The host daemon refuses it
    /// anyway, but a menu item that silently does nothing is worse than a
    /// greyed-out one — hence the guard *and* `validateMenuItem` below.
    /// Interrupt is deliberately not gated: it is on the allowlist.
    @objc func killSession(_ sender: Any?) {
        guard !connection.isRemote else { return }
        connection.kill(sessionID: sessionID)
    }

    @objc func reattachSession(_ sender: Any?) {
        connection.reattach(sessionID: sessionID)
    }

    @objc func focusTerminal(_ sender: Any?) {
        focus()
    }

    /// The one item this surface has an opinion about. Everything else the
    /// responder chain routes through here keeps AppKit's default answer.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(killSession(_:)):
            return !connection.isRemote
        case #selector(zoomInRemoteTerminal(_:)),
             #selector(zoomOutRemoteTerminal(_:)),
             #selector(resetRemoteTerminalZoom(_:)):
            // Zoom is what a viewer has *instead* of a resize (§1). A local
            // pane has no scale to change — it is already 1:1 — so the items
            // grey out rather than doing nothing.
            return scaleHost != nil
        default:
            return true
        }
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
