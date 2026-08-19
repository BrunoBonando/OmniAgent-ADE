import AppKit
import XCTest
@testable import OmniAgent

/// The canvas's input layer, and the one rule the whole spatial design rests
/// on: `NSView` coordinate conversion and `event.locationInWindow` are blind to
/// a `CALayer` transform, and roughly ten call sites in `PaneWorkspaceView`
/// depend on them — `PaneDividerView.mouseDragged`'s window-space delta,
/// `PaneHeaderView`'s 4pt drag threshold, `PaneHeaderButton.mouseUp`'s
/// `bounds.contains(convert(event.locationInWindow, from: nil))`,
/// `PaneHolePlaceholderView`'s `mouseMoved`/`mouseUp`/`dispatch(at:)`,
/// `PaneContainerView.editorTabDropZone`, and the `resetCursorRects` /
/// `updateTrackingAreas` pairs behind all of them. Every one of those is
/// correct at `sublayerTransform == identity` and wrong at any other scale, so
/// panes accept input at `scale == 1.0` and nowhere else. Below it the canvas
/// itself is the responder and the answer to every hit test.
final class DeskCanvasInputTests: XCTestCase {

    // MARK: - The identity boundary

    /// At identity the transform *is* identity, so nothing has changed for the
    /// panes: `hitTest` must defer to `super` and a pane must be able to answer.
    ///
    /// Entered rather than assigned, because "canvas mode with an identity
    /// camera" is not a state the app rests in: `landSession` turns canvas mode
    /// off as it snaps the transform, precisely so that "identity" and "this
    /// card fills the viewport" are the same picture. With no window the flight
    /// lands in this same turn.
    func testAtIdentityScaleHitTestingIsExactlyWhatItAlwaysWas() throws {
        let workspace = makeCanvasWorkspace(sessions: 2)
        workspace.enterSession(workspace.groupIDs[0])
        XCTAssertTrue(workspace.camera.isIdentity, "the fixture's premise")
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))

        let hit = workspace.hitTest(CGPoint(x: container.frame.midX, y: container.frame.midY))

        XCTAssertNotNil(hit, "something is under the pointer")
        XCTAssertFalse(hit === workspace, "at identity a pane answers, not the canvas")
    }

    /// And below it, nothing inside ever sees a mouse event.
    func testBelowIdentityScaleTheCanvasTakesEveryHitInsideItsFrame() {
        let workspace = makeCanvasWorkspace(sessions: 2)
        workspace.camera = DeskCamera(scale: 0.3, origin: .zero)
        XCTAssertFalse(workspace.camera.isIdentity, "the fixture's premise")

        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 600, y: 400), CGPoint(x: 1199, y: 799)] {
            XCTAssertTrue(workspace.hitTest(point) === workspace, "the canvas takes the hit at \(point)")
        }
        XCTAssertNil(workspace.hitTest(CGPoint(x: 1400, y: 400)), "and nothing outside its frame")
    }

    /// The node under the pointer comes from inverting the camera by hand,
    /// because AppKit cannot be asked: `convert(_:from:)` does not know the
    /// `sublayerTransform` exists.
    func testTheNodeUnderThePointerIsFoundByInvertingTheCamera() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let layout = try XCTUnwrap(workspace.canvasLayout, "canvas mode must produce a layout")
        let group = workspace.groupIDs[1]
        let node = try XCTUnwrap(nodeID(forGroup: group, in: workspace))
        let rect = try XCTUnwrap(layout.frames[node])
        workspace.camera = DeskCamera.fitAll(content: layout.contentRect, in: workspace.bounds)

        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let viewPoint = CGPoint(
            x: centre.x * workspace.camera.scale + workspace.camera.origin.x,
            y: centre.y * workspace.camera.scale + workspace.camera.origin.y
        )
        // The inverse the implementation uses, checked against the forward map
        // this test just applied — so the pair stays honest whatever
        // `DeskCamera.transform` turns out to be composed of.
        XCTAssertEqual(workspace.camera.canvasPoint(from: viewPoint).x, centre.x, accuracy: 0.01)
        XCTAssertEqual(workspace.camera.canvasPoint(from: viewPoint).y, centre.y, accuracy: 0.01)
        XCTAssertEqual(workspace.canvasNode(at: viewPoint), node, "the middle session card")
    }

    // MARK: - Camera gestures

    /// A pan is a pure origin translation: the scale does not move.
    func testPanningMovesTheOriginByTheScrollDeltaAndNothingElse() {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let before = workspace.camera

        workspace.panCanvas(by: CGSize(width: 40, height: -25))

        XCTAssertEqual(workspace.camera.scale, before.scale, accuracy: 0.0001, "a pan does not zoom")
        XCTAssertEqual(workspace.camera.origin.x, before.origin.x + 40, accuracy: 0.0001)
        XCTAssertEqual(workspace.camera.origin.y, before.origin.y - 25, accuracy: 0.0001)
    }

    /// The one thing people notice immediately if it is wrong: the canvas point
    /// under the pointer must not move while you pinch.
    ///
    /// Seated at `fitAll` first, because a fresh canvas mode camera is already
    /// at the 1.0 ceiling and "did it zoom in" has no answer up there.
    func testZoomingAboutAPointLeavesThatCanvasPointUnderThePointer() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let layout = try XCTUnwrap(workspace.canvasLayout)
        workspace.camera = DeskCamera.fitAll(content: layout.contentRect, in: workspace.bounds)
        let anchor = CGPoint(x: 900, y: 220)
        let before = workspace.camera.canvasPoint(from: anchor)
        let scaleBefore = workspace.camera.scale

        workspace.zoomCanvas(by: PaneWorkspaceView.canvasZoomStep, about: anchor)

        let after = workspace.camera.canvasPoint(from: anchor)
        XCTAssertEqual(after.x, before.x, accuracy: 0.001, "the point under the pointer is fixed")
        XCTAssertEqual(after.y, before.y, accuracy: 0.001)
        XCTAssertGreaterThan(workspace.camera.scale, scaleBefore, "and it did zoom in")
    }

    /// `[fitAll, 1.0]`. Above 1.0 there is nothing to see and
    /// `metalRenderingScaleFactor()` clamps at `max(1, …)` anyway; below fitAll
    /// the whole tree is already on screen.
    func testZoomStopsAtOneAboveAndAtFitAllBelow() {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let centre = CGPoint(x: workspace.bounds.midX, y: workspace.bounds.midY)

        for _ in 0..<40 { workspace.zoomCanvas(by: PaneWorkspaceView.canvasZoomStep, about: centre) }
        XCTAssertEqual(workspace.camera.scale, DeskCamera.maxScale, accuracy: 0.0001, "1.0 is the ceiling")

        for _ in 0..<40 { workspace.zoomCanvas(by: 1 / PaneWorkspaceView.canvasZoomStep, about: centre) }
        XCTAssertEqual(
            workspace.camera.scale,
            workspace.minimumCanvasScale,
            accuracy: 0.0001,
            "fitAll is the floor"
        )
    }

    /// "Keep zooming past a threshold" is the fourth way in (spec §5) and it has
    /// to resolve to the same one operation as a double-click. A pinch that
    /// reaches 1.0 over a session card enters that session, rather than leaving
    /// the camera at scale 1 with a fractional origin — a state `isIdentity`
    /// rejects, so no pane would accept input in it.
    ///
    /// It lives on `pinchCanvas` and not on `zoomCanvas` on purpose: ⌘+ is aimed
    /// at the viewport centre, which at fitAll is routinely over the middle
    /// card, and a keyboard zoom that teleported into a session would be a
    /// different command than the one that was pressed.
    func testAPinchThatReachesOneOverASessionCardEntersThatSession() throws {
        let workspace = makeCanvasWorkspace(sessions: 3)
        let layout = try XCTUnwrap(workspace.canvasLayout)
        let group = workspace.groupIDs[2]
        let node = try XCTUnwrap(nodeID(forGroup: group, in: workspace))
        let rect = try XCTUnwrap(layout.frames[node])
        workspace.camera = DeskCamera.fitAll(content: layout.contentRect, in: workspace.bounds)
        let anchor = CGPoint(
            x: rect.midX * workspace.camera.scale + workspace.camera.origin.x,
            y: rect.midY * workspace.camera.scale + workspace.camera.origin.y
        )

        for _ in 0..<40 { workspace.pinchCanvas(by: 1.3, about: anchor) }

        XCTAssertEqual(workspace.activeGroup, group, "the pinch landed in that session")
    }

    // MARK: - Helpers

    /// One session per group, one pane each, sized like the real Desk. Mirrors
    /// `PaneWorkspaceViewTests.makeWorkspace(panes:)`, whose helpers are private
    /// to that class. Terminals only, following `DeskCanvasLODTests`: the input
    /// rules are kind-neutral and a WKWebView pane costs the test host a
    /// renderer process for nothing. The socket is one nobody is listening on:
    /// the Debug `test` path deliberately never builds the Rust daemon.
    private func makeCanvasWorkspace(sessions: Int) -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-input-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for index in 1...sessions {
            XCTAssertTrue(workspace.addPane(PaneDescriptor(
                sessionID: "pane-\(index)",
                group: "sess-grp-\(index)",
                groupLabel: nil,
                title: ""
            )))
        }
        workspace.canvasMode = true
        return workspace
    }

    private func makeAttachedCanvasWorkspace(sessions: Int) -> (PaneWorkspaceView, NSWindow) {
        let workspace = makeCanvasWorkspace(sessions: sessions)
        let window = WorkspaceWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        // `NSWindow` defaults to releasing itself when closed and every helper
        // here closes its window in a `defer` while ARC still holds this
        // reference — an over-release that SIGSEGVs in a *later* test, inside a
        // CA commit's autorelease drain. See
        // `PaneWorkspaceViewTests.makeAttachedWorkspace`.
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        window.onFirstResponderChange = { [weak workspace] in workspace?.adoptFocus(from: $0) }
        window.makeKeyAndOrderFront(nil)
        return (workspace, window)
    }

    /// The tree the canvas is actually laid out from. `canvasRoot` is `nil`
    /// until something hands one in, and `nil` means "derive it" — the same
    /// thing `updateCanvasLayout()` means by it, so a test that read
    /// `canvasRoot` alone would be reading a tree the layout never used.
    private func tree(_ workspace: PaneWorkspaceView) -> DeskNode {
        workspace.canvasRoot ?? workspace.derivedCanvasRoot()
    }

    /// `DeskNode.id` and the group id are not required to be the same string,
    /// so a test that means "that session's node" has to walk the tree for it.
    private func nodeID(forGroup group: String, in workspace: PaneWorkspaceView) -> String? {
        func walk(_ node: DeskNode) -> String? {
            if case .session(let candidate) = node.kind, candidate == group { return node.id }
            for child in node.children {
                if let found = walk(child) { return found }
            }
            return nil
        }
        return walk(tree(workspace))
    }

    private func firstWorkspaceNode(in node: DeskNode) -> DeskNode? {
        if case .workspace = node.kind { return node }
        for child in node.children {
            if let found = firstWorkspaceNode(in: child) { return found }
        }
        return nil
    }

    /// A canvas point pushed forward through the camera and then out of the
    /// flipped view into the unflipped window, which is what an `NSEvent`
    /// carries. `PaneDividerView.mouseDragged` already depends on that flip.
    private func viewToWindow(canvas: CGPoint, _ workspace: PaneWorkspaceView) -> CGPoint {
        let viewPoint = CGPoint(
            x: canvas.x * workspace.camera.scale + workspace.camera.origin.x,
            y: canvas.y * workspace.camera.scale + workspace.camera.origin.y
        )
        return workspace.convert(viewPoint, to: nil)
    }

    private func mouseEvent(
        _ type: NSEvent.EventType,
        at windowPoint: CGPoint,
        clicks: Int = 1,
        in window: NSWindow
    ) -> NSEvent {
        // swiftlint:disable:next force_unwrapping
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: windowPoint.x, y: windowPoint.y),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: clicks,
            pressure: 1
        )!
    }
}
