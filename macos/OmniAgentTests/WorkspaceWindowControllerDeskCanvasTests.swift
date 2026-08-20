import AppKit
import XCTest
@testable import OmniAgent

/// The Desk canvas's wiring into the window: the destination that loads it,
/// the menu and toolbar commands that drive it, and the `desk_canvas_native`
/// row that outlives a launch. The canvas geometry itself is `DeskCanvasTests`'
/// job — nothing here computes a layout, it only checks that the app reaches
/// the canvas and hands it the right state.
final class WorkspaceWindowControllerDeskCanvasTests: XCTestCase {
    /// DESK *is* the canvas: there is no separate content root, so the only
    /// thing selecting it can do is put the one pane workspace into its second
    /// layout mode. Leaving takes it back out, so a hidden workspace is not
    /// laying out every session's grid for nobody.
    func testTheDeskDestinationLoadsTheCanvasAndLeavingItUnloadsIt() {
        let controller = makeEmptyController()
        defer { controller.close() }

        controller.applyDestination(.dashboard)
        XCTAssertFalse(controller.workspaceView.canvasMode, "off the Desk there is no canvas to lay out")
        XCTAssertTrue(controller.workspaceView.isHidden)

        controller.applyDestination(.terminals)
        XCTAssertTrue(controller.workspaceView.canvasMode, "selecting DESK loads the organigram")
        XCTAssertFalse(controller.workspaceView.isHidden)
        XCTAssertEqual(controller.destination, .terminals)
    }

    /// `deskCanvasLoaded` is the second half of the same statement, and it has
    /// no other writer: inside a session `canvasMode` is off (`landSession`
    /// turns it off as it lands, so that "identity" and "this card fills the
    /// viewport" are one picture), and the gesture that brings you back *out*
    /// of one is guarded on this flag rather than on the mode. Without it, a
    /// pinch out from inside a session is unreachable code.
    func testTheDeskDestinationAlsoTellsTheCanvasItIsLoaded() {
        let controller = makeEmptyController()
        defer { controller.close() }

        controller.applyDestination(.board)
        XCTAssertFalse(controller.workspaceView.deskCanvasLoaded)

        controller.applyDestination(.terminals)
        XCTAssertTrue(controller.workspaceView.deskCanvasLoaded)
    }

    /// `applyDestination` must never add or remove the pane workspace —
    /// `contentContainer`'s own doc: "Unmounting `PaneWorkspaceView` would tear
    /// down live SwiftTerm views and their PTY attachment along with it."
    /// Canvas mode is a layout switch, so the view stays in the same superview
    /// across the round trip.
    func testLoadingTheCanvasNeverRemountsThePaneWorkspace() {
        let controller = makeEmptyController()
        defer { controller.close() }
        let host = controller.workspaceView.superview

        controller.applyDestination(.board)
        controller.applyDestination(.terminals)

        XCTAssertNotNil(host)
        XCTAssertTrue(controller.workspaceView.superview === host, "hidden, never unmounted")
    }

    // MARK: - The Desk menu

    /// The canvas's shortcuts, and the two things that make them safe: ⌘0 and
    /// ⌃1…⌃9 were verified free before they were taken, and the pre-existing
    /// top-level menu titled "Session" is left alone — its items are one
    /// terminal's PTY verbs (Interrupt, Kill, Reattach), a different thing from
    /// the user-facing Session these commands switch between.
    func testTheDeskMenuBindsZoomToFitAndTheNineSessionDigits() throws {
        ApplicationMenus.install()

        let desk = try XCTUnwrap(NSApp.mainMenu?.item(withTitle: "Desk")?.submenu)

        let fit = try XCTUnwrap(desk.item(withTitle: "Zoom to Fit"))
        XCTAssertNil(fit.target, "travels the responder chain like every other command")
        XCTAssertEqual(fit.action, Selector(("zoomDeskToFit:")))
        // ⌘= and ⌘- reach the view's own commands through the responder chain;
        // without menu items they would be unreachable selectors.
        let zoomIn = try XCTUnwrap(desk.item(withTitle: "Zoom In"))
        XCTAssertEqual(zoomIn.action, Selector(("zoomCanvasIn:")))
        XCTAssertEqual(zoomIn.keyEquivalent, "=")
        let zoomOut = try XCTUnwrap(desk.item(withTitle: "Zoom Out"))
        XCTAssertEqual(zoomOut.action, Selector(("zoomCanvasOut:")))
        XCTAssertEqual(zoomOut.keyEquivalent, "-")
        XCTAssertEqual(fit.keyEquivalent, "0")
        XCTAssertEqual(fit.keyEquivalentModifierMask, [.command])

        let next = try XCTUnwrap(desk.item(withTitle: "Next Session"))
        XCTAssertEqual(next.action, Selector(("nextSession:")))
        XCTAssertEqual(next.keyEquivalent, "]")
        XCTAssertEqual(next.keyEquivalentModifierMask, [.command, .shift])

        let third = try XCTUnwrap(desk.item(withTitle: "Session 3"))
        XCTAssertEqual(third.action, Selector(("selectSession:")))
        XCTAssertEqual(third.keyEquivalent, "3")
        XCTAssertEqual(third.keyEquivalentModifierMask, [.control], "⌃N, not ⌘N — ⌘3 already selects pane 3")
        XCTAssertEqual(third.tag, 3, "the selectPane: precedent: the digit rides on the tag")

        XCTAssertNotNil(
            NSApp.mainMenu?.item(withTitle: "Session")?.submenu?.item(withTitle: "Interrupt"),
            "the per-pane Session menu is deliberately untouched"
        )
    }

    // MARK: - Entering and stepping between sessions

    /// One entry path, four callers. The sidebar row, ⌃N, ⇧⌘], the toolbar
    /// button and the palette row all land in `enterDeskSession`, so the
    /// canvas-mode rule ("fly the camera there") and the normal-mode rule
    /// ("activate that grid") are decided in exactly one place. The sidebar's
    /// old body called `workspace.focusPane(first)` directly; the spec's §5
    /// forbids that in canvas mode — "focusPane must not swap the grid
    /// underneath the user".
    func testSteppingSessionsStopsAtBothEndsRatherThanWrapping() {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "grp-1"),
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-b", group: "grp-2"),
                ])
            )
        )
        controller.showWindow(nil)
        controller.selectWorkspace(id: "alpha", animated: false)
        controller.workspaceView.focusPane("sess-a")
        // DESK loads canvas mode, so reaching a session the camera is not on is
        // a flight rather than a swap. Land it before asking where we are; the
        // landing turns canvas mode back off, which is why the steps below are
        // instant.
        settleCameraFlight()
        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-1", "the entry flight landed")

        controller.nextSession(nil)
        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-2")

        // JS index semantics, ported: index >= count yields null, it does not
        // wrap. `sessions[-1]` would trap in Swift, so the guard is explicit.
        controller.nextSession(nil)
        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-2", "the last session is the end, not a wrap")

        controller.previousSession(nil)
        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-1")
        controller.previousSession(nil)
        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-1", "and the first is the other end")
    }

    /// ⌃3 with two sessions open must do nothing rather than reach past the
    /// end — the menu item exists for nine, the workspace rarely has nine.
    func testASessionDigitPastTheEndDoesNothing() {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(
                fromLayout: PersistedLayoutCodec.serialize([
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "grp-1"),
                    PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-b", group: "grp-2"),
                ])
            )
        )
        controller.showWindow(nil)
        controller.selectWorkspace(id: "alpha", animated: false)
        controller.workspaceView.focusPane("sess-a")
        settleCameraFlight()

        let third = NSMenuItem(title: "Session 3", action: Selector(("selectSession:")), keyEquivalent: "3")
        third.tag = 3
        controller.selectSession(third)

        XCTAssertEqual(controller.currentDeskSessionGroup(), "grp-1", "nothing to reach, nothing moved")
        XCTAssertFalse(controller.validateMenuItem(third), "and the item says so")

        let first = NSMenuItem(title: "Session 1", action: Selector(("selectSession:")), keyEquivalent: "1")
        first.tag = 1
        XCTAssertTrue(controller.validateMenuItem(first))
    }

    // MARK: - desk_canvas_native

    /// The write gate is the *completed* flag, not the dispatched one. The read
    /// is asynchronous, and a node dragged while it is in flight would
    /// otherwise persist an empty pinned map over a row nothing has read yet —
    /// the exact reasoning `layoutReadCompleted`'s doc records for the shared
    /// layout row.
    func testTheCanvasRowIsNotWrittenBeforeItHasBeenRead() {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }

        controller.workspaceView.canvasPins["grp-1"] = CGPoint(x: 40, y: 60)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        XCTAssertTrue(
            writes.filter { $0.0 == SettingsKey.deskCanvas }.isEmpty,
            "the row has not been read, so nothing may be written over it"
        )
    }

    /// Restore hands the view its pinned nodes and its camera, and from then on
    /// a change writes the row back. Debounced: a camera being dragged around
    /// changes every frame, so `write`'s unchanged-value suppression cannot
    /// help and only a settle can.
    func testPinningANodeWritesTheCanvasRowOnceTheRowHasBeenRead() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }

        controller.applyRestoredDeskCanvas(
            DeskCanvasState(
                pinned: ["grp-1": CGPoint(x: 10, y: 20)],
                camera: DeskCamera(scale: 0.5, origin: CGPoint(x: 5, y: 7))
            )
        )
        XCTAssertEqual(controller.workspaceView.canvasPins["grp-1"], CGPoint(x: 10, y: 20))
        XCTAssertEqual(controller.workspaceView.camera.scale, 0.5, accuracy: 0.0001)

        controller.workspaceView.canvasPins["grp-2"] = CGPoint(x: 80, y: 90)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let row = try XCTUnwrap(writes.last { $0.0 == SettingsKey.deskCanvas })
        let stored = DeskCanvasCodec.deserialize(row.1)
        XCTAssertEqual(stored.pinned["grp-1"], CGPoint(x: 10, y: 20))
        XCTAssertEqual(stored.pinned["grp-2"], CGPoint(x: 80, y: 90))
    }

    /// Five changes in a row are one write, not five. A drag and a camera
    /// flight both produce a stream of them against a database the web app is
    /// also reading.
    func testAStreamOfCanvasChangesCoalescesIntoOneWrite() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }
        controller.applyRestoredDeskCanvas(DeskCanvasState(pinned: [:], camera: nil))

        for step in 1...5 {
            controller.workspaceView.canvasPins["grp-1"] = CGPoint(x: CGFloat(step) * 10, y: 0)
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let rows = writes.filter { $0.0 == SettingsKey.deskCanvas }
        XCTAssertEqual(rows.count, 1)
        let stored = DeskCanvasCodec.deserialize(try XCTUnwrap(rows.last).1)
        XCTAssertEqual(stored.pinned["grp-1"], CGPoint(x: 50, y: 0), "the last position, once")
    }

    /// A row that could not be *read* is not an empty row. The read re-arms for
    /// the next reconnect and the write gate stays shut, so a transient daemon
    /// error at launch cannot erase where the user put their nodes.
    func testAFailedCanvasReadReArmsWithoutOpeningTheWriteGate() {
        let controller = makeEmptyController()
        defer { controller.close() }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }

        controller.workspaceView.canvasPins["grp-1"] = CGPoint(x: 1, y: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        XCTAssertTrue(writes.filter { $0.0 == SettingsKey.deskCanvas }.isEmpty)
    }

    /// Entering a session must not rewrite the row. `landSession` turns canvas
    /// mode off and snaps the camera to the identity, so a persistence path
    /// that took any camera value it was handed would store "parked in the
    /// canvas's own corner" over the camera the user actually left — and the
    /// next Desk would open there instead of on the organigram.
    func testEnteringASessionLeavesTheStoredCameraWhereTheCanvasWas() throws {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        var writes: [(String, String)] = []
        controller.settingsWriter = { writes.append(($0, $1)) }
        controller.applyRestoredPanes(twoSessionPlan())
        controller.showWindow(nil)
        // Whatever the restore left focused, the canvas is where this starts.
        controller.workspaceView.exitToCanvas()
        settleCameraFlight()
        controller.applyRestoredDeskCanvas(DeskCanvasState(pinned: [:], camera: nil))

        controller.workspaceView.panCanvas(by: CGSize(width: 5, height: 6))
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        let onTheCanvas = try XCTUnwrap(writes.last { $0.0 == SettingsKey.deskCanvas })

        controller.workspaceView.enterSession("grp-2")
        settleCameraFlight()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        XCTAssertFalse(controller.workspaceView.canvasMode, "the entry landed")
        let last = try XCTUnwrap(writes.last { $0.0 == SettingsKey.deskCanvas })
        XCTAssertEqual(last.1, onTheCanvas.1, "a session has no camera of its own to store")
    }

    /// The canvas read lands *after* the restore chain has already flown the
    /// camera into the session the user was last in. Seating a stored camera on
    /// top of that flight would show the wrong place for its whole 0.38s, and
    /// the no-camera branch is worse still: `exitToCanvas` cancels the arrival,
    /// so the restore's last step would undo what the restore is for.
    func testARestoredCanvasDoesNotCancelTheEntryTheRestoreIsAlreadyFlying() {
        let controller = makeEmptyController()
        defer { controller.close() }
        controller.sessionEnsurer = { _ in }
        controller.applyRestoredPanes(twoSessionPlan())
        controller.showWindow(nil)
        controller.workspaceView.exitToCanvas()
        settleCameraFlight()

        // The last pane added owns the active session, so a focus request for
        // the other one is a flight rather than an instant switch.
        XCTAssertEqual(controller.workspaceView.activeGroup, "grp-2")
        controller.workspaceView.focusPane("sess-a")
        XCTAssertTrue(controller.workspaceView.isEnteringSession, "a flight is in the air")

        controller.applyRestoredDeskCanvas(DeskCanvasState(pinned: [:], camera: nil))
        settleCameraFlight()

        XCTAssertEqual(controller.workspaceView.activeGroup, "grp-1", "the entry still landed")
        XCTAssertFalse(controller.workspaceView.canvasMode)
    }

    // MARK: - Helpers

    /// Two sessions, one pane each, in one project — the smallest canvas with
    /// somewhere to fly to.
    private func twoSessionPlan() -> [RestoredPane] {
        WorkspaceRestoration.plan(
            fromLayout: PersistedLayoutCodec.serialize([
                PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-a", group: "grp-1"),
                PersistedTab(project: "alpha", engine: .shell, cwd: "/a", id: "sess-b", group: "grp-2"),
            ])
        )
    }

    /// Runs the run loop until a camera flight's scheduled landing has fired.
    /// `flyCamera` schedules it with `DispatchQueue.main.asyncAfter` — never an
    /// animation group's completion — so nothing arrives until the loop turns.
    private func settleCameraFlight() {
        RunLoop.current.run(
            until: Date().addingTimeInterval(PaneWorkspaceView.zoomTransitionDuration + 0.2)
        )
    }

    private func makeEmptyController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-test.sock")
            ),
            panes: []
        )
    }
}
