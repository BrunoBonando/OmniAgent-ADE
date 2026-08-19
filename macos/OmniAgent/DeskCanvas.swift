import Foundation
import QuartzCore

/// The Desk organigram — `You → Workspace → Sessions` — and the tidy tree that
/// arranges it. Pure value types: no AppKit view code, no layer, no window,
/// testable exactly the way `PaneGrid` is.
///
/// **Shape of the unit.** `PaneWorkspaceView` in canvas mode asks for one
/// `DeskCanvasLayout` and lays each session's `PaneGrid` out inside the rect
/// this names for that group; the chip views draw the `root`/`workspace` nodes
/// at theirs, and the edge layer strokes `edges` as one path. Nothing here
/// knows about zoom: the camera is a `sublayerTransform` applied on top of
/// these frames, so a camera move changes no frame and therefore costs no PTY
/// resize.
///
/// **Coordinates are the workspace view's own FLIPPED space, y growing
/// downward.** `PaneWorkspaceView.isFlipped` is `true` and the window is not —
/// the same distinction `PaneDividerView.mouseDragged` already turns on: "The
/// workspace view is flipped, the window is not: a downward drag is a *smaller*
/// window y but a *larger* workspace y." Every rect produced here obeys it: the
/// root node has the smallest `minY` and each level down the tree a larger one.
/// Pinned positions and the camera origin are defined in this same space and in
/// no other.
///
/// **Node ids are unique across the tree.** `frames` is keyed by id, and a
/// session node's id IS the group id the rest of the app uses
/// (`PaneDescriptor.group`, `PaneWorkspaceView.activeGroup`), so two nodes
/// sharing an id would collapse onto one frame.
struct DeskNode: Equatable {
    /// What the node draws as, and how big it is. `session` carries the group
    /// id used everywhere else in the app; `workspace` carries the project id.
    /// The Desk level is deliberately folded into the workspace node
    /// (`OmniAgent-ADE › Desk`) — it is 1:1 with Workspace and as its own level
    /// would only make the tree taller.
    enum Kind: Equatable {
        case root
        case workspace(String)
        case session(String)
    }

    let id: String
    let kind: Kind
    let children: [DeskNode]
}

/// One connector, parent to child. Pinned children keep theirs — dragging a
/// node off the tidy tree does not cut it out of the organigram.
struct DeskEdge: Equatable {
    let from: String   // node id
    let to: String     // node id
}

/// Node frames in the canvas's own coordinate space, which is FLIPPED
/// (`PaneWorkspaceView.isFlipped == true`), y growing downward.
struct DeskCanvasLayout: Equatable {
    let frames: [String: CGRect]
    let edges: [DeskEdge]
    /// Union of every frame — what `DeskCamera.fitAll` fits. Never `.null`:
    /// a tree always has at least its root, and a zero rect would make the fit
    /// scale meaningless.
    let contentRect: CGRect
}

/// The canvas camera: a uniform scale and a translation, applied as one
/// `CATransform3D` on `PaneWorkspaceView.layer.sublayerTransform`. It touches
/// no frame, so every container's frame stays in canvas coordinates and
/// nothing downstream learns about zoom.
///
/// **Coordinates.** Canvas space *is* the view's space, which is flipped —
/// `PaneWorkspaceView`'s `override var isFlipped: Bool { true }`, "Row 0 on
/// top, matching `PaneGrid.layout(in:dividerThickness:)`" — and AppKit flips
/// the backing layer's geometry to match ("this view is flipped, so AppKit
/// flips its backing layer's geometry to match"). y grows downward on both
/// sides of the transform, so nothing here inverts an axis.
///
/// **Direction.** `viewPoint = canvasPoint * scale + origin`, with
/// `canvasPoint(from:)` its exact inverse. `transform` scales *then*
/// translates, so `m41`/`m42` are `origin` unscaled — which assumes the
/// layer it is installed on anchors at its corner. That anchor was verified
/// rather than assumed, and it holds: `sublayerTransform` pivots about the
/// parent layer's **anchor point** (measured — a sublayer at 100 under a 0.5
/// scale renders at 50 with an anchor of `(0, 0)` and at 350 with
/// `(0.5, 0.5)`, and `isGeometryFlipped` does not change it), and AppKit gives
/// a layer-backed `NSView` an anchor of `(0, 0)` with `position` at the
/// frame's origin — *not* UIKit's centred default. So
/// `PaneWorkspaceView.applyCamera()` installs `camera.transform` unchanged.
/// Both halves are asserted in `PaneWorkspaceCanvasModeTests`; if either ever
/// changes, `applyCamera()` has to compose the recentring itself.
struct DeskCamera: Equatable {
    var scale: CGFloat
    var origin: CGPoint

    /// The ceiling, and there is nothing above it. SwiftTerm rasterizes at
    /// `metalRenderingScaleFactor()`, whose whole body is
    /// `max(1, metalScaleFactorOverride ?? backingScaleFactor())`, so past 1
    /// the camera only magnifies pixels that already exist. 1.0 is also the
    /// only scale at which the transform is a pure translation and the ten-odd
    /// `NSView`/`locationInWindow` conversions in `PaneWorkspaceView` — all
    /// blind to a `CALayer` transform — are still right, which is what makes
    /// panes interactive only here.
    static let maxScale: CGFloat = 1.0

    /// Scale first, translate second: `m41`/`m42` carry `origin` unscaled.
    var transform: CATransform3D {
        CATransform3DConcat(
            CATransform3DMakeScale(scale, scale, 1),
            CATransform3DMakeTranslation(origin.x, origin.y, 0)
        )
    }

    /// Maps a point in the view's coordinate space back into canvas space.
    /// A camera with no usable scale has no inverse; the point comes back
    /// unchanged rather than as an infinity that would poison a hit test.
    func canvasPoint(from viewPoint: CGPoint) -> CGPoint {
        guard scale > 0, scale.isFinite else { return viewPoint }
        return CGPoint(
            x: (viewPoint.x - origin.x) / scale,
            y: (viewPoint.y - origin.y) / scale
        )
    }

    /// The whole content plus `DeskCanvas.fitMargin` of breathing room — half
    /// of it on each side, so the fraction reads as "20% more than the tree" —
    /// centred in `bounds`. This is the zoom-out end of the clamp range.
    static func fitAll(content: CGRect, in bounds: CGRect) -> DeskCamera {
        let padded = content.insetBy(
            dx: -content.width * DeskCanvas.fitMargin / 2,
            dy: -content.height * DeskCanvas.fitMargin / 2
        )
        return focus(on: padded, in: bounds)
    }

    /// The camera that maps `rect` onto `bounds`: the tighter of the two axes,
    /// centred, and never above `maxScale`. A session card is viewport-sized,
    /// so focusing one is exactly 1.0 — the identity the whole navigation model
    /// is built on. A rect *smaller* than the viewport is centred at 1.0 rather
    /// than blown up, because there is no more detail up there to find.
    /// A degenerate rect or an unsized viewport answers identity rather than a
    /// NaN, which would blank every sublayer on screen and never recover.
    static func focus(on rect: CGRect, in bounds: CGRect) -> DeskCamera {
        guard rect.width > 0, rect.height > 0, bounds.width > 0, bounds.height > 0 else {
            return DeskCamera(scale: 1, origin: .zero)
        }
        let fitted = min(
            min(bounds.width / rect.width, bounds.height / rect.height),
            maxScale
        )
        return DeskCamera(
            scale: fitted,
            origin: CGPoint(
                x: bounds.midX - fitted * rect.midX,
                y: bounds.midY - fitted * rect.midY
            )
        )
    }

    /// Clamps scale into `[minScale, maxScale]`, keeping whatever sits under
    /// the viewport's centre exactly where it is. A `minScale` above the
    /// ceiling collapses onto the ceiling — the ceiling wins, rather than the
    /// range inverting. A camera already in range is returned untouched, so an
    /// `Equatable` no-change guard upstream stays true.
    func clamped(minScale: CGFloat, in bounds: CGRect) -> DeskCamera {
        let floorScale = min(minScale, Self.maxScale)
        let target = min(max(scale, floorScale), Self.maxScale)
        guard target != scale else { return self }
        guard scale > 0, scale.isFinite else {
            return DeskCamera(scale: target, origin: origin)
        }
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)
        let held = canvasPoint(from: middle)
        return DeskCamera(
            scale: target,
            origin: CGPoint(
                x: middle.x - target * held.x,
                y: middle.y - target * held.y
            )
        )
    }

    /// True when scale is exactly 1 and the origin is whole-pixel — the only
    /// state in which panes accept input, and the precondition `flyCamera(to:)`
    /// checks before snapping `sublayerTransform` to identity. Exactly 1, not
    /// within an epsilon: the landing camera is assigned, never accumulated,
    /// and a fractional origin is soft text for as long as it stands.
    var isIdentity: Bool {
        scale == 1
            && origin.x.isFinite && origin.y.isFinite
            && origin.x == origin.x.rounded()
            && origin.y == origin.y.rounded()
    }
}

extension DeskCamera {
    /// The part of the canvas `bounds` is showing, in canvas coordinates —
    /// the rect viewport culling is measured against.
    ///
    /// Two mapped corners bound it exactly: the camera is a scale and a
    /// translation with no rotation, so the image of an axis-aligned rect is
    /// an axis-aligned rect. `min`/`abs` rather than assuming an orientation,
    /// because the canvas lives in `PaneWorkspaceView`'s **flipped** space
    /// (`isFlipped == true`, y growing downward) and the window's is not.
    func canvasViewport(in bounds: CGRect) -> CGRect {
        let near = canvasPoint(from: CGPoint(x: bounds.minX, y: bounds.minY))
        let far = canvasPoint(from: CGPoint(x: bounds.maxX, y: bounds.maxY))
        return CGRect(
            x: min(near.x, far.x),
            y: min(near.y, far.y),
            width: abs(far.x - near.x),
            height: abs(far.y - near.y)
        )
    }
}

enum DeskCanvas {
    /// Chip node width as a fraction of a session card's width.
    static let chipWidthFraction: CGFloat = 0.25

    /// Below this scale an on-screen session shows chips instead of surfaces.
    /// At 0.2, 12pt type is 2.4pt: there is no information in those pixels,
    /// only cost.
    static let lodThreshold: CGFloat = 0.2

    /// fitAll's breathing room, as a fraction.
    static let fitMargin: CGFloat = 0.2

    /// Horizontal room between two packed siblings, as a fraction of a card's
    /// width. A fraction rather than a point count because a card is the whole
    /// Desk viewport — a 40pt gap between two 1200pt cards is invisible at
    /// fit-all zoom, which is the only zoom the gap exists to be read at.
    static let siblingGapFraction: CGFloat = 0.12

    /// Vertical room between one level's bottom edge and the next level's top,
    /// as a fraction of a card's height. Same reasoning as `siblingGapFraction`.
    static let levelGapFraction: CGFloat = 0.3

    /// A chip is the card at `chipWidthFraction` scale — same aspect, so the
    /// tree reads as one family of rectangles at any zoom, and one constant
    /// governs both dimensions. Rounded, so no chip lands on a half-point.
    static func chipSize(forCard cardSize: CGSize) -> CGSize {
        CGSize(
            width: (cardSize.width * chipWidthFraction).rounded(),
            height: (cardSize.height * chipWidthFraction).rounded()
        )
    }

    /// A session card is ALWAYS `cardSize`, one pane or twelve — a card is the
    /// size of the Desk viewport, because that is what makes "camera at 1.0
    /// over this card" identical to "you are in this session". Everything else
    /// is a chip.
    static func nodeSize(_ kind: DeskNode.Kind, cardSize: CGSize) -> CGSize {
        switch kind {
        case .session:
            return cardSize
        case .root, .workspace:
            return chipSize(forCard: cardSize)
        }
    }

    static func siblingGap(forCard cardSize: CGSize) -> CGFloat {
        (cardSize.width * siblingGapFraction).rounded()
    }

    static func levelGap(forCard cardSize: CGSize) -> CGFloat {
        (cardSize.height * levelGapFraction).rounded()
    }

    // MARK: - Layout

    /// Tidy tree, bottom-up: children packed left-to-right by width, parent
    /// centred over its children's span. `pinned` nodes are EXCLUDED from
    /// packing and placed at their stored canvas position; unpinned siblings
    /// close the gap. A session card's size is always `cardSize`.
    ///
    /// A pinned entry's `CGPoint` is the node's frame ORIGIN — its top-left in
    /// flipped canvas space — not an offset from an auto slot, so a pin means
    /// the same place whatever else opens or closes around it. The pinned
    /// node's own subtree follows it: dragging a node translates it and
    /// everything hanging off it.
    ///
    /// Deterministic by construction: the walk only ever iterates `children`
    /// arrays, and `contentRect` is folded in placement order rather than over
    /// `frames.values`, whose iteration order is not stable.
    static func layout(
        root: DeskNode,
        cardSize: CGSize,
        pinned: [String: CGPoint]
    ) -> DeskCanvasLayout {
        var placed: [(id: String, frame: CGRect)] = []
        var edges: [DeskEdge] = []
        place(
            root,
            left: 0,
            top: 0,
            cardSize: cardSize,
            pinned: pinned,
            placed: &placed,
            edges: &edges
        )

        var frames: [String: CGRect] = [:]
        frames.reserveCapacity(placed.count)
        var content = CGRect.null
        for entry in placed {
            frames[entry.id] = entry.frame
            content = content.union(entry.frame)
        }
        return DeskCanvasLayout(
            frames: frames,
            edges: edges,
            contentRect: content.isNull ? .zero : content
        )
    }

    /// The width the node's packed band needs: its own width, or its unpinned
    /// children's span, whichever is wider. Pinned children are not in the band
    /// at all — they are wherever the user dropped them, and their siblings
    /// close over the space they used to hold.
    ///
    /// The tree is three levels deep and tens of nodes wide, so measuring a
    /// subtree twice (once here, once as the caller advances) costs nothing and
    /// keeps the measure and place passes readable.
    private static func subtreeWidth(
        _ node: DeskNode,
        cardSize: CGSize,
        pinned: [String: CGPoint]
    ) -> CGFloat {
        let own = nodeSize(node.kind, cardSize: cardSize).width
        let packed = node.children.filter { pinned[$0.id] == nil }
        guard !packed.isEmpty else { return own }
        let span = packedSpan(packed, cardSize: cardSize, pinned: pinned)
        return max(own, span)
    }

    private static func packedSpan(
        _ packed: [DeskNode],
        cardSize: CGSize,
        pinned: [String: CGPoint]
    ) -> CGFloat {
        guard !packed.isEmpty else { return 0 }
        let widths = packed.reduce(CGFloat(0)) {
            $0 + subtreeWidth($1, cardSize: cardSize, pinned: pinned)
        }
        return widths + siblingGap(forCard: cardSize) * CGFloat(packed.count - 1)
    }

    /// Places `node` inside a band whose left edge is `left` and whose top edge
    /// is `top`, then recurses. `subtreeWidth` has already measured every
    /// descendant, so the parent can be centred over the span its children are
    /// about to occupy — that is what makes this bottom-up in effect while
    /// staying one downward walk.
    ///
    /// A pinned node ignores `left`/`top` entirely and takes its stored origin,
    /// then centres its own children under itself; an unpinned node centres
    /// itself over its children. Both are the same rule stated from the two
    /// ends.
    ///
    /// Origins are rounded to whole points, the way
    /// `PaneGrid.layout(in:dividerThickness:)` rounds its edges — a session
    /// card's rect becomes a real container frame, and a container on a
    /// half-point renders soft text. Rounding happens once per frame, from the
    /// exact ideal position, so nothing accumulates down a row.
    private static func place(
        _ node: DeskNode,
        left: CGFloat,
        top: CGFloat,
        cardSize: CGSize,
        pinned: [String: CGPoint],
        placed: inout [(id: String, frame: CGRect)],
        edges: inout [DeskEdge]
    ) {
        let size = nodeSize(node.kind, cardSize: cardSize)
        let packed = node.children.filter { pinned[$0.id] == nil }
        let span = packedSpan(packed, cardSize: cardSize, pinned: pinned)

        let frame: CGRect
        let childrenLeft: CGFloat
        if let pin = pinned[node.id] {
            frame = CGRect(
                origin: CGPoint(x: pin.x.rounded(), y: pin.y.rounded()),
                size: size
            )
            childrenLeft = frame.midX - span / 2
        } else {
            let band = max(size.width, span)
            frame = CGRect(
                x: (left + (band - size.width) / 2).rounded(),
                y: top.rounded(),
                width: size.width,
                height: size.height
            )
            childrenLeft = left + (band - span) / 2
        }
        placed.append((node.id, frame))

        let childrenTop = frame.maxY + levelGap(forCard: cardSize)
        let gap = siblingGap(forCard: cardSize)
        var x = childrenLeft
        for child in node.children {
            edges.append(DeskEdge(from: node.id, to: child.id))
            guard pinned[child.id] == nil else {
                // Pinned: `left`/`top` are unused on that branch, and the child
                // does not advance `x` — that is the gap closing.
                place(
                    child,
                    left: 0,
                    top: 0,
                    cardSize: cardSize,
                    pinned: pinned,
                    placed: &placed,
                    edges: &edges
                )
                continue
            }
            place(
                child,
                left: x,
                top: childrenTop,
                cardSize: cardSize,
                pinned: pinned,
                placed: &placed,
                edges: &edges
            )
            x += subtreeWidth(child, cardSize: cardSize, pinned: pinned) + gap
        }
    }
}
