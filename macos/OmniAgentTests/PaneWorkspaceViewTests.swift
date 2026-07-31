import MetalKit
import XCTest
@testable import OmniAgent

final class PaneWorkspaceViewTests: XCTestCase {
    func testAddingAndSwappingPanesPreservesTerminalSurfaceIdentity() throws {
        let workspace = try makeWorkspace(ids: ["a", "b"])
        workspace.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        workspace.layoutSubtreeIfNeeded()
        let a = try XCTUnwrap(workspace.surface(forPaneID: "a"))
        let b = try XCTUnwrap(workspace.surface(forPaneID: "b"))

        try workspace.addPane(pane("c"))
        workspace.swapPanes("a", "b")
        workspace.layoutSubtreeIfNeeded()

        XCTAssertTrue(workspace.surface(forPaneID: "a") === a)
        XCTAssertTrue(workspace.surface(forPaneID: "b") === b)
        XCTAssertEqual(workspace.paneLayout.cells, ["b", "c", "a", nil])
        XCTAssertNotEqual(a.frame, b.frame)
    }

    func testDirectDividerUpdateChangesFramesImmediately() throws {
        let workspace = try makeWorkspace(ids: ["a", "b"])
        workspace.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        workspace.layoutSubtreeIfNeeded()

        XCTAssertTrue(workspace.setColumnDivider(0, position: 240))

        XCTAssertEqual(try XCTUnwrap(workspace.surface(forPaneID: "a")).frame.width, 237, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(workspace.surface(forPaneID: "b")).frame.minX, 243, accuracy: 1)
    }

    func testFocusCommandsAndDropSwapKeepFocusOnSameTerminal() throws {
        let workspace = try makeWorkspace(ids: ["a", "b", "c", "d"])
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = workspace
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let modalSession = NSApp.beginModalSession(for: window)
        defer { NSApp.endModalSession(modalSession) }
        _ = NSApp.runModalSession(modalSession)

        XCTAssertTrue(workspace.focusPane(at: 1))
        XCTAssertTrue(workspace.focusPane(.right))
        XCTAssertEqual(workspace.paneLayout.focusedPaneID, "c")
        XCTAssertTrue(workspace.swapDroppedPane(sourceID: "c", targetID: "b"))
        XCTAssertEqual(workspace.paneLayout.focusedPaneID, "c")
        XCTAssertTrue(window.firstResponder === workspace.surface(forPaneID: "c")?.terminalView)
    }

    func testPaneAndTerminalExposeNativeAccessibilityDescriptions() throws {
        let workspace = try PaneWorkspaceView(
            connection: connection,
            panes: [
                PaneDescriptor(
                    id: "a",
                    sessionID: "a",
                    label: "Build",
                    group: "g",
                    groupLabel: "Migration"
                ),
            ]
        )
        let surface = try XCTUnwrap(workspace.surface(forPaneID: "a"))

        XCTAssertEqual(workspace.accessibilityRole(), .group)
        XCTAssertEqual(workspace.accessibilityLabel(), "Terminal workspace")
        XCTAssertEqual(surface.accessibilityRole(), .group)
        XCTAssertEqual(surface.accessibilityLabel(), "Pane 1 of 1, Build, Migration")
        XCTAssertEqual(surface.terminalView.accessibilityLabel(), "Terminal, Build")
    }

    func testTerminalFirstResponderUpdatesFocusedPaneIdentity() throws {
        let workspace = try makeWorkspace(ids: ["a", "b"])

        try XCTUnwrap(workspace.surface(forPaneID: "b")?.terminalView).paneWasFocused()

        XCTAssertEqual(workspace.paneLayout.focusedPaneID, "b")
    }

    func testGroupingMetadataUpdateKeepsSurfaceAndRefreshesAccessibility() throws {
        let workspace = try makeWorkspace(ids: ["a"])
        let surface = try XCTUnwrap(workspace.surface(forPaneID: "a"))

        workspace.updatePaneMetadata(
            id: "a",
            label: "Review",
            group: "group-review",
            groupLabel: "Release"
        )

        XCTAssertTrue(workspace.surface(forPaneID: "a") === surface)
        XCTAssertEqual(workspace.paneLayout.panes["a"]?.group, "group-review")
        XCTAssertEqual(surface.accessibilityLabel(), "Pane 1 of 1, Review, Release")
    }

    func testResizeCoalescerSendsOnlyLatestSizePerDisplayRefresh() {
        var sent: [TerminalSize] = []
        var coalescer = TerminalResizeCoalescer { sent.append($0) }

        coalescer.submit(TerminalSize(cols: 80, rows: 24, pixelWidth: 800, pixelHeight: 400))
        coalescer.submit(TerminalSize(cols: 90, rows: 30, pixelWidth: 900, pixelHeight: 500))
        coalescer.submit(TerminalSize(cols: 100, rows: 40, pixelWidth: 1_000, pixelHeight: 600))
        coalescer.flush()
        coalescer.flush()

        XCTAssertEqual(sent, [
            TerminalSize(cols: 100, rows: 40, pixelWidth: 1_000, pixelHeight: 600),
        ])
    }

    func testSuspendedDrawingStillFeedsBoundedTerminalParserState() {
        let surface = TerminalSurfaceView(connection: connection, sessionID: "a")

        surface.setDrawingSuspended(true)
        surface.feed(Data("state-keeps-moving".utf8), isSnapshot: false)

        XCTAssertTrue(surface.terminalView.isHidden)
        XCTAssertTrue(
            String(data: surface.terminalView.terminal.getBufferAsData(), encoding: .utf8)?
                .contains("state-keeps-moving") == true
        )
    }

    func testAttachedEightPaneDividerAndRendererSchedulingBenchmarkIsDiagnostic() throws {
        guard MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Metal is unavailable on this host")
        }
        let workspace = try makeWorkspace(ids: (1...8).map(String.init))
        let window = WorkspaceWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.contentView = workspace
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        workspace.layoutSubtreeIfNeeded()

        XCTContext.runActivity(
            named: "Diagnostic only; external 60/120 Hz hardware frame gate remains open"
        ) { _ in
            measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
                for offset in stride(from: CGFloat(260), through: 340, by: 10) {
                    _ = workspace.setColumnDivider(0, position: offset)
                    workspace.displayRefresh()
                    for id in workspace.paneLayout.paneIDs {
                        _ = workspace.surface(forPaneID: id)?.requestRendererDraw()
                    }
                }
            }
        }
    }

    private var connection: SessionConnection {
        SessionConnection(socketURL: URL(fileURLWithPath: "/tmp/omniagent-pane-test.sock"))
    }

    private func makeWorkspace(ids: [String]) throws -> PaneWorkspaceView {
        try PaneWorkspaceView(connection: connection, panes: ids.map { pane($0) })
    }

    private func pane(_ id: String) -> PaneDescriptor {
        PaneDescriptor(id: id, sessionID: id)
    }
}
