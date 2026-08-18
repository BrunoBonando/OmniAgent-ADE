import AppKit
import XCTest

@testable import OmniAgent

/// The design's shell: the two-level slide, the destination switch, the picker
/// the slide reveals, and the sessions tree that hangs off Terminals.
final class WorkspaceShellTests: XCTestCase {
    /// The seam persists to `UserDefaults`, so a dragging test would otherwise
    /// leave a stored height behind for the next run to inherit.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: WorkspaceSidebarView.dividerDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WorkspaceSidebarView.dividerDefaultsKey)
        super.tearDown()
    }

    private func makeSidebar() -> WorkspaceSidebarView {
        let sidebar = WorkspaceSidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private func project(_ id: String, _ label: String, _ path: String? = nil) -> BrainProjectSummary {
        BrainProjectSummary(id: id, label: label, path: path)
    }

    // MARK: - The FILES divider

    /// Dragging the seam up must stop while every nav row is still on screen —
    /// the user's rule is "the highest it can go is where Dash, Board,
    /// Terminals and Files are still visible".
    func testTheDividerStopsWhileEveryNavRowIsStillVisible() {
        let sidebar = makeSidebar()
        let floor = sidebar.minimumMenuHeight
        XCTAssertGreaterThan(floor, 0)

        // Shove it far past the top.
        sidebar.splitter.onDrag?(-10_000)
        sidebar.layoutSubtreeIfNeeded()

        XCTAssertEqual(sidebar.menuHeight.constant, floor, accuracy: 0.5)
        // And that floor really does account for all four rows, not just some.
        let rowHeights = sidebar.navRows.reduce(0.0) { total, row in
            total + max(row.fittingSize.height, row.intrinsicContentSize.height)
        }
        XCTAssertEqual(sidebar.navRows.count, WorkspaceDestination.allCases.count)
        XCTAssertGreaterThanOrEqual(floor, rowHeights)
    }

    /// And dragging it down must leave the FILES half something to show.
    func testTheDividerAlwaysLeavesRoomForTheFilesList() {
        let sidebar = makeSidebar()
        sidebar.splitter.onDrag?(10_000)
        sidebar.layoutSubtreeIfNeeded()

        let available = sidebar.bounds.height
            - sidebar.backRow.fittingSize.height
            - ShellSplitterView.grabThickness
        XCTAssertLessThanOrEqual(
            sidebar.menuHeight.constant,
            available - WorkspaceSidebarView.minimumFilesHeight + 0.5
        )
    }

    /// Shrinking the window must not leave the divider parked below a floor
    /// that was legal when it was dragged there.
    func testShrinkingTheSidebarReClampsTheDivider() {
        let sidebar = makeSidebar()
        sidebar.splitter.onDrag?(10_000)
        sidebar.layoutSubtreeIfNeeded()
        let tall = sidebar.menuHeight.constant

        sidebar.frame = NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 320)
        sidebar.layoutSubtreeIfNeeded()

        XCTAssertLessThan(sidebar.menuHeight.constant, tall, "the divider moved up with the window")
        let available = 320.0 - sidebar.backRow.fittingSize.height - ShellSplitterView.grabThickness
        XCTAssertLessThanOrEqual(
            sidebar.menuHeight.constant,
            max(sidebar.minimumMenuHeight, available - WorkspaceSidebarView.minimumFilesHeight) + 0.5
        )
    }

    /// Nobody has dragged it yet, so it splits the sidebar down the middle.
    func testTheDividerStartsHalfway() {
        let sidebar = makeSidebar()
        let available = sidebar.bounds.height
            - sidebar.backRow.fittingSize.height
            - ShellSplitterView.grabThickness
        XCTAssertEqual(sidebar.menuHeight.constant, available / 2, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(sidebar.menuHeight.constant, sidebar.minimumMenuHeight)
    }

    /// And once dragged it is remembered, at the position it was left in.
    func testTheDividerIsRememberedAcrossLaunches() {
        let dragged = makeSidebar()
        drag(dragged.splitter, fromWindowY: 400, toWindowY: 340)
        dragged.layoutSubtreeIfNeeded()
        let expected = dragged.menuHeight.constant

        let relaunched = makeSidebar()
        XCTAssertTrue(relaunched.hasUserAdjustedDivider)
        XCTAssertEqual(relaunched.menuHeight.constant, expected, accuracy: 0.5)
    }

    /// At the seam's floor the four nav rows fill the half, so the sessions
    /// tree only exists at all if the whole menu scrolls.
    func testTheMenuHalfScrollsSoSessionsAreReachableAtTheFloor() {
        let sidebar = makeSidebar()
        sidebar.showWorkspace(project("p1", "Project"), animated: false)
        sidebar.applyDestination(.terminals)
        sidebar.reloadSessions(
            panes: (0..<12).map { index in pane("pane-\(index)", group: "g\(index)") },
            focusedPaneID: nil,
            statuses: [:],
            project: "p1"
        )
        sidebar.splitter.onDrag?(-10_000)
        sidebar.layoutSubtreeIfNeeded()

        guard let scroll = sidebar.menuScroll else { return XCTFail("no menu scroll view") }
        XCTAssertEqual(sidebar.menuHeight.constant, sidebar.minimumMenuHeight, accuracy: 0.5)
        XCTAssertGreaterThan(
            scroll.documentView?.fittingSize.height ?? 0,
            scroll.contentView.bounds.height,
            "the menu has more content than height — which is only usable if it scrolls"
        )
        XCTAssertTrue(scroll.hasVerticalScroller)
    }

    /// The sessions overview belongs to Terminals, so it hangs directly off
    /// that row rather than trailing the whole menu.
    func testTheSessionsListSitsUnderTerminals() throws {
        let sidebar = makeSidebar()
        sidebar.showWorkspace(project("p1", "Project"), animated: false)
        sidebar.applyDestination(.terminals)
        sidebar.reloadSessions(
            panes: [pane("pane-1", group: "g1")],
            focusedPaneID: "pane-1",
            statuses: [:],
            project: "p1"
        )
        sidebar.layoutSubtreeIfNeeded()

        func position(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: sidebar).midY }
        let dash = try XCTUnwrap(sidebar.navRows.first { $0.destination == .dashboard })
        let terminals = try XCTUnwrap(sidebar.navRows.first { $0.destination == .terminals })
        XCTAssertFalse(sidebar.sessionsContainer.isHidden)

        // Which way "further down the menu" runs in this coordinate space is
        // read off a pair whose order is not in question, rather than assumed.
        let downwards: (CGFloat, CGFloat) -> Bool = position(terminals) > position(dash) ? (>) : (<)
        XCTAssertTrue(
            downwards(position(sidebar.sessionsContainer), position(terminals)),
            "the sessions list hangs off Terminals"
        )
    }

    /// The seam is a handle, not a hairline: a 1pt hit target is unusable.
    func testTheDividerIsGrabbableAndSaysSo() {
        let sidebar = makeSidebar()
        XCTAssertGreaterThan(ShellSplitterView.grabThickness, ShellSplitterView.visualThickness)
        XCTAssertEqual(sidebar.splitter.accessibilityRole(), .splitter)
    }

    /// Driven through real mouse events rather than by calling `onDrag`
    /// directly — the whole bug lived in `mouseDragged`, so every test that
    /// called the closure agreed with it. The seam measured the drag in its
    /// own bounds (an origin that moves as the drag resizes the halves) and
    /// applied it with a flipped view's sign, which this view does not
    /// have. It therefore travelled away from the pointer, further each
    /// event, and pinned itself to a limit on the first twitch.
    func testDraggingTheSeamDownGrowsTheMenuAndShrinksTheFilesList() {
        let sidebar = makeSidebar()
        let menuBefore = sidebar.menuHeight.constant
        let filesBefore = sidebar.filesTree.frame.height
        XCTAssertGreaterThan(filesBefore, 0, "the files half must actually be laid out")

        drag(sidebar.splitter, fromWindowY: 400, toWindowY: 340) // 60pt down
        sidebar.layoutSubtreeIfNeeded()

        XCTAssertEqual(sidebar.menuHeight.constant, menuBefore + 60, accuracy: 0.5)
        XCTAssertEqual(
            sidebar.filesTree.frame.height,
            filesBefore - 60,
            accuracy: 1,
            "the drag has to actually resize the files list, not just a constraint constant"
        )
    }

    func testDraggingTheSeamUpShrinksTheMenuAndGrowsTheFilesList() {
        let sidebar = makeSidebar()
        // Move it down first so there is room to travel in both directions.
        drag(sidebar.splitter, fromWindowY: 400, toWindowY: 300)
        sidebar.layoutSubtreeIfNeeded()
        let menuBefore = sidebar.menuHeight.constant
        let filesBefore = sidebar.filesTree.frame.height

        drag(sidebar.splitter, fromWindowY: 300, toWindowY: 340) // 40pt up
        sidebar.layoutSubtreeIfNeeded()

        XCTAssertEqual(sidebar.menuHeight.constant, menuBefore - 40, accuracy: 0.5)
        XCTAssertEqual(sidebar.filesTree.frame.height, filesBefore + 40, accuracy: 1)
    }

    private func drag(
        _ splitter: ShellSplitterView,
        fromWindowY start: CGFloat,
        toWindowY end: CGFloat
    ) {
        splitter.mouseDown(with: mouseEvent(.leftMouseDown, windowY: start))
        splitter.mouseDragged(with: mouseEvent(.leftMouseDragged, windowY: end))
        splitter.mouseUp(with: mouseEvent(.leftMouseUp, windowY: end))
    }

    private func mouseEvent(_ type: NSEvent.EventType, windowY: CGFloat) -> NSEvent {
        // swiftlint:disable:next force_unwrapping
        NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: 10, y: windowY),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func pane(
        _ id: String,
        group: String,
        project: String = "p1",
        engine: Engine = .claude,
        title: String = "term"
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: group,
            title: title,
            project: project,
            engine: engine,
            cwd: "/tmp"
        )
    }

    // MARK: - The slide

    func testStartsOnThePicker() {
        XCTAssertTrue(makeSidebar().isShowingPicker)
    }

    func testOpeningAWorkspaceSlidesToItsNav() {
        let sidebar = makeSidebar()
        sidebar.showWorkspace(project("p1", "api"), animated: false)
        XCTAssertFalse(sidebar.isShowingPicker)
        XCTAssertEqual(sidebar.selectedWorkspace?.id, "p1")
    }

    func testBackReturnsToThePicker() {
        let sidebar = makeSidebar()
        sidebar.showWorkspace(project("p1", "api"), animated: false)
        sidebar.showPicker(animated: false)
        XCTAssertTrue(sidebar.isShowingPicker)
    }

    // MARK: - Destinations

    func testTerminalsIsTheDefaultDestination() {
        XCTAssertEqual(makeSidebar().destination, .terminals)
    }

    func testSelectingADestinationLightsExactlyOneRow() {
        let sidebar = makeSidebar()
        sidebar.applyDestination(.board)
        XCTAssertEqual(sidebar.destination, .board)
        let lit = sidebar.navRows.filter { $0.destination == sidebar.destination }
        XCTAssertEqual(lit.count, 1)
    }

    /// The sessions tree hangs off Terminals, but stays on screen for every
    /// destination — the sidebar always shows at least the session list.
    func testTheSessionsTreeStaysVisibleAcrossDestinations() {
        let sidebar = makeSidebar()
        sidebar.applyDestination(.terminals)
        XCTAssertFalse(sidebar.sessionsTree.isHiddenOrHasHiddenAncestor)
        sidebar.applyDestination(.dashboard)
        XCTAssertFalse(sidebar.sessionsTree.isHiddenOrHasHiddenAncestor)
        sidebar.applyDestination(.board)
        XCTAssertFalse(sidebar.sessionsTree.isHiddenOrHasHiddenAncestor)
    }

    /// Every destination row exists, in the design's order. No FILES button —
    /// the file tree still hangs off the sidebar's lower half, unconditionally.
    func testNavRowsMatchTheDesignOrder() {
        XCTAssertEqual(
            makeSidebar().navRows.map(\.destination),
            [.dashboard, .board, .terminals]
        )
    }

    /// The `.files` destination was a dead end — clicking it blanked the pane
    /// grid for a "Coming in a later step" placeholder. The editor pane
    /// replaces it, launched from the FILES *tree* instead, so the destination
    /// must never come back: nav rows are built straight off `allCases`.
    func testFilesDestinationIsGone() {
        XCTAssertEqual(
            WorkspaceDestination.allCases.map(\.rawValue),
            ["dashboard", "board", "terminals"]
        )
    }

    // MARK: - The picker

    func testThePickerRendersOneCardPerWorkspace() {
        let sidebar = makeSidebar()
        sidebar.setWorkspaces(
            [project("p1", "api"), project("p2", "web")],
            sessionCounts: ["p1": 2]
        )
        XCTAssertEqual(sidebar.picker.cards.map(\.workspace.id), ["p1", "p2"])
    }

    func testThePickerRebuildsRatherThanAppends() {
        let sidebar = makeSidebar()
        sidebar.setWorkspaces([project("p1", "api")], sessionCounts: [:])
        sidebar.setWorkspaces([project("p2", "web")], sessionCounts: [:])
        XCTAssertEqual(sidebar.picker.cards.map(\.workspace.id), ["p2"])
    }

    func testTheCardPrintsTheFolderNotTheWholePath() {
        XCTAssertEqual(WorkspaceCardView.folderName("/Users/me/Code/api"), "api")
        XCTAssertEqual(WorkspaceCardView.folderName(nil), "—")
    }

    func testTheBackRowAbbreviatesTheHomeDirectory() {
        let home = NSHomeDirectory()
        XCTAssertEqual(WorkspaceBackRowView.abbreviate("\(home)/Code/api"), "~/Code/api")
        XCTAssertEqual(WorkspaceBackRowView.abbreviate(nil), "—")
    }

    // MARK: - Workspace identity

    /// The tile colour has to survive a relaunch without being persisted, so
    /// the hash must be stable and in range.
    func testTheAvatarGradientIsStableAndInRange() {
        let first = ShellPalette.avatarGradient(forID: "omniagent-ade")
        let second = ShellPalette.avatarGradient(forID: "omniagent-ade")
        XCTAssertEqual(first.0, second.0)
        XCTAssertEqual(first.1, second.1)
        XCTAssertTrue(ShellPalette.avatarGradients.contains { $0.0 == first.0 && $0.1 == first.1 })
    }

    /// A long id used to overflow-trap before the hash was made wrapping.
    func testTheAvatarGradientSurvivesALongID() {
        let long = String(repeating: "workspace-", count: 64)
        XCTAssertTrue(
            ShellPalette.avatarGradients.contains {
                let picked = ShellPalette.avatarGradient(forID: long)
                return $0.0 == picked.0 && $0.1 == picked.1
            }
        )
    }

    func testInitialsTakeTwoWordsThenTwoLetters() {
        XCTAssertEqual(ShellPalette.initials("OmniAgent ADE"), "OA")
        XCTAssertEqual(ShellPalette.initials("voice"), "VO")
        XCTAssertEqual(ShellPalette.initials("bruno-studio"), "BS")
    }

    func testSessionCountLabelReadsAsProse() {
        XCTAssertEqual(ShellPalette.sessionCountLabel(0), "no sessions")
        XCTAssertEqual(ShellPalette.sessionCountLabel(1), "1 session")
        XCTAssertEqual(ShellPalette.sessionCountLabel(4), "4 sessions")
    }

    // MARK: - Sessions tree

    func testTerminalsSubtitleNamesTheOpenSessionAndItsGrid() {
        let sidebar = makeSidebar()
        let panes = (1...4).map { pane("t\($0)", group: "s1") }
        sidebar.reloadSessions(
            panes: panes,
            focusedPaneID: "t1",
            statuses: [:],
            project: "p1"
        )
        let terminals = sidebar.navRows.first { $0.destination == .terminals }
        // Four panes ladder to a 2x2, which the design prints as rows×cols.
        XCTAssertEqual(terminals?.subtitleText, "s1 · 2×2")
    }

    func testTerminalsSubtitleSaysSoWhenThereIsNoSession() {
        let sidebar = makeSidebar()
        sidebar.reloadSessions(panes: [], focusedPaneID: nil, statuses: [:], project: "p1")
        let terminals = sidebar.navRows.first { $0.destination == .terminals }
        XCTAssertEqual(terminals?.subtitleText, "no session")
    }

    /// Panes belonging to another workspace must not leak into this one's tree.
    func testTheTreeIsScopedToTheOpenWorkspace() {
        let sidebar = makeSidebar()
        sidebar.reloadSessions(
            panes: [pane("a", group: "s1", project: "p1"), pane("b", group: "s2", project: "p2")],
            focusedPaneID: "a",
            statuses: [:],
            project: "p1"
        )
        XCTAssertEqual(sidebar.sessionsTree.renderedSessionIDs, ["s1"])
    }

    /// The cap is eight terminals per session, and `addPane` refuses a ninth —
    /// so the "+ New terminal" row must not still be offering one.
    func testTheNewTerminalRowGoesAwayAtTheCap() {
        let sidebar = makeSidebar()
        sidebar.reloadSessions(
            panes: (1...PaneGrid.maxPanes).map { pane("t\($0)", group: "s1") },
            focusedPaneID: "t1",
            statuses: [:],
            project: "p1"
        )
        XCTAssertEqual(sidebar.sessionsTree.renderedPaneIDs.count, PaneGrid.maxPanes)
        XCTAssertFalse(sidebar.sessionsTree.showsNewTerminalRow)
    }

    /// One short of the cap it is still there — the row only goes at eight.
    func testTheNewTerminalRowStaysOneShortOfTheCap() {
        let sidebar = makeSidebar()
        sidebar.reloadSessions(
            panes: (1..<PaneGrid.maxPanes).map { pane("t\($0)", group: "s1") },
            focusedPaneID: "t1",
            statuses: [:],
            project: "p1"
        )
        XCTAssertTrue(sidebar.sessionsTree.showsNewTerminalRow)
    }

    /// A terminal blocked on a question wears the amber pill beside its engine
    /// icon — until it is the selected one, whose ask is on screen already.
    func testAnAwaitingTerminalRowWearsTheBadgeUntilSelected() {
        let awaiting = TerminalRowView(
            pane: pane("t1", group: "s1"), focused: false, status: .awaitingApproval
        )
        XCTAssertEqual(awaiting.awaitingBadge?.count, 1)
        let selected = TerminalRowView(
            pane: pane("t1", group: "s1"), focused: true, status: .awaitingApproval
        )
        XCTAssertNil(selected.awaitingBadge)
        let working = TerminalRowView(
            pane: pane("t1", group: "s1"), focused: false, status: .thinking
        )
        XCTAssertNil(working.awaitingBadge)
    }

    /// The session row aggregates its blocked terminals expanded or collapsed
    /// — a session needing attention must be findable from the session list
    /// alone, whether or not its terminal rows are showing.
    func testTheSessionRowAggregatesTheWaitingCountInEitherState() {
        for expanded in [true, false] {
            let row = SessionRowView(
                session: sessionNode(label: "s"),
                expanded: expanded,
                statuses: [.awaitingApproval],
                awaitingCount: 2
            )
            XCTAssertEqual(row.awaitingBadge?.count, 2)
        }
        let quiet = SessionRowView(
            session: sessionNode(label: "s"),
            expanded: false,
            statuses: [.ready],
            awaitingCount: 0
        )
        XCTAssertNil(quiet.awaitingBadge)
    }

    /// End to end through the tree: collapsing the current session rolls its
    /// blocked terminals into one count, minus the focused one — selected
    /// counts as seen, the same rule that clears a terminal row's own badge.
    func testACollapsedSessionCountsItsUnseenAsks() throws {
        let sidebar = makeSidebar()
        let panes = (1...3).map { pane("t\($0)", group: "s1") }
        let statuses: [String: RemoteSessionStatus] = [
            "t1": .awaitingApproval, "t2": .awaitingApproval, "t3": .awaitingApproval,
        ]
        sidebar.reloadSessions(
            panes: panes, focusedPaneID: "t1", statuses: statuses, project: "p1"
        )
        let row = try XCTUnwrap(sidebar.sessionsTree.descendant(SessionRowView.self))
        XCTAssertEqual(row.awaitingBadge?.count, 2, "three asks, one focused")
        row.onPress?()
        let collapsed = try XCTUnwrap(sidebar.sessionsTree.descendant(SessionRowView.self))
        XCTAssertEqual(collapsed.awaitingBadge?.count, 2, "and collapsing keeps the count")
    }

    func testStatusDotColoursFollowTheDesign() {
        XCTAssertEqual(ShellDotsView.color(for: .thinking), ShellPalette.blue)
        // Running a tool is the agent *working*, not the agent needing you:
        // it reads blue with the rest of the working family, so amber means
        // exactly one thing anywhere it appears — waiting on your input.
        XCTAssertEqual(ShellDotsView.color(for: .toolExecution), ShellPalette.blue)
        XCTAssertEqual(ShellDotsView.color(for: .awaitingApproval), ShellPalette.amber)
        XCTAssertEqual(ShellDotsView.color(for: .ready), ShellPalette.green)
        XCTAssertEqual(ShellDotsView.color(for: .error), ShellPalette.red)
        XCTAssertEqual(ShellDotsView.color(for: nil), ShellPalette.idle)
    }

    /// Only a working agent breathes; a finished one would be noise. Running a
    /// tool is working, so its dot breathes with thinking's.
    func testOnlyTheWorkingStatusesPulse() {
        XCTAssertTrue(ShellDotsView.pulses(.thinking))
        XCTAssertTrue(ShellDotsView.pulses(.toolExecution))
        XCTAssertFalse(ShellDotsView.pulses(.ready))
        XCTAssertFalse(ShellDotsView.pulses(nil))
    }

    // MARK: - Rename

    /// Renaming used to live on `SessionOutlineView`; it has to keep working
    /// now that the design's own rows replaced it.
    func testCommittingARenameReportsTheNewName() {
        let row = SessionRowView(
            session: sessionNode(label: "old"),
            expanded: true,
            statuses: []
        )
        var reported: String?
        row.onRename = { reported = $0 }
        row.beginRenaming()
        row.renameField.stringValue = "new name"
        row.commitRenameForTesting()
        XCTAssertEqual(reported, "new name")
    }

    /// An empty name is a cancel, not a request to erase the label.
    func testAnEmptyRenameIsIgnored() {
        let row = SessionRowView(
            session: sessionNode(label: "old"),
            expanded: true,
            statuses: []
        )
        var reported: String?
        row.onRename = { reported = $0 }
        row.beginRenaming()
        row.renameField.stringValue = "   "
        row.commitRenameForTesting()
        XCTAssertNil(reported)
    }

    private func sessionNode(label: String) -> SessionGroupNode {
        SessionGroupNode(
            id: "s1",
            project: "p1",
            name: label,
            label: label,
            cwd: "/tmp",
            paneIDs: ["t1"],
            isCurrent: true
        )
    }

    // MARK: - Where a terminal starts

    /// A pane already inside the workspace keeps exactly where it is.
    func testAPaneInsideTheWorkspaceKeepsItsDirectory() {
        XCTAssertTrue(WorkspaceWindowController.isInside("/w/api/macos", "/w/api"))
        XCTAssertTrue(WorkspaceWindowController.isInside("/w/api", "/w/api"))
        XCTAssertTrue(WorkspaceWindowController.isInside("/w/api/", "/w/api"))
    }

    /// A stale home directory from an older layout is not "in the workspace",
    /// and neither is a sibling folder with a shared prefix.
    func testAStaleOrSiblingDirectoryIsNotInsideTheWorkspace() {
        XCTAssertFalse(WorkspaceWindowController.isInside("/Users/me", "/w/api"))
        XCTAssertFalse(WorkspaceWindowController.isInside("/w/api-old", "/w/api"))
        XCTAssertFalse(WorkspaceWindowController.isInside("", "/w/api"))
    }

    // MARK: - Files tree rows

    func testFileBadgesMatchTheDesignsLetters() {
        XCTAssertEqual(WorkspaceFileRowView.badgeText(file(badge: .modified)), "M")
        XCTAssertEqual(WorkspaceFileRowView.badgeText(file(badge: .added)), "A")
        XCTAssertEqual(WorkspaceFileRowView.badgeText(file(badge: .deleted)), "D")
        XCTAssertEqual(WorkspaceFileRowView.badgeText(file(badge: nil)), "")
    }

    /// A directory prints how many changed files are under it, and prints
    /// nothing at all when the answer is zero.
    func testDirectoryBadgeCountsChangesBeneathIt() {
        var directory = WorkspaceFileNode(
            name: "src",
            url: URL(fileURLWithPath: "/tmp/src"),
            isDirectory: true
        )
        directory.changedCount = 3
        XCTAssertEqual(WorkspaceFileRowView.badgeText(directory), "3")
        directory.changedCount = 0
        XCTAssertEqual(WorkspaceFileRowView.badgeText(directory), "")
    }

    private func file(badge: GitBadge?) -> WorkspaceFileNode {
        var node = WorkspaceFileNode(
            name: "token.service.ts",
            url: URL(fileURLWithPath: "/tmp/token.service.ts"),
            isDirectory: false
        )
        node.gitBadge = badge
        return node
    }
}

private extension NSView {
    /// Depth-first search for the tree tests — the rows live in a private
    /// stack, and walking the view tree is how a test sees what a user sees.
    func descendant<View: NSView>(_ type: View.Type) -> View? {
        for subview in subviews {
            if let match = subview as? View { return match }
            if let match = subview.descendant(type) { return match }
        }
        return nil
    }
}
