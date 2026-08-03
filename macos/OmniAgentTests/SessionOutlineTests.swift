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

/// An `NSView` that accepts first-responder status and then refuses to give
/// it up — the only reliable way to make `NSWindow.makeFirstResponder` return
/// `false` in a test, which is the case `beginRename`'s latch has to survive.
private final class StubbornResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override func resignFirstResponder() -> Bool { false }
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

        XCTAssertTrue(outline.beginRenamingSession(atRow: row))
        cell?.commitRename(named: "  Migration  ")
        XCTAssertTrue(outline.beginRenamingSession(atRow: row))
        cell?.commitRename(named: "   ")

        XCTAssertEqual(renames, ["Migration"])
    }

    func testAReloadWhileRenamingIsDeferredNotDroppedSoAnOpenFieldSurvives() throws {
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        outline.reload(panes: [pane("a", project: "alpha", group: "g1", groupLabel: "Build")], focusedPaneID: "a")
        let row = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.session(project: "alpha", group: "g1"))
        let cell = try XCTUnwrap(outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionOutlineRowView)
        XCTAssertTrue(outline.beginRenamingSession(atRow: row))
        XCTAssertTrue(outline.isRenaming)

        // A background pane repainting its OSC title fires this several times
        // a second; each one used to tear the open field down.
        for title in ["~/src", "~/src/deep", "~/"] {
            var busy = pane("a", project: "alpha", group: "g1", groupLabel: "Build")
            busy.title = title
            outline.reload(panes: [busy, pane("b", project: "alpha", group: "g1", groupLabel: "Build")], focusedPaneID: "a")
        }

        XCTAssertEqual(outline.outlineView.numberOfRows, 3, "the outline held still while the field was open")
        XCTAssertTrue(
            outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: false) === cell,
            "and the cell being edited was never rebuilt"
        )

        cell.commitRename(named: "Migration")

        XCTAssertFalse(outline.isRenaming)
        XCTAssertEqual(
            outline.outlineView.numberOfRows,
            3,
            "the reload must NOT run inline: commitRename can be reached from "
                + "controlTextDidEndEditing:, while AppKit is still tearing the field editor down"
        )

        flushMainQueue()

        XCTAssertEqual(
            outline.outlineView.numberOfRows,
            4,
            "the newest deferred reload lands on the next runloop turn — deferred, never dropped"
        )
    }

    /// The reload released by a rename is re-read at the moment it runs, not
    /// captured when editing ended, so a reload that lands in between wins.
    func testTheNewestReloadWinsWhenOneArrivesWhileTheDeferredOneIsInFlight() throws {
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        outline.reload(panes: [pane("a", project: "alpha", group: "g1", groupLabel: "Build")], focusedPaneID: "a")
        let row = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.session(project: "alpha", group: "g1"))
        let cell = try XCTUnwrap(outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionOutlineRowView)

        XCTAssertTrue(outline.beginRenamingSession(atRow: row))
        outline.reload(
            panes: [pane("a", project: "alpha", group: "g1"), pane("b", project: "alpha", group: "g1")],
            focusedPaneID: "a"
        )
        cell.commitRename(named: "Migration")
        // Lands after editing ended but before the deferred block runs.
        outline.reload(
            panes: [
                pane("a", project: "alpha", group: "g1"),
                pane("b", project: "alpha", group: "g1"),
                pane("c", project: "alpha", group: "g2"),
            ],
            focusedPaneID: "a"
        )
        flushMainQueue()

        // 1 project + 2 sessions + 3 panes.
        XCTAssertEqual(outline.outlineView.numberOfRows, 6, "the stale deferred reload must not win")
    }

    /// The `isEditing` latch is what suspends the outline's reloads, so
    /// latching it when focus never moved into the field would freeze the
    /// outline with no field to type in and no gesture that ends editing.
    func testARenameThatCannotTakeFocusIsRefusedRatherThanLatched() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        window.contentView?.addSubview(outline)
        outline.reload(panes: [pane("a", project: "alpha", group: "g1", groupLabel: "Build")], focusedPaneID: "a")
        let row = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.session(project: "alpha", group: "g1"))
        let cell = try XCTUnwrap(outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionOutlineRowView)

        // A real AppKit refusal: the current first responder declines to
        // resign, so `makeFirstResponder` returns false.
        let stubborn = StubbornResponderView()
        window.contentView?.addSubview(stubborn)
        XCTAssertTrue(window.makeFirstResponder(stubborn))

        XCTAssertFalse(cell.beginRename(), "the row must report that the field did not open")
        XCTAssertFalse(outline.beginRenamingSession(atRow: row), "and so must the outline")
        XCTAssertFalse(outline.isRenaming, "so reloads are never suspended by a rename that never began")

        // The outline is still live: a later reload applies immediately.
        outline.reload(
            panes: [pane("a", project: "alpha", group: "g1"), pane("b", project: "alpha", group: "g1")],
            focusedPaneID: "a"
        )
        XCTAssertEqual(outline.outlineView.numberOfRows, 4)
    }

    /// Drains one turn of the main queue. Every test here runs on the main
    /// thread, so `DispatchQueue.main.async` work does not run until the
    /// runloop spins; waiting on an expectation enqueued behind it does that.
    private func flushMainQueue(file: StaticString = #filePath, line: UInt = #line) {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testAnAbandonedRenameStillReleasesTheDeferredReload() {
        let outline = SessionOutlineView(frame: NSRect(x: 0, y: 0, width: 240, height: 400))
        outline.reload(panes: [pane("a", project: "alpha", group: "g1", groupLabel: "Build")], focusedPaneID: "a")
        let row = outline.outlineView.row(forItem: SessionOutlineView.OutlineItem.session(project: "alpha", group: "g1"))
        let cell = outline.outlineView.view(atColumn: 0, row: row, makeIfNecessary: true) as? SessionOutlineRowView
        outline.beginRenamingSession(atRow: row)
        outline.reload(panes: [pane("a", project: "alpha", group: "g1"), pane("b", project: "alpha", group: "g1")], focusedPaneID: "a")

        // A blank name is rejected as a rename, but editing has still ended.
        cell?.commitRename(named: "   ")

        XCTAssertFalse(outline.isRenaming)
        flushMainQueue()
        XCTAssertEqual(outline.outlineView.numberOfRows, 4, "the outline is not frozen forever")
    }

    func testARowIsReLabelledInPlaceAndNeverOverwritesAnOpenNameField() throws {
        // Each kind gets its own reuse identifier, so AppKit can only hand a
        // recycled row back to a row of the same shape.
        XCTAssertEqual(
            Set([
                SessionOutlineRowView.Kind.project.reuseIdentifier,
                SessionOutlineRowView.Kind.session(isCurrent: true).reuseIdentifier,
                SessionOutlineRowView.Kind.pane(isFocused: true).reuseIdentifier,
            ]).count,
            3
        )
        XCTAssertEqual(
            SessionOutlineRowView.Kind.session(isCurrent: true).reuseIdentifier,
            SessionOutlineRowView.Kind.session(isCurrent: false).reuseIdentifier,
            "the current marker is typography, not a different shape of row"
        )

        let row = SessionOutlineRowView(kind: .session(isCurrent: false))
        row.apply(title: "Build", detail: "1 pane", kind: .session(isCurrent: false))
        XCTAssertEqual(row.textField?.stringValue, "Build")

        row.apply(title: "Build", detail: "2 panes", kind: .session(isCurrent: true))
        XCTAssertEqual(row.textField?.stringValue, "Build", "re-labelled in place")

        row.beginRename()
        row.textField?.stringValue = "Migra"
        row.apply(title: "Build", detail: "3 panes", kind: .session(isCurrent: true))

        XCTAssertEqual(
            row.textField?.stringValue,
            "Migra",
            "a reload that slipped through must never overwrite what is being typed"
        )
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

    func testAFreshSessionGroupIDSurvivesARelaunchAndNeverRepeats() {
        let ids = (0..<50).map { _ in SessionOutline.newSessionGroupID() }
        XCTAssertEqual(Set(ids).count, 50, "two sessions started in the same millisecond still differ")
        XCTAssertTrue(ids.allSatisfy { SessionIdentifier.isValid($0) }, "a group id the backend rejects would un-group its panes")
    }
}
