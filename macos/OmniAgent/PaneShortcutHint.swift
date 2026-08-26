import AppKit

/// The "which key jumps here" hint — a small glass card that fades in over a
/// pane's upper-middle while ⌘ is held, showing the ⌘-chord that focuses it
/// (`AppDelegate.swift`'s Panes menu, `PaneWorkspaceView.selectPane`). Driven
/// entirely by `PaneWorkspaceView`'s own `.flagsChanged` monitor — this view
/// never watches the keyboard itself, just shows and hides on command.
///
/// Purely a label: `hitTest` always returns `nil`, so it never takes a click
/// or a drag away from the pane underneath, and the chord it advertises
/// already works without it being on screen at all.
final class PaneShortcutHintView: NSView {
    /// ⌘ and the number sit side by side, like the chord reads — not stacked.
    static let width: CGFloat = 72
    static let height: CGFloat = 44
    private static let cardRadius: CGFloat = 16
    private static let symbolSize: CGFloat = 18
    private static let gap: CGFloat = 6
    private static let labelWidth: CGFloat = 22

    /// "1"…"9" or "0" — exactly the string `AppDelegate` gave the matching
    /// `NSMenuItem`'s `keyEquivalent`.
    let key: String

    private let glass: NSView?
    /// The "you're here" gradient — the pane accent above, this pane's own
    /// live status colour below. A separate tinted view in front of the
    /// glass rather than the glass's own `tintColor`, exactly
    /// `PaneAskOverlayView.cardTint`'s technique, and for the same reason:
    /// `tintColor` washes everything *behind* the glass, and this is a
    /// flourish on the card, not on the pane underneath it.
    private let chosenTint = NSView()
    private let chosenTintLayer = CAGradientLayer()
    private let symbol = NSImageView()
    private let keyLabel: NSTextField
    private var isShown = false

    init(key: String) {
        self.key = key
        keyLabel = Self.label(key)
        glass = WorkspaceGlass.sheet(cornerRadius: Self.cardRadius)
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: Self.height))
        wantsLayer = true
        alphaValue = 0
        isHidden = true
        symbol.image = NSImage(systemSymbolName: "command", accessibilityDescription: "Command")?
            .withSymbolConfiguration(.init(pointSize: Self.symbolSize, weight: .semibold))
        symbol.contentTintColor = NSColor(white: 1, alpha: 0.92)
        symbol.imageScaling = .scaleProportionallyUpOrDown
        chosenTint.wantsLayer = true
        chosenTint.alphaValue = 0
        chosenTint.layer?.addSublayer(chosenTintLayer)
        chosenTint.layer?.cornerRadius = Self.cardRadius
        chosenTint.layer?.cornerCurve = .continuous
        chosenTint.layer?.masksToBounds = true
        chosenTintLayer.startPoint = CGPoint(x: 0.5, y: 1)
        chosenTintLayer.endPoint = CGPoint(x: 0.5, y: 0)
        for view in [glass, chosenTint, symbol as NSView, keyLabel].compactMap({ $0 }) {
            addSubview(view)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    private static func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = ShellFont.ui(20, .semibold)
        field.textColor = NSColor(white: 1, alpha: 0.92)
        field.alignment = .center
        return field
    }

    override func layout() {
        super.layout()
        glass?.frame = bounds
        chosenTint.frame = bounds
        chosenTintLayer.frame = bounds
        // One centered group, icon then number — the two read as one chord.
        let groupWidth = Self.symbolSize + Self.gap + Self.labelWidth
        let groupX = bounds.midX - groupWidth / 2
        symbol.frame = NSRect(
            x: groupX,
            y: bounds.midY - Self.symbolSize / 2,
            width: Self.symbolSize,
            height: Self.symbolSize
        )
        keyLabel.frame = NSRect(
            x: groupX + Self.symbolSize + Self.gap,
            y: bounds.midY - 13,
            width: Self.labelWidth,
            height: 26
        )
    }

    /// Only before macOS 26, where there is no glass to ask for — same flat
    /// stand-in `PaneAskOverlayView.draw` uses.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard glass == nil else { return }
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: Self.cardRadius, yRadius: Self.cardRadius).fill()
        NSColor(white: 1, alpha: 0.16).setStroke()
        let ring = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: Self.cardRadius,
            yRadius: Self.cardRadius
        )
        ring.lineWidth = 1
        ring.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The one-second "you're here" flourish once ⌘N actually lands on this
    /// pane (`PaneWorkspaceView.selectPane`) — a gradient pulse in, a beat,
    /// then out. A pulse, not a state: it never changes whether the card
    /// itself is shown or hidden, only washes over it briefly.
    func pulseChosen(statusColor: NSColor) {
        chosenTintLayer.colors = [
            PaneAskOverlayView.accent.withAlphaComponent(0.55).cgColor,
            statusColor.withAlphaComponent(0.45).cgColor,
        ]
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            chosenTint.animator().alphaValue = 1
        }, completionHandler: { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.3
                    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                    self.chosenTint.animator().alphaValue = 0
                }
            }
        })
    }

    /// Fades the hint in or out — always animated, no instant-set path, the
    /// same idiom as `PaneZoomBackdropView.setShown`.
    func setShown(_ shown: Bool) {
        guard isShown != shown else { return }
        isShown = shown
        if shown { isHidden = false }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().alphaValue = shown ? 1 : 0
        }, completionHandler: { [weak self] in
            guard let self, !self.isShown else { return }
            self.isHidden = true
        })
    }
}
