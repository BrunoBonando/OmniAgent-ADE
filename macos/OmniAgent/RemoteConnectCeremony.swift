import AppKit

// The connect ceremony (2026-09-01 remote environment sharing spec §6): the
// full-window overlay a viewer sees for the handful of seconds between
// pressing "Connect to ‹machine›" and sitting down at the host's real
// environment. `WorkspaceWindowController.beginConnecting(to:)` is the only
// production caller.
//
// **The one rule this file exists to keep: every step is a real milestone,
// never a progress animation, and never marked done ahead of its fact.**
// There is no timer anywhere in `RemoteConnectCeremony` — `step` only ever
// changes because `webSocketOpened()`, `helloAcknowledged()` or
// `environmentLoaded()` was called, and `WorkspaceWindowController` calls
// each of those only from a real `SessionConnection` event.
// `dataChannelOpened()` also exists (pinned by its own unit test) but is not
// called by any production path today — see its doc comment and
// `webSocketOpened()`'s for why checking a step off the moment its *sibling*
// event fires, rather than its own, is exactly the fake-progress failure
// this file exists to rule out. See those methods' doc comments for exactly
// what "happened" means for each, and `installConnectionHandlers`'s own
// comment in `WorkspaceWindowController` for what today's wire protocol does
// and does not let a viewer tell apart.

/// The four milestones of spec §6, plus the resting state once they have all
/// landed. Ordered so `<` reads "earlier than" — `RemoteConnectCeremonyOverlayView`
/// uses that to decide which rows are already checked.
enum ConnectStep: Int, Comparable, CaseIterable {
    case dialling
    case securing
    case confirming
    case loading
    case done

    static func < (lhs: ConnectStep, rhs: ConnectStep) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The four displayed rows, in order — `.done` is not one of them, it is
    /// what having reached the end of them looks like.
    static let displayed: [ConnectStep] = [.dialling, .securing, .confirming, .loading]

    /// The line this step shows while it is current or completed (spec §6).
    /// `machineName` only matters for `.dialling`, whose line is the only one
    /// that names the machine — the other three are the same for every
    /// takeover.
    func line(machineName: String) -> String {
        switch self {
        case .dialling: return "Connecting to \(machineName)…"
        case .securing: return "Establishing a secure line…"
        case .confirming: return "Confirming credentials…"
        case .loading: return "Loading environment…"
        case .done: return "Connected"
        }
    }
}

/// The state machine behind the ceremony — deliberately with no view, no
/// networking and no `NSObject` in it, so `RemoteConnectCeremonyTests` can
/// pin every transition against nothing but method calls.
@MainActor
final class RemoteConnectCeremony {
    /// The machine being connected to, for `.dialling`'s own line and the
    /// widget-adjacent copy ("End the session with ‹machineName› first").
    let machineName: String

    private(set) var step: ConnectStep = .dialling
    private(set) var failure: Failure?

    /// Fires on every change this type makes to itself — a step advancing, a
    /// failure landing, a retry — so a mounted view repaints. Never fires on
    /// its own; only ever from inside one of the methods below, each of which
    /// is called only once the real thing it names has happened.
    var onChange: (() -> Void)?
    /// Fires exactly once, from `environmentLoaded()` — the one place `step`
    /// reaches `.done`. `WorkspaceWindowController` starts the fade-and-take-
    /// down from here rather than polling `step`.
    var onDone: (() -> Void)?

    init(machineName: String) {
        self.machineName = machineName
    }

    /// Step 1 → 2. Driven off `SessionConnection.onStateChange`'s
    /// `.connecting` — the WebSocket dial to `/v1/viewer/{device_id}` spec
    /// §6 step 1 describes has genuinely begun (`SessionConnection.connect()`
    /// dispatches asynchronously; this is not fired at construction — and
    /// `.connecting` itself fires at the very top of `openConnection()`,
    /// before the socket exists, so even this is "the dial has started", not
    /// "the dial has finished").
    ///
    /// **`.securing` is left active here, not advanced past.** Today's
    /// transport gives the app exactly one signal before `HelloAck` — this
    /// one — so there is nothing standing for "the relay opened the data
    /// channel" (`crates/omniagent-pty-daemon/src/relay.rs`'s splice) other
    /// than the eventual `HelloAck` itself. `dataChannelOpened()` used to be
    /// called from this same event, in the same synchronous breath as this
    /// one — which checked "Establishing a secure line…" off *before* any
    /// secure line existed, at the very instant the attempt began, with
    /// "Confirming credentials…" then spinning for the entire real wait
    /// (socket, TLS, the Hello round trip). That is fake progress with extra
    /// steps: a milestone marked done ahead of its fact, exactly the thing
    /// this file's one rule forbids. `helloAcknowledged()` is what now
    /// carries `.securing` through to done — see its own doc comment.
    ///
    /// A future daemon/relay protocol version that gives the viewer a real
    /// frame for the data-channel splice (distinct from `HelloAck`) is what
    /// would let this call `dataChannelOpened()` honestly; until then, one
    /// step covers the span the protocol cannot split, rather than two steps
    /// where the second is a lie about the first.
    func webSocketOpened() { advance(to: .securing) }

    /// Step 2 → 3, in isolation: exists as a real, distinct milestone —
    /// pinned by `testEachStepAdvancesOnItsRealMilestone` — for the day a
    /// protocol version gives the viewer its own frame for the relay's
    /// data-channel splice. **Not called by any production code path
    /// today.** `webSocketOpened()`'s doc comment explains why: there is no
    /// wire signal to call it from that would not be earlier than the fact
    /// it claims. `helloAcknowledged()` reaches `.confirming` (and past it)
    /// directly, on the one signal that genuinely proves both this step and
    /// the one before it are true.
    func dataChannelOpened() { advance(to: .confirming) }

    /// Step 3 → 4 — and, today, the step that also retires `.securing`.
    /// Called only from `SessionConnection.onStateChange`'s `.connected`,
    /// which `SessionConnection.handle(_:)` reaches only on an actual
    /// `HelloAck` frame — the lease is genuinely granted by the time this
    /// runs. Because production never calls `dataChannelOpened()` (see
    /// `webSocketOpened()`), `step` is still `.securing` when this runs;
    /// `advance(to: .loading)` moves it directly there, and
    /// `ConnectStep`'s ordering is what makes every row-rendering call site
    /// (`RemoteConnectCeremonyOverlayView.rowState`) read both `.securing`
    /// *and* `.confirming` as done in the same repaint — one honest label
    /// covering the span the protocol cannot yet split, checked only once
    /// the fact it stands for has actually happened.
    func helloAcknowledged() { advance(to: .loading) }

    /// Step 4 → done. Called once `WorkspaceWindowController
    /// .applyRestoredPanes` has actually turned the saved `layout` row into
    /// panes — the environment is on screen, not merely requested.
    func environmentLoaded() {
        advance(to: .done)
        onDone?()
    }

    /// One step failed. Stamps the ceremony's *own* current step onto
    /// `failure` rather than trusting the caller's — the test constructs
    /// `Failure(message:)` with nothing else, and which step was in flight
    /// is this type's business to know, not the caller's to restate.
    func failed(_ failure: Failure) {
        self.failure = Failure(step: step, message: failure.message, code: failure.code)
        onChange?()
    }

    /// Resets to `.dialling` for a fresh attempt. Two callers: **Try
    /// again**, pressed after a failure the user has to act on, and the
    /// automatic case behind the carried "reconnect retry" item —
    /// `SessionConnection`'s own backoff redials on its own for every
    /// refusal except version skew (`SessionConnectionError.isTerminalRefusal`'s
    /// doc comment), so `WorkspaceWindowController` calls this the moment
    /// `.connecting` fires *again*, with no button pressed at all. That is
    /// what turns "in use by ‹machine›" from a dead end into "say what it is
    /// doing, then keep going" — the ceremony genuinely starts over because
    /// the connection genuinely is dialling again, not because a timer said
    /// enough time had passed.
    func retry() {
        step = .dialling
        failure = nil
        onChange?()
    }

    private func advance(to newStep: ConnectStep) {
        step = newStep
        // A step that advances clears whatever the *previous* attempt
        // failed with — the same reasoning `retry()` follows, just reached
        // from a milestone instead of a button.
        failure = nil
        onChange?()
    }

    /// One step's refusal: which step it happened on, the daemon's own
    /// sentence (shown verbatim — never replaced with a generic message),
    /// and, when the failure went through `Hello`, its machine-readable
    /// code.
    struct Failure: Equatable {
        let step: ConnectStep
        let message: String
        /// `RefusalCode`'s raw wire value (`"lease_held"`, `"version_skew"`,
        /// …) — `nil` for a failure that never reached `Hello` (a plain
        /// socket error) or for a pre-Task-14 daemon. Never re-derived from
        /// `message`: `SessionConnectionError.helloRefused`'s doc comment
        /// explains why that would be a second, driftable copy of a
        /// classification `SessionConnection` already owns.
        let code: String?

        init(step: ConnectStep = .dialling, message: String, code: String? = nil) {
            self.step = step
            self.message = message
            self.code = code
        }

        /// Whether dialling again cannot fix this by itself —
        /// `SessionConnection.isTerminalRefusal`, read through rather than
        /// reimplemented, so the ceremony's card and the transport's own
        /// backoff can never disagree about which refusals are which. A
        /// failure the transport will keep retrying on its own (`false`
        /// here) is the one the overlay marks "Retrying…" rather than
        /// presenting as a dead end (spec §6, the carried reconnect-retry
        /// item).
        var isTerminal: Bool {
            SessionConnection.isTerminalRefusal(code, message: message)
        }
    }
}

/// The full-window glass `RemoteConnectCeremony` is shown through —
/// `PaneAskOverlayView`'s building blocks (`WorkspaceGlass`,
/// `PaneApprovalButton`), never `NSAlert` (standing repo rule), stretched to
/// the whole window in the same full-bleed, no-corner-radius treatment
/// `PaneZoomBackdropView` wears for focus mode: a takeover is the one moment
/// this window shows nothing of the environment it is about to replace.
final class RemoteConnectCeremonyOverlayView: NSView {
    /// Pressed after a failure — the controller re-dials.
    var onRetry: (() -> Void)?
    /// Pressed after a failure, or Esc at any time — the controller unwinds
    /// the takeover and takes this view down.
    var onCancel: (() -> Void)?

    private let ceremony: RemoteConnectCeremony
    private let scrim: NSView?
    private let mark = NSImageView()
    private let stepRows: [ConnectStep: StepRowView]
    private let messageLabel: NSTextField
    private let retryingLabel: NSTextField
    private let tryAgainButton: PaneApprovalButton
    private let cancelButton: PaneApprovalButton
    private var isAnswered = false

    init(ceremony: RemoteConnectCeremony) {
        self.ceremony = ceremony
        // Full-bleed, no corner radius — `PaneZoomBackdropView`'s focus-mode
        // treatment, the one other place this app puts glass over the whole
        // window rather than a card.
        scrim = WorkspaceGlass.sheet()
        mark.image = NSImage(named: "OmniAgentMark")
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.contentTintColor = NSColor(white: 1, alpha: 0.92)

        var rows: [ConnectStep: StepRowView] = [:]
        for step in ConnectStep.displayed { rows[step] = StepRowView() }
        stepRows = rows

        messageLabel = Self.label(
            "",
            font: ShellFont.ui(12.5),
            color: ShellPalette.red
        )
        messageLabel.alignment = .center
        messageLabel.maximumNumberOfLines = 3

        retryingLabel = Self.label(
            "Retrying…",
            font: ShellFont.ui(11.5),
            color: NSColor(white: 1, alpha: 0.55)
        )
        retryingLabel.alignment = .center

        tryAgainButton = PaneApprovalButton(title: "Try again", isPrimary: true, tint: PaneAskOverlayView.accent)
        cancelButton = PaneApprovalButton(title: "Cancel", isPrimary: false, tint: PaneAskOverlayView.accent)

        super.init(frame: .zero)
        wantsLayer = true
        tryAgainButton.onClick = { [weak self] in self?.pressTryAgain() }
        cancelButton.onClick = { [weak self] in self?.pressCancel() }

        var subviews: [NSView] = [scrim].compactMap { $0 }
        subviews += [mark]
        subviews += ConnectStep.displayed.map { stepRows[$0]! }
        subviews += [messageLabel, retryingLabel, tryAgainButton, cancelButton]
        for view in subviews { addSubview(view) }

        ceremony.onChange = { [weak self] in self?.render() }
        ceremony.onDone = { [weak self] in self?.animateOutOnDone() }
        render()

        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Connecting to \(ceremony.machineName)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        // 53 == Esc, no named AppKit constant (`WorkspaceWindow.escapeKeyCode`'s
        // own reasoning).
        if event.keyCode == 53 { pressCancel() } else { NSSound.beep() }
    }

    private func pressTryAgain() {
        guard ceremony.failure != nil else { return }
        onRetry?()
    }

    private func pressCancel() {
        guard !isAnswered else { return }
        isAnswered = true
        onCancel?()
    }

    // MARK: - Testing

    /// The production path is a click on `tryAgainButton`; a test has no
    /// window focus to synthesise one, `PaneAskOverlayView.choose(_:)`'s own
    /// reasoning.
    func pressTryAgainForTesting() { pressTryAgain() }
    func pressCancelForTesting() { pressCancel() }

    /// What one row is actually showing right now — the glyph state and the
    /// line's text — for the test that the four rows track `ceremony.step`/
    /// `.failure` rather than the view's own separate idea of them.
    func rowStateForTesting(_ step: ConnectStep) -> StepRowView.State? { stepRows[step]?.state }
    func rowTextForTesting(_ step: ConnectStep) -> String? { stepRows[step]?.text }

    /// The failure card's own facts — the message shown verbatim, whether
    /// the "Retrying…" caption is up (spec §6's carried reconnect-retry
    /// item), and whether Try again/Cancel are offered at all.
    var failureMessageForTesting: String { messageLabel.stringValue }
    var isShowingRetryingCaptionForTesting: Bool { !retryingLabel.isHidden }
    var areFailureButtonsShowingForTesting: Bool { !tryAgainButton.isHidden }

    // MARK: - Rendering

    /// Redraws every row from `ceremony.step`/`ceremony.failure` — the whole
    /// point of the view being driven by a model with no timer in it is that
    /// this is the only place any of it gets painted.
    private func render() {
        let current = ceremony.step
        let failure = ceremony.failure
        for step in ConnectStep.displayed {
            let row = stepRows[step]!
            row.apply(
                text: step.line(machineName: ceremony.machineName),
                state: Self.rowState(for: step, current: current, failure: failure)
            )
        }
        messageLabel.stringValue = failure?.message ?? ""
        messageLabel.isHidden = failure == nil
        retryingLabel.isHidden = failure?.isTerminal != false
        tryAgainButton.isHidden = failure == nil
        cancelButton.isHidden = failure == nil
        needsLayout = true
    }

    private static func rowState(
        for step: ConnectStep,
        current: ConnectStep,
        failure: RemoteConnectCeremony.Failure?
    ) -> StepRowView.State {
        if let failure, failure.step == step { return .failed }
        if current == .done { return .done }
        if step.rawValue < current.rawValue { return .done }
        if step == current { return .active }
        return .pending
    }

    /// `ceremony.onDone`: a green check is already on screen (the last
    /// `render()` before this ran put `.loading`'s row at `.done`), so this
    /// only has the ~400ms fade left — spec §6's "a green check, then fade
    /// out over ~400 ms into the loaded environment". Skips the animation
    /// under Reduce Motion but still calls back, so the overlay is taken
    /// down either way.
    private func animateOutOnDone() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            removeFromSuperview()
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOutDuration
            context.timingFunction = SidebarMotion.settle
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.removeFromSuperview()
        })
    }

    static let fadeOutDuration: TimeInterval = 0.4

    // MARK: - Layout

    private static let markSize: CGFloat = 40
    private static let rowSpacing: CGFloat = 14
    private static let blockWidth: CGFloat = 340

    override func layout() {
        super.layout()
        scrim?.frame = bounds
        let x = (bounds.width - Self.blockWidth) / 2
        var y = (bounds.height / 2) - Self.blockHeight / 2

        mark.frame = NSRect(x: bounds.midX - Self.markSize / 2, y: y, width: Self.markSize, height: Self.markSize)
        y += Self.markSize + 28

        for step in ConnectStep.displayed {
            let row = stepRows[step]!
            let height = row.preferredHeight(width: Self.blockWidth)
            row.frame = NSRect(x: x, y: y, width: Self.blockWidth, height: height)
            y += height + Self.rowSpacing
        }

        if !messageLabel.isHidden {
            let height = Self.height(of: messageLabel, width: Self.blockWidth)
            y += 6
            messageLabel.frame = NSRect(x: x, y: y, width: Self.blockWidth, height: height)
            y += height
        } else {
            messageLabel.frame = .zero
        }

        if !retryingLabel.isHidden {
            y += 4
            let height = Self.height(of: retryingLabel, width: Self.blockWidth)
            retryingLabel.frame = NSRect(x: x, y: y, width: Self.blockWidth, height: height)
            y += height
        } else {
            retryingLabel.frame = .zero
        }

        if !tryAgainButton.isHidden {
            y += 16
            let gap: CGFloat = 9
            let widths = [cancelButton, tryAgainButton].map { $0.intrinsicContentSize.width }
            let total = widths.reduce(0, +) + gap
            var bx = bounds.midX - total / 2
            for (button, buttonWidth) in zip([cancelButton, tryAgainButton], widths) {
                button.frame = NSRect(x: bx, y: y, width: buttonWidth, height: 26)
                bx += buttonWidth + gap
            }
        } else {
            tryAgainButton.frame = .zero
            cancelButton.frame = .zero
        }
    }

    /// The whole centred block's height, computed the same way `layout`
    /// walks it — needed up front to centre the block vertically rather than
    /// pinning it to the top.
    private static var blockHeight: CGFloat {
        // A conservative fixed estimate: the block's true height depends on
        // whether the failure rows are showing, which `layout` accounts for
        // by simply starting a little high when they are not — close enough
        // for a card that is, either way, vertically centred within a whole
        // window.
        markSize + 28 + CGFloat(ConnectStep.displayed.count) * (StepRowView.height + rowSpacing) + 90
    }

    private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        return field
    }

    private static func height(of field: NSTextField, width: CGFloat) -> CGFloat {
        let font = field.font ?? ShellFont.ui(13)
        let rect = (field.stringValue as NSString).boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        return ceil(rect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Only before macOS 26 — `PaneAskOverlayView`'s own reasoning: with
        // the glass panel present this would paint behind it for nothing.
        guard scrim == nil else { return }
        NSColor(srgbRed: 0.05, green: 0.06, blue: 0.10, alpha: 0.96).setFill()
        bounds.fill()
    }
}

/// One of the four rows: a status glyph and the step's line. `State` is a
/// pure fact about the ceremony, read straight off `RemoteConnectCeremony
/// .step`/`.failure` — the row itself holds nothing.
final class StepRowView: NSView {
    enum State: Equatable { case pending, active, done, failed }

    static let height: CGFloat = 20

    private let icon = NSImageView()
    private let label: NSTextField
    private(set) var state: State = .pending
    /// The text actually on screen, for the layout test.
    var text: String { label.stringValue }

    override init(frame frameRect: NSRect) {
        label = NSTextField(labelWithString: "")
        label.font = ShellFont.ui(13.5)
        label.lineBreakMode = .byTruncatingTail
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyUpOrDown
        addSubview(icon)
        addSubview(label)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func preferredHeight(width: CGFloat) -> CGFloat { Self.height }

    func apply(text: String, state: State) {
        self.state = state
        label.stringValue = text
        let (symbol, color, textAlpha): (String, NSColor, CGFloat) = {
            switch state {
            case .pending: return ("circle", NSColor(white: 1, alpha: 0.28), 0.45)
            case .active: return ("circle.dotted", ShellPalette.accentBright, 1)
            case .done: return ("checkmark.circle.fill", .systemGreen, 0.75)
            case .failed: return ("xmark.circle.fill", ShellPalette.red, 1)
            }
        }()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .semibold))
        icon.contentTintColor = color
        label.textColor = NSColor(white: 1, alpha: textAlpha)
        setAccessibilityLabel("\(text), \(Self.accessibilityDescription(for: state))")
        runSpinIfNeeded()
    }

    private static func accessibilityDescription(for state: State) -> String {
        switch state {
        case .pending: return "not started"
        case .active: return "in progress"
        case .done: return "done"
        case .failed: return "failed"
        }
    }

    /// The current step's glyph turns gently, the one piece of motion in the
    /// whole ceremony — never a substitute for a real milestone (the *step*
    /// it draws on is real; only the glyph's own rotation is decorative),
    /// and off entirely under Reduce Motion.
    private static let spinKey = "omniagent.ceremony.spin"

    private func runSpinIfNeeded() {
        icon.layer?.removeAnimation(forKey: Self.spinKey)
        guard state == .active, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        icon.wantsLayer = true
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -Double.pi * 2
        spin.duration = 1.1
        spin.repeatCount = .infinity
        icon.layer?.add(spin, forKey: Self.spinKey)
    }

    override func layout() {
        super.layout()
        icon.frame = NSRect(x: 0, y: (bounds.height - 16) / 2, width: 16, height: 16)
        label.frame = NSRect(x: 24, y: 0, width: max(0, bounds.width - 24), height: bounds.height)
    }
}
