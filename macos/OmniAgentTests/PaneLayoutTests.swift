import XCTest
@testable import OmniAgent

final class PaneLayoutTests: XCTestCase {
    func testApprovedShapesAndHolesUseColumnMajorCells() throws {
        let expected = [
            (1, PaneGridShape(columns: 1, rows: 1), 0),
            (2, PaneGridShape(columns: 2, rows: 1), 0),
            (3, PaneGridShape(columns: 2, rows: 2), 1),
            (4, PaneGridShape(columns: 2, rows: 2), 0),
            (5, PaneGridShape(columns: 3, rows: 2), 1),
            (6, PaneGridShape(columns: 3, rows: 2), 0),
            (7, PaneGridShape(columns: 4, rows: 2), 1),
            (8, PaneGridShape(columns: 4, rows: 2), 0),
        ]

        for (count, shape, holeCount) in expected {
            let ids = (1...count).map(String.init)
            let layout = try PaneLayout(panes: ids.map { pane($0) })
            XCTAssertEqual(layout.shape, shape, "\(count) panes")
            XCTAssertEqual(layout.paneIDs, ids, "\(count) panes")
            XCTAssertEqual(layout.cells.filter { $0 == nil }.count, holeCount, "\(count) panes")
        }
    }

    func testAddingThirdPaneKeepsExistingPanesOnTopAndPlacesNewPaneLowerLeft() throws {
        var layout = try PaneLayout(panes: [pane("a"), pane("b")])

        try layout.add(pane("c"))

        XCTAssertEqual(layout.cells, ["a", "c", "b", nil])
    }

    func testAddingPaneRepairsLastHoleAndRejectsNinthPane() throws {
        var layout = try PaneLayout(panes: (1...7).map { pane(String($0)) })

        try layout.add(pane("8"))

        XCTAssertEqual(layout.cells, (1...8).map { Optional(String($0)) })
        XCTAssertThrowsError(try layout.add(pane("9"))) {
            XCTAssertEqual($0 as? PaneLayoutError, .maximumPanes)
        }
    }

    func testSwapMovesOnlyCellsAndKeepsPaneMetadataIdentity() throws {
        var layout = try PaneLayout(panes: [
            pane("a", group: "group-a"),
            pane("b", group: "group-b"),
            pane("c", group: "group-c"),
            pane("d", group: "group-d"),
        ])
        let records = layout.panes

        XCTAssertTrue(layout.swap("a", "d"))

        XCTAssertEqual(layout.cells, ["d", "b", "c", "a"])
        XCTAssertEqual(layout.panes, records)
    }

    func testCloseRepairsShapeAndFocusFallsLeft() throws {
        var layout = try PaneLayout(panes: ["a", "b", "c"].map { pane($0) })
        XCTAssertTrue(layout.focus("b"))

        XCTAssertEqual(layout.remove("b")?.id, "b")

        XCTAssertEqual(layout.cells, ["a", "c"])
        XCTAssertEqual(layout.focusedPaneID, "a")
    }

    func testDirectionalFocusUsesGridNeighborsWithoutWrappingThroughHoles() throws {
        var layout = try PaneLayout(panes: ["a", "b"].map { pane($0) })
        try layout.add(pane("c"))
        XCTAssertTrue(layout.focus("a"))

        XCTAssertEqual(layout.focus(.down), "c")
        XCTAssertEqual(layout.focus(.right), nil)
        XCTAssertEqual(layout.focus(.up), "a")
        XCTAssertEqual(layout.focus(.right), "b")
        XCTAssertEqual(layout.focus(.down), nil)
    }

    private func pane(_ id: String, group: String? = nil) -> PaneDescriptor {
        PaneDescriptor(id: id, sessionID: id, group: group)
    }
}
