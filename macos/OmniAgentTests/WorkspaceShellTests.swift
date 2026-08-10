import AppKit
import XCTest

@testable import OmniAgent

/// The design's step-1 shell: the two-level slide, the destination switch, and
/// the picker the slide reveals.
final class WorkspaceShellTests: XCTestCase {
    private func makeSidebar() -> WorkspaceSidebarView {
        let sidebar = WorkspaceSidebarView(outline: SessionOutlineView())
        sidebar.frame = NSRect(x: 0, y: 0, width: 240, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private func project(_ id: String, _ label: String, _ path: String? = nil) -> BrainProjectSummary {
        BrainProjectSummary(id: id, label: label, path: path)
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

    /// No workspace is not a nav to slide to — it is the first-run screen.
    func testNoWorkspacePinsThePicker() {
        let sidebar = makeSidebar()
        sidebar.showWorkspace(project("p1", "api"), animated: false)
        sidebar.showWorkspace(nil, animated: false)
        XCTAssertTrue(sidebar.isShowingPicker)
        XCTAssertNil(sidebar.selectedWorkspace)
    }

    /// The track's offset is re-derived in `layout()` rather than remembered,
    /// so a resized sidebar still lands exactly one level over.
    func testTheTrackFollowsASidebarResize() {
        let sidebar = makeSidebar()
        sidebar.showWorkspace(project("p1", "api"), animated: false)
        sidebar.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        // Converted into the sidebar's own space, not read off `frame`: the
        // level's frame is in the *track's* coordinates, where it always sits
        // one width over. What matters is where it lands on screen.
        let level2 = try? XCTUnwrap(sidebar.navRows[0].superview?.superview)
        let origin = level2?.convert(NSPoint.zero, to: sidebar)
        XCTAssertEqual(origin?.x ?? -1, 0, accuracy: 0.5)
    }

    // MARK: - Destinations

    func testTerminalsIsTheOpeningDestination() {
        XCTAssertEqual(makeSidebar().destination, .terminals)
    }

    func testSelectingADestinationLightsExactlyThatRow() {
        let sidebar = makeSidebar()
        sidebar.applyDestination(.board)
        XCTAssertEqual(sidebar.destination, .board)
        let lit = sidebar.navRows.filter(\.isSelected).map(\.destination)
        XCTAssertEqual(lit, [.board])
    }

    /// The sessions tree hangs off Terminals — the design draws it under that
    /// row and nowhere else.
    func testTheSessionTreeShowsOnlyUnderTerminals() {
        let sidebar = makeSidebar()
        sidebar.applyDestination(.terminals)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertFalse(sidebar.outlineContainer.isHidden)

        sidebar.applyDestination(.dashboard)
        sidebar.layoutSubtreeIfNeeded()
        XCTAssertTrue(sidebar.outlineContainer.isHidden)
    }

    func testEveryDestinationHasARow() {
        XCTAssertEqual(
            makeSidebar().navRows.map(\.destination),
            [.dashboard, .board, .terminals, .files]
        )
    }

    // MARK: - The picker

    func testThePickerBuildsOneCardPerWorkspace() {
        let sidebar = makeSidebar()
        sidebar.setWorkspaces(
            [project("p1", "api", "/tmp/api"), project("p2", "web", "/tmp/web")],
            sessionCounts: ["p1": 2]
        )
        XCTAssertEqual(sidebar.picker.cards.map(\.workspace.id), ["p1", "p2"])
    }

    func testPickingACardRaisesTheWorkspace() {
        let sidebar = makeSidebar()
        sidebar.setWorkspaces([project("p1", "api")], sessionCounts: [:])
        var picked: String?
        sidebar.onSelectWorkspace = { picked = $0.id }
        sidebar.picker.cards.first?.onPress?()
        XCTAssertEqual(picked, "p1")
    }

    func testRebuildingThePickerDoesNotStackOldCards() {
        let sidebar = makeSidebar()
        sidebar.setWorkspaces([project("p1", "api"), project("p2", "web")], sessionCounts: [:])
        sidebar.setWorkspaces([project("p3", "voice")], sessionCounts: [:])
        XCTAssertEqual(sidebar.picker.cards.map(\.workspace.id), ["p3"])
    }

    // MARK: - Palette

    func testInitialsTakeTwoWordsWhenThereAreTwo() {
        XCTAssertEqual(ShellPalette.initials("OmniAgent ADE"), "OA")
        XCTAssertEqual(ShellPalette.initials("bruno-digital"), "BD")
        XCTAssertEqual(ShellPalette.initials("voice"), "VO")
        XCTAssertEqual(ShellPalette.initials("x"), "X")
        XCTAssertEqual(ShellPalette.initials(""), "")
    }

    /// Pinned against the TypeScript `idColor` this ports: `"p1"` hashes to
    /// 3521, and 3521 % 6 is 5. If the wrapping arithmetic ever drifts, a
    /// workspace silently changes colour between the two builds.
    func testAvatarColourMatchesTheTypeScriptHash() {
        XCTAssertEqual(ShellPalette.avatarColor(forID: "p1"), ShellPalette.avatarColors[5])
    }

    /// A long id must wrap, not trap — plain `Int` arithmetic would overflow.
    func testAvatarColourSurvivesALongID() {
        let id = String(repeating: "workspace-", count: 40)
        XCTAssertTrue(ShellPalette.avatarColors.contains(ShellPalette.avatarColor(forID: id)))
    }

    func testAvatarColourIsStable() {
        XCTAssertEqual(
            ShellPalette.avatarColor(forID: "same"),
            ShellPalette.avatarColor(forID: "same")
        )
    }

    func testSessionCountLabelReadsNaturally() {
        XCTAssertEqual(ShellPalette.sessionCountLabel(0), "no sessions")
        XCTAssertEqual(ShellPalette.sessionCountLabel(1), "1 session")
        XCTAssertEqual(ShellPalette.sessionCountLabel(4), "4 sessions")
    }
}
