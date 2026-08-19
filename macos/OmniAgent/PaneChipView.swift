import AppKit

/// A pane, drawn small enough to be worth drawing at all.
///
/// Below `DeskCanvas.lodThreshold` a pane's surface carries no information —
/// at 0.2 a 12pt glyph is 2.4pt — so the surface comes down and this takes its
/// place: the engine's mark, the pane's name, and the status dot.
///
/// A **fourth sibling** of the container's header/surface/approvalBar rather
/// than a replacement surface. `PaneContainerView.surface` is
/// `let surface: any PaneContentView`, and a live terminal swapped out of the
/// view tree is one that has to be rebuilt — with its scrollback — to come
/// back.
///
/// Drawn rather than composed, the way `PaneHolePlaceholderView` is: three
/// pieces of static content in a box whose size changes with the camera, where
/// three subviews would each need their own frame maths for nothing.
final class PaneChipView: NSView {
    /// Everything here is a fraction of the chip's own box, never a point
    /// size. The camera scales the whole card, so a fixed 12pt label is 1.8pt
    /// on screen at the scale this view exists for — the same trap the surface
    /// it replaces falls into.
    private static let iconFraction: CGFloat = 0.30
    private static let titleFraction: CGFloat = 0.17
    private static let dotFraction: CGFloat = 0.11
    private static let gapFraction: CGFloat = 0.07

    var title = "" {
        didSet {
            guard title != oldValue else { return }
            needsDisplay = true
        }
    }

    /// `nil` for a browser or an editor. Both carry `.shell` as a placeholder
    /// engine, and a chip showing that badge would claim the pane runs
    /// something it does not — the header already refuses it for this reason.
    var engine: Engine? {
        didSet {
            guard engine != oldValue else { return }
            needsDisplay = true
        }
    }

    var status: RemoteSessionStatus? {
        didSet {
            guard status != oldValue else { return }
            needsDisplay = true
        }
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = PaneContainerView.paneBackgroundColor.cgColor
        // The container's own accessibility label already names this pane; a
        // second element for the same pane is noise to a screen reader.
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Matching `PaneContainerView` and `PaneBadgeView`, both flipped — the
    /// icon draw below is the same call `PaneBadgeView` makes in a flipped view.
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard bounds.width > 2, bounds.height > 2 else { return }
        let unit = min(bounds.width, bounds.height)
        let iconSide = unit * Self.iconFraction
        let dot = unit * Self.dotFraction
        let gap = bounds.height * Self.gapFraction
        let font = NSFont.systemFont(ofSize: max(1, bounds.height * Self.titleFraction), weight: .medium)
        let textHeight = font.boundingRectForFont.height
        var y = max(0, (bounds.height - (iconSide + gap + textHeight + gap + dot)) / 2)

        if let image = engine?.iconImage {
            image.tinted(engine?.badgeForeground ?? .labelColor).draw(
                in: NSRect(x: (bounds.width - iconSide) / 2, y: y, width: iconSide, height: iconSide)
            )
        }
        y += iconSide + gap

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail
        (title as NSString).draw(
            in: NSRect(x: gap, y: y, width: max(0, bounds.width - gap * 2), height: textHeight),
            withAttributes: [
                .font: font,
                .foregroundColor: NSColor(white: 1, alpha: 0.82),
                .paragraphStyle: paragraph,
            ]
        )
        y += textHeight + gap

        // Literally the sidebar's own mapping, through the same door the pane
        // header's mark uses — a session that reads amber in the tree has to
        // read amber on its chip.
        PaneStatusMarkView.color(for: status).setFill()
        NSBezierPath(
            ovalIn: NSRect(x: (bounds.width - dot) / 2, y: y, width: dot, height: dot)
        ).fill()
    }
}
