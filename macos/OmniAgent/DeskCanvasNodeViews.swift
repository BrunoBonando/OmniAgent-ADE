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
}
