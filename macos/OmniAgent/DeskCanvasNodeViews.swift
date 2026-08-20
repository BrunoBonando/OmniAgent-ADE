import AppKit

/// Every connector of the desk organigram, as one path on one `CAShapeLayer`.
///
/// One layer rather than one per edge: an account, a handful of workspaces and
/// up to eight sessions is a few dozen edges, and a few dozen sublayers is a few
/// dozen composites on every frame of a pinch. A single path is one.
///
/// A sublayer of `PaneWorkspaceView.layer`, so the camera's `sublayerTransform`
/// carries it for free — which is also why `lineWidth` has to be divided back
/// out; see `apply(_:scale:)`.
final class DeskCanvasEdgeLayer: CAShapeLayer {
    /// The stroke in **view** points, before the camera multiplies it.
    static let strokeWidth: CGFloat = 1

    override init() {
        super.init()
        fillColor = nil
        strokeColor = ShellPalette.inkFainter.cgColor
        lineWidth = Self.strokeWidth
        // The elbows are straight segments; a round join is what makes them read
        // as a connector rather than as two lines that happened to meet.
        lineJoin = .round
        lineCap = .round
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    /// Required by Core Animation: it copies a layer through this initializer to
    /// build the presentation layer, and a subclass that does not implement it
    /// gets a copy with none of its own state.
    override init(layer: Any) {
        super.init(layer: layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// `CAShapeLayer` animates `path` and `lineWidth` implicitly, and the camera
    /// changes `lineWidth` on every frame of a pinch — an implicit 0.25s
    /// animation per frame is a queue the eye reads as lag, and the path would
    /// lerp between two unrelated shapes on every relayout.
    override func action(forKey event: String) -> CAAction? { NSNull() }

    /// Rebuilds the connectors, and compensates the stroke for the camera.
    ///
    /// The camera is a `sublayerTransform`, so a 1pt stroke is 0.2pt at
    /// `fitAll` — under one device pixel, a line that fades out exactly when the
    /// tree is the only thing being looked at. The width is therefore set in view
    /// points and divided by the scale the transform will multiply it by.
    func apply(_ layout: DeskCanvasLayout, scale: CGFloat) {
        path = Self.path(for: layout)
        lineWidth = scale > 0 ? Self.strokeWidth / scale : Self.strokeWidth
    }

    /// Pure and static so the geometry can be checked without a window — the
    /// same reason `PaneWorkspaceView.focusCardFrame(in:)` is.
    ///
    /// Canvas space is FLIPPED (`PaneWorkspaceView.isFlipped == true`, y growing
    /// downward), so a parent's `maxY` is its bottom edge and its children sit at
    /// larger y. An edge whose endpoints the layout does not hold is skipped.
    static func path(for layout: DeskCanvasLayout) -> CGPath {
        let path = CGMutablePath()
        for edge in layout.edges {
            guard
                let from = layout.frames[edge.from],
                let to = layout.frames[edge.to]
            else { continue }
            let start = CGPoint(x: from.midX, y: from.maxY)
            let end = CGPoint(x: to.midX, y: to.minY)
            let waist = (start.y + end.y) / 2
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x, y: waist))
            path.addLine(to: CGPoint(x: end.x, y: waist))
            path.addLine(to: end)
        }
        return path
    }
}

/// One node of the organigram that is not a session card: the `You` account
/// node and a workspace node.
///
/// The two differ only in what they carry, so they are one view with one
/// `Role`, the way `ShellTileView` serves the sidebar's 34pt workspace card and
/// its 22pt account avatar from one class.
///
/// The per-pane level-of-detail chip is deliberately **not** a role here:
/// `PaneChipView` owns it, because it lives inside `PaneContainerView` as a
/// fourth sibling and has to be threaded through `applyLayout()` and
/// `roundChildren(inside:)` — constraints this class does not share, and a
/// second class drawing the same thing is how the two drift.
///
/// Frame-driven and proportional. `DeskCanvas.layout` owns every rect
/// (`chipWidthFraction` of a session card's width), and every size below is a
/// fraction of `bounds` — a fixed 13pt label would be 2pt of screen at fit-all,
/// which is the only zoom where these are the thing being read.
///
/// Drawn in `draw(_:)` rather than composed from `NSTextField`s: a chip is four
/// shapes and two strings, it never takes a click (`PaneWorkspaceView.hitTest`
/// answers for the whole canvas below identity scale), and one `draw(_:)` is one
/// layer to composite instead of five.
final class DeskCanvasChipView: NSView {
    enum Role: Equatable {
        /// `You` — a circular avatar over a name.
        case account
        /// A workspace — the gradient tile, the name, and a session count.
        case workspace
    }

    let role: Role

    /// The keyboard selection ring. A stroke change only: the arrows walk the
    /// selection and a relayout per keypress is not free.
    var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            needsDisplay = true
        }
    }

    private var title = ""
    private var detail: String?
    private var tint: (NSColor, NSColor)?
    /// Carried but not drawn: neither of the two roles has a status of its own —
    /// a workspace's is the sum of its sessions', and each session already draws
    /// its own. It stays in `apply(...)`'s signature because a session-level
    /// role is the obvious next one, and a chip that has to be rebuilt to gain a
    /// field is a chip that loses its selection ring mid-arrow-walk.
    private var status: RemoteSessionStatus?

    init(role: Role) {
        self.role = role
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is unavailable")
    }

    /// Flipped, like the canvas it sits in — `PaneWorkspaceView.isFlipped` is
    /// `true` and the node rects are in that space.
    override var isFlipped: Bool { true }

    func apply(
        title: String,
        detail: String?,
        tint: (NSColor, NSColor)?,
        status: RemoteSessionStatus?
    ) {
        self.title = title
        self.detail = detail
        self.tint = tint
        self.status = status
        needsDisplay = true
    }

    /// The chip's geometry, as one pure function of its bounds so it can be
    /// checked without a window — the same reason
    /// `DeskCanvasEdgeLayer.path(for:)` is static.
    ///
    /// Every size is a fraction of one `unit`, and the unit is capped by the
    /// **width**: a chip is `DeskCanvas.chipSize(forCard:)`, the card at 0.25,
    /// so it carries the Desk viewport's own aspect — around 1.6:1, not the
    /// 2.5:1 box these constants were first tuned against. Deriving them from
    /// the height alone put a 54pt title in a 135pt column and truncated every
    /// workspace name to "Om…", which the offscreen render caught and no
    /// assertion did; `testAWorkspaceNameFitsTheColumnTheLayoutActuallyGivesIt`
    /// is the assertion now.
    struct Metrics {
        let unit: CGFloat
        let cornerRadius: CGFloat
        let body: NSRect
        let tile: NSRect
        let title: NSRect
        let detail: NSRect
        let titleFont: NSFont
        let detailFont: NSFont
    }

    static func metrics(in bounds: NSRect, hasDetail: Bool) -> Metrics {
        let unit = min(bounds.height, bounds.width * 0.34)
        let inset = unit * 0.18
        let tileSide = unit * 0.46
        let tile = NSRect(
            x: inset,
            y: (bounds.height - tileSide) / 2,
            width: tileSide,
            height: tileSide
        )
        let textX = tile.maxX + inset * 0.75
        let textWidth = max(0, bounds.width - textX - inset)
        let titleHeight = unit * 0.30
        let detailHeight = unit * 0.26
        let block = hasDetail ? titleHeight + detailHeight : titleHeight
        let top = (bounds.height - block) / 2
        return Metrics(
            unit: unit,
            cornerRadius: unit * 0.18,
            body: bounds.insetBy(dx: unit * 0.03, dy: unit * 0.03),
            tile: tile,
            title: NSRect(x: textX, y: top, width: textWidth, height: titleHeight),
            detail: NSRect(x: textX, y: top + titleHeight, width: textWidth, height: detailHeight),
            titleFont: ShellFont.ui(unit * 0.24, .semibold),
            detailFont: ShellFont.ui(unit * 0.19, .regular)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.height > 0, bounds.width > 0 else { return }
        let hasDetail = detail?.isEmpty == false
        let metrics = Self.metrics(in: bounds, hasDetail: hasDetail)

        let body = NSBezierPath(
            roundedRect: metrics.body,
            xRadius: metrics.cornerRadius,
            yRadius: metrics.cornerRadius
        )
        ShellPalette.cardFill.setFill()
        body.fill()
        (isSelected ? ShellPalette.accent : ShellPalette.cardStroke).setStroke()
        body.lineWidth = metrics.unit * (isSelected ? 0.035 : 0.014)
        body.stroke()

        drawLeading(in: metrics.tile)

        guard metrics.title.width > 0 else { return }
        draw(title, in: metrics.title, font: metrics.titleFont, color: ShellPalette.ink)
        if let detail, hasDetail {
            draw(detail, in: metrics.detail, font: metrics.detailFont, color: ShellPalette.inkTertiary)
        }
    }

    private func draw(
        _ text: String,
        in rect: NSRect,
        font: NSFont,
        color: NSColor,
        centred: Bool = false
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = centred ? .center : .left
        NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]).draw(in: rect)
    }

    /// The account's avatar is a circle and a workspace's tile is a rounded
    /// square — the same two shapes the sidebar already uses for the same two
    /// things.
    private func drawLeading(in rect: NSRect) {
        switch role {
        case .account, .workspace:
            let path = role == .account
                ? NSBezierPath(ovalIn: rect)
                : NSBezierPath(roundedRect: rect, xRadius: rect.height * 0.28, yRadius: rect.height * 0.28)
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            let colours = tint ?? (ShellPalette.accent, ShellPalette.accent)
            // 150° in the design's CSS runs top-left to bottom-right;
            // `NSGradient`'s angle is counter-clockwise from east, which puts the
            // same ramp at -60 — exactly as `ShellTileView` does it.
            NSGradient(starting: colours.0, ending: colours.1)?.draw(in: rect, angle: -60)
            NSGraphicsContext.restoreGraphicsState()
            draw(
                ShellPalette.initials(title),
                in: rect.insetBy(dx: 0, dy: rect.height * 0.3),
                font: ShellFont.ui(rect.height * 0.4, .bold),
                color: .white,
                centred: true
            )
        }
    }
}
