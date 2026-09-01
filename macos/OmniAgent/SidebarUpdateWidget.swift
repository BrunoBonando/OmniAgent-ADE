import AppKit

/// The update card, directly above the session/week limits card at the foot of
/// the sidebar — the same sheet of liquid glass, the same 14pt radius, the same
/// 8pt inset, so the two read as one stack of cards rather than a card and a
/// row that happen to be near each other.
///
/// The whole self-update feature has one place to speak from, and this is it:
///
///     Update available -> Updating... (bar) -> Update ready, restart
///
/// Hidden when there is nothing to say, and hidden *properly*: it is an
/// arranged subview of the stack that holds it and the limits card, so
/// `isHidden` takes it out of the layout entirely instead of leaving a gap
/// above the gauges.
final class SidebarUpdateWidgetView: NSView {
    static let height: CGFloat = 56
    static let cornerRadius: CGFloat = 14

    /// Pressed while an update was available: start downloading.
    var onDownload: (() -> Void)?
    /// Pressed while an update was ready: restart into it.
    var onRestart: (() -> Void)?
    /// Pressed after a failure: try the check again.
    var onRetry: (() -> Void)?

    private let icon = NSImageView()
    private let titleField: NSTextField
    private let captionField: NSTextField
    private let bar = UpdateProgressBarView()
    /// The accent wash over the glass. A tint rather than a fill: the card is
    /// glass first, and the colour is what makes it read as *this* card.
    private let tint = NSView()
    /// A slow band of light crossing the card while an update is waiting to be
    /// taken — the one thing here that moves when nothing is happening, and
    /// the reason the card catches the eye without blinking at anyone.
    private let sheenHost = NSView()
    private let sheen = CAGradientLayer()
    private var isHovered = false
    /// The text block sits high only when the bar needs the lower half of the
    /// card. With no bar it centres, or the card reads as top-heavy with a
    /// band of dead glass under the caption.
    private var textTop: NSLayoutConstraint!
    private var textCentre: NSLayoutConstraint!

    private(set) var state: UpdateState = .idle

    override init(frame frameRect: NSRect) {
        titleField = ShellFont.label(
            "",
            font: ShellFont.ui(12.5, .semibold),
            color: ShellPalette.ink
        )
        captionField = ShellFont.label(
            "",
            font: ShellFont.ui(11),
            color: ShellPalette.inkSecondary
        )
        super.init(frame: frameRect)

        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // `SidebarClaudeLimitsView`'s treatment exactly — this is the same kind
        // of card sitting directly on top of it, and a second radius or fill
        // would read as two unrelated things.
        let glass = WorkspaceGlass.sheet(cornerRadius: Self.cornerRadius)
        if glass == nil {
            layer?.cornerRadius = Self.cornerRadius
            layer?.cornerCurve = .continuous
            layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
            layer?.borderWidth = 1
            layer?.borderColor = ShellPalette.hairlineStrong.cgColor
        }

        for host in [tint, sheenHost] {
            host.wantsLayer = true
            host.translatesAutoresizingMaskIntoConstraints = false
            host.layer?.cornerRadius = Self.cornerRadius
            host.layer?.cornerCurve = .continuous
            host.layer?.masksToBounds = true
        }
        // Clear at both ends so the band has no edges of its own — light
        // moving under the glass, not a rectangle sliding across it.
        sheen.colors = [
            NSColor(white: 1, alpha: 0).cgColor,
            NSColor(white: 1, alpha: 0.16).cgColor,
            NSColor(white: 1, alpha: 0).cgColor,
        ]
        sheen.startPoint = CGPoint(x: 0, y: 0.5)
        sheen.endPoint = CGPoint(x: 1, y: 0.5)
        sheen.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        sheen.opacity = 0
        sheenHost.layer?.addSublayer(sheen)

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let text = NSStackView(views: [titleField, captionField])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false

        for view in [glass, tint, sheenHost, icon, text, bar].compactMap({ $0 }) { addSubview(view) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),

            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 13),
            // Aligned to the title's own line rather than the card's top edge,
            // so it stays on the words when the block moves.
            icon.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 17),
            icon.heightAnchor.constraint(equalToConstant: 17),

            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),

            bar.leadingAnchor.constraint(equalTo: icon.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -13),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
        for host in [tint, sheenHost] {
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: leadingAnchor),
                host.trailingAnchor.constraint(equalTo: trailingAnchor),
                host.topAnchor.constraint(equalTo: topAnchor),
                host.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
        if let glass {
            glass.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        textTop = text.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        textCentre = text.centerYAnchor.constraint(equalTo: centerYAnchor)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        apply(.idle)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// What the card says right now — the facts tests assert on, since the
    /// words are the entire point of the view.
    var titleText: String { titleField.stringValue }
    var captionText: String { captionField.stringValue }
    /// Whether the band of light is running. Off in every resting state, and
    /// off entirely under Reduce Motion.
    var isSheenAnimating: Bool { sheen.animation(forKey: Self.sheenKey) != nil }

    // MARK: - State

    func apply(_ state: UpdateState) {
        let wasVisible = self.state.isVisible
        self.state = state
        isHidden = !state.isVisible

        switch state {
        case .idle:
            break
        case .checking:
            set("arrow.triangle.2.circlepath", "Checking for updates", "Asking dl.omni-agent.ai")
        case let .available(version):
            set("arrow.down.circle.fill", "Update available", "Version \(version) — click to download")
        case let .updating(fraction):
            let percent = fraction.map { " \(Int($0 * 100))%" } ?? ""
            set("arrow.down.circle.fill", "Updating\(percent)", "")
        case let .readyToRestart(version):
            let named = version.isEmpty ? "Restart to apply" : "Version \(version) — restart to apply"
            set("checkmark.circle.fill", "Update ready", named)
        case let .failed(message):
            set("exclamationmark.triangle.fill", "Update failed", message)
        }

        // The bar takes the caption's place rather than crowding in beside it:
        // while it is running, the percentage is already in the title.
        let updating = { if case .updating = state { return true }; return false }()
        bar.isHidden = !updating
        captionField.isHidden = updating
        textTop.isActive = updating
        textCentre.isActive = !updating
        if case let .updating(fraction) = state { bar.setFraction(fraction) }

        applyPalette()
        if !wasVisible && state.isVisible { animateIn() }
        refreshSheen()
    }

    private func set(_ symbol: String, _ title: String, _ caption: String) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        titleField.stringValue = title
        captionField.stringValue = caption
        setAccessibilityLabel(caption.isEmpty ? title : "\(title). \(caption)")
    }

    /// Failure is the one state that is not the app's accent: a red card is how
    /// it reads as a problem rather than an offer.
    private var accent: NSColor {
        if case .failed = state { return ShellPalette.red }
        return ShellPalette.accent
    }

    private func applyPalette() {
        icon.contentTintColor = { if case .failed = state { return ShellPalette.red }
                                  return ShellPalette.accentBright }()
        bar.fillColor = ShellPalette.accentBright
        // Hover lifts the wash rather than adding a second surface — there is
        // already glass here, and stacking another fill on it reads as murk.
        let strength: CGFloat = isHovered ? 0.26 : 0.17
        tint.layer?.backgroundColor = accent.withAlphaComponent(strength).cgColor
    }

    // MARK: - Motion

    private static let sheenKey = "omniagent.update.sheen"

    /// The band runs only in the two states that are waiting on the user, and
    /// never under Reduce Motion. A card that is already working, or that has
    /// nothing to ask for, does not need to catch anybody's eye.
    private var wantsSheen: Bool {
        switch state {
        case .available, .readyToRestart: return !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        case .idle, .checking, .updating, .failed: return false
        }
    }

    private func refreshSheen() {
        guard wantsSheen, window != nil else {
            sheen.removeAnimation(forKey: Self.sheenKey)
            sheen.opacity = 0
            return
        }
        guard sheen.animation(forKey: Self.sheenKey) == nil else { return }
        sheen.opacity = 1
        layoutSheen()
        let travel = CAKeyframeAnimation(keyPath: "position.x")
        let width = max(bounds.width, 1)
        // Off one edge, across, off the other — then held there for most of the
        // cycle. The pause is the difference between a card that glints
        // occasionally and one that strobes.
        travel.values = [-width * 0.4, width * 1.4, width * 1.4]
        travel.keyTimes = [0, 0.35, 1]
        travel.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(name: .linear),
        ]
        travel.duration = 4.2
        travel.repeatCount = .infinity
        sheen.add(travel, forKey: Self.sheenKey)
    }

    /// Fade and rise as the card takes its place, so it arrives rather than
    /// appears. `SidebarMotion.settle` is the curve the cards below it use.
    private func animateIn() {
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.34
            context.timingFunction = SidebarMotion.settle
            animator().alphaValue = 1
        }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -6
        rise.toValue = 0
        rise.duration = 0.34
        rise.timingFunction = SidebarMotion.settle
        layer?.add(rise, forKey: "omniagent.update.rise")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refreshSheen()
    }

    override func layout() {
        super.layout()
        layoutSheen()
    }

    private func layoutSheen() {
        // A raw CALayer gets no constraints, and the band is deliberately
        // taller and narrower than the card — it is a diagonal of light, not a
        // stripe, so it needs room to be rotated inside the rounded clip.
        sheen.bounds = CGRect(x: 0, y: 0, width: max(bounds.width * 0.45, 1), height: bounds.height * 2.2)
        sheen.position = CGPoint(x: sheen.position.x, y: bounds.midY)
        sheen.transform = CATransform3DMakeRotation(-0.32, 0, 0, 1)
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyPalette()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyPalette()
    }

    override func mouseDown(with event: NSEvent) {
        press()
    }

    /// Internal rather than private so a test can press the card without
    /// synthesising a click — the sidebar's own cards do the same.
    func press() {
        switch state {
        case .available: onDownload?()
        case .readyToRestart: onRestart?()
        case .failed: onRetry?()
        // Checking and updating are not buttons. Pressing during a download
        // should not cancel it by accident -- there is nothing here the user
        // can usefully do until it finishes.
        case .idle, .checking, .updating: break
        }
    }
}

/// The card's own progress bar, in `SidebarPercentBarView`'s visual language —
/// same 5pt height, same rounded track, same white-12% ground.
///
/// Not that class reused: its fill colour ramps green → amber → red with the
/// value, which is right for "how much of your quota is gone" and exactly
/// wrong here, where arriving at 100% is the good outcome.
final class UpdateProgressBarView: NSView {
    static let height: CGFloat = 5

    private let track = CALayer()
    private let fill = CALayer()
    /// nil means indeterminate — the server has not said how big the download
    /// is yet, so the bar breathes instead of sitting at zero, which reads as
    /// stuck.
    private(set) var fraction: Double?

    var fillColor: NSColor = ShellPalette.accentBright {
        didSet { fill.backgroundColor = fillColor.cgColor }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        track.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        track.cornerRadius = Self.height / 2
        fill.cornerRadius = Self.height / 2
        // Pinned by its left edge, so growing is a change to one property
        // rather than a frame change that has to move `position` in step.
        fill.anchorPoint = CGPoint(x: 0, y: 0.5)
        fill.backgroundColor = fillColor.cgColor
        layer?.addSublayer(track)
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: Self.height).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    /// The fill's drawn width, for tests — the presentation layer does not
    /// advance under `xcodebuild test`, so the model layer is the fact.
    var fillWidth: CGFloat { fill.bounds.width }

    func setFraction(_ fraction: Double?) {
        self.fraction = fraction
        needsLayout = true
        layoutSubtreeIfNeeded()
        setAccessibilityValue(fraction.map { Int($0 * 100) } ?? 0)
    }

    override func layout() {
        super.layout()
        track.frame = bounds
        fill.position = CGPoint(x: 0, y: bounds.midY)
        let full = bounds.width
        // Indeterminate draws a short travelling nub; a determinate reading
        // draws itself, with a minimum nub so 0% is visible as "none of it"
        // rather than as a broken empty track.
        let width: CGFloat
        if let fraction {
            width = max(Self.height, full * CGFloat(min(1, max(0, fraction))))
        } else {
            width = full * 0.3
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        CATransaction.setAnimationTimingFunction(SidebarMotion.settle)
        fill.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
    }
}
