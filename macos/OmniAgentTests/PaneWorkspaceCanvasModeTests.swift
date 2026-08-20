import AppKit
import QuartzCore
import XCTest
@testable import OmniAgent

/// Canvas mode is the *second answer* `PaneWorkspaceView` gives to the same
/// layout question. Normal mode: `activeGroup`'s grid fills `bounds` and every
/// other session is hidden. Canvas mode: every session's grid is laid out at
/// its own card rect in canvas coordinates and one `sublayerTransform` decides
/// what is on screen.
///
/// The three things this suite exists to hold down: normal mode is unchanged
/// (including after a round trip through the canvas), each session lands on its
/// own node rect, and the grid *inside* a card is byte-for-byte the grid normal
/// mode draws for that session — because a card is exactly the Desk viewport,
/// which is what makes "camera at 1.0 over this card" and "you are in that
/// session" the same picture.
final class PaneWorkspaceCanvasModeTests: XCTestCase {
    // MARK: - Normal mode is untouched

    func testNormalModeStillLaysTheActiveSessionOutFromGridBoundsAfterACanvasRoundTrip() throws {
        let workspace = makeCanvasWorkspace()
        let expected = try XCTUnwrap(workspace.grid).layout(
            in: workspace.gridBounds,
            dividerThickness: PaneWorkspaceView.dividerThickness
        )
        for id in workspace.paneIDs {
            XCTAssertEqual(workspace.container(for: id)?.frame, expected.frames[id], "\(id) before")
        }

        workspace.canvasMode = true
        workspace.camera = DeskCamera(scale: 0.4, origin: CGPoint(x: -120, y: -80))
        workspace.canvasMode = false

        for id in workspace.paneIDs {
            XCTAssertEqual(workspace.container(for: id)?.frame, expected.frames[id], "\(id) after")
        }
        XCTAssertEqual(
            workspace.paneIDs.sorted(),
            ["a-1", "a-2", "a-3"],
            "the same session is on screen"
        )
        XCTAssertEqual(
            workspace.container(for: "b-1")?.isHidden,
            true,
            "and the other one is off it again"
        )
        XCTAssertTrue(
            CATransform3DIsIdentity(try XCTUnwrap(workspace.layer).sublayerTransform),
            "leaving the canvas takes the camera off the layer"
        )
    }

    // MARK: - Canvas mode

    func testCanvasModeLaysEverySessionOutAtItsOwnCardRect() throws {
        let workspace = makeCanvasWorkspace()
        workspace.canvasMode = true

        let root = workspace.derivedCanvasRoot()
        let layout = DeskCanvas.layout(root: root, cardSize: workspace.bounds.size, pinned: [:])
        // Everything on screen at once, which is the state this assertion is
        // about: with the whole tree in the viewport, a hidden pane can only be
        // hidden for belonging to a session that is not `activeGroup` — which is
        // exactly the rule canvas mode drops.
        workspace.camera = DeskCamera.fitAll(content: layout.contentRect, in: workspace.bounds)

        for (group, panes) in Self.sessions {
            let card = try XCTUnwrap(layout.frames[group], "every session is a node with a rect")
            XCTAssertEqual(card.size, workspace.bounds.size, "a card is exactly the Desk viewport")
            for id in panes {
                let frame = try XCTUnwrap(workspace.container(for: id)?.frame)
                XCTAssertTrue(
                    card.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                    "\(id) sits inside \(group)'s card"
                )
                // Not a blanket `isHidden == false`: Task 6a adds viewport
                // culling, and this assertion has to keep meaning the same thing
                // afterwards. What canvas mode guarantees is that a pane is
                // hidden only for being off-viewport — never for belonging to a
                // session that is not `activeGroup`.
                XCTAssertEqual(
                    workspace.container(for: id)?.isHidden,
                    !card.intersects(canvasViewport(of: workspace.camera, in: workspace.bounds)),
                    "\(id) is hidden only if its card is off-viewport"
                )
            }
        }
    }

    /// A card is the Desk viewport, so the panes in it must sit exactly where
    /// scale 1.0 will show them: the same sizes, offset by the card's origin and
    /// by nothing else. Anything else and entering a session would nudge the
    /// grid as the camera lands.
    func testACardsPanesSitExactlyWhereNormalModeWouldPutThem() throws {
        let workspace = makeCanvasWorkspace()

        // What normal mode puts each pane at, read off the real thing one
        // session at a time. A session that leaves the screen keeps its frames,
        // so these stay valid once the next one is activated.
        var normal: [String: CGRect] = [:]
        for group in workspace.groupIDs {
            workspace.activateGroup(group)
            for id in workspace.paneIDs {
                normal[id] = try XCTUnwrap(workspace.container(for: id)?.frame)
            }
        }

        workspace.canvasMode = true
        let root = workspace.derivedCanvasRoot()
        let layout = DeskCanvas.layout(root: root, cardSize: workspace.bounds.size, pinned: [:])

        for (group, panes) in Self.sessions {
            let card = try XCTUnwrap(layout.frames[group])
            for id in panes {
                let canvas = try XCTUnwrap(workspace.container(for: id)?.frame)
                let flat = try XCTUnwrap(normal[id])
                XCTAssertEqual(canvas.minX - flat.minX, card.minX, accuracy: 0.001, "\(id) x")
                XCTAssertEqual(canvas.minY - flat.minY, card.minY, accuracy: 0.001, "\(id) y")
                XCTAssertEqual(canvas.width, flat.width, accuracy: 0.001, "\(id) width")
                XCTAssertEqual(canvas.height, flat.height, accuracy: 0.001, "\(id) height")
            }
        }
    }

    /// The camera is one `sublayerTransform` and nothing else. Container frames
    /// stay in canvas coordinates, so `PaneGrid`, `place`, the resize coalescer
    /// and the PTY never learn that a zoom happened.
    func testTheCameraIsOneSublayerTransformAndLeavesEveryContainerFrameInCanvasSpace() throws {
        let workspace = makeCanvasWorkspace()
        workspace.canvasMode = true
        let before = workspace.allPaneIDs.compactMap { workspace.container(for: $0)?.frame }

        workspace.camera = DeskCamera(scale: 0.5, origin: CGPoint(x: 30, y: 20))

        let after = workspace.allPaneIDs.compactMap { workspace.container(for: $0)?.frame }
        XCTAssertEqual(before, after, "the camera never touches a frame")
        XCTAssertFalse(
            CATransform3DIsIdentity(try XCTUnwrap(workspace.layer).sublayerTransform),
            "it is on the layer instead"
        )

        let atOrigin = rendered(.zero, in: workspace)
        XCTAssertEqual(atOrigin.x, 30, accuracy: 0.001, "canvas (0,0) renders at the camera origin")
        XCTAssertEqual(atOrigin.y, 20, accuracy: 0.001)
        let far = rendered(CGPoint(x: 400, y: 200), in: workspace)
        XCTAssertEqual(far.x, 0.5 * 400 + 30, accuracy: 0.001, "and every point at scale * p + origin")
        XCTAssertEqual(far.y, 0.5 * 200 + 20, accuracy: 0.001)
    }

    /// `DeskCamera.transform` is written for a top-left origin —
    /// `viewPoint = scale * canvasPoint + origin` — so it is the right thing to
    /// install on `sublayerTransform` only if that transform scales sublayers
    /// about the bounds **corner**. Two facts make it so, and both are measured
    /// here rather than assumed, because the whole canvas silently drifts by
    /// half a viewport if either changes: `sublayerTransform` pivots about the
    /// parent layer's anchor point, and AppKit gives a layer-backed `NSView` a
    /// corner anchor — not UIKit's centred default.
    func testTheBackingLayerAnchorsAtItsCornerWhichIsWhatDeskCameraIsWrittenFor() throws {
        for (anchor, expected) in [
            (CGPoint.zero, CGPoint(x: 50, y: 50)),
            (CGPoint(x: 0.5, y: 0.5), CGPoint(x: 350, y: 250)),
        ] {
            let parent = CALayer()
            parent.bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)
            parent.anchorPoint = anchor
            parent.position = .zero
            let child = CALayer()
            child.anchorPoint = .zero
            child.frame = CGRect(x: 100, y: 100, width: 10, height: 10)
            parent.addSublayer(child)
            parent.sublayerTransform = CATransform3DMakeScale(0.5, 0.5, 1)
            XCTAssertEqual(
                child.convert(CGPoint.zero, to: parent),
                expected,
                "sublayerTransform pivots about the anchor \(anchor)"
            )
        }

        let workspace = makeCanvasWorkspace()
        let layer = try XCTUnwrap(workspace.layer)
        XCTAssertEqual(layer.anchorPoint, .zero, "AppKit anchors a backing layer at its corner")

        workspace.canvasMode = true
        workspace.camera = DeskCamera(scale: 0.5, origin: CGPoint(x: 30, y: 20))
        XCTAssertTrue(
            CATransform3DEqualToTransform(layer.sublayerTransform, workspace.camera.transform),
            "so the camera goes on unchanged, with no recentring folded in"
        )
    }

    /// A workspace node's id **is** its project id and a session node's id **is**
    /// its group id — the whole reason `canvasLayout.frames[group]` is a card
    /// rect directly, with no prefixing scheme and no join table to drift.
    func testTheDerivedTreeIsTheAccountThenOneWorkspacePerProjectThenItsSessions() {
        let workspace = makeCanvasWorkspace()
        let root = workspace.derivedCanvasRoot()

        XCTAssertEqual(root.id, "root")
        XCTAssertEqual(root.kind, .root)
        XCTAssertEqual(root.children.map(\.id), ["OmniAgent-ADE"])
        XCTAssertEqual(root.children.first?.kind, .workspace("OmniAgent-ADE"))
        XCTAssertEqual(
            root.children.first?.children.map(\.id),
            ["sess-grp-a", "sess-grp-b"],
            "session nodes are group ids, in groupOrder"
        )
        XCTAssertEqual(
            root.children.first?.children.map(\.kind),
            [.session("sess-grp-a"), .session("sess-grp-b")]
        )
    }

    /// `canvasLayout` is the storage every later task reads — the camera's
    /// `fitAll` content and hit testing's node rects. It is the canvas pass's
    /// output and nothing else's, so normal mode must not leave a stale one
    /// behind for them to resolve a click against.
    func testCanvasLayoutIsPublishedByTheCanvasPassAndClearedOnTheWayOut() throws {
        let workspace = makeCanvasWorkspace()
        XCTAssertNil(workspace.canvasLayout, "no canvas pass has run")

        workspace.canvasMode = true
        let layout = try XCTUnwrap(workspace.canvasLayout)
        XCTAssertEqual(
            layout,
            DeskCanvas.layout(root: workspace.derivedCanvasRoot(), cardSize: workspace.bounds.size, pinned: [:])
        )

        workspace.canvasMode = false
        XCTAssertNil(workspace.canvasLayout, "and normal mode leaves none behind")
    }

    /// A pin is handed straight to `DeskCanvas.layout`, so a dragged card's
    /// panes have to follow it — the pin moves the *card*, and the grid inside
    /// is laid out from the card.
    func testAPinnedSessionCarriesItsPanesToWhereItWasDropped() throws {
        let workspace = makeCanvasWorkspace()
        workspace.canvasMode = true
        let before = try XCTUnwrap(workspace.container(for: "b-1")?.frame)
        let card = try XCTUnwrap(workspace.canvasLayout?.frames["sess-grp-b"])

        let pin = CGPoint(x: card.minX + 400, y: card.minY + 300)
        workspace.canvasPins = ["sess-grp-b": pin]

        XCTAssertEqual(workspace.canvasLayout?.frames["sess-grp-b"]?.origin, pin)
        let after = try XCTUnwrap(workspace.container(for: "b-1")?.frame)
        XCTAssertEqual(after.minX - before.minX, 400, accuracy: 0.001)
        XCTAssertEqual(after.minY - before.minY, 300, accuracy: 0.001)
    }

    /// Camera moves must cost zero PTY resizes: an ancestor transform never
    /// calls `setFrameSize` on a descendant, which is the whole reason the
    /// camera lives on `sublayerTransform` rather than on the frames.
    func testMovingTheCameraSchedulesNoPTYResize() {
        let workspace = makeCanvasWorkspace()
        workspace.canvasMode = true
        workspace.resizeCoalescer.flush()
        let flushes = workspace.resizeCoalescer.flushCount

        workspace.camera = DeskCamera(scale: 0.35, origin: CGPoint(x: -200, y: -140))
        workspace.camera = DeskCamera(scale: 0.6, origin: CGPoint(x: 12, y: 8))

        XCTAssertFalse(workspace.resizeCoalescer.hasPending, "no pane was reframed")
        XCTAssertEqual(workspace.resizeCoalescer.flushCount, flushes)
    }


    // MARK: - Helpers

    private static let sessions: [(group: String, panes: [String])] = [
        ("sess-grp-a", ["a-1", "a-2", "a-3"]),
        ("sess-grp-b", ["b-1", "b-2"]),
    ]

    /// The camera's viewport in canvas coordinates, through the camera's own
    /// inverse. `DeskCamera.canvasViewport(in:)` arrives with Task 6a's
    /// culling; until then the two corners say the same thing.
    private func canvasViewport(of camera: DeskCamera, in bounds: CGRect) -> CGRect {
        let topLeft = camera.canvasPoint(from: CGPoint(x: bounds.minX, y: bounds.minY))
        let bottomRight = camera.canvasPoint(from: CGPoint(x: bounds.maxX, y: bounds.maxY))
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    /// Where the compositor actually puts a canvas point. `sublayerTransform` is
    /// applied about the layer's **anchor point**, which AppKit puts at the
    /// corner of a backing layer's bounds — see
    /// `testTheBackingLayerAnchorsAtItsCornerWhichIsWhatDeskCameraIsWrittenFor`,
    /// which measures both halves of that claim.
    private func rendered(_ point: CGPoint, in view: NSView) -> CGPoint {
        guard let layer = view.layer else { return point }
        return point.applying(CATransform3DGetAffineTransform(layer.sublayerTransform))
    }

    /// Two sessions in one project — three panes and two — with the first on
    /// screen. The production `makeSurface` shape, against a socket nobody is
    /// listening on, exactly as every other workspace suite in this target does.
    private func makeCanvasWorkspace() -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            switch descriptor.kind {
            case .terminal:
                return TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
            case .browser:
                return BrowserPaneView(initialURL: descriptor.browserURL)
            case .editor:
                return EditorPaneView(
                    initialTabs: descriptor.editorTabs,
                    activeIndex: descriptor.editorActiveIndex
                )
            }
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for (group, panes) in Self.sessions {
            for id in panes {
                XCTAssertTrue(workspace.addPane(makeDescriptor(id, group: group)))
            }
        }
        workspace.activateGroup("sess-grp-a")
        return workspace
    }

    private func makeDescriptor(_ id: String, group: String) -> PaneDescriptor {
        PaneDescriptor(sessionID: id, group: group, title: "", project: "OmniAgent-ADE")
    }
}
