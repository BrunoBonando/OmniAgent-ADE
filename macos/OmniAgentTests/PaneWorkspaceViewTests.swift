import XCTest
import SwiftTerm
@testable import OmniAgent

/// Phase 4's behavioural contract: pane identity independent of cell position,
/// frames calculated directly, PTY resize coalesced to one send per display
/// refresh, focus preserved across every mutation, native commands, drag/drop
/// swapping, and accessibility descriptions.
final class PaneWorkspaceViewTests: XCTestCase {
    // MARK: - Shapes

    func testAddingPanesWalksTheApprovedLadderAndCapsAtEight() {
        let workspace = makeWorkspace(panes: 1)
        let expected: [(cols: Int, rows: Int)] = [
            (1, 1), (2, 1), (2, 2), (2, 2), (3, 2), (3, 2), (4, 2), (4, 2),
        ]
        for count in 1...PaneGrid.maxPanes {
            if count > 1 { XCTAssertTrue(workspace.addPane(makeDescriptor("pane-\(count)"))) }
            XCTAssertEqual(workspace.paneIDs.count, count)
            XCTAssertEqual(workspace.grid?.cols, expected[count - 1].cols, "\(count) panes")
            XCTAssertEqual(workspace.grid?.rows, expected[count - 1].rows, "\(count) panes")
        }
        XCTAssertFalse(workspace.addPane(makeDescriptor("pane-9")), "the cap refuses a ninth pane")
        XCTAssertEqual(workspace.paneIDs.count, PaneGrid.maxPanes)
    }

    func testPanesAndHolesTileTheWorkspaceBoundsExactly() {
        let workspace = makeWorkspace(panes: 3)
        let frames = workspace.paneIDs.compactMap { workspace.container(for: $0)?.frame }
        XCTAssertEqual(frames.count, 3)
        // The grid is inset by `gridInset` on every side (the design's 7px
        // padding), so the outermost panes stop short of the view's own bounds.
        XCTAssertEqual(frames[0].minX, PaneWorkspaceView.gridInset)
        XCTAssertEqual(frames[0].minY, PaneWorkspaceView.gridInset)
        // Column-major: pane 2 sits under pane 1, pane 3 tops the right column.
        XCTAssertEqual(frames[1].minX, frames[0].minX)
        XCTAssertGreaterThan(frames[1].minY, frames[0].minY)
        XCTAssertGreaterThan(frames[2].minX, frames[0].minX)
        XCTAssertEqual(frames[2].minY, PaneWorkspaceView.gridInset)
        XCTAssertEqual(frames[2].maxX, workspace.gridBounds.maxX)
    }

    func testHolesGetAnAddTerminalPlaceholderInTheEmptyCell() {
        let workspace = makeWorkspace(panes: 3)
        var requests = 0
        workspace.onRequestNewPane = { requests += 1 }

        XCTAssertEqual(workspace.holePlaceholders.count, 1, "3 panes leave one hole in the 2x2 rung")
        let hole = workspace.holePlaceholders[0]
        XCTAssertEqual(hole.frame.maxX, workspace.gridBounds.maxX, "the hole is the lower-right cell")
        XCTAssertEqual(hole.frame.maxY, workspace.gridBounds.maxY)
        XCTAssertEqual(hole.accessibilityRole(), .button)
        XCTAssertEqual(hole.accessibilityLabel(), "Add terminal")

        XCTAssertTrue(hole.accessibilityPerformPress())
        XCTAssertEqual(requests, 1, "the hole doubles as the Add Terminal affordance")

        for index in 4...PaneGrid.maxPanes {
            XCTAssertTrue(workspace.addPane(makeDescriptor("pane-\(index)")))
        }
        XCTAssertTrue(workspace.holePlaceholders.isEmpty, "a full rung has no holes")
    }

    // MARK: - Identity

    func testTerminalInstancesSurviveEveryLayoutMutation() {
        let workspace = makeWorkspace(panes: 4)
        let before = identities(in: workspace)

        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-5"))) // reshape 2x2 -> 3x2
        XCTAssertTrue(workspace.closePane("pane-5")) // reshape back
        XCTAssertTrue(workspace.swapPanes("pane-1", "pane-4"))
        workspace.focusPane("pane-3")

        let after = identities(in: workspace)
        XCTAssertEqual(before, after, "no pane mutation may recreate a live terminal view")
    }

    func testSwapMovesFramesNotTerminals() {
        let workspace = makeWorkspace(panes: 4)
        XCTAssertEqual(workspace.paneIDs, ["pane-1", "pane-3", "pane-2", "pane-4"])
        let first = workspace.container(for: "pane-1")!
        let last = workspace.container(for: "pane-4")!
        let firstFrame = first.frame
        let lastFrame = last.frame
        let firstTerminal = ObjectIdentifier(first.surface.terminalView)

        XCTAssertTrue(workspace.swapPanes("pane-1", "pane-4"))

        XCTAssertEqual(first.frame, lastFrame)
        XCTAssertEqual(last.frame, firstFrame)
        XCTAssertEqual(ObjectIdentifier(workspace.container(for: "pane-1")!.surface.terminalView), firstTerminal)
        XCTAssertEqual(workspace.paneIDs, ["pane-4", "pane-3", "pane-2", "pane-1"])
    }

    func testGroupingMetadataTravelsWithThePaneAcrossSwapAndReflow() {
        let workspace = makeWorkspace(panes: 3)
        var descriptor = makeDescriptor("pane-4")
        descriptor.groupLabel = "Session 2"
        descriptor.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(descriptor))

        // Swapping happens inside a session, where both panes are on screen.
        workspace.focusPane("pane-1")
        XCTAssertTrue(workspace.swapPanes("pane-1", "pane-3"))
        XCTAssertTrue(workspace.closePane("pane-2"))

        XCTAssertEqual(workspace.descriptor(for: "pane-1")?.group, "sess-grp-1")
        XCTAssertEqual(workspace.descriptor(for: "pane-4")?.group, "sess-grp-2")
        XCTAssertEqual(workspace.descriptor(for: "pane-4")?.groupLabel, "Session 2")
    }

    /// Two panes in different sessions are never on screen together, so
    /// trading their cells is not a thing that can be asked for — the grid a
    /// swap reorders only ever holds one session's panes.
    func testPanesInDifferentSessionsCannotBeSwapped() {
        let workspace = makeWorkspace(panes: 2)
        var descriptor = makeDescriptor("pane-3")
        descriptor.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(descriptor))

        XCTAssertFalse(workspace.swapPanes("pane-1", "pane-3"))
        XCTAssertFalse(workspace.canAcceptDrop(from: "pane-1", onto: "pane-3"))
    }

    // MARK: - Focus

    func testClosingTheFocusedPaneMovesFocusToItsFillOrderNeighbour() {
        let workspace = makeWorkspace(panes: 4) // fill order: 1, 3, 2, 4
        workspace.focusPane("pane-3")
        XCTAssertTrue(workspace.closePane("pane-3"))
        XCTAssertEqual(workspace.focusedPaneID, "pane-1", "focus falls to the previous pane in fill order")

        XCTAssertEqual(workspace.paneIDs, ["pane-1", "pane-2", "pane-4"])
        workspace.focusPane("pane-1")
        XCTAssertTrue(workspace.closePane("pane-1"))
        XCTAssertEqual(workspace.focusedPaneID, "pane-2", "the first pane hands focus forward")
    }

    func testDirectionalFocusCommandsWalkTheGridAndStopAtTheEdge() {
        // Incremental adds pass through the 2 -> 3 lower-left rule, so the
        // columns are [pane-1, pane-3] and [pane-2, pane-4].
        let workspace = makeWorkspace(panes: 4)
        workspace.focusPane("pane-1")

        workspace.focusPaneDown(nil)
        XCTAssertEqual(workspace.focusedPaneID, "pane-3")
        workspace.focusPaneRight(nil)
        XCTAssertEqual(workspace.focusedPaneID, "pane-4")
        workspace.focusPaneUp(nil)
        XCTAssertEqual(workspace.focusedPaneID, "pane-2")
        workspace.focusPaneRight(nil)
        XCTAssertEqual(workspace.focusedPaneID, "pane-2", "no wrap past the last column")
        workspace.focusPaneLeft(nil)
        XCTAssertEqual(workspace.focusedPaneID, "pane-1")
        workspace.focusPaneUp(nil)
        XCTAssertEqual(workspace.focusedPaneID, "pane-1", "no wrap past the first row")
    }

    func testDirectionalSwapCommandsTradePlacesAndKeepFocusOnTheMovedPane() {
        let workspace = makeWorkspace(panes: 4)
        workspace.focusPane("pane-1")

        workspace.swapPaneRight(nil)

        XCTAssertEqual(workspace.paneIDs, ["pane-2", "pane-3", "pane-1", "pane-4"])
        XCTAssertEqual(workspace.focusedPaneID, "pane-1", "focus follows the pane, not the cell")
    }

    func testNumericSelectionPicksTheNthPaneInFillOrder() {
        let workspace = makeWorkspace(panes: 4)
        XCTAssertEqual(workspace.paneIDs, ["pane-1", "pane-3", "pane-2", "pane-4"])
        let item = NSMenuItem(title: "Pane 3", action: nil, keyEquivalent: "")
        item.tag = 3
        workspace.selectPane(item)
        XCTAssertEqual(workspace.focusedPaneID, "pane-2", "the third cell in fill order, not the id")

        item.tag = 9
        workspace.selectPane(item)
        XCTAssertEqual(workspace.focusedPaneID, "pane-2", "an out-of-range index changes nothing")
    }

    func testFocusIsRestoredToTheFocusedPaneWhenTheWindowIsActivated() {
        let (workspace, window) = makeAttachedWorkspace(panes: 4)
        defer { window.close() }
        workspace.focusPane("pane-3")
        XCTAssertTrue(window.firstResponder === workspace.surface(for: "pane-3")?.terminalView)

        XCTAssertTrue(window.makeFirstResponder(window))
        workspace.restoreFocus()

        XCTAssertEqual(workspace.focusedPaneID, "pane-3")
        XCTAssertTrue(window.firstResponder === workspace.surface(for: "pane-3")?.terminalView)
    }

    func testFocusSurvivesASwapAndAReflow() {
        let (workspace, window) = makeAttachedWorkspace(panes: 4)
        defer { window.close() }
        workspace.focusPane("pane-2")

        XCTAssertTrue(workspace.swapPanes("pane-2", "pane-3"))
        XCTAssertEqual(workspace.focusedPaneID, "pane-2")
        XCTAssertTrue(window.firstResponder === workspace.surface(for: "pane-2")?.terminalView)

        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-5")))
        XCTAssertEqual(workspace.focusedPaneID, "pane-5", "a new pane takes focus")
        XCTAssertTrue(window.firstResponder === workspace.surface(for: "pane-5")?.terminalView)
    }

    // MARK: - Drag and drop

    func testDroppingOnePaneOnAnotherSwapsThemThroughTheRealDraggingDestination() {
        let workspace = makeWorkspace(panes: 4)
        let source = workspace.container(for: "pane-1")!
        let target = workspace.container(for: "pane-4")!
        let sourceTerminal = ObjectIdentifier(source.surface.terminalView)
        let info = StubDraggingInfo(paneID: "pane-1")

        XCTAssertEqual(target.draggingEntered(info), .move)
        XCTAssertTrue(target.isDropTarget, "the drop target highlights while the drag hovers")
        XCTAssertTrue(target.performDragOperation(info))

        XCTAssertFalse(target.isDropTarget)
        XCTAssertEqual(workspace.paneIDs, ["pane-4", "pane-3", "pane-2", "pane-1"])
        XCTAssertEqual(ObjectIdentifier(workspace.container(for: "pane-1")!.surface.terminalView), sourceTerminal)
    }

    func testDroppingAPaneOnItselfOrCarryingAnUnknownIDIsRefused() {
        let workspace = makeWorkspace(panes: 2)
        let target = workspace.container(for: "pane-1")!

        XCTAssertEqual(target.draggingEntered(StubDraggingInfo(paneID: "pane-1")), [])
        XCTAssertFalse(target.performDragOperation(StubDraggingInfo(paneID: "pane-1")))
        XCTAssertFalse(target.performDragOperation(StubDraggingInfo(paneID: "ghost")))
        XCTAssertEqual(workspace.paneIDs, ["pane-1", "pane-2"])
    }

    func testEveryPaneIsBothADragSourceAndADropDestination() {
        let workspace = makeWorkspace(panes: 2)
        let container = workspace.container(for: "pane-2")!
        XCTAssertEqual(
            container.pasteboardItemForDragging().string(forType: PaneWorkspaceView.paneDragType),
            "pane-2"
        )
        XCTAssertTrue(container.registeredDraggedTypes.contains(PaneWorkspaceView.paneDragType))
    }

    func testFocusRingAndDropTintCompositeAboveTheOpaqueTerminal() {
        let workspace = makeWorkspace(panes: 4)
        // pane-4 was added last and therefore holds focus; pane-1 starts idle.
        let target = workspace.container(for: "pane-1")!
        // The header and the terminal surface are both opaque and tile the
        // container inset by the border width — that 1pt gap, showing the
        // container's own background, *is* the border, and it is what lets the
        // rounded corner and the working ring live on one layer. The drop tint
        // stays a top-most subview rather than a draw(_:) fill.
        XCTAssertEqual(target.header.frame.maxY, target.surface.frame.minY)
        XCTAssertEqual(target.surface.frame.maxY, target.bounds.maxY - PaneContainerView.borderWidth)
        XCTAssertEqual(target.header.frame.minY, PaneContainerView.borderWidth)
        XCTAssertEqual(target.layer?.cornerRadius, PaneContainerView.cornerRadius)
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.idleBorderColor.cgColor)
        XCTAssertTrue(target.dropHighlight.isHidden)

        workspace.focusPane("pane-1")
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.focusedBorderColor.cgColor)
        workspace.focusPane("pane-4")
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.idleBorderColor.cgColor)

        XCTAssertEqual(target.draggingEntered(StubDraggingInfo(paneID: "pane-4")), .move)
        XCTAssertFalse(target.dropHighlight.isHidden, "the hovered pane is visibly the swap target")
        XCTAssertEqual(target.dropHighlight.frame, target.bounds)
        XCTAssertTrue(target.subviews.last === target.dropHighlight, "the tint sits above the terminal")
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.dropTargetBorderColor.cgColor)
        XCTAssertNil(
            target.dropHighlight.hitTest(NSPoint(x: 5, y: 5)),
            "the tint never swallows a click meant for the pane"
        )

        target.draggingExited(nil)
        XCTAssertTrue(target.dropHighlight.isHidden)
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.idleBorderColor.cgColor)
    }

    // MARK: - Header chrome

    /// The border says what the pane is doing, and "I have stopped to ask you
    /// something" outranks "you are looking at me" — a focused pane already
    /// reads as focused from everything else on screen.
    func testThePaneBorderFollowsStatusAndUrgencyOutranksFocus() {
        let workspace = makeWorkspace(panes: 2)
        let target = workspace.container(for: "pane-1")!
        workspace.focusPane("pane-1")
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.focusedBorderColor.cgColor)

        workspace.setStatus(.awaitingApproval, for: "pane-1")
        XCTAssertEqual(target.status, .awaitingApproval)
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.awaitingBorderColor.cgColor)

        workspace.setStatus(.error, for: "pane-1")
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.errorBorderColor.cgColor)

        workspace.setStatus(.ready, for: "pane-1")
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.focusedBorderColor.cgColor)

        // An unfocused pane still shows urgency; that is the whole point of
        // being able to see it from the other side of the grid.
        workspace.focusPane("pane-2")
        workspace.setStatus(.awaitingApproval, for: "pane-1")
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.awaitingBorderColor.cgColor)
    }

    /// One mapping, not two: the header's mark and the sidebar's session dots
    /// must never disagree about what a session is doing.
    func testTheHeaderMarkUsesTheSameStatusColoursAsTheSidebar() {
        for status: RemoteSessionStatus? in [.ready, .thinking, .toolExecution, .awaitingApproval, .error, nil] {
            XCTAssertEqual(PaneStatusMarkView.color(for: status), ShellDotsView.color(for: status))
        }
        XCTAssertNotEqual(PaneStatusMarkView.color(for: .ready), PaneStatusMarkView.color(for: nil))
    }

    /// Four panes side by side are told apart by colour before their labels are
    /// read, so no two engines may share a badge colour.
    func testEveryEngineBadgeIsItsOwnColour() {
        XCTAssertEqual(Engine.claude.badgeTitle, "Claude Code")
        XCTAssertEqual(Engine.antigravity.badgeTitle, "AntiGravity")
        let foregrounds = Set(Engine.allCases.map(\.badgeForeground.description))
        XCTAssertEqual(foregrounds.count, Engine.allCases.count)
    }

    // MARK: - Accessibility

    func testEachPaneAndItsTerminalCarryAccessibilityDescriptions() {
        let workspace = makeWorkspace(panes: 4)
        var descriptor = makeDescriptor("pane-5")
        descriptor.groupLabel = "Session 2"
        XCTAssertTrue(workspace.addPane(descriptor))

        XCTAssertEqual(workspace.accessibilityRole(), .group)
        XCTAssertEqual(workspace.accessibilityLabel(), "Terminal panes")
        XCTAssertEqual(workspace.accessibilityChildren()?.count, 5)

        // Fill order is 1, 3, 2, 4, 5 — pane-2 sits in the third cell.
        let second = workspace.container(for: "pane-2")!
        XCTAssertEqual(second.accessibilityRole(), .group)
        XCTAssertEqual(second.accessibilityLabel(), "Terminal pane 3 of 5")
        XCTAssertEqual(second.surface.terminalView.accessibilityLabel(), "Terminal")

        let grouped = workspace.container(for: "pane-5")!
        XCTAssertEqual(grouped.accessibilityLabel(), "Session 2, terminal pane 5 of 5")
    }

    // MARK: - Resize coalescing

    func testDividerDragCoalescesPTYResizeToAtMostOneSendPerDisplayRefresh() {
        let workspace = makeWorkspace(panes: 4)
        let divider = workspace.grid!
            .layout(in: workspace.bounds, dividerThickness: PaneWorkspaceView.dividerThickness)
            .dividers.first { $0.axis == .vertical }!

        for _ in 0..<20 { workspace.moveDivider(divider, by: 2) }

        XCTAssertEqual(workspace.resizeCoalescer.flushCount, 0, "nothing is sent mid-drag")
        XCTAssertEqual(workspace.resizeCoalescer.pending, Set(workspace.paneIDs))
        for id in workspace.paneIDs {
            XCTAssertEqual(workspace.surface(for: id)?.resizeSendCount, 0, id)
        }

        workspace.resizeCoalescer.flush()

        XCTAssertEqual(workspace.resizeCoalescer.flushCount, 1)
        XCTAssertTrue(workspace.resizeCoalescer.pending.isEmpty)
        for id in workspace.paneIDs {
            XCTAssertEqual(workspace.surface(for: id)?.resizeSendCount, 1, "\(id): 20 drag steps, one send")
        }
    }

    func testFramesFollowTheDragImmediatelyEvenThoughTheResizeIsDeferred() {
        let workspace = makeWorkspace(panes: 4)
        let divider = workspace.grid!
            .layout(in: workspace.bounds, dividerThickness: PaneWorkspaceView.dividerThickness)
            .dividers.first { $0.axis == .vertical }!
        let before = workspace.container(for: "pane-1")!.frame.width

        workspace.moveDivider(divider, by: 40)

        XCTAssertEqual(workspace.container(for: "pane-1")!.frame.width, before + 40)
        XCTAssertEqual(workspace.resizeCoalescer.flushCount, 0)
    }

    // MARK: - Occlusion

    func testSuspendedPanesStopRequestingDrawsButKeepParsingOutput() {
        let (workspace, window) = makeAttachedWorkspace(panes: 1)
        defer { window.close() }
        let surface = workspace.surface(for: "pane-1")!

        workspace.setSuspendsDrawing(true)
        surface.feed(Data("hidden-output".utf8), isSnapshot: false)
        spinRunLoop()

        XCTAssertEqual(surface.drawRequestCount, 0, "an occluded pane draws nothing")
        XCTAssertTrue(
            (surface.terminalView.accessibilityValue() as? String)?.contains("hidden-output") == true,
            "the parser keeps consuming output while drawing is suspended"
        )

        workspace.setSuspendsDrawing(false)
        surface.feed(Data("visible-output".utf8), isSnapshot: false)
        spinRunLoop()

        XCTAssertEqual(surface.drawRequestCount, 1)
    }

    // MARK: - Benchmark

    /// Attached eight-pane divider/renderer benchmark.
    ///
    /// **What it measures:** the in-process cost of the workspace's own work for
    /// a full-rung grid — recomputing the eight-pane rectangle, reframing eight
    /// `TerminalSurfaceView`s, and asking each one's renderer to draw — on
    /// whatever machine happens to run the test suite.
    ///
    /// **What it does not measure, and must not be quoted as:** end-to-end PTY
    /// throughput, daemon CPU, input-to-glyph latency, or memory under hidden
    /// output. There is no PTY behind these panes (the socket never connects)
    /// and no window compositing on a headless test host. The reference-hardware
    /// gate remains `scripts/native-macos-pty-harness.py benchmark` against a
    /// packaged app, recorded with `benchmarks/native-macos/reference-machine.schema.json`
    /// metadata — this test is a regression tripwire for the layout/draw path
    /// only, and no number it prints is a committed benchmark result.
    func testEightPaneDividerAndRendererDrawBenchmark() {
        let (workspace, window) = makeAttachedWorkspace(panes: PaneGrid.maxPanes)
        defer { window.close() }
        let dividers = workspace.grid!
            .layout(in: workspace.bounds, dividerThickness: PaneWorkspaceView.dividerThickness)
            .dividers

        measure(metrics: [XCTClockMetric(), XCTCPUMetric()]) {
            for step in 0..<30 {
                workspace.moveDivider(dividers[step % dividers.count], by: step.isMultiple(of: 2) ? 3 : -3)
            }
            workspace.resizeCoalescer.flush()
            for id in workspace.paneIDs {
                workspace.surface(for: id)?.requestRendererDraw()
            }
        }
    }

    // MARK: - A session holds its own terminals

    func testASecondSessionShowsOnlyItsOwnTerminals() throws {
        let workspace = makeWorkspace(panes: 2)
        var second = makeDescriptor("pane-3")
        second.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(second))

        XCTAssertEqual(workspace.paneIDs, ["pane-3"], "one terminal in it, one terminal shown")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-2")
        XCTAssertEqual(
            workspace.allPaneIDs.sorted(),
            ["pane-1", "pane-2", "pane-3"],
            "the other session's terminals still exist — they are off screen, not closed"
        )
        XCTAssertEqual(workspace.container(for: "pane-1")?.isHidden, true)
        XCTAssertEqual(workspace.container(for: "pane-2")?.isHidden, true)
        XCTAssertEqual(workspace.container(for: "pane-3")?.isHidden, false)
        XCTAssertNotNil(
            workspace.surface(for: "pane-1"),
            "and their terminals are alive, so the PTY keeps running"
        )
    }

    func testFocusingAPaneInAnotherSessionBringsThatSessionToTheScreen() {
        let workspace = makeWorkspace(panes: 2)
        var second = makeDescriptor("pane-3")
        second.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(second))

        // What the sidebar does for both a session row and a pane row.
        workspace.focusPane("pane-1")

        XCTAssertEqual(workspace.activeGroup, "sess-grp-1")
        XCTAssertEqual(workspace.paneIDs, ["pane-1", "pane-2"])
        XCTAssertEqual(workspace.container(for: "pane-3")?.isHidden, true)
        XCTAssertEqual(workspace.focusedPaneID, "pane-1")
    }

    func testEachSessionKeepsItsOwnLayout() {
        let workspace = makeWorkspace(panes: 2)
        var second = makeDescriptor("pane-3")
        second.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(second))
        XCTAssertEqual(workspace.grid?.cols, 1, "one terminal, one column")

        workspace.focusPane("pane-1")
        XCTAssertEqual(workspace.grid?.cols, 2, "the first session is still two across")

        workspace.focusPane("pane-3")
        XCTAssertEqual(workspace.grid?.cols, 1, "and switching back does not reshape either")
    }

    func testClosingASessionsLastPaneDropsTheSessionAndLandsInAnother() {
        let workspace = makeWorkspace(panes: 2)
        var second = makeDescriptor("pane-3")
        second.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(second))

        XCTAssertTrue(workspace.closePane("pane-3"))

        XCTAssertEqual(workspace.groupIDs, ["sess-grp-1"], "an empty session is not a session")
        XCTAssertEqual(workspace.activeGroup, "sess-grp-1")
        XCTAssertEqual(workspace.paneIDs, ["pane-1", "pane-2"])
        XCTAssertNotNil(workspace.focusedPaneID, "focus lands somewhere real, not on the closed pane")
    }

    // MARK: - Zoom

    func testZoomIsNotOfferedWithASingleTerminalOnScreen() {
        let workspace = makeWorkspace(panes: 1)

        XCTAssertFalse(workspace.toggleZoom("pane-1"), "there is nothing to zoom away from")
        XCTAssertNil(workspace.zoomedPaneID)
        XCTAssertEqual(workspace.container(for: "pane-1")?.isZoomAvailable, false)
    }

    func testZoomingCoversAlmostTheWorkspaceAndPutsTheBlurUnderIt() throws {
        let workspace = makeWorkspace(panes: 2)
        XCTAssertEqual(workspace.container(for: "pane-1")?.isZoomAvailable, true)

        XCTAssertTrue(workspace.toggleZoom("pane-2"))
        workspace.layoutSubtreeIfNeeded()

        XCTAssertEqual(workspace.zoomedPaneID, "pane-2")
        let zoomed = try XCTUnwrap(workspace.container(for: "pane-2"))
        let area = workspace.gridBounds
        XCTAssertTrue(area.contains(zoomed.frame), "it stays inside the workspace")
        XCTAssertGreaterThan(
            zoomed.frame.width * zoomed.frame.height,
            area.width * area.height * 0.8,
            "almost the entire terminal place"
        )

        let backdrop = try XCTUnwrap(
            workspace.subviews.compactMap { $0 as? PaneZoomBackdropView }.first
        )
        XCTAssertFalse(backdrop.isHidden)
        let order = workspace.subviews
        let blurIndex = try XCTUnwrap(order.firstIndex(of: backdrop))
        let zoomedIndex = try XCTUnwrap(order.firstIndex(of: zoomed))
        let otherIndex = try XCTUnwrap(
            order.firstIndex(of: try XCTUnwrap(workspace.container(for: "pane-1")))
        )
        XCTAssertGreaterThan(zoomedIndex, blurIndex, "the zoomed pane sits above the blur")
        XCTAssertLessThan(otherIndex, blurIndex, "and everything else behind it, blurred")

        XCTAssertTrue(workspace.toggleZoom("pane-2"), "the same button shrinks it back")
        XCTAssertNil(workspace.zoomedPaneID)
        XCTAssertTrue(backdrop.isHidden)
    }

    func testZoomEndsWhenItWouldOtherwiseHideWhatYouAskedFor() {
        let workspace = makeWorkspace(panes: 2)
        XCTAssertTrue(workspace.toggleZoom("pane-1"))

        // Opening a terminal you cannot see would be worse than losing the zoom.
        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-3")))
        XCTAssertNil(workspace.zoomedPaneID)

        XCTAssertTrue(workspace.toggleZoom("pane-1"))
        var elsewhere = makeDescriptor("pane-4")
        elsewhere.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(elsewhere))
        XCTAssertNil(workspace.zoomedPaneID, "and a session switch takes it off screen entirely")

        workspace.focusPane("pane-1")
        XCTAssertTrue(workspace.toggleZoom("pane-1"))
        XCTAssertTrue(workspace.closePane("pane-2"))
        XCTAssertTrue(workspace.closePane("pane-3"))
        XCTAssertNil(workspace.zoomedPaneID, "one terminal left, nothing to zoom over")
    }

    // MARK: - Click to activate

    /// Clicking anywhere in a terminal makes it the active one. Every click
    /// inside a pane ends with something in that pane holding the first
    /// responder, which is the signal `adoptFocus` turns into activation — so
    /// the terminal body and the pane's own chrome both count, and there is no
    /// dead region that looks clickable and is not.
    func testClickingAnywhereInAPaneMakesItTheActiveOne() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 2)
        defer { window.close() }
        workspace.focusPane("pane-1")
        let target = try XCTUnwrap(workspace.container(for: "pane-2"))

        workspace.adoptFocus(from: target.surface)
        XCTAssertEqual(workspace.focusedPaneID, "pane-2", "a click in the terminal body")

        workspace.focusPane("pane-1")
        workspace.adoptFocus(from: target.header)
        XCTAssertEqual(workspace.focusedPaneID, "pane-2", "a click on its header")

        workspace.focusPane("pane-1")
        workspace.adoptFocus(from: workspace)
        XCTAssertEqual(
            workspace.focusedPaneID,
            "pane-1",
            "and a responder belonging to no pane changes nothing"
        )
    }

    // MARK: - Helpers

    /// Panes are added one at a time, exactly as ⌘T does, so the fill order
    /// carries the 2 -> 3 lower-left rule: four panes end up as columns
    /// [pane-1, pane-3] and [pane-2, pane-4].
    private func makeWorkspace(panes: Int) -> PaneWorkspaceView {
        let connection = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-pane-workspace-test.sock")
        )
        let workspace = PaneWorkspaceView { id in
            TerminalSurfaceView(connection: connection, sessionID: id)
        }
        workspace.frame = CGRect(x: 0, y: 0, width: 1200, height: 800)
        for index in 1...panes {
            XCTAssertTrue(workspace.addPane(makeDescriptor("pane-\(index)")))
        }
        return workspace
    }

    private func makeAttachedWorkspace(panes: Int) -> (PaneWorkspaceView, NSWindow) {
        let workspace = makeWorkspace(panes: panes)
        let window = WorkspaceWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = workspace
        window.makeKeyAndOrderFront(nil)
        return (workspace, window)
    }

    private func makeDescriptor(_ id: String) -> PaneDescriptor {
        PaneDescriptor(sessionID: id, group: "sess-grp-1", groupLabel: nil, title: "")
    }

    private func identities(in workspace: PaneWorkspaceView) -> [String: ObjectIdentifier] {
        var result: [String: ObjectIdentifier] = [:]
        for id in workspace.paneIDs {
            result[id] = workspace.surface(for: id).map(ObjectIdentifier.init)
        }
        return result
    }

    private func spinRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
}

/// Minimal `NSDraggingInfo` so the tests drive the real
/// `NSDraggingDestination` entry points rather than a private shortcut.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard

    init(paneID: String) {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("omniagent-pane-drag-test"))
        pasteboard.declareTypes([PaneWorkspaceView.paneDragType], owner: nil)
        pasteboard.setString(paneID, forType: PaneWorkspaceView.paneDragType)
        draggingPasteboard = pasteboard
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var numberOfValidItemsForDrop: Int = 1
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination: Bool = false
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
