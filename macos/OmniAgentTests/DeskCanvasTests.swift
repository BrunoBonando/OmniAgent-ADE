import XCTest
@testable import OmniAgent

/// The Desk organigram's geometry: a tidy tree packed bottom-up, session cards
/// forced to the viewport size, chips a quarter of that, pinned nodes lifted
/// out of the packing entirely, and every frame in the workspace view's own
/// FLIPPED space. Pure — no window, no layer, no camera, the way
/// `PaneGridTests` is pure.
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
