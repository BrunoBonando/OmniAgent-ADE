import XCTest
@testable import OmniAgent

/// The Swift port of `ui/src/state/paneGrid.ts` answers what the TypeScript
/// oracle answers for the ladder, the hole padding, the 2 -> 3 lower-left
/// placement, and the 1-for-1 replacement — but NOT for fill order, which is
/// row-major here against the oracle's column-major (see `PaneGrid.fillOrder`'s
/// doc comment for why). The cases below are the Swift transliteration of
/// `paneGrid.test.ts`, adjusted for that one divergence, plus the
/// geometry/neighbour behaviour the web grid delegated to react-mosaic and the
/// browser and the native workspace now owns itself.
final class PaneGridTests: XCTestCase {
    // MARK: - shape

    func testShapeWalksTheApprovedLadderAndStops() {
        let expected: [(cols: Int, rows: Int)] = [
            (1, 1), // 1
            (2, 1), // 2
            (2, 2), // 3
            (2, 2), // 4
            (3, 2), // 5
            (3, 2), // 6
            (4, 2), // 7
            (4, 2), // 8
            (4, 3), // 9
            (4, 3), // 10
            (4, 3), // 11
            (4, 3), // 12
        ]
        for (index, shape) in expected.enumerated() {
            XCTAssertEqual(
                PaneGrid.shape(count: index + 1),
                PaneGridShape(cols: shape.cols, rows: shape.rows),
                "\(index + 1) panes"
            )
        }
    }

    func testMaxPanesIsTheLastRungCapacity() {
        XCTAssertEqual(PaneGrid.maxPanes, 12)
        let shape = PaneGrid.shape(count: PaneGrid.maxPanes)
        XCTAssertEqual(shape, PaneGridShape(cols: 4, rows: 3), "three rows and four columns")
        XCTAssertEqual(shape.cols * shape.rows, PaneGrid.maxPanes)
    }

    func testPastTheCapItKeepsTheWidestShapeAndGrowsRows() {
        XCTAssertEqual(PaneGrid.shape(count: 13), PaneGridShape(cols: 4, rows: 4))
        XCTAssertEqual(PaneGrid.build(ids(13))?.paneIDs(), ids(13))
    }

    // MARK: - the third row

    /// The founder's rule for the ninth pane (2026-08-18): it opens the third
    /// row at the FIRST column, and the three cells beside it stay empty until
    /// panes 10, 11 and 12 claim them left to right. Nothing already on screen
    /// moves.
    func testTheNinthPaneOpensTheThirdRowAtTheFirstColumnAndLeavesThreeHoles() {
        let eight = PaneGrid.build(ids(8))!
        let nine = PaneGrid.synced(eight, desiredIDs: ids(9))!

        XCTAssertEqual(nine.cols, 4)
        XCTAssertEqual(nine.rows, 3)
        XCTAssertEqual(nine.position(of: "9").map { [$0.column, $0.row] }, [0, 2])
        XCTAssertEqual(nine.cells.filter(\.isHole).count, 3)
        for column in 1...3 {
            XCTAssertTrue(
                nine.cells[column * 3 + 2].isHole,
                "column \(column)'s third row is an empty cell"
            )
        }
    }

    func testGrowingIntoTheThirdRowMovesNobodyAlreadyOnScreen() {
        let eight = PaneGrid.build(ids(8))!
        let seats = ids(8).map { id in eight.position(of: id).map { [$0.column, $0.row] } }
        let nine = PaneGrid.synced(eight, desiredIDs: ids(9))!
        XCTAssertEqual(
            ids(8).map { id in nine.position(of: id).map { [$0.column, $0.row] } },
            seats,
            "every one of the first eight keeps the cell it held in the 4x2 rung"
        )
    }

    /// Each further pane replaces the next empty cell along the third row —
    /// left to right, one at a time, no reshuffle.
    func testPanesTenElevenAndTwelveFillTheThirdRowLeftToRight() {
        var grid = PaneGrid.build(ids(8))!
        for count in 9...12 {
            grid = PaneGrid.synced(grid, desiredIDs: ids(count))!
            XCTAssertEqual(grid.rows, 3, "\(count) panes")
            XCTAssertEqual(
                grid.position(of: "\(count)").map { [$0.column, $0.row] },
                [count - 9, 2],
                "pane \(count) takes column \(count - 9) of the third row"
            )
            XCTAssertEqual(grid.cells.filter(\.isHole).count, 12 - count, "\(count) panes")
        }
        XCTAssertEqual(grid.paneIDs(), ids(12))
    }

    /// The layout `build` produces for a full third row, cell by cell, in the
    /// column-major storage order `cells` uses — each column now holds every
    /// third id (row-major fill), not three consecutive ones.
    func testBuildingTwelvePanesIsALiteralThreeByFourWithNoHoles() {
        let grid = PaneGrid.build(ids(12))!
        XCTAssertEqual(
            grid.cells,
            [
                .pane("1"), .pane("5"), .pane("9"), // column 0, top to bottom
                .pane("2"), .pane("6"), .pane("10"),
                .pane("3"), .pane("7"), .pane("11"),
                .pane("4"), .pane("8"), .pane("12"),
            ]
        )
        XCTAssertEqual(grid.paneIDs(), ids(12), "fill order, not storage order")
    }

    /// Row by row, left to right — including the 1-2 row rungs, which used to
    /// be a column-major identity. See `fillOrder`'s doc comment for the
    /// stability this costs.
    func testFillOrderReadsRowByRowLeftToRight() {
        XCTAssertEqual(PaneGrid.fillOrder(cols: 2, rows: 2), [0, 2, 1, 3])
        XCTAssertEqual(PaneGrid.fillOrder(cols: 4, rows: 2), [0, 2, 4, 6, 1, 3, 5, 7])
        XCTAssertEqual(PaneGrid.fillOrder(cols: 4, rows: 3), [0, 3, 6, 9, 1, 4, 7, 10, 2, 5, 8, 11])
    }

    func testDirectionalNeighboursReachTheThirdRow() {
        let grid = PaneGrid.build(ids(12))! // row-major: row 2 is [9, 10, 11, 12]
        XCTAssertEqual(grid.neighbor(of: "2", direction: .down), "6")
        XCTAssertEqual(grid.neighbor(of: "9", direction: .up), "5")
        XCTAssertEqual(grid.neighbor(of: "9", direction: .right), "10")
        XCTAssertNil(grid.neighbor(of: "9", direction: .down), "the grid never wraps")
        XCTAssertNil(grid.neighbor(of: "9", direction: .left))
    }

    /// A half-full third row is holes on its right, and a hole is never a focus
    /// target: a vertical move into one stops, a horizontal move into one falls
    /// back to the nearest real cell above — the rule the 2x2 rung's single
    /// bottom-right hole already follows.
    func testTheThirdRowsHolesAreNeverFocusTargets() {
        let grid = PaneGrid.build(ids(9))!
        XCTAssertNil(grid.neighbor(of: "6", direction: .down), "column 1's third row is a hole, nothing sits past it")
        XCTAssertEqual(grid.neighbor(of: "9", direction: .right), "6", "falls back to the nearest real cell above the hole")
    }

    func testAThreeRowGridTilesItsBoundsExactly() {
        let layout = PaneGrid.build(ids(12))!.layout(in: bounds, dividerThickness: 6)
        XCTAssertEqual(layout.frames.count, 12)
        XCTAssertEqual(layout.dividers.filter { $0.axis == .vertical }.count, 3)
        XCTAssertEqual(layout.dividers.filter { $0.axis == .horizontal }.count, 8, "two seams per column")
        for frame in layout.frames.values {
            XCTAssertEqual(frame, frame.integral)
        }
        XCTAssertEqual(layout.frames["9"]?.maxY, bounds.maxY, "the third row reaches the bottom edge")
        XCTAssertEqual(layout.frames["12"]?.maxX, bounds.maxX, "the last column reaches the right edge")
    }

    // MARK: - build

    func testBuildIsNilForNoPanesAndASingleCellForOne() {
        XCTAssertNil(PaneGrid.build([]))
        let single = PaneGrid.build(["a"])
        XCTAssertEqual(single?.cells, [.pane("a")])
        XCTAssertEqual(single?.cols, 1)
        XCTAssertEqual(single?.rows, 1)
    }

    func testBuildTwoPanesIsAPlainSideBySideRow() {
        let grid = PaneGrid.build(["a", "b"])
        XCTAssertEqual(grid?.cols, 2)
        XCTAssertEqual(grid?.rows, 1)
        XCTAssertEqual(grid?.cells, [.pane("a"), .pane("b")])
    }

    func testBuildThreePanesFillsTheTwoByTwoRowMajorWithABottomRightHole() {
        let grid = PaneGrid.build(["a", "b", "c"]) // row 0: [a, b], row 1: [c, hole]
        XCTAssertEqual(grid?.cols, 2)
        XCTAssertEqual(grid?.rows, 2)
        XCTAssertEqual(grid?.cells, [.pane("a"), .pane("c"), .pane("b"), .hole(0)])
        XCTAssertEqual(grid?.paneIDs(), ["a", "b", "c"])
    }

    func testBuildFourPanesIsALiteralTwoByTwoWithNoHoles() {
        // row 0: [a, b], row 1: [c, d]
        XCTAssertEqual(
            PaneGrid.build(["a", "b", "c", "d"])?.cells,
            [.pane("a"), .pane("c"), .pane("b"), .pane("d")]
        )
    }

    /// row 0: [1, 2, 3], row 1: [4, 5, hole].
    func testBuildFivePanesTakesTheThreeByTwoRungReadingRowByRow() {
        let grid = PaneGrid.build(ids(5))
        XCTAssertEqual(grid?.cols, 3)
        XCTAssertEqual(grid?.rows, 2)
        XCTAssertEqual(
            grid?.cells,
            [.pane("1"), .pane("4"), .pane("2"), .pane("5"), .pane("3"), .hole(0)]
        )
    }

    func testBuildEightPanesIsALiteralTwoByFourWithNoHoles() {
        let grid = PaneGrid.build(ids(8))
        XCTAssertEqual(grid?.cols, 4)
        XCTAssertEqual(grid?.rows, 2)
        XCTAssertEqual(grid?.cells.filter(\.isHole).count, 0)
        XCTAssertEqual(grid?.paneIDs(), ids(8))
    }

    func testBuildKeepsEveryRealIDOnceInFillOrderAndPadsEveryRungToItsRectangle() {
        for count in 1...PaneGrid.maxPanes {
            let grid = PaneGrid.build(ids(count))
            XCTAssertEqual(grid?.paneIDs(), ids(count), "\(count) panes")
            let shape = PaneGrid.shape(count: count)
            XCTAssertEqual(grid?.cells.count, shape.cols * shape.rows, "\(count) panes")
        }
    }

    func testHoleIDsAreRecognisableAndNeverRealSessionIDs() {
        XCTAssertTrue(PaneGrid.isHole(PaneGrid.holeID(0)))
        XCTAssertFalse(PaneGrid.isHole("pane-1"))
        XCTAssertEqual(PaneCell.hole(2).id, "__pane-hole-2")
    }

    // MARK: - synced (syncPaneTree)

    func testSyncedBuildsAFreshGridWhenStartingFromNothing() {
        XCTAssertEqual(PaneGrid.synced(nil, desiredIDs: ["a", "b"])?.cells, [.pane("a"), .pane("b")])
    }

    func testSyncedLandsTheThirdPaneLowerLeft() {
        let grid = PaneGrid.synced(PaneGrid.build(["a", "b"]), desiredIDs: ["a", "b", "c"])
        XCTAssertEqual(grid?.cols, 2)
        XCTAssertEqual(grid?.rows, 2)
        // Column-major cells: [top-left, bottom-left, top-right, bottom-right].
        XCTAssertEqual(grid?.cells, [.pane("a"), .pane("c"), .pane("b"), .hole(0)])
    }

    /// Row-major growth is NOT free the way column-major was: widening every
    /// row for a 5th pane shifts "3" and "4" down-left. See `fillOrder`'s doc
    /// comment for the tradeoff.
    func testSyncedGrowingAFullTwoByTwoIntoAThirdColumnReshufflesTheLastRow() {
        let grid = PaneGrid.synced(PaneGrid.build(ids(4)), desiredIDs: ids(5))
        XCTAssertEqual(
            grid?.cells,
            [.pane("1"), .pane("4"), .pane("2"), .pane("5"), .pane("3"), .hole(0)]
        )
    }

    func testSyncedFillsTheRemainingHoleWithinTheCurrentRung() {
        let grid = PaneGrid.synced(PaneGrid.build(ids(7)), desiredIDs: ids(8))
        XCTAssertEqual(grid?.paneIDs(), ids(8))
        XCTAssertEqual(grid?.cells.filter(\.isHole).count, 0)
    }

    func testSyncedReflowsBackDownARungOnClose() {
        let grid = PaneGrid.synced(PaneGrid.build(["a", "b", "c"]), desiredIDs: ["a", "b"])
        XCTAssertEqual(grid?.cells, [.pane("a"), .pane("b")])
    }

    func testSyncedKeepsSurvivorFillOrderIncludingAUserRearrangement() {
        var dragged = PaneGrid.build(["a", "b", "c"])
        dragged?.swap("a", "c") // fill order becomes c, b, a
        XCTAssertEqual(dragged?.paneIDs(), ["c", "b", "a"])
        let grid = PaneGrid.synced(dragged, desiredIDs: ["a", "b", "c", "d"])
        XCTAssertEqual(grid?.cells, [.pane("c"), .pane("a"), .pane("b"), .pane("d")])
    }

    func testSyncedReturnsTheSameGridWhenMembershipHasNotMoved() {
        var grid = PaneGrid.build(["a", "b"])!
        let divider = grid.layout(in: bounds, dividerThickness: 6).dividers[0]
        grid.moveDivider(
            divider,
            by: 90,
            in: bounds,
            dividerThickness: 6,
            minimumPaneSize: minimumPane
        )
        XCTAssertEqual(PaneGrid.synced(grid, desiredIDs: ["a", "b"]), grid)
        XCTAssertEqual(PaneGrid.synced(grid, desiredIDs: ["b", "a"]), grid, "membership, not order")
    }

    func testSyncedClearingEveryIDResolvesToNil() {
        XCTAssertNil(PaneGrid.synced(PaneGrid.build(["a", "b"]), desiredIDs: []))
        XCTAssertNil(PaneGrid.synced(nil, desiredIDs: []))
    }

    func testSyncedTreatsAOneForOneDiffAsAnInPlaceReplacement() {
        let before = PaneGrid.build(["a", "b", "c"])
        let after = PaneGrid.synced(before, desiredIDs: ["a", "b2", "c"])
        XCTAssertEqual(after?.cells, [.pane("a"), .pane("c"), .pane("b2"), .hole(0)])
    }

    func testSyncedDoesNotTreatATwoForTwoDiffAsAReplacement() {
        let grid = PaneGrid.synced(PaneGrid.build(["a", "b"]), desiredIDs: ["c", "d"])
        XCTAssertEqual(grid?.paneIDs().sorted(), ["c", "d"])
    }

    // MARK: - replace / swap

    func testReplaceSwapsALeafInPlaceAndIsANoOpForAnUnknownID() {
        var grid = PaneGrid.build(["a", "b", "c"])!
        grid.replace("b", with: "b2")
        XCTAssertEqual(grid.cells, [.pane("a"), .pane("c"), .pane("b2"), .hole(0)])
        let untouched = grid
        grid.replace("ghost", with: "x")
        XCTAssertEqual(grid, untouched)
    }

    func testSwapTradesTwoPanesAcrossColumnsAndLeavesEverybodyElseAlone() {
        var grid = PaneGrid.build(ids(4))!
        grid.swap("1", "4")
        XCTAssertEqual(grid.cells, [.pane("4"), .pane("3"), .pane("2"), .pane("1")])
    }

    func testSwapKeepsTheShapeAndAnyManualResize() {
        var grid = PaneGrid.build(["a", "b"])!
        let divider = grid.layout(in: bounds, dividerThickness: 6).dividers[0]
        grid.moveDivider(
            divider,
            by: 90,
            in: bounds,
            dividerThickness: 6,
            minimumPaneSize: minimumPane
        )
        let fractions = grid.columnFractions
        grid.swap("a", "b")
        XCTAssertEqual(grid.cells, [.pane("b"), .pane("a")])
        XCTAssertEqual(grid.columnFractions, fractions)
    }

    func testSwapIsANoOpForSelfDropsUnknownIDsAndHoles() {
        var grid = PaneGrid.build(["a", "b", "c"])!
        let untouched = grid
        grid.swap("a", "a")
        grid.swap("a", "ghost")
        grid.swap("a", PaneGrid.holeID(0))
        XCTAssertEqual(grid, untouched)
    }

    // MARK: - fixtures

    func testMatchesTheCommittedCrossPlatformPaneGridFixture() throws {
        let fixture = try Fixture.paneGrid()
        for shape in fixture.shapes {
            XCTAssertEqual(
                PaneGrid.shape(count: shape.count),
                PaneGridShape(cols: shape.cols, rows: shape.rows),
                "\(shape.count) panes"
            )
            let grid = try XCTUnwrap(PaneGrid.build(shape.paneIDs))
            XCTAssertEqual(grid.paneIDs(), shape.paneIDs, "\(shape.count) panes")
            XCTAssertEqual(grid.cells.filter(\.isHole).count, shape.holes, "\(shape.count) panes")
        }

        let repaired = try XCTUnwrap(
            PaneGrid.synced(
                PaneGrid.build(fixture.holeRepair.existingIDs),
                desiredIDs: fixture.holeRepair.desiredIDs
            )
        )
        // Not `fixture.holeRepair.expectedPaneIDs` here: that field is the
        // TypeScript oracle's column-major answer, and this is the one place
        // in the fixture that's fill-order-sensitive (every per-shape
        // `pane_ids` above is a round-trip identity, so it doesn't care). See
        // `PaneGrid.fillOrder`'s doc comment for the native-only divergence.
        XCTAssertEqual(repaired.paneIDs(), ["pane-1", "pane-2", "pane-3"])
        XCTAssertEqual(repaired.cells.filter(\.isHole).count, fixture.holeRepair.holes)
    }

    // MARK: - directional neighbours

    func testDirectionalNeighboursWalkTheGridWithoutWrapping() {
        let grid = PaneGrid.build(ids(4))! // row-major: row 0 [1,2], row 1 [3,4]
        XCTAssertEqual(grid.neighbor(of: "1", direction: .down), "3")
        XCTAssertEqual(grid.neighbor(of: "1", direction: .right), "2")
        XCTAssertNil(grid.neighbor(of: "1", direction: .up))
        XCTAssertNil(grid.neighbor(of: "1", direction: .left))
        XCTAssertEqual(grid.neighbor(of: "4", direction: .left), "3")
        XCTAssertEqual(grid.neighbor(of: "4", direction: .up), "2")
        XCTAssertNil(grid.neighbor(of: "4", direction: .right))
    }

    func testHorizontalNeighbourFallsBackToTheNearestRealCellWhenTheRowIsAHole() {
        let grid = PaneGrid.build(["a", "b", "c"])! // row-major: row 0 [a,b], row 1 [c,hole]
        XCTAssertEqual(grid.neighbor(of: "c", direction: .right), "b", "never lands on a hole")
        XCTAssertNil(grid.neighbor(of: "b", direction: .down), "the hole below is not a target")
        XCTAssertEqual(grid.neighbor(of: "b", direction: .left), "a")
    }

    func testNeighbourIsNilForAnUnknownPane() {
        XCTAssertNil(PaneGrid.build(["a"])!.neighbor(of: "ghost", direction: .right))
    }

    // MARK: - geometry

    func testLayoutTilesTheBoundsExactlyWithIntegralPaneFrames() {
        let grid = PaneGrid.build(ids(4))! // row-major: row 0 [1,2], row 1 [3,4]
        let layout = grid.layout(in: bounds, dividerThickness: 6)
        XCTAssertEqual(layout.frames["1"], CGRect(x: 0, y: 0, width: 397, height: 297))
        XCTAssertEqual(layout.frames["2"], CGRect(x: 403, y: 0, width: 397, height: 297))
        XCTAssertEqual(layout.frames["3"], CGRect(x: 0, y: 303, width: 397, height: 297))
        XCTAssertEqual(layout.frames["4"], CGRect(x: 403, y: 303, width: 397, height: 297))
        for frame in layout.frames.values {
            XCTAssertEqual(frame, frame.integral)
        }
    }

    func testLayoutGivesHolesTheirOwnFrameSoTheRectangleStaysComplete() {
        let grid = PaneGrid.build(["a", "b", "c"])!
        let layout = grid.layout(in: bounds, dividerThickness: 6)
        XCTAssertEqual(layout.frames.count, 4)
        XCTAssertEqual(layout.frames[PaneGrid.holeID(0)], CGRect(x: 403, y: 303, width: 397, height: 297))
    }

    func testLayoutEmitsOneDividerPerSeamWithTheRequestedThickness() {
        let layout = PaneGrid.build(ids(4))!.layout(in: bounds, dividerThickness: 6)
        // One vertical seam between the two columns, one horizontal seam inside each column.
        XCTAssertEqual(layout.dividers.filter { $0.axis == .vertical }.count, 1)
        XCTAssertEqual(layout.dividers.filter { $0.axis == .horizontal }.count, 2)
        let vertical = layout.dividers.first { $0.axis == .vertical }
        XCTAssertEqual(vertical?.frame, CGRect(x: 397, y: 0, width: 6, height: 600))
        let firstHorizontal = layout.dividers.first { $0.axis == .horizontal && $0.column == 0 }
        XCTAssertEqual(firstHorizontal?.frame, CGRect(x: 0, y: 297, width: 397, height: 6))
    }

    func testSinglePaneFillsTheBoundsAndHasNoDividers() {
        let layout = PaneGrid.build(["a"])!.layout(in: bounds, dividerThickness: 6)
        XCTAssertEqual(layout.frames["a"], bounds)
        XCTAssertTrue(layout.dividers.isEmpty)
    }

    func testMovingAVerticalDividerResizesOnlyItsTwoColumns() {
        var grid = PaneGrid.build(ids(4))! // row-major: column 0 is [1,3], column 1 is [2,4]
        let divider = grid.layout(in: bounds, dividerThickness: 6).dividers.first { $0.axis == .vertical }!
        grid.moveDivider(
            divider,
            by: 100,
            in: bounds,
            dividerThickness: 6,
            minimumPaneSize: minimumPane
        )
        let layout = grid.layout(in: bounds, dividerThickness: 6)
        XCTAssertEqual(layout.frames["1"]?.width, 497)
        XCTAssertEqual(layout.frames["2"]?.width, 297)
        XCTAssertEqual(layout.frames["1"]?.height, 297, "row heights are untouched")
    }

    func testMovingAHorizontalDividerResizesOnlyItsOwnColumn() {
        var grid = PaneGrid.build(ids(4))! // row-major: column 0 is [1,3], column 1 is [2,4]
        let divider = grid.layout(in: bounds, dividerThickness: 6)
            .dividers.first { $0.axis == .horizontal && $0.column == 0 }!
        grid.moveDivider(
            divider,
            by: -50,
            in: bounds,
            dividerThickness: 6,
            minimumPaneSize: minimumPane
        )
        let layout = grid.layout(in: bounds, dividerThickness: 6)
        XCTAssertEqual(layout.frames["1"]?.height, 247)
        XCTAssertEqual(layout.frames["3"]?.height, 347)
        XCTAssertEqual(layout.frames["2"]?.height, 297, "the other column keeps its own split")
    }

    func testDividerDragIsClampedToTheMinimumPaneSize() {
        var grid = PaneGrid.build(ids(4))! // row-major: column 0 is [1,3], column 1 is [2,4]
        let divider = grid.layout(in: bounds, dividerThickness: 6).dividers.first { $0.axis == .vertical }!
        grid.moveDivider(
            divider,
            by: -10_000,
            in: bounds,
            dividerThickness: 6,
            minimumPaneSize: minimumPane
        )
        let layout = grid.layout(in: bounds, dividerThickness: 6)
        XCTAssertEqual(layout.frames["1"]?.width, minimumPane.width)
        XCTAssertEqual(layout.frames["2"]?.width, 794 - minimumPane.width)
    }

    func testReshapingResetsFractionsSoANewRungStartsEven() {
        var grid = PaneGrid.build(["a", "b"])!
        grid.moveDivider(
            grid.layout(in: bounds, dividerThickness: 6).dividers[0],
            by: 200,
            in: bounds,
            dividerThickness: 6,
            minimumPaneSize: minimumPane
        )
        let grown = PaneGrid.synced(grid, desiredIDs: ["a", "b", "c"])!
        XCTAssertEqual(grown.columnFractions, [0.5, 0.5])
        XCTAssertEqual(grown.rowFractions, [[0.5, 0.5], [0.5, 0.5]])
    }

    // MARK: - helpers

    private let bounds = CGRect(x: 0, y: 0, width: 800, height: 600)
    private let minimumPane = CGSize(width: 120, height: 60)

    private func ids(_ count: Int) -> [String] {
        (1...count).map(String.init)
    }
}

/// The committed cross-platform fixture the TypeScript grid is checked against
/// (`ui/src/state/nativeMacosCompatibility.test.ts`), read straight from the
/// repository so both ports answer one file rather than two copies.
enum Fixture {
    struct PaneGridFixture: Decodable {
        struct Shape: Decodable {
            let count: Int
            let cols: Int
            let rows: Int
            let paneIDs: [String]
            let holes: Int

            enum CodingKeys: String, CodingKey {
                case count, cols, rows, holes
                case paneIDs = "pane_ids"
            }
        }

        struct HoleRepair: Decodable {
            let existingIDs: [String]
            let desiredIDs: [String]
            let expectedPaneIDs: [String]
            let holes: Int

            enum CodingKeys: String, CodingKey {
                case holes
                case existingIDs = "existing_ids"
                case desiredIDs = "desired_ids"
                case expectedPaneIDs = "expected_pane_ids"
            }
        }

        let shapes: [Shape]
        let holeRepair: HoleRepair

        enum CodingKeys: String, CodingKey {
            case shapes
            case holeRepair = "hole_repair"
        }
    }

    static func paneGrid() throws -> PaneGridFixture {
        let url = try XCTUnwrap(
            Bundle(for: PaneGridTests.self).url(forResource: "pane-grid", withExtension: "json"),
            "fixtures/native-macos-compat/pane-grid.json is not bundled with the tests"
        )
        return try JSONDecoder().decode(PaneGridFixture.self, from: Data(contentsOf: url))
    }
}
