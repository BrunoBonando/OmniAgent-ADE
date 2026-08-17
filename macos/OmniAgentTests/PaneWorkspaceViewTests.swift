import XCTest
import CoreImage
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

    /// Exactly one cursor blinks at a time. Every other pane holds a steady
    /// cursor of the same shape, so a grid of eight has one thing moving in it
    /// and it is the pane you are typing into.
    func testOnlyTheSelectedPaneBlinksItsCursor() {
        let workspace = makeWorkspace(panes: 3)
        func style(_ id: String) -> CursorStyle {
            workspace.container(for: id)!.surface.terminalView.terminal.options.cursorStyle
        }

        workspace.focusPane("pane-2")
        XCTAssertEqual(style("pane-2"), .blinkBlock)
        XCTAssertEqual(style("pane-1"), .steadyBlock)
        XCTAssertEqual(style("pane-3"), .steadyBlock)

        workspace.focusPane("pane-3")
        XCTAssertEqual(style("pane-3"), .blinkBlock)
        XCTAssertEqual(style("pane-2"), .steadyBlock, "the pane you left stops blinking at you")
    }

    /// A program that sets its own cursor style while in the background keeps
    /// it — the deselect override only ever puts back what it took away.
    func testDeselectDoesNotClobberACursorStyleTheProgramChose() {
        let workspace = makeWorkspace(panes: 2)
        let background = workspace.container(for: "pane-1")!.surface
        workspace.focusPane("pane-2")
        XCTAssertEqual(background.terminalView.terminal.options.cursorStyle, .steadyBlock)

        // DECSCUSR 5: blinking bar, sent while the pane is unselected.
        background.terminalView.terminal.setCursorStyle(.blinkBar)
        workspace.focusPane("pane-1")
        XCTAssertEqual(background.terminalView.terminal.options.cursorStyle, .blinkBar)
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

    /// Eight terminals is what one grid can draw, and each session has its
    /// own grid — so it is a per-session number. Applying it to the whole app
    /// meant a full session stopped every other session from opening a
    /// terminal at all.
    func testEachSessionGetsItsOwnEightTerminals() {
        let workspace = makeWorkspace(panes: PaneGrid.maxPanes)
        XCTAssertFalse(workspace.addPane(makeDescriptor("pane-9")), "this session is full")

        var elsewhere = makeDescriptor("other-1")
        elsewhere.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(elsewhere), "a different session is not")

        XCTAssertEqual(workspace.paneCount(inGroup: "sess-grp-1"), PaneGrid.maxPanes)
        XCTAssertEqual(workspace.paneCount(inGroup: "sess-grp-2"), 1)
        XCTAssertEqual(workspace.allPaneIDs.count, PaneGrid.maxPanes + 1)
        XCTAssertEqual(workspace.paneIDs.count, 1, "and it shows only its own")
    }

    /// The app-wide ceiling is a backstop, not a limit anyone meets, and it
    /// only works if it stays above what the per-session cap allows — the
    /// mistake being guarded against is exactly the one this replaces, a
    /// whole-app number standing in for a per-session one.
    ///
    /// Asserted on the constants rather than by opening that many terminals:
    /// building `maxTerminals` live `TerminalSurfaceView`s to prove a `guard`
    /// destabilised the rest of the suite, and crashed an unrelated test two
    /// runs out of two. `omniagent-pty-daemon`'s
    /// `session_cap_leaves_room_for_every_pane_the_ui_can_draw` pins the same
    /// relationship from the daemon's side.
    func testTheAppWideCeilingLeavesRoomForEverySessionsFullGrid() {
        XCTAssertGreaterThanOrEqual(
            PaneWorkspaceView.maxTerminals,
            PaneGrid.maxPanes * 8,
            "eight sessions of eight panes has to fit under the app-wide backstop"
        )
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
        // The card, centred in an overlay padded by 26 — and a real share of the
        // window at any size, which the mock's flat 1080x720 ceiling stopped
        // being the moment the window grew past it.
        XCTAssertEqual(zoomed.frame, PaneWorkspaceView.focusCardFrame(in: workspace.bounds))

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

        XCTAssertEqual(
            backdrop.blendingMode,
            .withinWindow,
            "blurring the app behind it rather than the desktop behind the window"
        )

        XCTAssertTrue(workspace.toggleZoom("pane-2"), "the same button shrinks it back")
        XCTAssertNil(workspace.zoomedPaneID)
        // Back to zero at once — the eased animation is what takes time, the
        // model value lands immediately.
        XCTAssertEqual(backdrop.alphaValue, 0)
        // Hidden only once it has faded out, since it swallows clicks.
        let deadline = Date().addingTimeInterval(2)
        while !backdrop.isHidden || backdrop.superview != nil, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(backdrop.isHidden, "once the fade has landed")
        // And taken out of the grid rather than parked in it: with no window this
        // view is the overlay host, so removing the host alone left it behind.
        XCTAssertNil(backdrop.superview, "the backdrop does not stay in the grid")
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

    /// The card as a share of the overlay it is centred in, which has `padding:26px`.
    /// Pure geometry, so it is asked directly rather than through a window.
    func testFocusCardFrameIsAShareOfTheOverlayItIsCentredIn() {
        let padding = PaneWorkspaceView.focusOverlayPadding
        let scale = PaneWorkspaceView.focusCardScale
        let roomy = PaneWorkspaceView.focusCardFrame(
            in: NSRect(x: 0, y: 0, width: 1600, height: 1000)
        )
        XCTAssertEqual(
            roomy.size,
            NSSize(width: (1600 * scale).rounded(.down), height: (1000 * scale).rounded(.down))
        )
        XCTAssertEqual(roomy.midX, 800, "centred in the overlay")
        XCTAssertEqual(roomy.midY, 500)
        // The point of the change: it keeps growing with the window instead of
        // stopping at the mock's 1080x720 and shrinking, relatively, from there.
        let bigger = PaneWorkspaceView.focusCardFrame(
            in: NSRect(x: 0, y: 0, width: 2400, height: 1500)
        )
        XCTAssertGreaterThan(bigger.width, roomy.width)
        XCTAssertGreaterThan(bigger.height, roomy.height)

        // Small enough that the share would come within 26 of an edge: the card
        // gives up its own size rather than the padding that keeps the blur
        // reading as a surround.
        let cramped = PaneWorkspaceView.focusCardFrame(
            in: NSRect(x: 0, y: 0, width: 300, height: 200)
        )
        XCTAssertEqual(
            cramped,
            NSRect(
                x: padding,
                y: padding,
                width: 300 - padding * 2,
                height: 200 - padding * 2
            )
        )

        // A host with no room for the padding at all still has to describe a
        // drawable rect.
        let sliver = PaneWorkspaceView.focusCardFrame(in: NSRect(x: 0, y: 0, width: 30, height: 10))
        XCTAssertEqual(sliver.width, 0, "never a negative dimension")
        XCTAssertEqual(sliver.height, 0)

        // Centred in the host it is given, not in one that happens to start at
        // the origin — the overlay host is a subview of the window's content
        // view, and its bounds are not the window's.
        let offset = PaneWorkspaceView.focusCardFrame(
            in: NSRect(x: 100, y: 50, width: 1600, height: 1000)
        )
        XCTAssertEqual(offset.midX, 900)
        XCTAssertEqual(offset.midY, 550)
    }

    /// The overlay is the design's full-bleed one
    /// (`top:30px;left:0;right:0;bottom:24px`, the app frame less its title bar
    /// and status strip): it covers the window's whole **content view** — the
    /// sidebar with it — rather than the pane grid alone, so while a pane is
    /// focused neither the blur nor the card is a subview of the workspace. Both
    /// come back out of the window when focus ends: a plain view left over the
    /// content view would swallow every click in the app.
    ///
    /// Driven through a window shaped like the real one — a content view holding
    /// a sidebar beside the pane grid — because that is the only arrangement in
    /// which "covers the content view" and "covers the grid" are different
    /// claims, and the bug this fixes was the overlay covering only the grid.
    func testFocusOverlayCoversTheContentViewAndOwnsTheCardWhileFocused() throws {
        let (workspace, window, sidebar) = makeSplitHostedWorkspace(panes: 2)
        defer { window.close() }
        let content = try XCTUnwrap(window.contentView)
        XCTAssertFalse(content === workspace, "the content view is not the pane grid")
        XCTAssertLessThan(workspace.frame.width, content.bounds.width, "the sidebar takes its share")

        XCTAssertTrue(workspace.toggleZoom("pane-2"))
        workspace.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(workspace.container(for: "pane-2"))
        let host = try XCTUnwrap(card.superview)
        XCTAssertFalse(host === workspace, "the card leaves the grid it is covering")
        XCTAssertTrue(host.superview === content, "for a host over the whole content view")
        XCTAssertEqual(host.frame, content.bounds, "the sidebar's rect included")
        XCTAssertTrue(host.frame.contains(sidebar.frame), "so the sidebar is inside the blur")
        let contentOrder = content.subviews
        XCTAssertGreaterThan(
            try XCTUnwrap(contentOrder.firstIndex(of: host)),
            try XCTUnwrap(contentOrder.firstIndex(of: sidebar)),
            "and under the overlay rather than beside it"
        )
        // The card is centred in the whole content view, which — with a sidebar
        // on one side — is a different rect from centred in the grid.
        XCTAssertEqual(card.frame, PaneWorkspaceView.focusCardFrame(in: host.bounds))
        XCTAssertNotEqual(
            card.frame,
            PaneWorkspaceView.focusCardFrame(in: workspace.bounds),
            "not centred in the grid alone"
        )
        XCTAssertEqual(
            card.layer?.cornerRadius,
            PaneContainerView.focusedCornerRadius,
            "and rounds to the card's 12 rather than the grid pane's 9"
        )

        let backdrop = try XCTUnwrap(
            host.subviews.compactMap { $0 as? PaneZoomBackdropView }.first
        )
        XCTAssertFalse(backdrop.isHidden, "the blur is shown")
        XCTAssertEqual(backdrop.frame, host.bounds, "over the same rect the host covers")
        let order = host.subviews
        XCTAssertGreaterThan(
            try XCTUnwrap(order.firstIndex(of: card)),
            try XCTUnwrap(order.firstIndex(of: backdrop)),
            "with the card on top of it"
        )

        // The shadow cannot be the card's own layer's — `masksToBounds` rounds
        // the terminal's corners and would clip it — so it is a layer of the
        // host, on the card's rect.
        let shadow = try XCTUnwrap(host.layer?.sublayers?.first { $0.shadowOpacity > 0 })
        XCTAssertEqual(shadow.frame, card.frame)
        XCTAssertEqual(shadow.cornerRadius, PaneContainerView.focusedCornerRadius)

        // The design's spinning accent ring belongs to the card the same way it
        // belongs to a grid pane — `updateWorkingRing` draws it as a sublayer of
        // the container, so it survives the reparent and tracks the card's own
        // bounds rather than the cell it came from.
        if !ShellMotion.reduced { // the ring is not drawn at all under Reduce Motion
            workspace.setStatus(.thinking, for: "pane-2")
            card.layoutSubtreeIfNeeded()
            let ring = try XCTUnwrap(
                card.layer?.sublayers?.compactMap { $0 as? CAGradientLayer }.first,
                "the working ring travels with the card"
            )
            XCTAssertEqual(ring.frame, card.bounds, "sized to the card, not to its old cell")
            XCTAssertNotNil(ring.animation(forKey: "om-spin"), "and is still spinning")
            workspace.setStatus(nil, for: "pane-2")
        }

        // Cleared first, so what the exit schedules is the only thing in here: this
        // is what pins the resize to the *shrink* rather than to the landing.
        // `landCard` schedules one too, and while that was the only assertion
        // deleting `place(_:at:)` from `collapseZoom` still passed.
        workspace.resizeCoalescer.flush()
        XCTAssertFalse(workspace.resizeCoalescer.pending.contains("pane-2"))

        workspace.setZoomed(nil)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            // Inside the exit's 0.32s, which is the state the app is actually in
            // when someone clicks straight after leaving focus: the card is still
            // flying, and the overlay is still mounted because the transition's
            // completion has not run yet.
            XCTAssertTrue(host.superview === content, "the overlay is still mounted")
            let overSidebar = sidebar.convert(NSPoint(x: 5, y: 5), to: nil)
            XCTAssertNil(
                host.hitTest(content.convert(overSidebar, from: nil)),
                "the host answers for nothing on its own account"
            )
            XCTAssertTrue(
                content.hitTest(overSidebar) === sidebar,
                "so a click over the sidebar reaches the sidebar, not the overlay"
            )
            XCTAssertTrue(
                workspace.resizeCoalescer.pending.contains("pane-2"),
                "and the PTY hears its cell size when the shrink starts, not when it lands"
            )
        }
        // The card shrinks home in the host's coordinates and is reparented once
        // the transition's own completion fires, so the grid owns its frame again.
        let deadline = Date().addingTimeInterval(2)
        while card.superview !== workspace, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(card.superview === workspace, "and comes back into the grid")
        XCTAssertTrue(workspace.gridBounds.contains(card.frame), "in its cell")
        XCTAssertEqual(card.layer?.cornerRadius, PaneContainerView.cornerRadius)
        XCTAssertNil(host.superview, "leaving nothing of the overlay over the app")
        XCTAssertNil(shadow.superlayer)
        XCTAssertEqual(backdrop.alphaValue, 0)
        // Alpha 0 is not enough on its own: for the 0.32s of the fade the
        // backdrop is invisible and still covers the whole window, so it must
        // stop hit-testing or it eats every click, sidebar included.
        XCTAssertNil(
            backdrop.hitTest(NSPoint(x: backdrop.bounds.midX, y: backdrop.bounds.midY)),
            "and stops swallowing clicks the moment it stops being shown"
        )
    }

    /// Every Panes-menu command has to keep working while a card is up. The nine
    /// selectors live on the workspace and the menu items carry no target, so
    /// AppKit resolves them along the responder chain from the first responder —
    /// and while zoomed that chain runs terminal → card → overlay host → content
    /// view, with the workspace nowhere on it. Sixteen items (⌘⌥arrows, ⌃⌘arrows,
    /// ⌘1…⌘8) silently greyed out, which they do not do with no card up.
    func testThePanesMenuCommandsStayReachableAndEnabledWhileACardIsUp() throws {
        let (workspace, window, _) = makeSplitHostedWorkspace(panes: 4)
        defer { window.close() }
        workspace.focusPane("pane-1")
        XCTAssertTrue(workspace.toggleZoom("pane-1"))
        let card = try XCTUnwrap(workspace.container(for: "pane-1"))
        XCTAssertTrue(window.makeFirstResponder(card.surface.terminalView))

        // The hazard itself: the plain chain from inside the overlay misses it.
        var chain: [NSResponder] = []
        var walk: NSResponder? = window.firstResponder
        while let current = walk {
            chain.append(current)
            walk = current.nextResponder
        }
        XCTAssertFalse(
            chain.contains { $0 === workspace },
            "the workspace is off the plain responder chain while zoomed"
        )

        // And what AppKit does about it: anything on the chain that does not
        // handle the action is asked for a supplemental target, which must be
        // the workspace — and the item must then validate as enabled.
        let commands: [(Selector, Int)] = [
            (#selector(PaneWorkspaceView.focusPaneRight(_:)), 0),
            (#selector(PaneWorkspaceView.focusPaneDown(_:)), 0),
            (#selector(PaneWorkspaceView.swapPaneRight(_:)), 0),
            (#selector(PaneWorkspaceView.selectPane(_:)), 3),
        ]
        for (action, tag) in commands {
            let resolved = try XCTUnwrap(
                target(for: action, from: window.firstResponder),
                "nothing answers \(action) while a card is up"
            )
            XCTAssertTrue(resolved === workspace, "\(action) has to land on the workspace")
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            item.tag = tag
            XCTAssertTrue(workspace.validateMenuItem(item), "\(action) greys out while zoomed")
        }

        // Narrow on purpose: the terminal's own Edit-menu actions must keep
        // resolving to the terminal, which is earlier in the chain either way.
        let host = try XCTUnwrap(card.superview)
        XCTAssertNil(
            host.supplementalTarget(forAction: #selector(NSText.copy(_:)), sender: nil),
            "the host offers the workspace for pane commands and nothing else"
        )
        // And the half that an open `responds(to:)` forward would have got wrong:
        // `print:` is implemented by every `NSView`, so a Print item added later
        // would have resolved to the pane grid while a card was up and to the
        // window the rest of the time.
        let printAction = Selector(("print:"))
        XCTAssertTrue(workspace.responds(to: printAction), "the premise of this assertion")
        XCTAssertNil(
            host.supplementalTarget(forAction: printAction, sender: nil),
            "a selector the workspace merely inherits is not a pane command"
        )
    }

    /// `setZoomed` is reached by ⌘↩, the palette and `revealPane`, so it owes the
    /// same two refusals `toggleZoom` makes — and must never refuse the way out.
    func testSetZoomedRefusesAPaneItCannotZoomOverButNeverRefusesTheWayOut() {
        let workspace = makeWorkspace(panes: 1)
        workspace.setZoomed("pane-1")
        XCTAssertNil(workspace.zoomedPaneID, "one terminal has nothing to zoom over")

        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-2")))
        var elsewhere = makeDescriptor("pane-3")
        elsewhere.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(elsewhere))
        workspace.setZoomed("pane-1")
        XCTAssertNil(workspace.zoomedPaneID, "and a pane off screen is not on the grid to cover")

        XCTAssertTrue(workspace.activateGroup("sess-grp-1"))
        workspace.setZoomed("pane-1")
        XCTAssertEqual(workspace.zoomedPaneID, "pane-1")
        workspace.setZoomed(nil)
        XCTAssertNil(workspace.zoomedPaneID, "and nil is always taken")
    }

    /// The card's subtitle names its session, and the derived `Session N` is a
    /// position in a list — so naming *another* session renumbers this one, with
    /// no layout pass to re-derive it. An engine can rename a session on its own,
    /// so nobody has to touch anything for the card to start lying.
    func testNamingAnotherSessionRefreshesTheCardsSubtitle() throws {
        // Two unnamed sessions: the first derives `Session 1`, the second
        // `Session 2`. The card is in the second, because naming a session only
        // renumbers the unnamed ones *after* it.
        let workspace = makeWorkspace(panes: 2)
        for id in ["pane-3", "pane-4"] {
            var pane = makeDescriptor(id)
            pane.group = "sess-grp-2"
            XCTAssertTrue(workspace.addPane(pane))
        }
        XCTAssertTrue(workspace.toggleZoom("pane-3"))
        let card = try XCTUnwrap(workspace.container(for: "pane-3"))
        XCTAssertEqual(card.header.subtitle, "Session 2 · terminal 1 of 2")

        // An engine naming the *first* session — no user action on this card at
        // all — takes `Session 1` and pushes this one up into it.
        workspace.updateDescriptor(for: "pane-1") { $0.groupLabel = "Token rotation" }

        XCTAssertEqual(
            card.header.subtitle,
            "Session 1 · terminal 1 of 2",
            "the card re-derives the name rather than keeping the number it was born with"
        )
    }

    /// The card shows the focused pane, whichever command moved focus. ⌘1…⌘8 and
    /// ⌥arrows leave the zoom alone by themselves, which used to leave the caret
    /// behind the blur — an approval typed in answer to a notification going into
    /// a terminal the user cannot see. `revealPane` already obeyed this on its own
    /// path; these are the other two doors.
    func testAFocusCommandCarriesTheCardWithIt() throws {
        let (workspace, window, _) = makeSplitHostedWorkspace(panes: 4)
        defer { window.close() }
        workspace.focusPane("pane-1")
        XCTAssertTrue(workspace.toggleZoom("pane-1"))

        // ⌘3 — fill order is 1, 3, 2, 4, so the third is pane-2.
        XCTAssertTrue(workspace.focusPane(at: 3))
        XCTAssertEqual(workspace.focusedPaneID, "pane-2")
        XCTAssertEqual(workspace.zoomedPaneID, "pane-2", "the card follows ⌘3")

        // ⌥← — back across the grid to pane-1.
        XCTAssertTrue(workspace.focusNeighbor(.left))
        XCTAssertEqual(workspace.focusedPaneID, "pane-1")
        XCTAssertEqual(workspace.zoomedPaneID, "pane-1", "and follows ⌥arrow")

        // The pane the user is typing into is the one on screen, and every hand-over
        // put the pane it replaced back in the grid.
        let card = try XCTUnwrap(workspace.container(for: "pane-1"))
        XCTAssertFalse(card.superview === workspace, "the focused pane is the one in the overlay")
        for id in workspace.paneIDs where id != "pane-1" {
            XCTAssertTrue(
                workspace.container(for: id)?.superview === workspace,
                "\(id) is back in the grid"
            )
        }
    }

    /// Closing a pane re-homes focus, which is a focus move by another door — the
    /// palette's "close pane" arm focuses the pane it is about to close, so focus
    /// lands on a neighbour afterwards and the card has to follow that too.
    func testClosingAPaneCarriesTheCardToWhereFocusLands() throws {
        let (workspace, window, _) = makeSplitHostedWorkspace(panes: 4)
        defer { window.close() }
        workspace.focusPane("pane-1")
        XCTAssertTrue(workspace.toggleZoom("pane-1"))

        // Exactly what the palette does: focus it, then close it.
        workspace.focusPane("pane-4")
        XCTAssertTrue(workspace.closePane("pane-4"))

        XCTAssertEqual(workspace.focusedPaneID, "pane-2", "focus falls to its fill-order neighbour")
        XCTAssertEqual(
            workspace.zoomedPaneID,
            "pane-2",
            "and the card shows whoever has focus now, not the pane it started on"
        )
    }

    /// ⌘↩ on one pane, ⌘2 to another, ⌘↩ again. Focus commands deliberately leave
    /// the zoom alone, so the second ⌘↩ hands the overlay straight from one card
    /// to the next with no exit in between — and the pane being replaced has to
    /// come back to the grid on that hand-over. Left in the overlay it is a pane
    /// nobody owns: the grid feeds it cell rects in the host's coordinates, and
    /// the next teardown carries it out of the window with nothing to re-add it,
    /// which loses a live terminal and its session with no way back.
    func testHandingTheCardStraightToAnotherPaneReturnsTheFirstToTheGrid() throws {
        let (workspace, window, _) = makeSplitHostedWorkspace(panes: 2)
        defer { window.close() }
        let first = try XCTUnwrap(workspace.container(for: "pane-1"))
        let second = try XCTUnwrap(workspace.container(for: "pane-2"))

        XCTAssertTrue(workspace.toggleZoom("pane-1"))
        XCTAssertFalse(first.superview === workspace, "pane-1 is the card")

        // ⌘2, which now carries the card with it: the hand-over happens with no
        // exit in between, which is the sequence that used to orphan pane-1.
        XCTAssertTrue(workspace.focusPane(at: 2))

        XCTAssertEqual(workspace.zoomedPaneID, "pane-2")
        XCTAssertFalse(second.superview === workspace, "pane-2 is the card now")
        XCTAssertTrue(first.superview === workspace, "and pane-1 is back in the grid")
        XCTAssertTrue(workspace.gridBounds.contains(first.frame), "at a cell, not a host rect")
        XCTAssertEqual(first.layer?.animationKeys() ?? [], [], "with nothing animating it")
        XCTAssertEqual(first.layer?.cornerRadius, PaneContainerView.cornerRadius)

        // And it is still there after the teardown that used to take it away.
        workspace.setZoomed(nil)
        let deadline = Date().addingTimeInterval(2)
        while second.superview !== workspace, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(first.superview === workspace, "still in the grid once the overlay goes")
        XCTAssertNotNil(first.window, "and still in the window")
        XCTAssertTrue(second.superview === workspace)
    }

    /// Two ⌘↩ inside one transition's 0.32s. Both directions' animation groups end
    /// at the same completion, so without a token the *entry* group's completion
    /// arrives partway through the exit that followed it and finishes that exit
    /// early — the card snaps home instead of shrinking and the overlay is pulled
    /// out from under the fade. Timed rather than inspected: the exit either ran
    /// its own duration or it was cut short, and only the elapsed time tells them
    /// apart. Slow machines can only make this wait longer, never shorter.
    func testAnEntrysCompletionCannotFinishTheExitThatFollowedIt() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("under Reduce Motion both directions land instantly")
        }
        let (workspace, window, _) = makeSplitHostedWorkspace(panes: 2)
        defer { window.close() }
        let card = try XCTUnwrap(workspace.container(for: "pane-2"))

        let entered = Date()
        XCTAssertTrue(workspace.toggleZoom("pane-2"))
        // Halfway into the entry, so its completion is still to come when the exit
        // starts and lands mid-shrink if it is allowed to act. Timed from the
        // entry rather than from "now" so the wait cannot drift past the entry's
        // own completion — a wait that overshot would mean the entry's completion
        // had already been spent harmlessly, and the assertion below would hold
        // for a reason that has nothing to do with the token.
        RunLoop.current.run(
            until: entered.addingTimeInterval(PaneWorkspaceView.zoomTransitionDuration / 2)
        )
        XCTAssertLessThan(
            Date().timeIntervalSince(entered),
            PaneWorkspaceView.zoomTransitionDuration,
            "the entry's completion has to still be pending, or this proves nothing"
        )

        let exitStarted = Date()
        workspace.setZoomed(nil)
        let deadline = exitStarted.addingTimeInterval(3)
        while card.superview !== workspace, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(card.superview === workspace, "the card came home")
        XCTAssertGreaterThan(
            Date().timeIntervalSince(exitStarted),
            PaneWorkspaceView.zoomTransitionDuration * 0.75,
            "and took its own transition to do it rather than the entry's leftover"
        )
    }

    /// Opening a terminal in the 0.32s a card is still shrinking (⌘↩ then ⌘T)
    /// has to land that card in its cell at once. Both halves matter: the grid
    /// must not hand a cell to a pane that still lives in the overlay — its frame
    /// is in the host's coordinates, so it would slide the width of the sidebar —
    /// and the in-flight animation must be cancelled, or it replays that move
    /// after the reparent and the pane visibly snaps back.
    func testOpeningATerminalMidShrinkLandsTheCardAtOnce() throws {
        let (workspace, window, _) = makeSplitHostedWorkspace(panes: 2)
        defer { window.close() }

        XCTAssertTrue(workspace.toggleZoom("pane-2"))
        let card = try XCTUnwrap(workspace.container(for: "pane-2"))
        XCTAssertFalse(card.superview === workspace, "the card is in the overlay")

        workspace.setZoomed(nil)
        // No run loop turn: the shrink is in flight and its completion has not
        // fired, which is exactly the window ⌘T lands in.
        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-3")))

        XCTAssertNil(workspace.zoomedPaneID)
        XCTAssertTrue(card.superview === workspace, "the card is back in the grid")
        XCTAssertEqual(card.layer?.animationKeys() ?? [], [], "with nothing left animating it")
        XCTAssertTrue(workspace.gridBounds.contains(card.frame), "at a grid cell, not a host rect")
        XCTAssertEqual(card.layer?.cornerRadius, PaneContainerView.cornerRadius)
        // Leaving focus resizes the terminal: the card is cell-sized now, and a
        // PTY still told it has the card's ~1080 columns tears its output.
        XCTAssertTrue(
            workspace.resizeCoalescer.pending.contains("pane-2"),
            "and its PTY told about the size it actually has"
        )
    }

    /// The card *scales* into focus and back out: the pane, its header and its
    /// terminal text all grow together from the cell it left. Animating the
    /// container's `bounds` instead — which this used to do — moves nothing
    /// inside it, because its subviews are laid out at the final size the
    /// instant the frame lands: a full-size pane revealed through a widening
    /// window, with the text sitting still, rather than a zoom.
    func testEnteringFocusScalesTheCardUpFromItsCell() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("under Reduce Motion the card lands instantly")
        }
        let (workspace, window, _) = makeSplitHostedWorkspace(panes: 2)
        defer { window.close() }
        let card = try XCTUnwrap(workspace.container(for: "pane-2"))
        let cell = card.frame

        XCTAssertTrue(workspace.toggleZoom("pane-2"))
        let layer = try XCTUnwrap(card.layer)
        XCTAssertNil(layer.animation(forKey: "bounds"), "not a resize of the container alone")
        let zoom = try XCTUnwrap(layer.animation(forKey: "transform") as? CABasicAnimation)
        let from = try XCTUnwrap((zoom.fromValue as? NSValue)?.caTransform3DValue)
        XCTAssertEqual(from.m11, cell.width / card.frame.width, accuracy: 0.02, "from the cell's size")
        XCTAssertEqual(from.m22, cell.height / card.frame.height, accuracy: 0.02)
        XCTAssertEqual(zoom.duration, PaneWorkspaceView.zoomTransitionDuration)
        XCTAssertNotNil(layer.animation(forKey: "position"), "travelling as it grows")
    }

    /// `backdrop-filter:blur(16px) saturate(70%)` over `rgba(6,6,8,.62)`, as the
    /// platform's within-window blur. The `CIGaussianBlur` in
    /// `layer.backgroundFilters` this replaces passed a test just like this one
    /// and blurred nothing on screen: `backgroundFilters` are not composited for
    /// a layer-backed view in an ordinary window, so the assertions could only
    /// ever confirm the filter was *installed*. Hence the blending mode below —
    /// it is the property that decides whether anything is blurred at all.
    func testTheBackdropBlursTheAppBehindItUnderTheDesignsTint() throws {
        let backdrop = PaneZoomBackdropView()
        backdrop.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        XCTAssertEqual(backdrop.blendingMode, .withinWindow, "the app behind it, not the desktop")
        XCTAssertEqual(backdrop.state, .active, "and blurred whether or not the window is key")

        backdrop.setShown(true, duration: 0)
        backdrop.layoutSubtreeIfNeeded()
        let tint = try XCTUnwrap(backdrop.subviews.first)
        XCTAssertEqual(tint.frame, backdrop.bounds, "the tint covers the blur")
        XCTAssertEqual(
            tint.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.alphaComponent },
            0.62,
            "at the design's rgba(6,6,8,.62)"
        )
        XCTAssertEqual(backdrop.alphaValue, 1)
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

    /// The assumption above, actually exercised: a real click in the terminal
    /// body — not `adoptFocus` called by hand — activates that pane.
    func testMouseDownInTheTerminalBodyActivatesThePane() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 2)
        defer { window.close() }
        workspace.focusPane("pane-1")
        let target = try XCTUnwrap(workspace.container(for: "pane-2"))
        workspace.layoutSubtreeIfNeeded()

        let middle = target.surface.terminalView.convert(
            CGPoint(x: target.surface.bounds.midX, y: target.surface.bounds.midY),
            from: target.surface
        )
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: target.surface.terminalView.convert(middle, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        target.surface.terminalView.mouseDown(with: click)

        XCTAssertEqual(workspace.focusedPaneID, "pane-2")
    }

    // MARK: - Focus-mode header

    /// The bar has to *change* when a pane is focused, or the control that got
    /// you in still looks like the control that gets you in. The design's
    /// focused card carries a taller header, a bigger name, the
    /// `session · terminal N of M` subtitle and one labelled way out — and none
    /// of it may survive the trip back into the grid.
    func testTheFocusHeaderWearsTheDesignsTallerBarAndItsOwnControls() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 4)
        defer { window.close() }
        for id in workspace.paneIDs {
            workspace.updateDescriptor(for: id) { $0.groupLabel = "session restore" }
        }
        let card = try XCTUnwrap(workspace.container(for: "pane-2"))
        XCTAssertEqual(card.header.currentHeight, 30, "the grid bar is the design's 30px")
        XCTAssertNil(card.header.subtitle, "the grid header has no subtitle to show")
        XCTAssertEqual(controls(in: card.header), ["Zoom this terminal", "Close this terminal"])

        XCTAssertTrue(workspace.toggleZoom("pane-2"))
        card.layoutSubtreeIfNeeded()

        // 34, not "the grid's height plus a bit": bumping the grid bar must not
        // quietly redefine what the focused card's own `height:34px` means.
        XCTAssertEqual(card.header.currentHeight, 34, "the focused card's bar is 34px")
        XCTAssertEqual(card.header.frame.height, 34, "and the pane gives it that")
        XCTAssertEqual(
            card.surface.frame.minY,
            PaneContainerView.borderWidth + 34,
            "with the terminal starting under the taller bar rather than behind it"
        )
        // pane-2 sits in the third cell — fill order is 1, 3, 2, 4.
        XCTAssertEqual(card.header.subtitle, "session restore · terminal 3 of 4")
        XCTAssertEqual(
            controls(in: card.header),
            [Self.exitFocusText],
            "one labelled way out, and no close button beside it"
        )

        // Out the way the design says you get out — by pressing the pill, not by
        // calling the toggle it happens to be wired to.
        let pill = try XCTUnwrap(button(labelled: Self.exitFocusText, in: card.header))
        click(pill, in: window)
        XCTAssertNil(workspace.zoomedPaneID, "the pill is the way out, not a picture of one")

        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.header.currentHeight, 30)
        XCTAssertEqual(card.header.frame.height, 30)
        XCTAssertNil(card.header.subtitle)
        XCTAssertEqual(controls(in: card.header), ["Zoom this terminal", "Close this terminal"])
    }

    /// Every number the focused card's header is built from, pinned to the
    /// design's own values (line 1070 onward) rather than to the grid's plus a
    /// delta — the grid header is free to move without dragging the card's with
    /// it, and if it ever does move, this is the test that says so.
    func testTheFocusHeaderIsBuiltFromTheDesignsOwnMetrics() throws {
        let header = PaneHeaderView(title: "token rotation")
        header.isZoomAvailable = true
        header.subtitleProvider = { "session restore · terminal 1 of 4" }

        XCTAssertEqual(PaneHeaderView.height, 30, "grid `height:30px`")
        XCTAssertEqual(PaneHeaderView.focusHeight, 34, "focused card `height:34px`")

        // Focus first, because the subtitle only has text to be found by while
        // the bar is wearing it: `padding:0 7px 0 12px`, `gap:9px`,
        // `600 15.5px` / `#f0f0f4` title, `400 14px` / `#5c5c66` subtitle, and
        // the pill in place of both icons — `padding:5px 9px` around a 16pt
        // glyph is 26pt tall.
        header.isZoomed = true
        layOut(header, width: 1080)
        let fields = header.subviews.compactMap { $0 as? NSTextField }
        let subtitle = try XCTUnwrap(fields.first { $0.stringValue == "session restore · terminal 1 of 4" })
        let title = try XCTUnwrap(fields.first { $0 !== subtitle })
        let mark = try XCTUnwrap(header.subviews.compactMap { $0 as? PaneStatusMarkView }.first)
        let pill = try XCTUnwrap(button(labelled: Self.exitFocusText, in: header))
        XCTAssertEqual(mark.frame.size, CGSize(width: 15, height: 15), "the 15px status mark, both modes")
        XCTAssertEqual(mark.frame.minX, 12)
        XCTAssertEqual(title.frame.minX - mark.frame.maxX, 9, "focus `gap:9px`")
        XCTAssertEqual(subtitle.frame.minX - title.frame.maxX, 9)
        XCTAssertEqual(pill.frame.maxX, 1080 - 7, "focus `padding-right:7px`")
        XCTAssertEqual(pill.frame.height, 26, "5pt of padding above and below a 16pt glyph")
        XCTAssertEqual(title.font?.pointSize, 15.5, "focus title `15.5px`")
        XCTAssertEqual(title.font, ShellFont.ui(15.5, .semibold), "at `600`, through this file's own font helper")
        XCTAssertEqual(
            title.textColor,
            NSColor(srgbRed: 240 / 255, green: 240 / 255, blue: 244 / 255, alpha: 1),
            "`#f0f0f4`"
        )
        XCTAssertEqual(subtitle.font?.pointSize, 14, "subtitle `14px`")
        XCTAssertEqual(subtitle.font, ShellFont.ui(14), "at `400`")
        XCTAssertEqual(
            subtitle.textColor,
            NSColor(srgbRed: 92 / 255, green: 92 / 255, blue: 102 / 255, alpha: 1),
            "`#5c5c66`"
        )

        // And back to the grid's own numbers: `padding:0 6px 0 10px`, `gap:8px`,
        // `500 14.5px`, two 20pt icon squares, no subtitle.
        header.isZoomed = false
        layOut(header, width: 620)
        let zoom = try XCTUnwrap(button(labelled: "Zoom this terminal", in: header))
        let close = try XCTUnwrap(button(labelled: "Close this terminal", in: header))
        XCTAssertEqual(mark.frame.minX, 10)
        XCTAssertEqual(title.frame.minX - mark.frame.maxX, 8, "grid `gap:8px`")
        XCTAssertEqual(close.frame.maxX, 620 - 6, "grid `padding-right:6px`")
        XCTAssertEqual(zoom.frame.size, CGSize(width: 20, height: 20))
        XCTAssertEqual(close.frame.size, CGSize(width: 20, height: 20))
        XCTAssertEqual(title.font, ShellFont.ui(14.5, .medium), "grid title `500 14.5px`")
        XCTAssertTrue(subtitle.isHidden, "and nothing left of the subtitle")
    }

    /// The exit control is not the grid's icon with a tooltip on it: it is the
    /// design's bordered pill, labelled `Exit focus · esc` — the label is the
    /// only place the escape hatch is spelled out, in the app *and* to Voice
    /// Control, which resolves a command by what a control says.
    func testTheExitControlIsALabelledPillThatSaysHowToLeave() throws {
        let header = PaneHeaderView(title: "token rotation")
        header.isZoomAvailable = true
        header.isZoomed = true
        let pill = try XCTUnwrap(button(labelled: Self.exitFocusText, in: header))
        let zoom = try XCTUnwrap(button(labelled: "Zoom this terminal", in: header))

        XCTAssertEqual(pill.label, "Exit focus · esc", "the words the button draws")
        XCTAssertEqual(pill.accessibilityLabel(), pill.label, "and the name it answers to")
        XCTAssertNil(zoom.label, "while the grid's control stays a bare icon")
        XCTAssertEqual(
            zoom.intrinsicContentSize,
            NSSize(width: PaneHeaderButton.iconSize, height: PaneHeaderButton.iconSize)
        )
        XCTAssertGreaterThan(
            pill.intrinsicContentSize.width,
            zoom.intrinsicContentSize.width * 3,
            "a glyph, a gap and a label, not a 20pt square"
        )
        XCTAssertEqual(pill.intrinsicContentSize.height, 26)
        XCTAssertLessThan(
            pill.intrinsicContentSize.height,
            PaneHeaderView.focusHeight,
            "and it fits inside the bar it sits in"
        )

        // Pressed by assistive technology, not only by a mouse: an `NSView` with
        // a button role does nothing on press unless it says otherwise.
        var presses = 0
        pill.onClick = { presses += 1 }
        XCTAssertTrue(pill.accessibilityPerformPress())
        XCTAssertEqual(presses, 1)
    }

    func testPaneOrdinalCountsAPanesPlaceAmongItsOwnSessionsTerminals() {
        let workspace = makeWorkspace(panes: 4) // fill order: 1, 3, 2, 4
        XCTAssertEqual(ordinal(workspace, "pane-1"), [1, 4])
        XCTAssertEqual(ordinal(workspace, "pane-3"), [2, 4])
        XCTAssertEqual(ordinal(workspace, "pane-2"), [3, 4])
        XCTAssertEqual(ordinal(workspace, "pane-4"), [4, 4])

        XCTAssertTrue(workspace.closePane("pane-3"))
        XCTAssertEqual(ordinal(workspace, "pane-2"), [2, 3], "a sibling closing renumbers the rest")

        var elsewhere = makeDescriptor("pane-5")
        elsewhere.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(elsewhere))
        XCTAssertEqual(ordinal(workspace, "pane-5"), [1, 1], "counted within its own session")
        XCTAssertNil(
            ordinal(workspace, "pane-2"),
            "and a pane whose session is off screen has no place in what you are looking at"
        )
    }

    /// The count in the subtitle is resolved every time the panes move, not
    /// stored when focus starts: closing a sibling while a card is up must not
    /// leave it claiming "terminal 3 of 4" with three terminals left.
    func testTheFocusSubtitleFollowsASiblingClosingUnderIt() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 4)
        defer { window.close() }
        let card = try XCTUnwrap(workspace.container(for: "pane-2"))

        XCTAssertTrue(workspace.toggleZoom("pane-2"))
        XCTAssertEqual(
            card.header.subtitle,
            "Session 1 · terminal 3 of 4",
            "an unnamed session still gets both halves — the name the sidebar derives for it"
        )

        XCTAssertTrue(workspace.closePane("pane-3"))
        XCTAssertEqual(workspace.zoomedPaneID, "pane-2", "two siblings left, so the card stays up")
        XCTAssertEqual(card.header.subtitle, "Session 1 · terminal 2 of 3")

        workspace.updateDescriptor(for: "pane-2") { $0.groupLabel = "session restore" }
        XCTAssertEqual(
            card.header.subtitle,
            "session restore · terminal 2 of 3",
            "and a rename reaches the bar you are looking at"
        )
    }

    /// A narrow window has to give up the subtitle before it gives up the
    /// terminal's own name — the subtitle describes where the pane sits, which
    /// is worth less than what it is.
    func testANarrowFocusHeaderDropsTheSubtitleRatherThanTheName() throws {
        let header = PaneHeaderView(title: "token rotation")
        header.subtitleProvider = { "session restore · terminal 1 of 4" }
        header.isZoomed = true
        let fields = header.subviews.compactMap { $0 as? NSTextField }
        let subtitle = try XCTUnwrap(fields.first { $0.stringValue == header.subtitle })
        let title = try XCTUnwrap(fields.first { $0 !== subtitle })

        layOut(header, width: 900)
        XCTAssertEqual(
            title.frame.width,
            ceil(title.fittingSize.width),
            "with room, the name takes exactly the width it draws in — never less, or it ellipsises"
        )
        XCTAssertEqual(subtitle.frame.width, ceil(subtitle.fittingSize.width))
        XCTAssertEqual(subtitle.frame.minX, title.frame.maxX + 9, "directly after the name, at the design's 9pt gap")

        layOut(header, width: 300)
        XCTAssertEqual(subtitle.frame, .zero, "dropped whole, the way the badges are")
        XCTAssertGreaterThanOrEqual(title.frame.width, 40, "and the name keeps its share")
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
        // `NSWindow` defaults to releasing itself when closed, and every helper
        // here closes its window in a `defer` while ARC still holds this
        // reference — an over-release that frees the window early. AppKit and
        // CoreAnimation keep window-scoped registrations (an
        // `_NSWindowTransformAnimation` per animated view among them), so a freed
        // window leaves dangling pointers that the next autorelease-pool drain
        // inside a CA commit dereferences: SIGSEGV in that class's `dealloc`, in
        // whichever *later* test happens to turn the run loop. The app itself
        // never had this — `NSWindowController` owns its window and clears the
        // flag — and every other window in the app sets it explicitly.
        window.isReleasedWhenClosed = false
        window.contentView = workspace
        // Exactly the controller's wiring, so a click routes to focus here too.
        window.onFirstResponderChange = { [weak workspace] in workspace?.adoptFocus(from: $0) }
        window.makeKeyAndOrderFront(nil)
        return (workspace, window)
    }

    /// A window shaped like the real one: a plain content view holding the
    /// sidebar's 238pt column beside the pane grid, which is what
    /// `WorkspaceWindowController` builds with an `NSSplitViewController`. The
    /// overlay's whole point is that it covers this content view rather than the
    /// grid, and `makeAttachedWorkspace` cannot show that — there the workspace
    /// *is* the content view.
    private func makeSplitHostedWorkspace(
        panes: Int
    ) -> (PaneWorkspaceView, NSWindow, NSView) {
        let workspace = makeWorkspace(panes: panes)
        let window = WorkspaceWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false // see `makeAttachedWorkspace`
        let content = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 800))
        let sidebar = NSView(frame: CGRect(x: 0, y: 0, width: 238, height: 800))
        workspace.frame = CGRect(x: 238, y: 0, width: 1200 - 238, height: 800)
        content.addSubview(sidebar)
        content.addSubview(workspace)
        window.contentView = content
        window.onFirstResponderChange = { [weak workspace] in workspace?.adoptFocus(from: $0) }
        window.makeKeyAndOrderFront(nil)
        return (workspace, window, sidebar)
    }

    /// AppKit's own rule for finding an action's target, in the two steps
    /// `NSApplication.targetForAction(_:to:from:)` takes: walk the responder
    /// chain, and ask anything that does not respond itself for a supplemental
    /// target.
    private func target(for action: Selector, from start: NSResponder?) -> AnyObject? {
        var responder = start
        while let current = responder {
            if current.responds(to: action) { return current }
            if let supplemental = current.supplementalTarget(forAction: action, sender: nil)
                as AnyObject?, supplemental.responds(to: action) {
                return supplemental
            }
            responder = current.nextResponder
        }
        return nil
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

    /// What the exit pill says, which is also the name it answers to and how
    /// these tests tell the header's three controls apart without the header
    /// exposing them.
    private static let exitFocusText = "Exit focus · esc"

    /// Which trailing controls the bar is currently offering, named by what they
    /// say they do, in the order the header lays them out.
    private func controls(in header: PaneHeaderView) -> [String] {
        header.subviews
            .compactMap { $0 as? PaneHeaderButton }
            .filter { !$0.isHidden }
            .compactMap { $0.accessibilityLabel() }
    }

    private func button(labelled label: String, in header: PaneHeaderView) -> PaneHeaderButton? {
        header.subviews
            .compactMap { $0 as? PaneHeaderButton }
            .first { $0.accessibilityLabel() == label }
    }

    /// A header laid out at a given width, on its own. `needsLayout` by hand
    /// because nothing owns this one: in the app its pane sets the frame and
    /// AppKit runs the pass.
    private func layOut(_ header: PaneHeaderView, width: CGFloat) {
        header.frame = CGRect(x: 0, y: 0, width: width, height: header.currentHeight)
        header.needsLayout = true
        header.layoutSubtreeIfNeeded()
    }

    /// A real click on a header control: the mouse path the user takes, rather
    /// than reaching for the closure behind it.
    private func click(_ button: PaneHeaderButton, in window: NSWindow) {
        let centre = button.convert(
            CGPoint(x: button.bounds.midX, y: button.bounds.midY),
            to: nil
        )
        guard
            let event = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: centre,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        else { return XCTFail("could not synthesize a click") }
        button.mouseUp(with: event)
    }

    /// `paneOrdinal` as a comparable pair — a tuple is not `Equatable`.
    private func ordinal(_ workspace: PaneWorkspaceView, _ sessionID: String) -> [Int]? {
        workspace.paneOrdinal(of: sessionID).map { [$0.index, $0.total] }
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
