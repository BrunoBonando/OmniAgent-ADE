import AppKit
import XCTest
@testable import OmniAgent

/// The canvas has exactly one operation: move the camera so a rect maps onto
/// the viewport. A click on a card, a double-click, a session shortcut and a
/// zoom past identity (`pinchCanvas`, Task 8) all resolve to it, and so does the way back
/// out. This file pins the operation itself — the animation's mechanics, the
/// exactness of the landing, and the two things a camera move must *not* do:
/// swap the grid underneath the user, or cost a PTY resize.
final class DeskCameraFlightTests: XCTestCase {
    // MARK: - The flight

    /// The completion is scheduled with `DispatchQueue.main.asyncAfter` and
    /// guarded by a token, never handed to an animation's delegate, because with
    /// no window or under Reduce Motion "an animation group's completion is not
    /// guaranteed to arrive at all" (`setZoomed`). Here there is no window at
    /// all: the landing has to be synchronous or it never happens, and a camera
    /// stranded between two sessions leaves no pane accepting input.
    func testAFlightWithNoWindowLandsTheSessionTheInstantItIsAsked() throws {
        let workspace = makeWorkspace(groups: 2, panesPerGroup: 2)
        XCTAssertNil(workspace.window, "the point of this test")
        workspace.canvasMode = true
        let layer = try XCTUnwrap(workspace.layer)
        // A decoy under another key. `finishCameraFlight` removes its own
        // animation by key and leaves everything else alone — `landCard`'s rule:
        // "yanking whatever else a layer happens to be running is how you break
        // something you did not write."
        let decoy = CABasicAnimation(keyPath: "opacity")
        decoy.fromValue = 1.0
        decoy.toValue = 1.0
        decoy.duration = 60
        layer.add(decoy, forKey: "test-decoy")

        workspace.enterSession("sess-grp-2")

        XCTAssertFalse(workspace.canvasMode, "landed, with nothing to wait for")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-2")
        XCTAssertEqual(workspace.camera, DeskCamera(scale: 1, origin: .zero))
        XCTAssertTrue(workspace.camera.isIdentity, "identity is what landing means")
        XCTAssertTrue(
            CATransform3DIsIdentity(layer.sublayerTransform),
            "snapped on arrival, or the text stays permanently soft"
        )
        XCTAssertNil(layer.animation(forKey: PaneWorkspaceView.cameraFlightKey))
        XCTAssertNotNil(
            layer.animation(forKey: "test-decoy"),
            "removed by key, never with removeAllAnimations()"
        )
    }

    /// One system with the pane zoom: the same 0.38s and the same front-loaded
    /// curve, so entering a session and zooming a pane read as the same gesture
    /// at two scales. A raw `CABasicAnimation` rather than `NSView.animator()`,
    /// for the reason `place` records — the animator wraps each frame change in
    /// an `_NSWindowTransformAnimation`, and two of those were seen alive on one
    /// view when a second transition began inside the first's.
    func testTheFlightAnimatesThisViewsSublayerTransformWithTheZoomsDurationAndCurve() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("under Reduce Motion the camera lands instantly")
        }
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 1)
        defer { window.close() }
        workspace.canvasMode = true
        let layer = try XCTUnwrap(workspace.layer)
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)
        let before = layer.sublayerTransform

        workspace.flyCamera(to: DeskCamera.fitAll(content: content, in: workspace.bounds))

        let flight = try XCTUnwrap(
            layer.animation(forKey: PaneWorkspaceView.cameraFlightKey) as? CABasicAnimation
        )
        XCTAssertEqual(flight.keyPath, "sublayerTransform", "the camera is a transform, not a frame")
        XCTAssertEqual(flight.duration, PaneWorkspaceView.zoomTransitionDuration)
        XCTAssertEqual(flight.timingFunction, PaneWorkspaceView.zoomTimingFunction)
        let from = try XCTUnwrap((flight.fromValue as? NSValue)?.caTransform3DValue)
        XCTAssertTrue(
            CATransform3DEqualToTransform(from, before),
            "from where the eye is, not from the model it already left"
        )
        XCTAssertTrue(
            CATransform3DEqualToTransform(layer.sublayerTransform, workspace.camera.transform),
            "the model value lands immediately — `place`'s discipline"
        )
        XCTAssertNil(layer.animation(forKey: "position"), "the camera moves nothing's frame")
    }

    /// Two flights inside one duration. Both completions arrive; without the
    /// token the *entry*'s completion lands session 2 partway through the exit
    /// that followed it, and the user is dropped into a session they just flew
    /// away from. The same failure `zoomTransitionToken` exists for.
    func testAnEntrysCompletionCannotLandTheSessionTheExitFlewAwayFrom() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("under Reduce Motion both flights land instantly")
        }
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 1)
        defer { window.close() }
        workspace.canvasMode = true
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)

        let entered = Date()
        workspace.enterSession("sess-grp-2")
        RunLoop.current.run(
            until: entered.addingTimeInterval(PaneWorkspaceView.zoomTransitionDuration / 2)
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(entered),
            PaneWorkspaceView.zoomTransitionDuration,
            "the entry's completion has to still be pending, or this proves nothing"
        )

        workspace.exitToCanvas()
        RunLoop.current.run(
            until: Date().addingTimeInterval(PaneWorkspaceView.zoomTransitionDuration + 0.2)
        )

        XCTAssertTrue(workspace.canvasMode, "the leftover completion did not land session 2")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-1")
        XCTAssertEqual(
            workspace.camera,
            DeskCamera.fitAll(content: content, in: workspace.bounds)
        )
    }

    // MARK: - In and out

    /// Entering is aiming: the camera that maps that card's rect onto the
    /// viewport. Because §4 forces a card to be exactly the Desk viewport, that
    /// camera is identity-scaled — which is what makes "the camera arrived" and
    /// "you are in the session" the same fact.
    func testEnteringASessionAimsTheCameraAtThatSessionsCard() throws {
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 1)
        defer { window.close() }
        workspace.canvasMode = true
        let card2 = try card(workspace, "sess-grp-2")

        workspace.enterSession("sess-grp-2")

        XCTAssertEqual(workspace.camera, DeskCamera.focus(on: card2, in: workspace.bounds))
        XCTAssertEqual(workspace.camera.scale, 1, accuracy: 0.0001, "a card is the viewport")
        XCTAssertTrue(
            workspace.camera.isIdentity,
            "and the layout places cards at integral origins, or nothing may accept input here"
        )
        XCTAssertTrue(workspace.canvasMode, "still flying — the landing is 0.38s away")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-1", "and the grid has not changed yet")
    }

    /// Off the canvas the rule is the old one. Every existing caller of
    /// `activateGroup` — the sidebar, the palette, restore — reaches this and
    /// must still get an instant switch and no camera at all.
    func testEnteringASessionOffTheCanvasIsStillTheInstantSwitch() {
        let workspace = makeWorkspace(groups: 2, panesPerGroup: 1)
        XCTAssertFalse(workspace.canvasMode)

        workspace.enterSession("sess-grp-2")

        XCTAssertEqual(workspace.activeGroup, "sess-grp-2")
        XCTAssertTrue(workspace.paneIDs.contains("sess-2-pane-1"))
        XCTAssertEqual(workspace.camera, DeskCamera(scale: 1, origin: .zero), "no flight off the canvas")
    }

    /// Leaving joins the canvas *where the session already is*: the layout mode
    /// changes and the camera is re-seated on that card in the same turn, so the
    /// flight starts from the pixels that were on screen. Read off the
    /// animation's `fromValue`, because the presentation layer at that instant
    /// still holds the transform of the layout that was just replaced — the one
    /// case `place`'s `start:` parameter exists for.
    func testLeavingASessionJoinsTheCanvasWhereItWasBeforeFlyingToFitAll() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("under Reduce Motion the camera lands instantly, with no fromValue to read")
        }
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 1)
        defer { window.close() }
        XCTAssertFalse(workspace.canvasMode)
        let layer = try XCTUnwrap(workspace.layer)

        workspace.exitToCanvas()

        XCTAssertTrue(workspace.canvasMode)
        let card1 = try card(workspace, "sess-grp-1")
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)
        let flight = try XCTUnwrap(
            layer.animation(forKey: PaneWorkspaceView.cameraFlightKey) as? CABasicAnimation
        )
        let from = try XCTUnwrap((flight.fromValue as? NSValue)?.caTransform3DValue)
        XCTAssertTrue(
            CATransform3DEqualToTransform(
                from,
                DeskCamera.focus(on: card1, in: workspace.bounds).transform
            ),
            "the canvas opens on the session you were in, so the mode change shows nothing"
        )
        XCTAssertEqual(
            workspace.camera,
            DeskCamera.fitAll(content: content, in: workspace.bounds),
            "and flies to the whole tree"
        )
    }

    // MARK: - Focus

    /// `focusPane`'s comment today: "Focusing a pane in another session brings
    /// that session to the screen. This is the single rule that makes the
    /// sidebar work." On the canvas that rule becomes *fly there* — swapping
    /// `activeGroup` underneath the user would replace what they are looking at
    /// with a session that is drawn somewhere else entirely.
    func testFocusingAPaneInAnotherSessionFliesInsteadOfSwappingTheGridUnderneath() throws {
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 2)
        defer { window.close() }
        workspace.canvasMode = true
        let card2 = try card(workspace, "sess-grp-2")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-1")

        workspace.focusPane("sess-2-pane-1")

        XCTAssertEqual(workspace.activeGroup, "sess-grp-1", "the grid did not change underneath")
        XCTAssertTrue(workspace.canvasMode)
        XCTAssertEqual(
            workspace.camera,
            DeskCamera.focus(on: card2, in: workspace.bounds),
            "aimed at session 2's card"
        )
        XCTAssertNotEqual(workspace.focusedPaneID, "sess-2-pane-1", "focus waits for the landing")
    }

    /// And the request is not lost on the way: the pane the caller asked for is
    /// the pane that has focus when the camera arrives, not merely the session's
    /// first. Works with or without Reduce Motion — the loop exits on the first
    /// pass when the landing was instant.
    func testTheLandingFocusesTheVeryPaneTheFlightWasAskedFor() throws {
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 2)
        defer { window.close() }
        workspace.canvasMode = true

        workspace.focusPane("sess-2-pane-2")
        let deadline = Date().addingTimeInterval(3)
        while workspace.canvasMode, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        XCTAssertFalse(workspace.canvasMode, "the flight landed")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-2")
        XCTAssertEqual(workspace.focusedPaneID, "sess-2-pane-2")
        XCTAssertTrue(workspace.camera.isIdentity)
        let layer = try XCTUnwrap(workspace.layer)
        XCTAssertTrue(CATransform3DIsIdentity(layer.sublayerTransform))
    }

    // MARK: - The gestures are one operation

    /// The spec's whole navigation rule in one test. A click on a card and a
    /// double-click both call `enterSession`; a session shortcut reaches
    /// `focusPane`; a pinch reaches `pinchCanvas` (Task 8). All three aim the camera at
    /// exactly the same rect, so there is one operation and no second code path
    /// to drift.
    func testEveryWayIntoASessionResolvesToTheSameCamera() throws {
        let (workspace, window) = makeAttachedWorkspace(groups: 2, panesPerGroup: 2)
        defer { window.close() }
        workspace.canvasMode = true
        let card2 = try card(workspace, "sess-grp-2")
        let expected = DeskCamera.focus(on: card2, in: workspace.bounds)

        workspace.enterSession("sess-grp-2")
        let byClick = workspace.camera

        workspace.exitToCanvas()
        workspace.focusPane("sess-2-pane-1")
        let byShortcut = workspace.camera

        workspace.exitToCanvas()
        let cursor = viewPoint(workspace.camera, CGPoint(x: card2.midX, y: card2.midY))
        XCTAssertEqual(
            workspace.camera.canvasPoint(from: cursor).x,
            card2.midX,
            accuracy: 0.5,
            "the helper's inverse agrees with the camera's own"
        )
        // The pinch funnel lives in Task 8 (`pinchCanvas`); this task pins only
        // that the rect it must land on is the same one the other two reach.
        workspace.enterSession("sess-grp-2")
        let byZoom = workspace.camera

        XCTAssertEqual(byClick, expected, "the click")
        XCTAssertEqual(byShortcut, expected, "the session shortcut")
        XCTAssertEqual(byZoom, expected, "the zoom past the threshold, which hands off to enterSession")
    }

    // MARK: - What a camera move must not cost

    /// An ancestor's `sublayerTransform` does not call `setFrameSize` on
    /// descendants, so `TerminalSurfaceView.sizeChanged(source:newCols:newRows:)`
    /// never fires and no `resize` is scheduled. That is the whole reason the
    /// camera is a transform rather than N reframes: panning and zooming a
    /// canvas of up to 96 live terminals must be free of PTY traffic. Asserted
    /// rather than assumed.
    func testACameraMoveCostsNoPTYResizes() throws {
        let workspace = makeWorkspace(groups: 2, panesPerGroup: 3)
        workspace.canvasMode = true
        let content = try XCTUnwrap(workspace.canvasLayout?.contentRect)
        workspace.camera = DeskCamera.fitAll(content: content, in: workspace.bounds)
        // Everything the mode change itself scheduled, sent and settled first.
        workspace.resizeCoalescer.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        workspace.resizeCoalescer.flush()
        let flushes = workspace.resizeCoalescer.flushCount
        let sends = workspace.allPaneIDs.reduce(into: [String: Int]()) {
            $0[$1] = workspace.terminalSurface(for: $1)?.resizeSendCount
        }

        workspace.camera = DeskCamera.focus(
            on: content.insetBy(dx: content.width * 0.05, dy: content.height * 0.05),
            in: workspace.bounds
        )
        workspace.flyCamera(to: DeskCamera.fitAll(content: content, in: workspace.bounds))
        workspace.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertLessThan(
            workspace.camera.scale,
            DeskCamera.maxScale,
            "these moves must stay short of identity, or the landing's reflow is what is measured"
        )
        XCTAssertTrue(workspace.canvasMode)
        XCTAssertFalse(workspace.resizeCoalescer.hasPending, "nothing was even scheduled")
        XCTAssertEqual(workspace.resizeCoalescer.flushCount, flushes, "no flush")
        for id in workspace.allPaneIDs {
            XCTAssertEqual(workspace.terminalSurface(for: id)?.resizeSendCount, sends[id], id)
        }
    }

    /// The camera looks cards up by group id and never walks the node tree, so
    /// a session node's id has to *be* its group id. If the tidy tree ever keys
    /// a card by anything else, every entry silently aims at nothing.
    func testEverySessionHasACardKeyedByItsGroupID() {
        let workspace = makeWorkspace(groups: 3, panesPerGroup: 1)
        workspace.canvasMode = true

        for group in workspace.groupIDs {
            XCTAssertNotNil(workspace.canvasRect(forGroup: group), "no card for \(group)")
        }
        XCTAssertNil(workspace.canvasRect(forGroup: "sess-grp-nope"))
    }

    // MARK: - Helpers

    /// Panes are added one at a time, exactly as ⌘T does, across `groups`
    /// sessions. `addPane` makes the last-added pane's session active, so this
    /// ends by activating the first — every test here starts in session 1.
    private func makeWorkspace(groups: Int, panesPerGroup: Int) -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-camera-test.sock")
        )
        let workspace = PaneWorkspaceView { descriptor in
            TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for group in 1...groups {
            for pane in 1...panesPerGroup {
                XCTAssertTrue(workspace.addPane(PaneDescriptor(
                    sessionID: "sess-\(group)-pane-\(pane)",
                    group: "sess-grp-\(group)"
                )))
            }
        }
        workspace.activateGroup("sess-grp-1")
        return workspace
    }

    private func makeAttachedWorkspace(
        groups: Int,
        panesPerGroup: Int
    ) -> (PaneWorkspaceView, NSWindow) {
        let workspace = makeWorkspace(groups: groups, panesPerGroup: panesPerGroup)
        let window = WorkspaceWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        // `NSWindow` defaults to releasing itself when closed and every helper
        // here closes its window in a `defer` while ARC still holds this
        // reference — an over-release that frees the window early, leaving
        // CoreAnimation's window-scoped registrations dangling for the next
        // autorelease-pool drain to dereference. See `PaneWorkspaceViewTests`.
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        window.onFirstResponderChange = { [weak workspace] in workspace?.adoptFocus(from: $0) }
        window.makeKeyAndOrderFront(nil)
        return (workspace, window)
    }

    /// Where the canvas pass actually drew a session's card. Read back rather
    /// than assumed, so these tests pin the camera's behaviour and not the tidy
    /// tree's arithmetic.
    private func card(_ workspace: PaneWorkspaceView, _ group: String) throws -> CGRect {
        try XCTUnwrap(
            workspace.canvasRect(forGroup: group),
            "the canvas pass must place a card per session — none for \(group)"
        )
    }

    /// Canvas → view, the exact inverse of `DeskCamera.canvasPoint(from:)`
    /// without assuming which order the camera composes its scale and its
    /// translation: the transform itself is affine, so ask it.
    private func viewPoint(_ camera: DeskCamera, _ canvasPoint: CGPoint) -> CGPoint {
        canvasPoint.applying(CATransform3DGetAffineTransform(camera.transform))
    }
}
