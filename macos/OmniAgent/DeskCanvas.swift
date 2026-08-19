import Foundation

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
