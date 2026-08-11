import AppKit
import XCTest

@testable import OmniAgent

/// The design's shell: the two-level slide, the destination switch, the picker
/// the slide reveals, and the sessions tree that hangs off Terminals.
final class WorkspaceShellTests: XCTestCase {
    private func makeSidebar() -> WorkspaceSidebarView {
        let sidebar = WorkspaceSidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private func project(_ id: String, _ label: String, _ path: String? = nil) -> BrainProjectSummary {
        BrainProjectSummary(id: id, label: label, path: path)
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

    /// The design nests the sessions tree under Terminals, so it is only on
    /// screen for that destination.
    func testTheSessionsTreeOnlyShowsUnderTerminals() {
        let sidebar = makeSidebar()
        sidebar.applyDestination(.terminals)
        XCTAssertFalse(sidebar.sessionsTree.isHiddenOrHasHiddenAncestor)
        sidebar.applyDestination(.dashboard)
        XCTAssertTrue(sidebar.sessionsTree.isHiddenOrHasHiddenAncestor)
    }

    /// Every destination row exists, in the design's order.
    func testNavRowsMatchTheDesignOrder() {
        XCTAssertEqual(
            makeSidebar().navRows.map(\.destination),
            [.dashboard, .board, .terminals, .files]
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

    /// One pane is printed as a bare count; more than one gets the grid shape.
    func testTheGridBadgeMatchesTheLadder() {
        XCTAssertEqual(SessionRowView.badgeText(paneCount: 1), "1")
        XCTAssertEqual(SessionRowView.badgeText(paneCount: 2), "1×2")
        XCTAssertEqual(SessionRowView.badgeText(paneCount: 4), "2×2")
    }

    func testStatusDotColoursFollowTheDesign() {
        XCTAssertEqual(ShellDotsView.color(for: .thinking), ShellPalette.blue)
        XCTAssertEqual(ShellDotsView.color(for: .awaitingApproval), ShellPalette.amber)
        XCTAssertEqual(ShellDotsView.color(for: .ready), ShellPalette.green)
        XCTAssertEqual(ShellDotsView.color(for: .error), ShellPalette.red)
        XCTAssertEqual(ShellDotsView.color(for: nil), ShellPalette.idle)
    }

    /// Only the working agent breathes; a finished one would be noise.
    func testOnlyThinkingPulses() {
        XCTAssertTrue(ShellDotsView.pulses(.thinking))
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
