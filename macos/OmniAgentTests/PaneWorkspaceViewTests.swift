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

    func testAddingPanesWalksTheApprovedLadderAndCapsAtTwelve() {
        let workspace = makeWorkspace(panes: 1)
        let expected: [(cols: Int, rows: Int)] = [
            (1, 1), (2, 1), (2, 2), (2, 2), (3, 2), (3, 2), (4, 2), (4, 2),
            (4, 3), (4, 3), (4, 3), (4, 3),
        ]
        for count in 1...PaneGrid.maxPanes {
            if count > 1 { XCTAssertTrue(workspace.addPane(makeDescriptor("pane-\(count)"))) }
            XCTAssertEqual(workspace.paneIDs.count, count)
            XCTAssertEqual(workspace.grid?.cols, expected[count - 1].cols, "\(count) panes")
            XCTAssertEqual(workspace.grid?.rows, expected[count - 1].rows, "\(count) panes")
        }
        XCTAssertFalse(
            workspace.addPane(makeDescriptor("pane-13")),
            "the cap refuses a thirteenth pane"
        )
        XCTAssertEqual(workspace.paneIDs.count, PaneGrid.maxPanes)
    }

    /// The ninth pane opens the third row at column 0 and the three cells
    /// beside it stay empty, each one an add-a-pane placeholder, until panes
    /// 10-12 replace them left to right.
    func testTheNinthPaneOpensAThirdRowWithThreeEmptyCellsBesideIt() {
        let workspace = makeWorkspace(panes: 8)
        XCTAssertTrue(workspace.holePlaceholders.isEmpty, "the 4x2 rung is full")

        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-9")))
        XCTAssertEqual(workspace.grid?.rows, 3)
        XCTAssertEqual(workspace.grid?.cols, 4)
        XCTAssertEqual(workspace.holePlaceholders.count, 3, "three empty cells beside it")

        let ninth = try? XCTUnwrap(workspace.container(for: "pane-9"))
        XCTAssertEqual(ninth?.frame.minX, PaneWorkspaceView.gridInset, "first column")
        XCTAssertEqual(ninth?.frame.maxY, workspace.gridBounds.maxY, "bottom row")
        for hole in workspace.holePlaceholders {
            XCTAssertEqual(hole.frame.maxY, workspace.gridBounds.maxY, "all on the third row")
            XCTAssertGreaterThan(hole.frame.minX, ninth?.frame.minX ?? 0, "and all to its right")
        }

        for index in 10...PaneGrid.maxPanes {
            XCTAssertTrue(workspace.addPane(makeDescriptor("pane-\(index)")))
            XCTAssertEqual(
                workspace.holePlaceholders.count,
                PaneGrid.maxPanes - index,
                "\(index) panes: each new one takes an empty cell"
            )
        }
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

    /// The hole's dock offers one button per pane kind. Each acts for itself,
    /// and the space around them does nothing.
    func testTheHoleTileOffersADockOfPaneKinds() {
        let workspace = makeWorkspace(panes: 3)
        var terminals = 0
        var browsers = 0
        workspace.onRequestNewPane = { terminals += 1 }
        workspace.onRequestNewBrowserPane = { browsers += 1 }
        var editors = 0
        workspace.onRequestNewEditorPane = { editors += 1 }
        let hole = workspace.holePlaceholders[0]

        XCTAssertEqual(hole.itemRects.count, 3, "Terminal, Browser, Editor")
        let ys = Set(hole.itemRects.map(\.minY))
        XCTAssertEqual(ys.count, 1, "side by side, like the Dock")
        XCTAssertLessThan(hole.itemRects[0].maxX, hole.itemRects[1].minX)
        XCTAssertLessThan(hole.itemRects[1].maxX, hole.itemRects[2].minX)
        XCTAssertEqual(
            (hole.itemRects[0].minX + hole.itemRects[2].maxX) / 2,
            hole.bounds.midX,
            accuracy: 0.5,
            "centred in the empty cell"
        )

        hole.dispatch(at: NSPoint(x: hole.itemRects[1].midX, y: hole.itemRects[1].midY))
        XCTAssertEqual(browsers, 1, "the browser button opens a browser")
        XCTAssertEqual(terminals, 0)

        hole.dispatch(at: NSPoint(x: hole.itemRects[0].midX, y: hole.itemRects[0].midY))
        XCTAssertEqual(terminals, 1, "the terminal button opens a terminal")

        hole.dispatch(at: NSPoint(x: hole.itemRects[2].midX, y: hole.itemRects[2].midY))
        XCTAssertEqual(editors, 1, "the Editor button opens an editor pane")
        XCTAssertEqual(terminals, 1)
        XCTAssertEqual(browsers, 1)

        hole.dispatch(at: NSPoint(x: hole.bounds.minX + 2, y: hole.bounds.minY + 2))
        XCTAssertEqual(terminals, 1, "the space around the buttons is not a button")
        XCTAssertEqual(browsers, 1)
        XCTAssertEqual(editors, 1)

        XCTAssertTrue(hole.accessibilityPerformPress())
        XCTAssertEqual(terminals, 2, "the assistive press stays the single Add terminal action")
        XCTAssertEqual(hole.accessibilityLabel(), "Add terminal")
    }

    /// The seam pays off: a browser descriptor builds a `BrowserPaneView`
    /// behind the same container chrome, reachable through its own accessor
    /// and named by its own noun.
    func testABrowserPaneGetsKindAwareChromeAndItsOwnAccessor() {
        let workspace = makeWorkspace(panes: 2)
        var descriptor = makeDescriptor("web-1")
        descriptor.kind = .browser
        XCTAssertTrue(workspace.addPane(descriptor))

        XCTAssertNotNil(workspace.browserPane(for: "web-1"))
        XCTAssertNil(workspace.terminalSurface(for: "web-1"), "a browser is not a terminal")
        // By fill-order position, since the 2→3 reshape decides where the
        // new pane lands.
        let browserIndex = workspace.paneIDs.firstIndex(of: "web-1")! + 1
        XCTAssertEqual(
            workspace.container(for: "web-1")!.accessibilityLabel(),
            "Browser pane \(browserIndex) of 3"
        )
        let terminalIndex = workspace.paneIDs.firstIndex(of: "pane-1")! + 1
        XCTAssertEqual(
            workspace.container(for: "pane-1")!.accessibilityLabel(),
            "Terminal pane \(terminalIndex) of 3",
            "terminals keep their own noun"
        )
    }

    /// `.editor` gets the same kind-aware placeholder name as `.browser`
    /// (its own `Editor N` ladder), recognised as generated the same way.
    func testEditorPlaceholderName() {
        let pane = PaneDescriptor(sessionID: "e", group: "g", kind: .editor)
        XCTAssertEqual(SessionOutline.paneLabel(pane), "Editor 1")
        XCTAssertTrue(SessionOutline.isGeneratedPaneName("Editor 3"))
    }

    /// Only a terminal's number is disambiguated by engine — an editor
    /// numbers its own ladder regardless of what `engine` its descriptor
    /// happens to carry, exactly like `.browser`.
    func testEditorNumberingIgnoresEngine() {
        var first = PaneDescriptor(sessionID: "e1", group: "g", kind: .editor)
        first.autoNumber = 1
        let next = SessionOutline.nextPaneNumber([first], group: "g", engine: .shell, kind: .editor)
        XCTAssertEqual(next, 2)
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
        let firstTerminal = ObjectIdentifier(first.terminalSurface.terminalView)

        XCTAssertTrue(workspace.swapPanes("pane-1", "pane-4"))

        XCTAssertEqual(first.frame, lastFrame)
        XCTAssertEqual(last.frame, firstFrame)
        XCTAssertEqual(ObjectIdentifier(workspace.container(for: "pane-1")!.terminalSurface.terminalView), firstTerminal)
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

    /// Task 14's edge drop: the new pane lands *adjacent* in grid order rather
    /// than appended, and the ladder re-lays out around it.
    /// Read against the grid's *own* fill order rather than a literal list:
    /// `synced`'s 2->3 rule puts the third pane lower-left, so three panes are
    /// not in the order they were added — and the promise here is only that
    /// the newcomer lands beside its anchor and nothing else moves relative to
    /// anything else.
    func testInsertingAPaneAdjacentInGridOrder() {
        let workspace = makeWorkspace(panes: 3)
        var expected = workspace.paneIDs
        XCTAssertEqual(expected.count, 3)

        XCTAssertTrue(workspace.addPane(makeDescriptor("x"), inserting: .after, of: expected[0]))
        expected.insert("x", at: 1)
        XCTAssertEqual(workspace.paneIDs, expected)

        XCTAssertTrue(workspace.addPane(makeDescriptor("y"), inserting: .before, of: expected[0]))
        expected.insert("y", at: 0)
        XCTAssertEqual(workspace.paneIDs, expected)
    }

    /// Every refusal the plain `addPane` makes, the inserting one makes too —
    /// the cap is `PaneGrid.maxPanes` and an id already on screen is never
    /// added twice — plus its own: a pane in another session has no cell in
    /// this grid to sit beside.
    func testInsertingRefusesAnotherSessionAFullGridAndADuplicate() {
        let workspace = makeWorkspace(panes: 2)
        var other = makeDescriptor("other-session")
        other.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(other))

        XCTAssertFalse(
            workspace.addPane(makeDescriptor("x"), inserting: .after, of: "other-session"),
            "the anchor is in a different session's grid"
        )
        XCTAssertFalse(
            workspace.addPane(makeDescriptor("pane-1"), inserting: .after, of: "pane-1"),
            "an id already on screen is never added twice"
        )

        while workspace.paneCount(inGroup: "sess-grp-1") < PaneGrid.maxPanes {
            XCTAssertTrue(workspace.addPane(makeDescriptor("filler-\(workspace.paneIDs.count)")))
        }
        XCTAssertFalse(
            workspace.addPane(makeDescriptor("z"), inserting: .before, of: "pane-1"),
            "the cap refuses an insert exactly as it refuses an append"
        )
    }

    /// A drop glides both panes into their new cells instead of cutting. Read
    /// off the layers rather than off a rect: the frames land immediately either
    /// way, and the animation is the whole difference.
    func testADropGlidesBothPanesIntoTheirNewCells() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("under Reduce Motion a swap lands instantly")
        }
        let (workspace, window) = makeAttachedWorkspace(panes: 2)
        defer { window.close() }
        workspace.layoutSubtreeIfNeeded()

        XCTAssertTrue(workspace.performPaneDrop(from: "pane-1", onto: "pane-2"))

        for id in ["pane-1", "pane-2"] {
            let layer = try XCTUnwrap(workspace.container(for: id)?.layer)
            XCTAssertNotNil(layer.animation(forKey: "position"), "\(id) cut to its new cell")
        }
    }

    /// And it glides over the grid, never under it: both movers are the topmost
    /// panes for the flight, the dragged one topmost of all. Four panes so there
    /// are bystanders to be hidden behind.
    func testADropRaisesBothMoversAboveEveryOtherPane() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 4)
        defer { window.close() }
        workspace.layoutSubtreeIfNeeded()

        XCTAssertTrue(workspace.performPaneDrop(from: "pane-1", onto: "pane-4"))

        let panes = workspace.subviews.compactMap { ($0 as? PaneContainerView)?.paneID }
        XCTAssertEqual(panes.suffix(2), ["pane-4", "pane-1"], "the movers must be the top two")
    }

    /// Each mover casts a shadow for the flight and only for the flight: one
    /// layer directly beneath its own — the pane's mask would clip a shadow of
    /// its own away — gone again once it has landed.
    func testEachGlidingPaneCastsAShadowThatLeavesWhenItLands() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("under Reduce Motion a swap lands instantly, with nothing to shade")
        }
        let (workspace, window) = makeAttachedWorkspace(panes: 4)
        defer { window.close() }
        workspace.layoutSubtreeIfNeeded()

        XCTAssertTrue(workspace.performPaneDrop(from: "pane-1", onto: "pane-4"))

        func shadows(in workspace: PaneWorkspaceView) -> [NSView] {
            workspace.subviews.filter { ($0.layer?.shadowOpacity ?? 0) > 0 }
        }
        XCTAssertEqual(shadows(in: workspace).count, 2, "one per mover, none for the panes standing still")
        for id in ["pane-1", "pane-4"] {
            let pane = try XCTUnwrap(workspace.container(for: id))
            let index = try XCTUnwrap(workspace.subviews.firstIndex(of: pane))
            XCTAssertGreaterThan(index, 0)
            XCTAssertGreaterThan(
                workspace.subviews[index - 1].layer?.shadowOpacity ?? 0, 0,
                "\(id)'s shadow has to sit directly under it, or it falls on the wrong pane"
            )
        }

        RunLoop.current.run(until: Date().addingTimeInterval(PaneWorkspaceView.swapTransitionDuration + 0.1))
        XCTAssertEqual(shadows(in: workspace).count, 0, "a shadow left behind is one on every later frame")
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
        XCTAssertTrue(window.firstResponder === workspace.terminalSurface(for: "pane-3")?.terminalView)

        XCTAssertTrue(window.makeFirstResponder(window))
        workspace.restoreFocus()

        XCTAssertEqual(workspace.focusedPaneID, "pane-3")
        XCTAssertTrue(window.firstResponder === workspace.terminalSurface(for: "pane-3")?.terminalView)
    }

    func testFocusSurvivesASwapAndAReflow() {
        let (workspace, window) = makeAttachedWorkspace(panes: 4)
        defer { window.close() }
        workspace.focusPane("pane-2")

        XCTAssertTrue(workspace.swapPanes("pane-2", "pane-3"))
        XCTAssertEqual(workspace.focusedPaneID, "pane-2")
        XCTAssertTrue(window.firstResponder === workspace.terminalSurface(for: "pane-2")?.terminalView)

        XCTAssertTrue(workspace.addPane(makeDescriptor("pane-5")))
        XCTAssertEqual(workspace.focusedPaneID, "pane-5", "a new pane takes focus")
        XCTAssertTrue(window.firstResponder === workspace.terminalSurface(for: "pane-5")?.terminalView)
    }

    // MARK: - Drag and drop

    func testDroppingOnePaneOnAnotherSwapsThemThroughTheRealDraggingDestination() {
        let workspace = makeWorkspace(panes: 4)
        let source = workspace.container(for: "pane-1")!
        let target = workspace.container(for: "pane-4")!
        let sourceTerminal = ObjectIdentifier(source.terminalSurface.terminalView)
        let info = StubDraggingInfo(paneID: "pane-1")

        XCTAssertEqual(target.draggingEntered(info), .move)
        XCTAssertTrue(target.isDropTarget, "the drop target highlights while the drag hovers")
        XCTAssertTrue(target.performDragOperation(info))

        XCTAssertFalse(target.isDropTarget)
        XCTAssertEqual(workspace.paneIDs, ["pane-4", "pane-3", "pane-2", "pane-1"])
        XCTAssertEqual(ObjectIdentifier(workspace.container(for: "pane-1")!.terminalSurface.terminalView), sourceTerminal)
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
            workspace.container(for: id)!.terminalSurface.terminalView.terminal.options.cursorStyle
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
        let background = workspace.container(for: "pane-1")!.terminalSurface
        workspace.focusPane("pane-2")
        XCTAssertEqual(background.terminalView.terminal.options.cursorStyle, .steadyBlock)

        // DECSCUSR 5: blinking bar, sent while the pane is unselected.
        background.terminalView.terminal.setCursorStyle(.blinkBar)
        workspace.focusPane("pane-1")
        XCTAssertEqual(background.terminalView.terminal.options.cursorStyle, .blinkBar)
    }

    /// Every pane but the selected one has its background washed out a shade,
    /// and the veil never swallows a click meant for the terminal under it.
    func testOnlyTheSelectedPaneIsUnwashed() {
        let workspace = makeWorkspace(panes: 3)
        func wash(_ id: String) -> TerminalWashOverlayView {
            workspace.container(for: id)!.terminalSurface.wash
        }

        workspace.focusPane("pane-2")
        XCTAssertTrue(wash("pane-2").isHidden)
        XCTAssertFalse(wash("pane-1").isHidden)
        XCTAssertFalse(wash("pane-3").isHidden)

        workspace.focusPane("pane-3")
        XCTAssertFalse(wash("pane-2").isHidden, "the pane you left recedes")
        XCTAssertEqual(wash("pane-2").frame, workspace.container(for: "pane-2")!.surface.bounds)
        XCTAssertNil(wash("pane-2").hitTest(NSPoint(x: 5, y: 5)))
    }

    /// The veil is that pane's status colour at the top falling away to the
    /// neutral wash at the bottom. Which way up it runs is the whole point and
    /// nothing in the code reads as up or down — a gradient's unit space is y-up
    /// while the pane container it sits in is flipped — so it is rendered, with
    /// a green marker at the container's `y = 0` as the anchor for which end of
    /// the bitmap is the top of the screen.
    func testTheWashRunsTheStatusColourFromTheTopDown() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 2)
        defer { window.close() }
        workspace.focusPane("pane-2")
        let container = try XCTUnwrap(workspace.container(for: "pane-1"))
        container.status = .error
        let marker = NSView(frame: NSRect(x: 0, y: 0, width: container.bounds.width, height: 12))
        marker.wantsLayer = true
        marker.layer?.backgroundColor = NSColor.green.cgColor
        container.addSubview(marker, positioned: .above, relativeTo: nil)
        window.displayIfNeeded()
        container.layoutSubtreeIfNeeded()

        let image = try XCTUnwrap(render(container))
        let column = image.pixelsWide / 2
        func pixel(_ row: Int) -> NSColor {
            image.colorAt(x: column, y: row)?.usingColorSpace(.sRGB) ?? .black
        }
        let anchor = try XCTUnwrap(
            (0..<image.pixelsHigh).first { pixel($0).greenComponent > 0.8 },
            "the marker has to show up, or the render proves nothing"
        )
        let rows = anchor < image.pixelsHigh / 2
            ? Array(0..<image.pixelsHigh)
            : Array((0..<image.pixelsHigh).reversed())

        // Red over the near-black terminal, against the blue it has none of.
        func redness(_ row: Int) -> CGFloat { pixel(row).redComponent - pixel(row).blueComponent }
        let near = redness(rows[rows.count / 5])
        let far = redness(rows[rows.count - rows.count / 20])
        XCTAssertGreaterThan(near, 0.05, "the top of an errored pane carries its red")
        XCTAssertGreaterThan(near, far + 0.05, "and it fades on the way down")
    }

    /// Renders a view's whole layer tree, gradients included — `cacheDisplay`
    /// draws `draw(_:)` output only, which is nothing here.
    private func render(_ view: NSView) -> NSBitmapImageRep? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(view.bounds.width),
            pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .calibratedRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        view.layer?.render(in: context.cgContext)
        return rep
    }

    /// Nothing reads this in CI; it exists so Bruno can eyeball a render.
    /// `xcodebuild test`'s `TEST_RUNNER_` prefix is stripped and the rest
    /// handed straight to the test host's environment, so
    /// `TEST_RUNNER_PANE_RENDER_DIR=/tmp/panes ./macos/build.sh test` drops a
    /// PNG per named render there; unset, this is a no-op.
    private func saveRenderForInspection(_ rep: NSBitmapImageRep, named name: String) {
        guard
            let dir = ProcessInfo.processInfo.environment["PANE_RENDER_DIR"],
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? png.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// A pane ask sits centred over the pane that asked, with every part of
    /// the card inside the card. Drops a PNG when `PANE_RENDER_DIR` is set.
    func testAPaneAskCoversItsOwnPaneAndCentresTheCard() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 4)
        defer { window.close() }
        let paneID = try XCTUnwrap(workspace.paneIDs.last)
        let container = try XCTUnwrap(workspace.container(for: paneID))

        var chosen: String?
        container.presentAsk(
            title: "Start over with Shell?",
            message: "This terminal's conversation with Claude Code ends here. "
                + "Shell opens a fresh one in its place, in the same folder.",
            icon: Engine.shell.iconImage,
            options: [
                PaneAskOption("Stay") { _ in chosen = "Stay" },
                PaneAskOption("Switch to Shell", isPrimary: true) { _ in chosen = "Switch" },
            ]
        )
        window.displayIfNeeded()
        workspace.layoutSubtreeIfNeeded()

        let card = try XCTUnwrap(container.askOverlay)
        XCTAssertEqual(card.frame, container.bounds, "the glass covers the whole pane, and only it")
        saveRenderForInspection(try XCTUnwrap(render(container)), named: "pane-ask")

        // Every subview inside the overlay, and the buttons in the given order
        // across the middle — the card is built from measured text, so a
        // message one line longer must not push a button off it.
        for view in card.subviews {
            XCTAssertTrue(card.bounds.contains(view.frame), "\(view) escaped the card")
        }
        let buttons = card.subviews.compactMap { $0 as? PaneApprovalButton }
        XCTAssertEqual(buttons.map(\.title), ["Stay", "Switch to Shell"])
        XCTAssertLessThan(buttons[0].frame.maxX, buttons[1].frame.minX, "primary on the right")

        // And answering it takes the glass down exactly once.
        buttons[1].onClick?()
        XCTAssertEqual(chosen, "Switch")
        XCTAssertNil(container.askOverlay)

        // The same card with a text field: its height is built from measured
        // text plus the field, so the field is the part that can push a button
        // off the bottom if the arithmetic is wrong.
        // No message, exactly as the rename asks it: the card has to close the
        // gap the subtitle used to fill rather than leave a hole in the middle.
        container.presentAsk(
            title: "Rename this conversation",
            icon: NSImage(systemSymbolName: "pencil", accessibilityDescription: nil),
            input: "Ingest",
            options: [
                PaneAskOption("Cancel") { _ in },
                PaneAskOption("Rename", isPrimary: true) { _ in },
            ]
        )
        window.displayIfNeeded()
        workspace.layoutSubtreeIfNeeded()
        let rename = try XCTUnwrap(container.askOverlay)
        saveRenderForInspection(try XCTUnwrap(render(container)), named: "pane-ask-rename")
        for view in rename.subviews {
            XCTAssertTrue(rename.bounds.contains(view.frame), "\(view) escaped the card")
        }
        XCTAssertEqual(rename.text, "Ingest")
    }

    /// A pane in a session that is not on screen still gets its question seen:
    /// the quit walk asks about every pane in every session, and a card drawn
    /// on a hidden pane is a quit that never gets its answer.
    func testAnAskOnAnOffScreenSessionBringsThatSessionToTheScreen() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 1)
        defer { window.close() }
        let visible = try XCTUnwrap(workspace.paneIDs.first)
        var hidden = makeDescriptor("other-session-pane")
        hidden.group = "session-2"
        XCTAssertTrue(workspace.addPane(hidden))
        workspace.focusPane(visible)
        XCTAssertFalse(workspace.paneIDs.contains("other-session-pane"), "it is off screen")

        let container = try XCTUnwrap(workspace.container(for: "other-session-pane"))
        container.presentAsk(
            title: "Save changes to a.swift?",
            message: "There are edits that are not on disk.",
            icon: nil,
            options: [PaneAskOption("Save", isPrimary: true) { _ in }]
        )

        XCTAssertTrue(
            workspace.paneIDs.contains("other-session-pane"),
            "asking switched to the session that is asking"
        )
        XCTAssertNotNil(container.askOverlay)
    }

    /// An ask replaced by another ask pays out the first one's cancel. Both of
    /// the editor's askers (the save walk, the watcher's on-disk conflict) hold
    /// a completion that gates quitting and pane persistence; dropping one
    /// silently wedges both.
    func testAnAskReplacedByAnotherAnswersTheFirstOnesCaller() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 1)
        defer { window.close() }
        let paneID = try XCTUnwrap(workspace.paneIDs.first)
        let container = try XCTUnwrap(workspace.container(for: paneID))

        var stranded = true
        container.presentAsk(
            title: "Save changes to a.swift?",
            message: "There are edits that are not on disk.",
            icon: nil,
            options: [PaneAskOption("Save", isPrimary: true) { _ in stranded = false }],
            onCancel: { stranded = false }
        )
        container.presentAsk(
            title: "a.swift changed on disk",
            message: "An agent wrote it while you were being asked about it.",
            icon: nil,
            options: [PaneAskOption("Take Disk", isPrimary: true) { _ in }]
        )
        XCTAssertFalse(stranded, "the save prompt's caller heard back when its card was replaced")

        // And an answered card owes nothing: cancel must not fire on top of it.
        var cancelled = false
        container.presentAsk(
            title: "Start over with Shell?",
            message: "This terminal's conversation ends here.",
            icon: nil,
            options: [PaneAskOption("Switch", isPrimary: true) { _ in }],
            onCancel: { cancelled = true }
        )
        try XCTUnwrap(container.askOverlay).choose(0)
        XCTAssertFalse(cancelled, "an answered ask is not also a cancelled one")
        XCTAssertNil(container.askOverlay)
    }

    /// A render of the third row, for eyeballing rather than for CI: nine
    /// panes (the ninth alone on the bottom row, three empty cells beside it)
    /// and a full twelve. Drops PNGs when `PANE_RENDER_DIR` is set; the
    /// assertions below hold either way.
    func testThirdRowRendersAsThreeRowsOfFour() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 8)
        defer { window.close() }

        for index in 9...PaneGrid.maxPanes {
            XCTAssertTrue(workspace.addPane(makeDescriptor("pane-\(index)")))
            window.displayIfNeeded()
            workspace.layoutSubtreeIfNeeded()
            if index == 9 || index == PaneGrid.maxPanes {
                let rep = try XCTUnwrap(render(workspace))
                saveRenderForInspection(rep, named: "grid-\(index)-panes")
            }
        }

        // Three distinct row bands, four distinct columns, every cell the same
        // size — the 3x4 the brief asks for, read off the frames themselves.
        let cells = workspace.paneIDs.compactMap { workspace.container(for: $0)?.frame }
        XCTAssertEqual(cells.count, 12)
        XCTAssertEqual(Set(cells.map(\.minY)).count, 3, "three rows")
        XCTAssertEqual(Set(cells.map(\.minX)).count, 4, "four columns")
        XCTAssertEqual(Set(cells.map { [$0.width, $0.height] }).count, 1, "one cell size")
        XCTAssertEqual(cells.map(\.maxY).max(), workspace.gridBounds.maxY)
        XCTAssertEqual(cells.map(\.maxX).max(), workspace.gridBounds.maxX)
    }

    // MARK: - Milestone 1: mixed terminal/browser grids

    /// The seam's whole point proven at once: a browser pane sitting beside
    /// terminals lands at the grid cell like any other pane and lays out its
    /// own chrome inside it — nothing about the container or the grid needed
    /// to know a WKWebView was in there.
    func testMixedGridLaysOutAndRendersTheBrowserPaneAtItsGridCell() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 2)
        defer { window.close() }
        var descriptor = makeDescriptor("web-1")
        descriptor.kind = .browser
        XCTAssertTrue(workspace.addPane(descriptor))
        window.displayIfNeeded()
        workspace.layoutSubtreeIfNeeded()

        let container = try XCTUnwrap(workspace.container(for: "web-1"))
        let browser = try XCTUnwrap(container.surface as? BrowserPaneView)

        let expectedFrame = try XCTUnwrap(
            workspace.grid?.layout(
                in: workspace.gridBounds,
                dividerThickness: PaneWorkspaceView.dividerThickness
            ).frames["web-1"]
        )
        XCTAssertEqual(container.frame, expectedFrame, "a browser pane sits at its grid cell like any other")

        XCTAssertEqual(
            browser.webView.frame.minY, BrowserPaneView.toolbarHeight,
            "the web content starts right under the nav bar"
        )
        XCTAssertGreaterThan(browser.urlField.frame.width, 0, "the URL field got real room, not a degenerate layout")

        let image = try XCTUnwrap(render(container), "the container's whole layer tree has to render")
        XCTAssertGreaterThan(image.pixelsWide, 0)
        XCTAssertGreaterThan(image.pixelsHigh, 0)
        saveRenderForInspection(image, named: "mixed-grid-browser-pane")
    }

    /// Mirrors `testFocusIsRestoredToTheFocusedPaneWhenTheWindowIsActivated`
    /// for a browser pane, where the terminal test's identity check
    /// (`=== terminalView`) cannot apply: WKWebView's real first responder is
    /// an internal `WKContentView`, so this checks descendance instead, the
    /// same relaxation `reclaimFirstResponder` made for the same reason.
    func testFocusIsRestoredToABrowserPaneWhenTheWindowIsActivated() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 2)
        defer { window.close() }
        var descriptor = makeDescriptor("web-1")
        descriptor.kind = .browser
        XCTAssertTrue(workspace.addPane(descriptor))

        let container = try XCTUnwrap(workspace.container(for: "web-1"))
        workspace.focusPane("web-1")
        XCTAssertTrue(
            (window.firstResponder as? NSView)?.isDescendant(of: container) == true,
            "focusing a browser pane lands the responder inside its container"
        )

        XCTAssertTrue(window.makeFirstResponder(window))
        workspace.restoreFocus()

        XCTAssertEqual(workspace.focusedPaneID, "web-1")
        XCTAssertTrue(
            (window.firstResponder as? NSView)?.isDescendant(of: container) == true,
            "restoreFocus reclaims a browser pane the same way it reclaims a terminal"
        )
    }

    /// Mirrors `testTerminalInstancesSurviveEveryLayoutMutation`'s identity
    /// check, for the mutation that is browser-specific: zooming in and back
    /// must not tear down and rebuild anyone's `PaneContentView`, terminal or
    /// browser.
    func testZoomingABrowserPaneInAMixedGridPreservesEveryPaneIdentity() {
        let workspace = makeWorkspace(panes: 2)
        var descriptor = makeDescriptor("web-1")
        descriptor.kind = .browser
        XCTAssertTrue(workspace.addPane(descriptor))
        let before = identities(in: workspace)

        XCTAssertTrue(workspace.toggleZoom("web-1"))
        XCTAssertEqual(workspace.zoomedPaneID, "web-1")
        XCTAssertTrue(workspace.toggleZoom("web-1"), "the same button shrinks it back")
        XCTAssertNil(workspace.zoomedPaneID)

        XCTAssertEqual(before, identities(in: workspace), "zooming a browser pane must not recreate any surface")
    }

    // MARK: - Header chrome

    /// The border says what the pane is doing, in the same colours the
    /// sidebar's dots and the header's mark already use — one mapping, not
    /// three. Focus brightens the ring; a question or an error keeps a visible
    /// ring even on a pane you are not looking at, because that pane is the
    /// one the user must act on.
    func testThePaneBorderWearsTheStatusColourAndUrgencySurvivesUnfocus() {
        let workspace = makeWorkspace(panes: 2)
        let target = workspace.container(for: "pane-1")!
        workspace.focusPane("pane-1")
        // Before anything has been reported, focus falls back to the accent.
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.focusedBorderColor.cgColor)

        func ring(_ status: RemoteSessionStatus, alpha: CGFloat) -> CGColor {
            PaneStatusMarkView.color(for: status).withAlphaComponent(alpha).cgColor
        }
        for status: RemoteSessionStatus in [.ready, .thinking, .toolExecution, .awaitingApproval, .error] {
            workspace.setStatus(status, for: "pane-1")
            XCTAssertEqual(target.status, status)
            XCTAssertEqual(
                target.layer?.backgroundColor,
                ring(status, alpha: PaneContainerView.focusedRingAlpha),
                "a focused pane's ring wears its own status colour (\(status))"
            )
        }

        // An unfocused pane still shows urgency; that is the whole point of
        // being able to see it from the other side of the grid. Everything
        // else recedes to the hairline — the mark and the wash still carry
        // the status there.
        workspace.focusPane("pane-2")
        workspace.setStatus(.awaitingApproval, for: "pane-1")
        XCTAssertEqual(
            target.layer?.backgroundColor,
            ring(.awaitingApproval, alpha: PaneContainerView.urgentRingAlpha)
        )
        workspace.setStatus(.error, for: "pane-1")
        XCTAssertEqual(
            target.layer?.backgroundColor,
            ring(.error, alpha: PaneContainerView.urgentRingAlpha)
        )
        workspace.setStatus(.ready, for: "pane-1")
        XCTAssertEqual(target.layer?.backgroundColor, PaneContainerView.idleBorderColor.cgColor)
    }

    /// The ring has to survive the corners. It is the container's background
    /// showing through a 1pt inset around two square children — so at a corner
    /// the child ran straight into the arc the container's mask cuts and the ring
    /// pinched out to nothing there, most visibly on the focused card, where the
    /// radius is 12 and the ring is a bright accent. Each child is rounded one
    /// radius smaller, concentric inside the container's.
    func testThePaneRingSurvivesTheCorners() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 2)
        defer { window.close() }
        window.displayIfNeeded()
        let pane = try XCTUnwrap(workspace.container(for: "pane-1"))
        let header = try XCTUnwrap(pane.header.layer)
        let surface = try XCTUnwrap(pane.surface.layer)
        let bar = try XCTUnwrap(pane.approvalBar.layer)

        for child in [header, surface] {
            XCTAssertEqual(
                child.cornerRadius,
                PaneContainerView.cornerRadius - PaneContainerView.borderWidth,
                "concentric inside the container's 9, one border width in"
            )
            XCTAssertTrue(child.masksToBounds, "or the radius rounds nothing")
        }
        // Only the corners each child actually owns: rounding the header's
        // bottom or the terminal's top would cut a notch out of the seam between
        // them, in the middle of the pane. Which *literal* pair that is differs
        // per child: the compositor resolves `maskedCorners` in the layer's own
        // space, whose screen orientation is the XOR of `isGeometryFlipped`
        // down the layer chain — AppKit sets it per backing layer to preserve
        // each *view's* own coordinate convention, not the container's. The
        // terminal surface is unflipped, so a literal `MaxY` pair put its
        // rounding at its top corners on screen: an accent wedge under the
        // header's hairline, and the ring pinching out to nothing at the pane's
        // bottom corners. The offscreen render harness cannot see this —
        // `CALayer.render(in:)` does not apply the compositor's geometry flips
        // — so this asserts on the layer state the compositor actually consumes.
        let minY: CACornerMask = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        let maxY: CACornerMask = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        func rendersMinYAtTheTop(_ layer: CALayer) -> Bool {
            var flipped = false
            var current: CALayer? = layer
            while let step = current {
                flipped = flipped != step.isGeometryFlipped
                current = step.superlayer
            }
            return flipped
        }
        XCTAssertEqual(
            header.maskedCorners,
            rendersMinYAtTheTop(header) ? minY : maxY,
            "the header's rounded pair has to render at the screen top"
        )
        XCTAssertEqual(
            surface.maskedCorners,
            rendersMinYAtTheTop(surface) ? maxY : minY,
            "the surface's rounded pair has to render at the screen bottom"
        )
        XCTAssertEqual(
            bar.maskedCorners,
            rendersMinYAtTheTop(bar) ? maxY : minY,
            "the approval bar takes over the screen-bottom pair while showing"
        )

        XCTAssertTrue(workspace.toggleZoom("pane-1"))
        XCTAssertEqual(
            surface.cornerRadius,
            PaneContainerView.focusedCornerRadius - PaneContainerView.borderWidth,
            "and the card's bigger corner is followed inwards too"
        )
    }

    /// One mapping, not two: the header's mark and the sidebar's session dots
    /// must never disagree about what a session is doing.
    func testTheHeaderMarkUsesTheSameStatusColoursAsTheSidebar() {
        for status: RemoteSessionStatus? in [.ready, .thinking, .toolExecution, .awaitingApproval, .error, nil] {
            XCTAssertEqual(PaneStatusMarkView.color(for: status), ShellDotsView.color(for: status))
        }
        XCTAssertNotEqual(PaneStatusMarkView.color(for: .ready), PaneStatusMarkView.color(for: nil))
    }

    /// Tool execution keeps thinking's blue and is told apart by tempo alone:
    /// the same smooth pulse, run faster.
    func testToolExecutionPulsesFasterThanThinking() throws {
        let mark = PaneStatusMarkView()
        mark.status = .thinking
        let thinking = try XCTUnwrap(mark.layer?.animation(forKey: "om-pulse") as? CABasicAnimation)
        mark.status = .toolExecution
        let tool = try XCTUnwrap(mark.layer?.animation(forKey: "om-pulse") as? CABasicAnimation)
        XCTAssertLessThan(tool.duration, thinking.duration)
        XCTAssertEqual(tool.autoreverses, thinking.autoreverses)
        XCTAssertEqual(
            PaneStatusMarkView.color(for: .toolExecution),
            PaneStatusMarkView.color(for: .thinking),
            "and the colour stays blue -- only the motion says which kind of work"
        )
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
        XCTAssertEqual(workspace.accessibilityLabel(), "Workspace panes")
        XCTAssertEqual(workspace.accessibilityChildren()?.count, 5)

        // Fill order is 1, 3, 2, 4, 5 — pane-2 sits in the third cell.
        let second = workspace.container(for: "pane-2")!
        XCTAssertEqual(second.accessibilityRole(), .group)
        XCTAssertEqual(second.accessibilityLabel(), "Terminal pane 3 of 5")
        XCTAssertEqual(second.terminalSurface.terminalView.accessibilityLabel(), "Terminal")

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
            XCTAssertEqual(workspace.terminalSurface(for: id)?.resizeSendCount, 0, id)
        }

        workspace.resizeCoalescer.flush()

        XCTAssertEqual(workspace.resizeCoalescer.flushCount, 1)
        XCTAssertTrue(workspace.resizeCoalescer.pending.isEmpty)
        for id in workspace.paneIDs {
            XCTAssertEqual(workspace.terminalSurface(for: id)?.resizeSendCount, 1, "\(id): 20 drag steps, one send")
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
        let surface = workspace.terminalSurface(for: "pane-1")!

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
                workspace.terminalSurface(for: id)?.requestRendererDraw()
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

    /// A full grid is what one session can draw, and each session has its
    /// own grid — so it is a per-session number. Applying it to the whole app
    /// meant a full session stopped every other session from opening a
    /// terminal at all.
    func testEachSessionGetsItsOwnFullGridOfTerminals() {
        let workspace = makeWorkspace(panes: PaneGrid.maxPanes)
        XCTAssertFalse(workspace.addPane(makeDescriptor("pane-over-cap")), "this session is full")

        var elsewhere = makeDescriptor("other-1")
        elsewhere.group = "sess-grp-2"
        XCTAssertTrue(workspace.addPane(elsewhere), "a different session is not")

        XCTAssertEqual(workspace.paneCount(inGroup: "sess-grp-1"), PaneGrid.maxPanes)
        XCTAssertEqual(workspace.paneCount(inGroup: "sess-grp-2"), 1)
        XCTAssertEqual(workspace.allPaneIDs.count, PaneGrid.maxPanes + 1)
        XCTAssertEqual(workspace.paneIDs.count, 1, "and it shows only its own")
    }

    /// The app-wide terminal backstop mirrors the daemon's `MAX_SESSIONS` — a
    /// PTY budget. A browser pane holds no PTY, so it must not spend one.
    func testBrowserPanesDoNotCountAgainstTheTerminalCap() {
        let workspace = makeWorkspace(panes: 2)
        XCTAssertEqual(workspace.terminalPaneCount, 2)
        XCTAssertTrue(workspace.addPane(
            PaneDescriptor(sessionID: "web-1", group: "sess-grp-1", kind: .browser)
        ))
        XCTAssertEqual(workspace.terminalPaneCount, 2, "a browser consumes no PTY budget")
        XCTAssertEqual(workspace.allPaneIDs.count, 3)
    }

    /// Same backstop, same exemption, for `.editor` — a tabbed editor holds
    /// no PTY either.
    func testEditorPaneCostsNoTerminalSlot() {
        let workspace = makeWorkspace(panes: 1)
        XCTAssertEqual(workspace.terminalPaneCount, 1)
        XCTAssertTrue(workspace.addPane(
            PaneDescriptor(sessionID: "e1", group: "sess-grp-1", kind: .editor)
        ))
        XCTAssertEqual(workspace.terminalPaneCount, 1, "an editor consumes no PTY budget")
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
            "eight sessions of a full grid each has to fit under the app-wide backstop"
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
        XCTAssertGreaterThan(zoomedIndex, blurIndex, "the zoomed pane sits above the glass")
        XCTAssertLessThan(otherIndex, blurIndex, "and everything else behind it, refracted")

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

    /// The card as a share of the overlay it is centred in, capped, keeping the
    /// window's proportions. Pure geometry, so it is asked directly rather than
    /// through a window.
    func testFocusCardFrameIsACappedShareOfTheOverlayItIsCentredIn() {
        let padding = PaneWorkspaceView.focusOverlayPadding
        let scale = PaneWorkspaceView.focusCardScale
        let heightScale = PaneWorkspaceView.focusCardHeightScale
        let cap = PaneWorkspaceView.focusCardMaxSize
        let roomy = PaneWorkspaceView.focusCardFrame(
            in: NSRect(x: 0, y: 0, width: 1400, height: 900)
        )
        XCTAssertEqual(
            roomy.size,
            NSSize(
                width: (1400 * scale).rounded(.down),
                height: (900 * heightScale).rounded(.down)
            ),
            "a share of the window while that share fits the cap — height's own, larger one"
        )
        XCTAssertGreaterThan(
            heightScale, scale,
            "height spends the slack the width's share leaves; rows of terminal are the point"
        )
        XCTAssertEqual(roomy.midX, 700, "centred in the overlay")
        XCTAssertEqual(roomy.midY, 450)

        // A big display is the case the cap exists for: a fraction of it is so
        // wide there is nothing left to focus *on*.
        let huge = NSRect(x: 0, y: 0, width: 3840, height: 1600)
        let capped = PaneWorkspaceView.focusCardFrame(in: huge)
        XCTAssertEqual(capped.width, cap.width, "width capped")
        XCTAssertEqual(capped.height, cap.height, "and on a display this tall, height too")
        XCTAssertGreaterThan(
            capped.height,
            (huge.height * (capped.width / huge.width)).rounded(.down),
            "taller than the width's share alone would make it, never shorter"
        )
        XCTAssertEqual(capped.midX, huge.midX, accuracy: 1, "still centred")
        XCTAssertEqual(capped.midY, huge.midY, accuracy: 1)

        // Small enough that the share would come within 26 of an edge: the card
        // gives up its own size rather than the padding that keeps the blur
        // reading as a surround.
        let cramped = PaneWorkspaceView.focusCardFrame(
            in: NSRect(x: 0, y: 0, width: 200, height: 120)
        )
        XCTAssertEqual(
            cramped,
            NSRect(
                x: padding,
                y: padding,
                width: 200 - padding * 2,
                height: 120 - padding * 2
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
        XCTAssertFalse(backdrop.isHidden, "the glass is shown")
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
            // And the shadow is already fading rather than riding the shrink all
            // the way down at full strength: the teardown is on a timer that
            // cannot land on the frame the animation ends, and a shadow still
            // there flickers on whichever side of it the timer falls.
            XCTAssertEqual(shadow.opacity, 0)
            XCTAssertNotNil(shadow.animation(forKey: "opacity"), "faded, not cut")
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
    /// ⌘1…⌘9) silently greyed out, which they do not do with no card up.
    func testThePanesMenuCommandsStayReachableAndEnabledWhileACardIsUp() throws {
        let (workspace, window, _) = makeSplitHostedWorkspace(panes: 4)
        defer { window.close() }
        workspace.focusPane("pane-1")
        XCTAssertTrue(workspace.toggleZoom("pane-1"))
        let card = try XCTUnwrap(workspace.container(for: "pane-1"))
        XCTAssertTrue(window.makeFirstResponder(card.terminalSurface.terminalView))

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

    /// The card shows the focused pane, whichever command moved focus. ⌘1…⌘9 and
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

        // And it starts from where the pane *is*. The card changes superview on
        // the way up, and until the next commit its presentation layer still
        // holds the position it had in the grid — read in the overlay host, that
        // is a point a sidebar's width away, which is where the lift used to
        // appear to begin. Only a hosted workspace with a sidebar can tell the
        // two apart, which is why this test builds one.
        let move = try XCTUnwrap(layer.animation(forKey: "position") as? CABasicAnimation)
        let origin = try XCTUnwrap((move.fromValue as? NSValue)?.pointValue)
        let host = try XCTUnwrap(card.superview)
        let cellInHost = workspace.convert(cell, to: host)
        // A layer's `position` is wherever its `anchorPoint` sits — the corner,
        // for these views, not the centre — so the cell is expressed the same way
        // rather than assumed to be centre-anchored.
        let anchor = layer.anchorPoint
        XCTAssertNotEqual(cellInHost.minX, cell.minX, "the two spaces really do differ here")
        XCTAssertEqual(
            origin.x,
            cellInHost.minX + anchor.x * cellInHost.width,
            accuracy: 1,
            "from the cell, in the host's space"
        )
        XCTAssertEqual(
            origin.y,
            cellInHost.minY + anchor.y * cellInHost.height,
            accuracy: 1
        )
    }

    /// One panel of untinted Liquid Glass filling the window the card sits in
    /// front of — glass on macOS 26, nothing at all before it, since every
    /// pre-26 stand-in dims and dimming is the thing this panel must not do.
    /// Configuration and geometry only: an effect view is exactly as
    /// unrenderable in an offscreen test as it has always been.
    func testTheBackdropIsOnePanelOfUntintedGlassFillingTheWindow() throws {
        let backdrop = PaneZoomBackdropView()
        backdrop.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        backdrop.setShown(true, duration: 0)
        backdrop.layoutSubtreeIfNeeded()

        XCTAssertEqual(backdrop.alphaValue, 1, "glass is made to be looked through")
        // Nothing of our own is painted over or under it either — the glass is
        // the whole panel, and a layer fill would be a dim by another name.
        XCTAssertNil(backdrop.layer?.backgroundColor)

        guard #available(macOS 26.0, *) else {
            XCTAssertTrue(
                backdrop.subviews.isEmpty,
                "no glass on this OS, and no dimming stand-in either"
            )
            return
        }
        XCTAssertEqual(backdrop.subviews.count, 1, "one panel, nothing layered over it")
        let glass = try XCTUnwrap(backdrop.subviews.first as? NSGlassEffectView)
        XCTAssertEqual(glass.frame, backdrop.bounds, "the size of the window it covers")
        XCTAssertEqual(glass.style, .clear, "refracting the workspace, not darkening it")
        XCTAssertNil(glass.tintColor, "and no wash of colour over it")

        // And keeps covering it: the overlay host is resized on every layout
        // pass, and a panel that stopped following would leave the app sharp
        // down one side of the card.
        backdrop.setFrameSize(NSSize(width: 900, height: 500))
        backdrop.layoutSubtreeIfNeeded()
        XCTAssertEqual(glass.frame, backdrop.bounds, "on a resize too")
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

        let middle = target.terminalSurface.terminalView.convert(
            CGPoint(x: target.surface.bounds.midX, y: target.surface.bounds.midY),
            from: target.surface
        )
        let click = try XCTUnwrap(
            NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: target.terminalSurface.terminalView.convert(middle, to: nil),
                modifierFlags: [],
                timestamp: 0,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: 1
            )
        )
        target.terminalSurface.terminalView.mouseDown(with: click)

        XCTAssertEqual(workspace.focusedPaneID, "pane-2")
    }

    // MARK: - Focus-mode header

    /// The bar has to *change* when a pane is focused: the design's focused
    /// card carries a taller header, a bigger name and the
    /// `session · terminal N of M` subtitle, and none of it may survive the trip
    /// back into the grid. What must *not* change is the cluster — all three
    /// discs stay put in both modes, and only which of them is live moves.
    func testTheFocusHeaderWearsTheDesignsTallerBarAndItsOwnControls() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 4)
        defer { window.close() }
        for id in workspace.paneIDs {
            workspace.updateDescriptor(for: id) { $0.groupLabel = "session restore" }
        }
        let card = try XCTUnwrap(workspace.container(for: "pane-2"))
        XCTAssertEqual(card.header.currentHeight, 30, "the grid bar is the design's 30px")
        XCTAssertNil(card.header.subtitle, "the grid header has no subtitle to show")
        XCTAssertEqual(
            controls(in: card.header),
            [Self.restoreText, "Zoom this pane", "Close this pane"]
        )
        XCTAssertEqual(
            liveControls(in: card.header),
            ["Zoom this pane", "Close this pane"],
            "with nothing to come back from, yellow is the one disc that is off"
        )
        // For eyeballing the cluster in both treatments — see
        // `saveRenderForInspection`. A no-op unless `PANE_RENDER_DIR` is set.
        window.displayIfNeeded()
        try saveRenderForInspection(XCTUnwrap(render(card)), named: "header-cluster-grid")

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
            [Self.restoreText, "Zoom this pane", "Close this pane"],
            "the same three controls in the same places — a zoom moves none of them"
        )
        XCTAssertEqual(
            liveControls(in: card.header),
            [Self.restoreText],
            "and the live controls invert: yellow comes on, green and red go off"
        )

        window.displayIfNeeded()
        try saveRenderForInspection(XCTUnwrap(render(card)), named: "header-cluster-zoomed")

        // Out by pressing the yellow disc, not by calling the toggle it happens
        // to be wired to.
        let restore = try XCTUnwrap(button(labelled: Self.restoreText, in: card.header))
        click(restore, in: window)
        XCTAssertNil(workspace.zoomedPaneID, "yellow is the way out, not a picture of one")

        card.layoutSubtreeIfNeeded()
        XCTAssertEqual(card.header.currentHeight, 30)
        XCTAssertEqual(card.header.frame.height, 30)
        XCTAssertNil(card.header.subtitle)
        XCTAssertEqual(
            liveControls(in: card.header),
            ["Zoom this pane", "Close this pane"]
        )
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
        // `600 15.5px` / `#f0f0f4` title, `400 14px` / `#5c5c66` subtitle.
        header.isZoomed = true
        layOut(header, width: 1080)
        let fields = header.subviews.compactMap { $0 as? NSTextField }
        let subtitle = try XCTUnwrap(fields.first { $0.stringValue == "session restore · terminal 1 of 4" })
        let title = try XCTUnwrap(fields.first { $0 !== subtitle })
        let mark = try XCTUnwrap(header.subviews.compactMap { $0 as? PaneStatusMarkView }.first)
        let red = try XCTUnwrap(button(labelled: "Close this pane", in: header))
        XCTAssertEqual(mark.frame.size, CGSize(width: 15, height: 15), "the 15px status mark, both modes")
        XCTAssertEqual(mark.frame.minX, 12)
        XCTAssertEqual(title.frame.minX - mark.frame.maxX, 9, "focus `gap:9px`")
        XCTAssertEqual(subtitle.frame.minX - title.frame.maxX, 9)
        XCTAssertEqual(red.frame.maxX, 1080 - 7, "focus `padding-right:7px`")
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
        // `500 14.5px`, 20pt icon squares, no subtitle.
        header.isZoomed = false
        layOut(header, width: 620)
        let zoom = try XCTUnwrap(button(labelled: "Zoom this pane", in: header))
        let close = try XCTUnwrap(button(labelled: "Close this pane", in: header))
        XCTAssertEqual(mark.frame.minX, 10)
        XCTAssertEqual(title.frame.minX - mark.frame.maxX, 8, "grid `gap:8px`")
        XCTAssertEqual(close.frame.maxX, 620 - 6, "grid `padding-right:6px`")
        XCTAssertEqual(zoom.frame.size, CGSize(width: 20, height: 20))
        XCTAssertEqual(close.frame.size, CGSize(width: 20, height: 20))
        XCTAssertEqual(title.font, ShellFont.ui(14.5, .medium), "grid title `500 14.5px`")
        XCTAssertTrue(subtitle.isHidden, "and nothing left of the subtitle")
    }

    /// The three discs are one cluster, read by position: yellow restores, green
    /// expands, red closes, always in that order and always all three present.
    /// A control that cannot act greys out where it stands — if a disabled disc
    /// were ever hidden instead, the two survivors would slide into new places
    /// and the position you learned would stop meaning anything.
    func testTheHeaderCarriesAYellowGreenRedClusterThatNeverReorders() throws {
        let header = PaneHeaderView(title: "token rotation")
        header.isZoomAvailable = true
        layOut(header, width: 620)

        let restore = try XCTUnwrap(button(labelled: Self.restoreText, in: header))
        let zoom = try XCTUnwrap(button(labelled: "Zoom this pane", in: header))
        let close = try XCTUnwrap(button(labelled: "Close this pane", in: header))
        XCTAssertEqual(restore.trafficLight, .yellow)
        XCTAssertEqual(zoom.trafficLight, .green)
        XCTAssertEqual(close.trafficLight, .red)
        for disc in [restore, zoom, close] {
            XCTAssertEqual(
                disc.intrinsicContentSize,
                NSSize(width: PaneHeaderButton.iconSize, height: PaneHeaderButton.iconSize),
                "every disc is the grid's 20pt square"
            )
            XCTAssertFalse(disc.isHidden, "and none of them ever leaves the bar")
        }
        // Abutting 20pt squares, which is macOS's own 20pt between disc centres.
        XCTAssertEqual(zoom.frame.minX, restore.frame.maxX, "yellow, then green")
        XCTAssertEqual(close.frame.minX, zoom.frame.maxX, "then red, nearest the edge")

        // Unzoomed: nothing to come back from, so yellow alone is off.
        XCTAssertFalse(restore.isEnabled)
        XCTAssertTrue(zoom.isEnabled)
        XCTAssertTrue(close.isEnabled)

        // Zoomed: the pair invert, and the cluster keeps its shape. (The card's
        // taller bar and its own `padding-right:7px` shift the whole cluster —
        // what may not change is the order and the abutting.)
        let places = [restore.frame, zoom.frame, close.frame]
        header.isZoomed = true
        layOut(header, width: 620)
        XCTAssertTrue(restore.isEnabled)
        XCTAssertFalse(zoom.isEnabled, "you are already in — green is the way in")
        XCTAssertFalse(close.isEnabled, "closing what you just blew up is what ⌘W is for")
        XCTAssertEqual(zoom.frame.minX, restore.frame.maxX, "still yellow, then green")
        XCTAssertEqual(close.frame.minX, zoom.frame.maxX, "then red")
        XCTAssertEqual(close.frame.maxX, 620 - 7, "focus `padding-right:7px`")

        // A single pane on screen has nothing to zoom over, so green goes off
        // too rather than offering a no-op — and still holds its place.
        header.isZoomed = false
        header.isZoomAvailable = false
        layOut(header, width: 620)
        XCTAssertFalse(zoom.isEnabled)
        XCTAssertTrue(close.isEnabled, "which says nothing about closing it")
        XCTAssertEqual(
            [restore.frame, zoom.frame, close.frame],
            places,
            "a disc going dark moves nothing"
        )
    }

    /// A disabled disc has to actually refuse, not merely look grey: it is still
    /// on screen, still under the pointer, and still reachable by assistive
    /// technology, so every one of those paths has to be closed.
    func testADisabledDiscRefusesEveryWayItCanBePressed() throws {
        let (workspace, window) = makeAttachedWorkspace(panes: 4)
        defer { window.close() }
        let card = try XCTUnwrap(workspace.container(for: "pane-2"))
        let restore = try XCTUnwrap(button(labelled: Self.restoreText, in: card.header))

        // Yellow, with nothing zoomed: clicking it must not zoom anything.
        XCTAssertFalse(restore.isEnabled)
        click(restore, in: window)
        XCTAssertNil(workspace.zoomedPaneID, "a disabled disc is not a live toggle")
        XCTAssertFalse(restore.accessibilityPerformPress(), "nor a live one to VoiceOver")
        XCTAssertFalse(restore.isAccessibilityEnabled(), "which is also what it reports")

        // Red, while zoomed: the pane may not be closed out from under the card.
        XCTAssertTrue(workspace.toggleZoom("pane-2"))
        var closes: [String] = []
        workspace.onRequestClosePane = { closes.append($0) }
        let close = try XCTUnwrap(button(labelled: "Close this pane", in: card.header))
        XCTAssertFalse(close.isEnabled)
        click(close, in: window)
        XCTAssertEqual(closes, [], "red is off while zoomed, and off means off")
        XCTAssertEqual(workspace.zoomedPaneID, "pane-2")
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
        // The production factory's shape, so a browser descriptor builds a
        // real `BrowserPaneView` here too.
        let workspace = PaneWorkspaceView { descriptor in
            switch descriptor.kind {
            case .terminal:
                return TerminalSurfaceView(connection: connection, sessionID: descriptor.sessionID)
            case .browser:
                return BrowserPaneView(initialURL: descriptor.browserURL)
            case .editor:
                return EditorPaneView(
                    initialTabs: descriptor.editorTabs,
                    activeIndex: descriptor.editorActiveIndex
                )
            }
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
            result[id] = workspace.surface(for: id).map { ObjectIdentifier($0) }
        }
        return result
    }

    private func spinRunLoop() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    /// What the yellow disc answers to — the one place the escape hatch is
    /// spelled out, and how these tests tell the cluster apart without the
    /// header exposing its buttons.
    private static let restoreText = "Restore this pane · esc"

    /// Which trailing controls the bar is showing, named by what they say they
    /// do, in the order the header lays them out.
    private func controls(in header: PaneHeaderView) -> [String] {
        header.subviews
            .compactMap { $0 as? PaneHeaderButton }
            .filter { !$0.isHidden }
            .compactMap { $0.accessibilityLabel() }
    }

    /// The same list narrowed to the controls that would do something if you
    /// pressed them — which is the part a zoom actually changes.
    private func liveControls(in header: PaneHeaderView) -> [String] {
        header.subviews
            .compactMap { $0 as? PaneHeaderButton }
            .filter { !$0.isHidden && $0.isEnabled }
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

/// Task-1 seam helper: everything in this file drives terminal panes, so the
/// concrete surface is one force-cast away — a crash here means a test built a
/// pane kind it does not handle, which deserves to fail loudly.
private extension PaneContainerView {
    var terminalSurface: TerminalSurfaceView { surface as! TerminalSurfaceView }
}

