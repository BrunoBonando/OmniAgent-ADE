import XCTest
import SwiftTerm
@testable import OmniAgent

/// Level of detail on the Desk canvas: what the camera cannot see is hidden,
/// what it can see but cannot read is drawn as a chip, and no cursor blinks
/// while nothing is being typed into.
///
/// All three exist because the canvas takes the number of panes AppKit
/// actually displays from ≤12 (one session) to ≤96 (`PaneWorkspaceView.maxTerminals`).
/// They assert on `isHidden`, never on `drawRequestCount`: that counter is
/// incremented only inside `TerminalSurfaceView.requestRendererDraw()`, so it
/// proves "our own extra kick was skipped" and nothing more — SwiftTerm's
/// `feedFinish() -> queuePendingDisplay() -> setNeedsDisplay` path runs on
/// every feed regardless of `suspendsDrawing`. Copying the assertion style of
/// `PaneWorkspaceViewTests.testSuspendedPanesStopRequestingDrawsButKeepParsingOutput`
/// into a level-of-detail test would ship a green test over a pane still
/// rendering full-resolution Metal frames.
final class DeskCanvasLODTests: XCTestCase {

    // MARK: - Reading the canvas

    /// The rect culling is measured against: what the camera can see, mapped
    /// back into canvas coordinates. Scale and translation only, no rotation,
    /// so two mapped corners bound it exactly.
    func testTheViewportIsWhatTheCameraCanSeeMappedBackIntoCanvasSpace() {
        let camera = DeskCamera(scale: 0.5, origin: CGPoint(x: 120, y: -40))
        let bounds = CGRect(x: 0, y: 0, width: 1200, height: 800)

        let viewport = camera.canvasViewport(in: bounds)

        XCTAssertEqual(viewport.width, 2400, accuracy: 0.001, "at half scale the viewport sees twice the canvas")
        XCTAssertEqual(viewport.height, 1600, accuracy: 0.001)
        XCTAssertTrue(
            viewport.contains(camera.canvasPoint(from: CGPoint(x: 600, y: 400))),
            "the centre of the view is inside what the view is showing"
        )
        XCTAssertFalse(
            viewport.contains(camera.canvasPoint(from: CGPoint(x: -10, y: 400))),
            "a point left of the view is not"
        )
    }

    /// A session's card rect is looked up by its **group** id, because a
    /// session node's id is its group id — `DeskNode.Kind.session` "carries the
    /// group id used everywhere else in the app".
    func testASessionsCardIsFoundByItsGroupId() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 2)

        let first = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        let second = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-2"))

        XCTAssertEqual(first.size, workspace.bounds.size, "a card is exactly the Desk viewport")
        XCTAssertEqual(second.size, workspace.bounds.size)
        XCTAssertFalse(first.intersects(second), "two session cards do not overlap")
        XCTAssertNil(workspace.canvasRect(forGroup: "grp-nobody"))
    }

    // MARK: - Viewport culling

    /// A card the camera is not showing is hidden outright — not "suspended".
    ///
    /// Asserted on `isHiddenOrHasHiddenAncestor` of the *surface*, because
    /// that is the observable that corresponds to work not happening: a hidden
    /// view is not composited and its `setNeedsDisplay` schedules nothing.
    /// `surface.suspendsDrawing` is checked too, but only as the belt-and-
    /// braces half — on its own it would gate one skipped renderer kick per
    /// feed burst and nothing else.
    func testASessionCardTheCameraCannotSeeIsHiddenEntirely() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 2)
        let near = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        let far = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-2"))

        workspace.camera = DeskCamera.focus(on: near, in: workspace.bounds)

        let viewport = workspace.camera.canvasViewport(in: workspace.bounds)
        XCTAssertTrue(near.intersects(viewport), "the fixture must put the first card on camera")
        XCTAssertFalse(far.intersects(viewport), "and the second one off it")

        let onCamera = try XCTUnwrap(workspace.container(for: "s1-p1"))
        XCTAssertFalse(onCamera.isHidden, "the card the camera is on stays up")
        XCTAssertFalse(onCamera.surface.isHiddenOrHasHiddenAncestor)

        for id in ["s2-p1", "s2-p2"] {
            let culled = try XCTUnwrap(workspace.container(for: id))
            XCTAssertTrue(culled.isHidden, "\(id) is off camera and must be hidden")
            XCTAssertTrue(
                culled.surface.isHiddenOrHasHiddenAncestor,
                "\(id)'s surface is not composited — the only thing that actually stops it rendering"
            )
            XCTAssertTrue(culled.surface.suspendsDrawing, "and our own renderer kick is skipped as well")
        }

        XCTAssertEqual(
            workspace.allPaneIDs.sorted(),
            ["s1-p1", "s1-p2", "s2-p1", "s2-p2"],
            "culling hides panes, it never tears one down"
        )
    }

    /// Culling follows the camera without a layout pass: an ancestor
    /// `CATransform3D` moves nothing's frame, so nothing else would recompute
    /// the visible set.
    func testMovingTheCameraBackOverACardBringsItUpAgain() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 1)
        let first = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        let second = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-2"))

        workspace.camera = DeskCamera.focus(on: first, in: workspace.bounds)
        XCTAssertTrue(try XCTUnwrap(workspace.container(for: "s2-p1")).isHidden)

        workspace.camera = DeskCamera.focus(on: second, in: workspace.bounds)
        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s2-p1")).isHidden)
        XCTAssertTrue(try XCTUnwrap(workspace.container(for: "s1-p1")).isHidden)
    }

    /// Normal mode is untouched by any of it: one session on screen, the rest
    /// hidden, exactly as `updateVisibility`'s doc comment has always said.
    func testLeavingCanvasModeRestoresTheOneSessionOnScreenRule() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 1)
        workspace.camera = DeskCamera.focus(
            on: try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1")),
            in: workspace.bounds
        )

        workspace.canvasMode = false

        XCTAssertEqual(workspace.activeGroup, "grp-2", "the last pane added is still the active session")
        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s2-p1")).isHidden)
        XCTAssertTrue(
            try XCTUnwrap(workspace.container(for: "s1-p1")).isHidden,
            "the camera's opinion dies with canvas mode"
        )
    }

    /// A card the camera is flying towards — or away from — is not hidden
    /// mid-flight. `flyCamera(to:)` sets `camera` to its destination on frame
    /// one, so culling against that alone would blink the tree out from under
    /// a camera still travelling through it.
    func testACardTheCameraIsFlyingAcrossStaysVisibleForTheWholeFlight() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 1)
        let first = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        let second = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-2"))

        workspace.camera = DeskCamera.focus(on: first, in: workspace.bounds)
        workspace.transitionViewport = first.union(second)
        workspace.camera = DeskCamera.focus(on: second, in: workspace.bounds)

        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s1-p1")).isHidden, "the card being left")
        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s2-p1")).isHidden, "the card being reached")

        workspace.transitionViewport = nil

        XCTAssertTrue(try XCTUnwrap(workspace.container(for: "s1-p1")).isHidden, "and on arrival it is culled")
        XCTAssertFalse(try XCTUnwrap(workspace.container(for: "s2-p1")).isHidden)
    }

    // MARK: - The chip threshold

    /// Below `DeskCanvas.lodThreshold` a pane surface carries no information —
    /// at 0.2 a 12pt glyph is 2.4pt — so the surface comes down and a chip
    /// takes its place. Hidden, not suspended: hiding is the only thing that
    /// stops SwiftTerm's own draw path.
    func testAnOnScreenSessionBelowTheThresholdHidesItsSurfacesAndShowsChips() throws {
        let workspace = makeCanvasWorkspace(sessions: 2, panesEach: 2)
        let both = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
            .union(try XCTUnwrap(workspace.canvasRect(forGroup: "grp-2")))

        workspace.camera = DeskCamera.focus(
            on: both.insetBy(dx: -both.width * 4.5, dy: -both.height * 4.5),
            in: workspace.bounds
        )

        XCTAssertLessThan(
            workspace.camera.scale,
            DeskCanvas.lodThreshold,
            "the fixture must actually be below the chip threshold"
        )
        XCTAssertTrue(workspace.showsChips)

        for id in ["s1-p1", "s1-p2", "s2-p1", "s2-p2"] {
            let container = try XCTUnwrap(workspace.container(for: id))
            XCTAssertFalse(container.isHidden, "\(id)'s card is on camera")
            XCTAssertTrue(container.isChipped, "\(id) is drawn as a chip")
            XCTAssertTrue(container.surface.isHidden, "\(id)'s surface is down, not merely suspended")
            XCTAssertTrue(container.header.isHidden, "and so is its 3pt header")
            XCTAssertFalse(container.chip.isHidden)
            XCTAssertEqual(
                container.chip.frame,
                container.bounds.insetBy(
                    dx: PaneContainerView.borderWidth,
                    dy: PaneContainerView.borderWidth
                ),
                "the chip fills the pane inside its 1pt ring"
            )
        }
    }

    /// The chip carries what the header carries — engine, name, status —
    /// because at this scale the header cannot.
    func testTheChipCarriesTheEngineTheNameAndTheStatus() throws {
        let workspace = makeCanvasWorkspace(sessions: 1, panesEach: 1)
        workspace.updateDescriptor(for: "s1-p1") { $0.label = "Ingest rewrite" }
        workspace.setStatus(.awaitingApproval, for: "s1-p1")

        let chip = try XCTUnwrap(workspace.container(for: "s1-p1")).chip

        XCTAssertEqual(chip.title, "Ingest rewrite")
        XCTAssertEqual(chip.engine, .claude)
        XCTAssertEqual(chip.status, .awaitingApproval)
    }

    /// A browser or editor carries `.shell` as a placeholder engine, and a chip
    /// claiming it runs one would say a thing that is not true — the header
    /// already refuses this for exactly the same reason.
    func testANonTerminalPanesChipShowsNoEngine() throws {
        let workspace = makeCanvasWorkspace(sessions: 1, panesEach: 1)
        XCTAssertTrue(
            workspace.addPane(
                PaneDescriptor(
                    sessionID: "web-1",
                    group: "grp-1",
                    kind: .browser,
                    browserURL: "https://example.com"
                )
            )
        )

        XCTAssertNil(try XCTUnwrap(workspace.container(for: "web-1")).chip.engine)
        XCTAssertEqual(try XCTUnwrap(workspace.container(for: "web-1")).chip.title, "https://example.com")
    }

    /// `roundChildren(inside:)` resolves `maskedCorners` in each child's **own**
    /// coordinate space, and its comment records what getting that wrong cost:
    /// "Naming `MaxY` \"the bottom\" for every child put the unflipped terminal
    /// surface's rounding at its *top* on screen … The offscreen render harness
    /// cannot show the difference (`CALayer.render(in:)` skips the compositor's
    /// geometry flips), which is how it went unseen."
    ///
    /// The chip fills the container on its own, so it takes all four corners
    /// and no flip can matter. That is what this pins — a PNG never could.
    func testTheChipTakesAllFourCornersSoNoGeometryFlipCanRoundItUpsideDown() throws {
        let workspace = makeCanvasWorkspace(sessions: 1, panesEach: 2)
        let chip = try XCTUnwrap(workspace.container(for: "s1-p1")).chip

        XCTAssertEqual(
            try XCTUnwrap(chip.layer?.maskedCorners),
            [
                .layerMinXMinYCorner, .layerMaxXMinYCorner,
                .layerMinXMaxYCorner, .layerMaxXMaxYCorner,
            ],
            "all four, so the chip's rounding reads the same whichever way its layer is flipped"
        )
        XCTAssertEqual(
            chip.layer?.cornerRadius,
            PaneContainerView.cornerRadius - PaneContainerView.borderWidth,
            "concentric inside the container's, one border width smaller"
        )
    }

    /// Coming back above the threshold, the surface must be told to paint.
    /// While it was hidden its `setNeedsDisplay` scheduled nothing, and
    /// `MacTerminalView.draw(_:)` is `if metalView != nil { return }` — so
    /// `needsDisplay = true` is a no-op once Metal is on and an idle terminal
    /// would sit there showing a stale drawable.
    ///
    /// `drawRequestCount` is the right assertion *here* and only here: this
    /// test asserts a draw was requested, which is exactly what the counter
    /// counts. It is the wrong assertion for anything claiming a pane stopped
    /// drawing.
    func testASurfaceComingBackAboveTheThresholdIsRepaintedNotLeftOnItsLastDrawable() throws {
        let workspace = makeCanvasWorkspace(sessions: 1, panesEach: 1)
        let card = try XCTUnwrap(workspace.canvasRect(forGroup: "grp-1"))
        workspace.camera = DeskCamera.focus(
            on: card.insetBy(dx: -card.width * 4.5, dy: -card.height * 4.5),
            in: workspace.bounds
        )
        XCTAssertTrue(try XCTUnwrap(workspace.container(for: "s1-p1")).isChipped)
        let before = try XCTUnwrap(workspace.container(for: "s1-p1")).terminalSurface.drawRequestCount

        workspace.camera = DeskCamera.focus(on: card, in: workspace.bounds)

        let container = try XCTUnwrap(workspace.container(for: "s1-p1"))
        XCTAssertFalse(container.isChipped)
        XCTAssertFalse(container.surface.isHidden)
        XCTAssertTrue(container.chip.isHidden)
        XCTAssertGreaterThan(
            container.terminalSurface.drawRequestCount,
            before,
            "the surface is kicked once on the way back up"
        )
    }

    // MARK: - Helpers

    /// `PaneWorkspaceViewTests.makeWorkspace(panes:)`'s shape, with one grid
    /// per session and canvas mode already on. Terminals only: the level-of-
    /// detail rules are kind-neutral and a WKWebView pane costs the test host
    /// a renderer process for nothing.
    private func makeCanvasWorkspace(sessions: Int, panesEach: Int) -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-lod-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for session in 1...sessions {
            for pane in 1...panesEach {
                XCTAssertTrue(
                    workspace.addPane(
                        PaneDescriptor(
                            sessionID: "s\(session)-p\(pane)",
                            group: "grp-\(session)",
                            title: "",
                            engine: .claude
                        )
                    ),
                    "s\(session)-p\(pane) must be accepted"
                )
            }
        }
        workspace.canvasMode = true
        workspace.layoutSubtreeIfNeeded()
        return workspace
    }
}

/// Everything in this file drives terminal panes, so the concrete surface is
/// one force-cast away — a crash here means a test built a pane kind it does
/// not handle, which deserves to fail loudly. (The same helper is `private` to
/// `PaneWorkspaceViewTests`, so it is repeated rather than shared.)
private extension PaneContainerView {
    var terminalSurface: TerminalSurfaceView { surface as! TerminalSurfaceView }
}
