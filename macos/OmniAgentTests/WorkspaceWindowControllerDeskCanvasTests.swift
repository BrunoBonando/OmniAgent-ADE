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

    // MARK: - Helpers

    private func makeEmptyController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-desk-canvas-test.sock")
            ),
            panes: []
        )
    }
}
