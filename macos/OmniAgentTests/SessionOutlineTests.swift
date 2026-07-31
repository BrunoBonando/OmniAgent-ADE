import XCTest
@testable import OmniAgent

/// Ported from `ui/src/state/sessionGroups.test.ts` — the grouping, the
/// ordering, and the "lowest free number" naming rule.
final class SessionOutlineTests: XCTestCase {
    func testPanesGroupByProjectThenSessionInFirstSeenOrder() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "alpha", group: "g1"),
                pane("b", project: "beta", group: "g9"),
                pane("c", project: "alpha", group: "g2"),
                pane("d", project: "alpha", group: "g1"),
            ],
            focusedPaneID: nil
        )

        XCTAssertEqual(tree.map(\.project), ["alpha", "beta"], "projects keep first-seen order")
        XCTAssertEqual(tree[0].sessions.map(\.id), ["g1", "g2"], "so do sessions")
        XCTAssertEqual(tree[0].sessions[0].paneIDs, ["a", "d"], "a later pane joins its known session")
        XCTAssertEqual(tree[1].sessions.map(\.paneIDs), [["b"]])
    }

    func testExactlyOneSessionIsCurrentAndItIsTheOneHoldingTheFocusedPane() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "alpha", group: "g1"),
                pane("b", project: "alpha", group: "g2"),
                pane("c", project: "beta", group: "g3"),
            ],
            focusedPaneID: "b"
        )

        XCTAssertEqual(tree.flatMap(\.sessions).filter(\.isCurrent).map(\.id), ["g2"])
    }

    func testNothingIsCurrentWhenNoPaneHasFocus() {
        let tree = SessionOutline.group([pane("a", project: "alpha", group: "g1")], focusedPaneID: nil)
        XCTAssertFalse(tree[0].sessions[0].isCurrent)
    }

    func testAStoredNameIsShownAndAnUnnamedSessionGetsTheLowestFreeNumber() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "alpha", group: "g1", groupLabel: "Session 2"),
                pane("b", project: "alpha", group: "g2"),
                pane("c", project: "alpha", group: "g3"),
            ],
            focusedPaneID: nil
        )

        XCTAssertEqual(
            tree[0].sessions.map(\.label),
            ["Session 2", "Session 1", "Session 3"],
            "a derived default never collides with a name someone actually typed"
        )
        XCTAssertEqual(tree[0].sessions.map(\.name), ["Session 2", nil, nil])
    }

    func testABlankGroupLabelCountsAsUnnamedRatherThanAsAnEmptyName() {
        let tree = SessionOutline.group(
            [pane("a", project: "alpha", group: "g1", groupLabel: "   ")],
            focusedPaneID: nil
        )
        XCTAssertNil(tree[0].sessions[0].name)
        XCTAssertEqual(tree[0].sessions[0].label, "Session 1")
    }

    func testAHalfRenamedSessionReadsFromWhicheverPaneCarriesTheName() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "alpha", group: "g1"),
                pane("b", project: "alpha", group: "g1", groupLabel: "Build"),
            ],
            focusedPaneID: nil
        )
        XCTAssertEqual(tree[0].sessions[0].label, "Build")
    }

    func testASessionsRootIsItsFirstPanesDirectory() {
        let tree = SessionOutline.group(
            [
                pane("a", project: "alpha", group: "g1", cwd: "/alpha"),
                pane("b", project: "alpha", group: "g1", cwd: "/alpha/sub"),
            ],
            focusedPaneID: nil
        )
        XCTAssertEqual(tree[0].sessions[0].cwd, "/alpha")
    }

    func testTheNextSessionNameFillsTheLowestGapAndNeverClimbsForever() {
        let panes = [
            pane("a", project: "alpha", group: "g1", groupLabel: "Session 1"),
            pane("b", project: "alpha", group: "g3", groupLabel: "Session 3"),
        ]
        XCTAssertEqual(SessionOutline.nextSessionName(panes, project: "alpha"), "Session 2")
        XCTAssertEqual(
            SessionOutline.nextSessionName(panes, project: "beta"),
            "Session 1",
            "another project's numbering is its own"
        )
        XCTAssertEqual(SessionOutline.nextSessionName([], project: "alpha"), "Session 1")
    }

    func testAPaneRowPrefersItsOwnNameThenItsLiveTitleThenItsEngine() {
        XCTAssertEqual(
            SessionOutline.paneLabel(pane("a", project: "p", group: "g", label: "migrate")),
            "migrate"
        )
        var titled = pane("a", project: "p", group: "g")
        titled.title = "~/src"
        XCTAssertEqual(SessionOutline.paneLabel(titled), "~/src")
        XCTAssertEqual(SessionOutline.paneLabel(pane("a", project: "p", group: "g")), "shell")
    }

    func testAPaneWithNoProjectIsNamedRatherThanShownAsABlankRow() {
        XCTAssertEqual(SessionOutline.projectLabel(""), "No project")
        XCTAssertEqual(SessionOutline.projectLabel("alpha"), "alpha")
    }

    private func pane(
        _ id: String,
        project: String,
        group: String,
        groupLabel: String? = nil,
        cwd: String = "/",
        label: String? = nil
    ) -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: groupLabel,
            project: project,
            engine: .shell,
            cwd: cwd,
            label: label
        )
    }
}

/// The `NSOutlineView` half: the rows it builds and the intents it raises.
final class SessionOutlineViewTests: XCTestCase {
    func testTheOutlineShowsEveryProjectSessionAndPaneExpanded() {
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))

        outline.reload(
            panes: [
                pane("a", project: "alpha", group: "g1", groupLabel: "Build"),
                pane("b", project: "alpha", group: "g1", groupLabel: "Build"),
                pane("c", project: "beta", group: "g2"),
            ],
            focusedPaneID: "b"
        )

        // 2 projects + 2 sessions + 3 panes, everything disclosed.
        XCTAssertEqual(outline.outlineView.numberOfRows, 7)
        XCTAssertEqual(
            outline.outlineView.item(atRow: 0) as? SessionOutlineView.OutlineItem,
            .project("alpha")
        )
        XCTAssertEqual(
            outline.outlineView.item(atRow: 1) as? SessionOutlineView.OutlineItem,
            .session(project: "alpha", group: "g1")
        )
        XCTAssertEqual(outline.outlineView.item(atRow: 2) as? SessionOutlineView.OutlineItem, .pane("a"))
    }

    func testTheFocusedPanesRowIsSelectedAndSelectingBackDoesNotEchoAnIntent() {
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        var selected: [String] = []
        outline.onSelectPane = { selected.append($0) }

        outline.reload(panes: [pane("a", project: "alpha", group: "g1"), pane("b", project: "alpha", group: "g1")], focusedPaneID: "b")

        let row = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.pane("b"))
        XCTAssertEqual(outline.outlineView.selectedRow, row)
        XCTAssertTrue(selected.isEmpty, "the outline reflecting focus is not a request to change it")
    }

    func testClickingAPaneRowAsksForThatPane() {
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        var selected: [String] = []
        outline.onSelectPane = { selected.append($0) }
        outline.reload(panes: [pane("a", project: "alpha", group: "g1"), pane("b", project: "alpha", group: "g1")], focusedPaneID: "a")

        let row = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.pane("b"))
        outline.outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)

        XCTAssertEqual(selected, ["b"])
    }

    func testASessionRowAsksForItsFirstPaneAndAProjectRowIsNotSelectable() {
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        var sessions: [String] = []
        outline.onSelectSession = { sessions.append($0.paneIDs.first ?? "") }
        outline.reload(panes: [pane("a", project: "alpha", group: "g1"), pane("b", project: "alpha", group: "g1")], focusedPaneID: nil)

        let sessionRow = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.session(project: "alpha", group: "g1"))
        outline.outlineView.selectRowIndexes(IndexSet(integer: sessionRow), byExtendingSelection: false)
        XCTAssertEqual(sessions, ["a"])

        let projectRow = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.project("alpha"))
        XCTAssertFalse(
            outline.outlineView(outline.outlineView, shouldSelectItem: SessionOutlineView.OutlineItem.project("alpha")),
            "a project row groups, it never navigates"
        )
        XCTAssertGreaterThanOrEqual(projectRow, 0)
    }

    func testDoubleClickingASessionRowStartsARenameAndOtherRowsDoNot() {
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        outline.reload(panes: [pane("a", project: "alpha", group: "g1", groupLabel: "Build")], focusedPaneID: "a")

        let projectRow = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.project("alpha"))
        let sessionRow = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.session(project: "alpha", group: "g1"))
        let paneRow = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.pane("a"))

        XCTAssertTrue(outline.beginRenamingSession(atRow: sessionRow))
        XCTAssertFalse(outline.beginRenamingSession(atRow: projectRow), "a project row is not a session name")
        XCTAssertFalse(outline.beginRenamingSession(atRow: paneRow), "neither is a pane row")
        XCTAssertFalse(outline.beginRenamingSession(atRow: -1), "nor is empty space below the list")
    }

    func testARenamedSessionRowReportsTheTrimmedNameAndNeverABlankOne() {
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        var renames: [String] = []
        outline.onRenameSession = { _, name in renames.append(name) }
        outline.reload(panes: [pane("a", project: "alpha", group: "g1", groupLabel: "Build")], focusedPaneID: "a")
        let row = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.session(project: "alpha", group: "g1"))
        let cell = outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionOutlineRowView

        cell?.commitRename(named: "  Migration  ")
        cell?.commitRename(named: "   ")

        XCTAssertEqual(renames, ["Migration"])
    }

    func testEveryRowCarriesAnAccessibilityLabelThatNamesWhatItIs() throws {
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        outline.reload(panes: [pane("a", project: "alpha", group: "g1", groupLabel: "Build")], focusedPaneID: "a")

        let labels = (0..<outline.outlineView.numberOfRows).compactMap {
            (outline.outlineView.view(atColumn: 0, row: $0, makeIfNecessary: true) as? SessionOutlineRowView)?
                .accessibilityLabel()
        }

        XCTAssertEqual(labels, ["Workspace alpha", "Build, current session", "shell, focused pane"])
    }

    private func pane(_ id: String, project: String, group: String, groupLabel: String? = nil) -> PaneDescriptor {
        PaneDescriptor(sessionID: id, group: group, groupLabel: groupLabel, project: project, engine: .shell, cwd: "/")
    }
}
