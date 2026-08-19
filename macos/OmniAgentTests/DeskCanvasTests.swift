import QuartzCore
import XCTest
@testable import OmniAgent

/// The Desk organigram's geometry: a tidy tree packed bottom-up, session cards
/// forced to the viewport size, chips a quarter of that, pinned nodes lifted
/// out of the packing entirely, and every frame in the workspace view's own
/// FLIPPED space, plus the camera that looks at it. Pure — no window and no
/// layer, the way `PaneGridTests` is pure.
///
/// The card size used throughout is 1200x800 because every derived quantity
/// then falls on a whole point (chip 300x200, sibling gap 144, level gap 240),
/// so these cases pin the arithmetic itself rather than a rounding artefact.
/// `testEveryFrameLandsOnWholePointsSoNoCardRendersOnAHalfPixel` deliberately
/// uses an ugly card size instead.
final class DeskCanvasTests: XCTestCase {
    private let cardSize = CGSize(width: 1200, height: 800)

    // MARK: - Node sizes

    func testASessionCardIsAlwaysTheViewportCardAndAChipIsAQuarterOfIt() throws {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["sess-grp-1"]),
            cardSize: cardSize,
            pinned: [:]
        )

        XCTAssertEqual(
            try XCTUnwrap(layout.frames["sess-grp-1"]).size,
            cardSize,
            "a session card is exactly the Desk viewport, one pane or twelve"
        )
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["root"]).size,
            CGSize(width: 300, height: 200),
            "the You chip is the card at chipWidthFraction"
        )
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["OmniAgent-ADE"]).size,
            CGSize(width: 300, height: 200),
            "so is the workspace chip"
        )
        XCTAssertEqual(
            DeskCanvas.chipSize(forCard: cardSize).width,
            cardSize.width * DeskCanvas.chipWidthFraction,
            "chip width is the fraction the shared constant names"
        )
    }

    // MARK: - Packing and centring

    func testChildrenPackLeftToRightAndTheParentSitsCentredOverTheirSpan() throws {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a", "b", "c"]),
            cardSize: cardSize,
            pinned: [:]
        )
        let a = try XCTUnwrap(layout.frames["a"])
        let b = try XCTUnwrap(layout.frames["b"])
        let c = try XCTUnwrap(layout.frames["c"])
        let workspace = try XCTUnwrap(layout.frames["OmniAgent-ADE"])
        let root = try XCTUnwrap(layout.frames["root"])
        let gap = DeskCanvas.siblingGap(forCard: cardSize)

        XCTAssertEqual(a.minX, 0, "the first child opens the band at the origin")
        XCTAssertEqual(b.minX - a.maxX, gap, "one sibling gap between a and b")
        XCTAssertEqual(c.minX - b.maxX, gap, "one sibling gap between b and c")
        XCTAssertEqual(Set([a.minY, b.minY, c.minY]).count, 1, "siblings share one row")
        XCTAssertEqual(
            workspace.midX,
            (a.minX + c.maxX) / 2,
            "the parent is centred over its children's span, not over its first child"
        )
        XCTAssertEqual(root.midX, workspace.midX, "and its parent over that")
    }

    /// A workspace with two sessions is 2544 wide while its own chip is 300, so
    /// packing by node width instead of subtree width would overlap the two
    /// branches. Bottom-up means the parent asks how wide its children ended up
    /// before it decides where the next sibling starts.
    func testSiblingSubtreesPackByTheirMeasuredWidthNotByTheirNodeWidth() throws {
        let root = DeskNode(id: "root", kind: .root, children: [
            DeskNode(id: "alpha", kind: .workspace("alpha"), children: [
                DeskNode(id: "a1", kind: .session("a1"), children: []),
                DeskNode(id: "a2", kind: .session("a2"), children: []),
            ]),
            DeskNode(id: "beta", kind: .workspace("beta"), children: [
                DeskNode(id: "b1", kind: .session("b1"), children: []),
            ]),
        ])
        let layout = DeskCanvas.layout(root: root, cardSize: cardSize, pinned: [:])
        let a2 = try XCTUnwrap(layout.frames["a2"])
        let b1 = try XCTUnwrap(layout.frames["b1"])

        XCTAssertEqual(
            b1.minX - a2.maxX,
            DeskCanvas.siblingGap(forCard: cardSize),
            "beta's band opens one gap after alpha's widest row, not after alpha's chip"
        )
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["alpha"]).midX,
            (try XCTUnwrap(layout.frames["a1"]).minX + a2.maxX) / 2,
            "alpha centres over its two cards"
        )
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["beta"]).midX,
            b1.midX,
            "beta centres over its one"
        )
    }

    // MARK: - The flipped space

    /// `PaneWorkspaceView.isFlipped == true` and the window is not — the same
    /// distinction `PaneDividerView.mouseDragged` turns on. Every level of the
    /// canvas grows y DOWNWARD; getting this backwards would draw the tree
    /// upside down and put every pinned position on the wrong side of its node.
    func testEachLevelSitsBelowTheOneAboveItInTheFlippedCanvasSpace() throws {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a"]),
            cardSize: cardSize,
            pinned: [:]
        )
        let root = try XCTUnwrap(layout.frames["root"])
        let workspace = try XCTUnwrap(layout.frames["OmniAgent-ADE"])
        let session = try XCTUnwrap(layout.frames["a"])
        let gap = DeskCanvas.levelGap(forCard: cardSize)

        XCTAssertEqual(root.minY, 0, "the tree starts at the canvas origin")
        XCTAssertEqual(workspace.minY - root.maxY, gap, "one level gap below You")
        XCTAssertEqual(session.minY - workspace.maxY, gap, "one level gap below the workspace")
        XCTAssertTrue(
            root.minY < workspace.minY && workspace.minY < session.minY,
            "y grows downward — the canvas lives in the view's flipped space"
        )
        XCTAssertEqual(session.midX, workspace.midX, "a lone child sits directly under its parent")
    }

    func testARootWithNoWorkspacesIsItsOwnContent() {
        let layout = DeskCanvas.layout(
            root: DeskNode(id: "root", kind: .root, children: []),
            cardSize: cardSize,
            pinned: [:]
        )

        XCTAssertEqual(layout.frames.count, 1, "one node, one frame")
        XCTAssertEqual(layout.edges, [], "nothing to connect")
        XCTAssertEqual(
            layout.contentRect,
            CGRect(x: 0, y: 0, width: 300, height: 200),
            "contentRect never collapses to zero while a node exists — fitAll would divide by it"
        )
    }

    // MARK: - Determinism

    /// The layout walks `children` arrays and never a dictionary, so the same
    /// tree must produce a byte-identical `DeskCanvasLayout` on every call —
    /// including `contentRect`, which is folded in placement order rather than
    /// over `frames.values`. A camera restored from `desk_canvas_native` is
    /// meaningless the moment this drifts.
    func testTheSameTreeLaysOutIdenticallyEveryTime() {
        let root = tree(sessions: ["a", "b", "c", "d"])
        let pinned = ["c": CGPoint(x: 4000, y: 2500)]
        let first = DeskCanvas.layout(root: root, cardSize: cardSize, pinned: pinned)

        for attempt in 1...20 {
            XCTAssertEqual(
                DeskCanvas.layout(root: root, cardSize: cardSize, pinned: pinned),
                first,
                "run \(attempt) differs — the layout must not depend on dictionary order"
            )
        }
    }

    // MARK: - Pinning

    func testAPinnedSessionSitsWhereItWasDroppedAndItsSiblingsCloseTheGap() throws {
        let root = tree(sessions: ["a", "b", "c"])
        let loose = DeskCanvas.layout(root: root, cardSize: cardSize, pinned: [:])
        let drop = CGPoint(x: 5000, y: 5000)
        let layout = DeskCanvas.layout(root: root, cardSize: cardSize, pinned: ["b": drop])

        let a = try XCTUnwrap(layout.frames["a"])
        let b = try XCTUnwrap(layout.frames["b"])
        let c = try XCTUnwrap(layout.frames["c"])

        XCTAssertEqual(b.origin, drop, "the dragged card keeps the absolute position it was dropped at")
        XCTAssertEqual(b.size, cardSize, "pinning changes where a card is, never how big it is")
        XCTAssertEqual(
            c.minX - a.maxX,
            DeskCanvas.siblingGap(forCard: cardSize),
            "a and c are adjacent — the packing does not hold b's empty slot open"
        )
        XCTAssertNotEqual(layout.frames["c"], loose.frames["c"], "c moved left into the gap")
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["OmniAgent-ADE"]).midX,
            (a.minX + c.maxX) / 2,
            "the parent centres over the children it still packs, not over the pinned one"
        )
    }

    /// "Dragging a node translates it *and its subtree*." Pinning the workspace
    /// has to take its sessions with it, and the unpinned remainder above has to
    /// pack as if the pinned branch were not in the tree at all.
    func testAPinnedWorkspaceCarriesItsSessionsWithIt() throws {
        let drop = CGPoint(x: 2000, y: 3000)
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a", "b", "c"]),
            cardSize: cardSize,
            pinned: ["OmniAgent-ADE": drop]
        )
        let workspace = try XCTUnwrap(layout.frames["OmniAgent-ADE"])
        let a = try XCTUnwrap(layout.frames["a"])
        let c = try XCTUnwrap(layout.frames["c"])

        XCTAssertEqual(workspace.origin, drop)
        XCTAssertEqual(
            a.minY,
            workspace.maxY + DeskCanvas.levelGap(forCard: cardSize),
            "the subtree hangs one level below the node it was dragged with"
        )
        XCTAssertEqual(
            (a.minX + c.maxX) / 2,
            workspace.midX,
            "the sessions re-centre under the pinned parent"
        )
        XCTAssertEqual(
            try XCTUnwrap(layout.frames["root"]).minX,
            0,
            "with its only child pinned away, You packs as a leaf at the origin"
        )
    }

    // MARK: - contentRect and edges

    func testTheContentRectIsTheUnionOfEveryFrame() throws {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a", "b", "c"]),
            cardSize: cardSize,
            pinned: ["b": CGPoint(x: 5000, y: 5000)]
        )
        var union = CGRect.null
        for frame in layout.frames.values { union = union.union(frame) }

        XCTAssertEqual(layout.contentRect, union, "contentRect is exactly what fitAll has to fit")
        XCTAssertTrue(
            layout.contentRect.contains(try XCTUnwrap(layout.frames["b"])),
            "a card dragged far off the tidy tree is still inside the fit"
        )
    }

    func testEveryParentChildPairGetsExactlyOneEdgeIncludingThePinnedOnes() {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a", "b"]),
            cardSize: cardSize,
            pinned: ["b": CGPoint(x: 5000, y: 5000)]
        )

        XCTAssertEqual(
            layout.edges,
            [
                DeskEdge(from: "root", to: "OmniAgent-ADE"),
                DeskEdge(from: "OmniAgent-ADE", to: "a"),
                DeskEdge(from: "OmniAgent-ADE", to: "b"),
            ],
            "depth first, children in tree order; the connector to a dragged node stays"
        )
    }

    // MARK: - Rounding

    /// `PaneGrid.layout(in:dividerThickness:)` rounds its edges to whole points
    /// "so the panes tile `bounds` exactly and no pane draws on a half-pixel".
    /// A session card's rect becomes a real container frame here, so the same
    /// rule applies — with an awkward card size and a half-point drop position,
    /// which is what a real drag produces.
    func testEveryFrameLandsOnWholePointsSoNoCardRendersOnAHalfPixel() {
        let layout = DeskCanvas.layout(
            root: tree(sessions: ["a", "b", "c", "d", "e"]),
            cardSize: CGSize(width: 1207, height: 813),
            pinned: ["c": CGPoint(x: 999.5, y: 1000.4)]
        )

        XCTAssertEqual(layout.frames.count, 7, "root, workspace and five sessions")
        for (id, frame) in layout.frames {
            XCTAssertEqual(frame.minX, frame.minX.rounded(), "\(id) x is on a whole point")
            XCTAssertEqual(frame.minY, frame.minY.rounded(), "\(id) y is on a whole point")
        }
    }

    // MARK: - camera

    /// The property the whole navigation model rests on. A session card is
    /// exactly the size of the Desk viewport, so "the camera is at 1.0 over
    /// this card" and "you are in this session" have to be the *same state*.
    /// Exact equality, not an accuracy: `bounds.width / rect.width` for two
    /// equal finite values is exactly 1, and a camera that lands at 0.999
    /// leaves the text permanently soft.
    func testFocusingOnARectTheSizeOfTheViewportIsExactlyIdentityScale() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let card = CGRect(x: 2400, y: 960, width: 1200, height: 800)
        let camera = DeskCamera.focus(on: card, in: bounds)

        XCTAssertEqual(camera.scale, 1, "a card is viewport-sized, so focusing one is exactly 1.0")
        XCTAssertEqual(
            camera.canvasPoint(from: bounds.origin),
            card.origin,
            "the card's near corner lands on the viewport's near corner"
        )
        XCTAssertEqual(
            camera.canvasPoint(from: CGPoint(x: bounds.maxX, y: bounds.maxY)),
            CGPoint(x: card.maxX, y: card.maxY),
            "and its far corner on the viewport's — the card fills the Desk exactly"
        )
        XCTAssertTrue(camera.isIdentity, "an integral card origin lands on an integral camera origin")
    }

    /// `fitAll` is the zoom-out end of the clamp range: the whole tree plus
    /// `DeskCanvas.fitMargin` of breathing room *in total*, half of it on each
    /// side, centred. The numbers are chosen so the margin shows up in the
    /// answer — bare, this content would fit at 0.6.
    func testFitAllShowsTheWholeContentPlusItsMarginCentred() {
        XCTAssertEqual(DeskCanvas.fitMargin, 0.2, "the arithmetic below is on this value")
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let content = CGRect(x: -500, y: 250, width: 2000, height: 1000)
        let camera = DeskCamera.fitAll(content: content, in: bounds)

        XCTAssertEqual(camera.scale, 0.5, accuracy: 1e-12, "0.6 bare, over the 1.2 the margin adds")

        let mapped = content.applying(CATransform3DGetAffineTransform(camera.transform))
        XCTAssertEqual(mapped.midX, bounds.midX, accuracy: 1e-9, "centred across")
        XCTAssertEqual(mapped.midY, bounds.midY, accuracy: 1e-9, "and down")
        XCTAssertEqual(mapped.width, 1000, accuracy: 1e-9)
        XCTAssertEqual(
            mapped.minX - bounds.minX,
            100,
            accuracy: 1e-9,
            "100pt of margin on the tight axis — half of fitMargin, mapped"
        )
        XCTAssertTrue(bounds.contains(mapped), "the whole tree is on screen, which is what fit-all means")
    }

    /// A lone session on a big display: content plus margin is smaller than the
    /// viewport and the bare fit would be 1.67. It is not taken. `maxScale` is
    /// the ceiling everywhere, `fitAll` included, so the clamp range
    /// `[fitAll, 1]` can never come out inverted.
    func testFitAllOnContentSmallerThanTheViewportNeverZoomsPastOne() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 1200)
        let content = CGRect(x: 0, y: 0, width: 800, height: 600)
        let camera = DeskCamera.fitAll(content: content, in: bounds)

        XCTAssertEqual(
            DeskCamera.maxScale,
            1,
            "nothing rasterizes sharper than 1x: metalRenderingScaleFactor() is max(1, override ?? backingScaleFactor())"
        )
        XCTAssertEqual(camera.scale, DeskCamera.maxScale, "the ceiling wins over the fit")

        let mapped = content.applying(CATransform3DGetAffineTransform(camera.transform))
        XCTAssertEqual(mapped.midX, bounds.midX, accuracy: 1e-9, "still centred, just not blown up")
        XCTAssertEqual(mapped.midY, bounds.midY, accuracy: 1e-9)
    }

    /// `updateLayout()` runs before the view has a size, and a canvas with no
    /// nodes has no content rect at all. Neither may produce a NaN camera: a
    /// NaN reaching `layer.sublayerTransform` blanks every sublayer on screen
    /// and never recovers, and `Equatable` on a NaN never compares equal, so
    /// the "unchanged camera" guards downstream would fire forever.
    func testAnEmptyCanvasOrAZeroSizedViewportFitsAsIdentityRatherThanNaN() {
        let viewport = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertEqual(
            DeskCamera.fitAll(content: .zero, in: viewport),
            DeskCamera(scale: 1, origin: .zero),
            "an empty tree fits as identity"
        )
        XCTAssertEqual(
            DeskCamera.fitAll(content: CGRect(x: 0, y: 0, width: 2000, height: 1000), in: .zero),
            DeskCamera(scale: 1, origin: .zero),
            "so does a viewport that has not been sized yet"
        )
        XCTAssertEqual(
            DeskCamera.focus(on: CGRect(x: 0, y: 0, width: 1200, height: 800), in: .zero),
            DeskCamera(scale: 1, origin: .zero),
            "focus too — same guard"
        )

        let stalled = DeskCamera(scale: 0, origin: CGPoint(x: 10, y: 10))
        XCTAssertEqual(
            stalled.canvasPoint(from: CGPoint(x: 4, y: 4)),
            CGPoint(x: 4, y: 4),
            "a zero scale has no inverse; the point comes back unchanged rather than infinite"
        )
    }

    /// The transform is a scale *then* a translation — `m41`/`m42` are the
    /// origin unscaled — and `canvasPoint(from:)` is its exact inverse at any
    /// scale and origin. That inverse is the whole of the canvas's hit testing
    /// below identity scale: `NSView.convert` and `event.locationInWindow` are
    /// blind to a `CALayer` transform, so this is the only way back from a
    /// click to a node.
    func testTheTransformScalesThenTranslatesAndTheInverseUndoesIt() {
        let camera = DeskCamera(scale: 0.35, origin: CGPoint(x: 128.5, y: -940.25))
        let transform = camera.transform

        XCTAssertTrue(CATransform3DIsAffine(transform), "no perspective term ever enters the camera")
        XCTAssertEqual(transform.m11, 0.35, accuracy: 1e-12)
        XCTAssertEqual(transform.m22, 0.35, accuracy: 1e-12)
        XCTAssertEqual(transform.m41, 128.5, accuracy: 1e-12, "the origin unscaled: translate is last")
        XCTAssertEqual(transform.m42, -940.25, accuracy: 1e-12)

        let scales: [CGFloat] = [0.08, DeskCanvas.lodThreshold, 0.37, 0.5, 1]
        let origins = [CGPoint.zero, CGPoint(x: 317, y: -128.5), CGPoint(x: -940.25, y: 2200)]
        let canvasPoints = [CGPoint.zero, CGPoint(x: 1234.5, y: -67.25), CGPoint(x: -3000, y: 4096)]
        for scale in scales {
            for origin in origins {
                let probe = DeskCamera(scale: scale, origin: origin)
                let affine = CATransform3DGetAffineTransform(probe.transform)
                for canvas in canvasPoints {
                    let onScreen = canvas.applying(affine)
                    XCTAssertEqual(
                        onScreen.x,
                        canvas.x * scale + origin.x,
                        accuracy: 1e-9,
                        "canvas * scale + origin at \(scale) \(origin)"
                    )
                    XCTAssertEqual(onScreen.y, canvas.y * scale + origin.y, accuracy: 1e-9)

                    let back = probe.canvasPoint(from: onScreen)
                    XCTAssertEqual(back.x, canvas.x, accuracy: 1e-6, "round trip x at \(scale) \(origin)")
                    XCTAssertEqual(back.y, canvas.y, accuracy: 1e-6, "round trip y at \(scale) \(origin)")
                }
            }
        }
    }

    /// Pinching keeps whatever is under the middle of the screen under the
    /// middle of the screen. Both ends of `[minScale, DeskCamera.maxScale]` are
    /// hard: nothing above 1 to see, nothing below the fit worth showing.
    func testClampingHoldsTheViewportCentreStillBetweenTheFloorAndOne() {
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let floorScale: CGFloat = 0.25
        let middle = CGPoint(x: bounds.midX, y: bounds.midY)

        let tooClose = DeskCamera(scale: 2.4, origin: CGPoint(x: -3000, y: -1800))
        let wasUnderMiddle = tooClose.canvasPoint(from: middle)
        let pulledBack = tooClose.clamped(minScale: floorScale, in: bounds)
        XCTAssertEqual(pulledBack.scale, DeskCamera.maxScale, "never past 1")
        XCTAssertEqual(
            pulledBack.canvasPoint(from: middle).x,
            wasUnderMiddle.x,
            accuracy: 1e-9,
            "and what was under the middle is still under it"
        )
        XCTAssertEqual(pulledBack.canvasPoint(from: middle).y, wasUnderMiddle.y, accuracy: 1e-9)

        let tooFar = DeskCamera(scale: 0.02, origin: CGPoint(x: 640, y: 380))
        let wasUnderMiddleOut = tooFar.canvasPoint(from: middle)
        let pushedIn = tooFar.clamped(minScale: floorScale, in: bounds)
        XCTAssertEqual(pushedIn.scale, floorScale, "and never below the floor")
        XCTAssertEqual(pushedIn.canvasPoint(from: middle).x, wasUnderMiddleOut.x, accuracy: 1e-9)
        XCTAssertEqual(pushedIn.canvasPoint(from: middle).y, wasUnderMiddleOut.y, accuracy: 1e-9)

        let inRange = DeskCamera(scale: 0.5, origin: CGPoint(x: 120, y: -40))
        XCTAssertEqual(
            inRange.clamped(minScale: floorScale, in: bounds),
            inRange,
            "a camera already in range comes back untouched, origin included"
        )

        let inverted = DeskCamera(scale: 0.5, origin: .zero).clamped(minScale: 4, in: bounds)
        XCTAssertEqual(
            inverted.scale,
            DeskCamera.maxScale,
            "a floor above the ceiling collapses onto the ceiling rather than inverting the range"
        )
    }

    /// The landing condition, and the *only* state in which panes take input:
    /// `NSView.convert`, `event.locationInWindow`, the divider drags, the drop
    /// overlays and the tracking areas are all blind to
    /// `layer.sublayerTransform`, and all of them are right when it is a
    /// whole-pixel translation at 1.0. Exactly 1 rather than a tolerance,
    /// because `flyCamera(to:)` *assigns* the landing camera and never
    /// accumulates towards it — and 0.999 is soft text for good.
    func testACameraIsIdentityOnlyAtExactlyOneWithAWholePixelOrigin() {
        XCTAssertTrue(DeskCamera(scale: 1, origin: .zero).isIdentity)
        XCTAssertTrue(
            DeskCamera(scale: 1, origin: CGPoint(x: -2400, y: 960)).isIdentity,
            "a whole-pixel pan at 1.0 is still a landed camera"
        )
        XCTAssertFalse(
            DeskCamera(scale: 1, origin: CGPoint(x: -2400.5, y: 960)).isIdentity,
            "half a pixel across is soft text"
        )
        XCTAssertFalse(DeskCamera(scale: 1, origin: CGPoint(x: -2400, y: 959.75)).isIdentity)
        XCTAssertFalse(DeskCamera(scale: 0.999, origin: .zero).isIdentity, "not near 1 — at 1")
        XCTAssertFalse(DeskCamera(scale: 1.0001, origin: .zero).isIdentity)
        XCTAssertFalse(DeskCamera(scale: .nan, origin: .zero).isIdentity, "a NaN scale is not a landing")
        XCTAssertFalse(DeskCamera(scale: 1, origin: CGPoint(x: CGFloat.infinity, y: 0)).isIdentity)
    }

    // MARK: - Helpers

    /// `You → OmniAgent-ADE → sessions`, the shape the Desk actually draws. A
    /// session node's id IS its group id, the same string
    /// `PaneDescriptor.group` and `PaneWorkspaceView.activeGroup` carry.
    private func tree(sessions: [String]) -> DeskNode {
        DeskNode(
            id: "root",
            kind: .root,
            children: [
                DeskNode(
                    id: "OmniAgent-ADE",
                    kind: .workspace("OmniAgent-ADE"),
                    children: sessions.map {
                        DeskNode(id: $0, kind: .session($0), children: [])
                    }
                ),
            ]
        )
    }
}
