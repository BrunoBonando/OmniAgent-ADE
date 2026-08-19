import AppKit
import XCTest
@testable import OmniAgent

/// The organigram's two drawn pieces: the chips that stand for the account and
/// the workspaces, and the single shape layer that carries every connector.
/// Both are frame-driven — `DeskCanvas.layout` owns every rect — so everything
/// here is checked either as pure geometry or through the repo's offscreen
/// render convention.
final class DeskCanvasNodeViewsTests: XCTestCase {

    // MARK: - Connectors

    /// One elbow per edge: down out of the parent's bottom, across at the waist,
    /// down into the child's top. Canvas space is FLIPPED
    /// (`PaneWorkspaceView.isFlipped == true`), so a parent's `maxY` is its
    /// *bottom* edge and the child sits at the larger y. Reading that the other
    /// way round draws every connector backwards through its own parent, and it
    /// is exactly the class of mistake the PNG harness cannot catch.
    func testEachConnectorLeavesTheParentsBottomAndArrivesAtTheChildsTop() {
        let layout = DeskCanvasLayout(
            frames: [
                "parent": CGRect(x: 100, y: 0, width: 200, height: 80),
                "child": CGRect(x: 0, y: 200, width: 120, height: 60),
            ],
            edges: [DeskEdge(from: "parent", to: "child")],
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 260)
        )

        let path = DeskCanvasEdgeLayer.path(for: layout)
        let box = path.boundingBoxOfPath

        XCTAssertEqual(box.minY, 80, accuracy: 0.01, "it starts at the parent's bottom edge")
        XCTAssertEqual(box.maxY, 200, accuracy: 0.01, "and ends at the child's top edge")
        XCTAssertEqual(box.minX, 60, accuracy: 0.01, "spanning the child's centre")
        XCTAssertEqual(box.maxX, 200, accuracy: 0.01, "to the parent's centre")
        XCTAssertFalse(path.isEmpty, "one edge, one elbow")
    }

    /// Every connector in one path on one layer. A tree of an account, a few
    /// workspaces and up to eight sessions is a few dozen edges, and a few dozen
    /// sublayers is a few dozen composites on every frame of a pinch.
    func testEveryEdgeGoesIntoOnePathNotOneLayerEach() throws {
        let layout = DeskCanvasLayout(
            frames: [
                "a": CGRect(x: 0, y: 0, width: 100, height: 40),
                "b": CGRect(x: 0, y: 100, width: 100, height: 40),
                "c": CGRect(x: 200, y: 100, width: 100, height: 40),
            ],
            edges: [DeskEdge(from: "a", to: "b"), DeskEdge(from: "a", to: "c")],
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 140)
        )
        let edgeLayer = DeskCanvasEdgeLayer()

        edgeLayer.apply(layout, scale: 1)

        XCTAssertNil(edgeLayer.sublayers, "one layer, one path")
        let box = try XCTUnwrap(edgeLayer.path).boundingBoxOfPath
        XCTAssertEqual(box.maxX, 250, accuracy: 0.01, "both edges are in it")
    }

    /// An edge naming a node the layout does not hold is skipped rather than
    /// crashing: the tree and the frames are computed together, but a pinned
    /// node removed mid-drag is the way to get one out of step.
    func testAnEdgeToAMissingNodeIsSkippedRatherThanDrawn() {
        let layout = DeskCanvasLayout(
            frames: ["a": CGRect(x: 0, y: 0, width: 100, height: 40)],
            edges: [DeskEdge(from: "a", to: "gone")],
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 40)
        )

        XCTAssertTrue(DeskCanvasEdgeLayer.path(for: layout).isEmpty, "nothing to draw, nothing drawn")
    }

    /// The camera is a `sublayerTransform`, which scales the stroke along with
    /// everything else: at `fitAll` a 1pt line is 0.2pt, under one device pixel,
    /// and the connectors fade out exactly when the tree is the only thing on
    /// screen. The width is divided back out.
    func testTheConnectorStrokeIsDividedBackOutOfTheCameraScale() {
        let layout = DeskCanvasLayout(
            frames: [
                "a": CGRect(x: 0, y: 0, width: 100, height: 40),
                "b": CGRect(x: 0, y: 100, width: 100, height: 40),
            ],
            edges: [DeskEdge(from: "a", to: "b")],
            contentRect: CGRect(x: 0, y: 0, width: 100, height: 140)
        )
        let edgeLayer = DeskCanvasEdgeLayer()

        edgeLayer.apply(layout, scale: 1)
        XCTAssertEqual(edgeLayer.lineWidth, DeskCanvasEdgeLayer.strokeWidth, accuracy: 0.001)

        edgeLayer.apply(layout, scale: 0.2)
        XCTAssertEqual(
            edgeLayer.lineWidth,
            DeskCanvasEdgeLayer.strokeWidth / 0.2,
            accuracy: 0.001,
            "five times as wide in canvas units, one point on screen"
        )

        edgeLayer.apply(layout, scale: 0)
        XCTAssertEqual(edgeLayer.lineWidth, DeskCanvasEdgeLayer.strokeWidth, accuracy: 0.001, "no divide by zero")
    }

    /// `CAShapeLayer` animates `path` and `lineWidth` implicitly, and the camera
    /// changes `lineWidth` on every frame of a pinch.
    func testTheEdgeLayerRefusesImplicitAnimationsOnEveryKey() {
        let edgeLayer = DeskCanvasEdgeLayer()
        for key in ["path", "lineWidth", "strokeColor", "position"] {
            XCTAssertTrue(
                edgeLayer.action(forKey: key) is NSNull,
                "\(key) must not animate itself sixty times a second"
            )
        }
    }

    /// Core Animation copies a layer through `init(layer:)` to build the
    /// presentation layer. A subclass that does not implement it gets a copy
    /// with none of its own state — and the presentation layer is what is on
    /// screen during any animation the canvas runs over it.
    func testTheEdgeLayerSurvivesCoreAnimationsCopyInitializer() {
        let original = DeskCanvasEdgeLayer()
        let copy = DeskCanvasEdgeLayer(layer: original)
        XCTAssertTrue(copy.action(forKey: "path") is NSNull, "the copy is still a DeskCanvasEdgeLayer")
    }
}
