import AppKit

/// One card in the filmstrip's rail: the OmniAgent mark, the pane's name, and
/// a wash of whatever its agent is doing.
///
/// **Not a picture of the pane.** The rail used to seat the pane containers
/// themselves, drawn small — which meant the pane you were reading had to leave
/// the rail to be shown, and the strip shuffled under the pointer every time
/// you picked something. A card is a *stand-in*, so every pane keeps its place
/// in the strip whether or not it is the one on screen, and the selected one is
/// marked rather than removed (founder brief, 2026-08-20).
///
/// **Fixed metrics, deliberately.** Everything here is a point size: the card
/// is `PaneFilmstrip.itemHeight` tall whatever the window is doing, the mark is
/// 16pt and the label is 12pt. `PaneChipView`, the canvas's miniature, is the
/// opposite — every measurement there is a fraction of its own box, because the
/// camera scales it. This is never scaled, so a fraction would only make the
/// text change size with the window for no reason.
///
/// **The OmniAgent mark, not the engine's.** Which agent is driving shows up
/// as a word under the name; the icon is the product's own, tinted and pulsed
/// by status (`PaneStatusMarkView`), so a rail of eight reads as *what is
/// happening* at a glance rather than as a column of vendor badges.
final class PaneFilmstripItemView: NSView {
    let paneID: String

    /// Raised on a click. The workspace answers by focusing that pane, which is
    /// the only thing selecting a card can mean.
    var onSelect: ((String) -> Void)?

    static let cornerRadius: CGFloat = 9
    private static let inset: CGFloat = 11
    private static let markSize: CGFloat = 16
    private static let labelSize: CGFloat = 12
    private static let detailSize: CGFloat = 10.5
    private static let labelHeight: CGFloat = 16
    private static let detailHeight: CGFloat = 14
    private static let gap: CGFloat = 9

    /// The card's own ground, one step lighter than the pane body behind it, so
    /// a rail of cards reads as a list rather than as holes cut in the window.
    private static let background = NSColor(white: 1, alpha: 0.045)
    private static let selectedBackground = NSColor(white: 1, alpha: 0.085)
    private static let idleBorder = NSColor(white: 1, alpha: 0.07)
    private static let labelColor = NSColor(white: 1, alpha: 0.9)
    private static let detailColor = NSColor(white: 1, alpha: 0.45)

    /// How much of the status colour the wash carries, unselected and selected.
    /// A gradient rather than a fill: at a flat tint the rail reads as a stack
    /// of coloured blocks and the eye stops being able to find the one that is
    /// actually selected.
    private static let washAlpha: CGFloat = 0.16
    private static let selectedWashAlpha: CGFloat = 0.34

    /// Where the text block sits, centred in whatever height the card has.
    private static var contentHeight: CGFloat { labelHeight + detailHeight }

    /// What the wash and the ring are coloured by: the agent's status, which is
    /// the whole point of the rail — except that "ready" has no colour of its
    /// own, and a selected card has to be findable whatever its pane is doing.
    /// Idle and selected therefore falls back to the accent the focused pane's
    /// own ring wears, so the two sides of the seam agree.
    private var washTint: NSColor {
        if status == nil, isSelected { return PaneContainerView.focusedBorderColor }
        return PaneStatusMarkView.color(for: status)
    }

    private let mark = PaneStatusMarkView()

    var title = "" {
        didSet {
            guard title != oldValue else { return }
            setAccessibilityLabel(title)
            needsDisplay = true
        }
    }

    /// The pane's engine, printed under the name — "Claude Code", "Shell".
    var detail = "" {
        didSet {
            guard detail != oldValue else { return }
            needsDisplay = true
        }
    }

    var status: RemoteSessionStatus? {
        didSet {
            guard status != oldValue else { return }
            mark.status = status
            needsDisplay = true
        }
    }

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
        }
    }

    init(paneID: String) {
        self.paneID = paneID
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        addSubview(mark)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    override var isFlipped: Bool { true }

    private var contentTop: CGFloat {
        ((bounds.height - Self.contentHeight) / 2).rounded()
    }

    override func layout() {
        super.layout()
        // On the name's own line, centred against it.
        mark.frame = CGRect(
            x: Self.inset,
            y: contentTop + ((Self.labelHeight - Self.markSize) / 2).rounded(),
            width: Self.markSize,
            height: Self.markSize
        )
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(paneID)
    }

    override func draw(_ dirtyRect: NSRect) {
        let body = bounds
        let path = NSBezierPath(
            roundedRect: body,
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        (isSelected ? Self.selectedBackground : Self.background).setFill()
        path.fill()

        // The wash: the status colour strongest at the leading edge and gone by
        // the far side. Clipped to the card and drawn under the text, so the
        // name stays legible whatever the agent is doing.
        let tint = washTint
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colors: [
            tint.withAlphaComponent(isSelected ? Self.selectedWashAlpha : Self.washAlpha),
            tint.withAlphaComponent(0),
        ])?.draw(in: body, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        // The ring. Selected wears the status colour at full strength — the
        // rule the focused pane's own ring follows, so "which one am I looking
        // at" is answered the same way on both sides of the seam.
        let ring = NSBezierPath(
            roundedRect: body.insetBy(dx: 0.75, dy: 0.75),
            xRadius: Self.cornerRadius - 0.75,
            yRadius: Self.cornerRadius - 0.75
        )
        (isSelected ? tint.withAlphaComponent(0.9) : Self.idleBorder).setStroke()
        ring.lineWidth = isSelected ? 1.5 : 1
        ring.stroke()

        let textX = Self.inset + Self.markSize + Self.gap
        let width = max(0, body.width - textX - Self.inset)
        guard width > 0 else { return }
        (title as NSString).draw(
            in: CGRect(x: textX, y: contentTop, width: width, height: Self.labelHeight),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: Self.labelSize, weight: .medium),
                .foregroundColor: Self.labelColor,
            ]
        )
        guard !detail.isEmpty else { return }
        (detail as NSString).draw(
            in: CGRect(
                x: textX,
                y: contentTop + Self.labelHeight,
                width: width,
                height: Self.detailHeight
            ),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: Self.detailSize, weight: .regular),
                .foregroundColor: Self.detailColor,
            ]
        )
    }
}
