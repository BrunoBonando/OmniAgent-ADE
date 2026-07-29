import XCTest
@testable import OmniAgent

final class WorkspaceWindowControllerTests: XCTestCase {
    func testWindowOwnsExactlyOneTerminalAndFocusReturnsToIt() {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-controller-test.sock")
        )
        let controller = WorkspaceWindowController(
            connection: connection,
            sessionID: "native-terminal"
        )

        controller.showWindow(nil)
        let surfaces = controller.window?.contentView?.subviews.compactMap {
            $0 as? TerminalSurfaceView
        }
        XCTAssertEqual(surfaces?.count, 1)

        controller.focusTerminal(nil)
        XCTAssertTrue(controller.window?.firstResponder === surfaces?.first?.terminalView)
        controller.close()
    }
}
