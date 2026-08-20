import AppKit
import XCTest

@testable import OmniAgent

/// The flat Copilot-style sidebar from the 2026-08-20 navigation redesign:
/// the fixed nav rows, the Search seam, the Workspaces section, the pinned
/// account row — and the content routing the rows drive on the controller.
final class NavigationSidebarTests: XCTestCase {
    private func makeSidebar() -> NavigationSidebarView {
        let sidebar = NavigationSidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    // MARK: - Fixed nav rows

    /// The spec's order, top to bottom: Home, To Do List, Search.
    func testNavRowsArePresentInTheSpecOrder() {
        let sidebar = makeSidebar()
        XCTAssertEqual(sidebar.navRows.map(\.item), [.home, .todo, .search])
        XCTAssertEqual(
            sidebar.navRows.map(\.item.title),
            ["Home", "To Do List", "Search"]
        )
        XCTAssertEqual(
            sidebar.navRows.map(\.item.symbol),
            ["house", "checklist", "magnifyingglass"]
        )
    }

    func testHomeAndToDoListRouteAsDestinations() throws {
        let sidebar = makeSidebar()
        var reported: [WorkspaceDestination] = []
        sidebar.onSelectDestination = { reported.append($0) }

        try XCTUnwrap(sidebar.navRows.first { $0.item == .home }?.onPress)()
        XCTAssertEqual(reported, [.home])
        XCTAssertEqual(sidebar.destination, .home)
        XCTAssertEqual(sidebar.navRows.filter(\.isSelected).map(\.item), [.home])

        try XCTUnwrap(sidebar.navRows.first { $0.item == .todo }?.onPress)()
        XCTAssertEqual(reported, [.home, .todo])
        XCTAssertEqual(sidebar.navRows.filter(\.isSelected).map(\.item), [.todo])
    }

    /// Search is an action, not a place: it raises the spotlight and the lit
    /// row stays exactly where it was.
    func testSearchFiresTheSpotlightSeamAndDoesNotSelect() throws {
        let sidebar = makeSidebar()
        var searches = 0
        var routed = 0
        sidebar.onSearch = { searches += 1 }
        sidebar.onSelectDestination = { _ in routed += 1 }
        sidebar.applyDestination(.home)

        try XCTUnwrap(sidebar.navRows.first { $0.item == .search }?.onPress)()

        XCTAssertEqual(searches, 1)
        XCTAssertEqual(routed, 0, "Search never routes")
        XCTAssertEqual(sidebar.destination, .home, "and never moves the selection")
        XCTAssertEqual(sidebar.navRows.filter(\.isSelected).map(\.item), [.home])
    }

    /// The Desk has no sidebar row any more — on `.terminals` nothing is lit.
    func testTheDeskLightsNoNavRow() {
        let sidebar = makeSidebar()
        sidebar.applyDestination(.home)
        sidebar.applyDestination(.terminals)
        XCTAssertTrue(sidebar.navRows.filter(\.isSelected).isEmpty)
    }

    // MARK: - Workspaces section

    /// The workspaces tree stays mounted, under a "Workspaces" section header
    /// that sits between the nav rows and the tree.
    func testTheWorkspacesHeaderSitsBetweenTheNavRowsAndTheTree() throws {
        let sidebar = makeSidebar()
        XCTAssertEqual(sidebar.workspacesHeader.title, "Workspaces")
        XCTAssertNotNil(sidebar.workspacesTree.superview, "the tree is mounted")

        func top(_ view: NSView) -> CGFloat { view.convert(view.bounds, to: sidebar).maxY }
        let lastNav = try XCTUnwrap(sidebar.navRows.last)
        // Not flipped: larger y is higher on screen.
        XCTAssertLessThan(top(sidebar.workspacesHeader), top(lastNav))
        XCTAssertLessThanOrEqual(top(sidebar.workspacesTree), top(sidebar.workspacesHeader))
    }

    // MARK: - Account row

    func testTheAccountRowIsPinnedAtTheBottom() {
        let sidebar = makeSidebar()
        XCTAssertTrue(sidebar.accountRow.superview === sidebar)
        XCTAssertEqual(sidebar.accountRow.frame.minY, 0, accuracy: 0.5, "pinned to the bottom edge")
        XCTAssertEqual(sidebar.accountRow.frame.width, sidebar.bounds.width, accuracy: 0.5)
        // Everything else sits above it.
        for sibling in sidebar.subviews where sibling !== sidebar.accountRow {
            XCTAssertGreaterThanOrEqual(
                sibling.frame.minY,
                sidebar.accountRow.frame.maxY - 0.5,
                "\(type(of: sibling)) overlaps the pinned account row"
            )
        }
    }

    /// A placeholder until real accounts exist: a generic avatar and
    /// "Not signed in" — never the machine user's name.
    func testTheAccountRowIsAPlaceholder() {
        XCTAssertEqual(makeSidebar().accountRow.accountLabel, "Not signed in")
    }

    func testTheGearOpensSettings() throws {
        let sidebar = makeSidebar()
        var opened = 0
        sidebar.onOpenSettings = { opened += 1 }
        try XCTUnwrap(sidebar.accountRow.gear.onPress)()
        XCTAssertEqual(opened, 1)
    }

    // MARK: - Content routing (controller)

    /// Home and To Do List land on the "Under development" placeholder; the
    /// pane workspace hides and comes back with the Desk.
    func testHomeAndToDoShowTheUnderDevelopmentPlaceholder() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        for destination in [WorkspaceDestination.home, .todo] {
            controller.applyDestination(destination)
            XCTAssertTrue(controller.workspaceView.isHidden)
            let placeholder = try XCTUnwrap(placeholderView(in: controller))
            XCTAssertFalse(placeholder.isHiddenOrHasHiddenAncestor)
            XCTAssertEqual(placeholder.titleText, destination.title)
            XCTAssertEqual(placeholder.subtitleText, "Under development")
        }

        controller.applyDestination(.terminals)
        XCTAssertFalse(controller.workspaceView.isHidden)
        XCTAssertTrue(try XCTUnwrap(placeholderView(in: controller)).isHidden)
    }

    /// The sidebar's rows drive the same routing the palette does.
    func testTheSidebarRowsRouteToTheController() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)

        try XCTUnwrap(controller.shellSidebar.navRows.first { $0.item == .home }?.onPress)()
        XCTAssertEqual(controller.destination, .home)

        try XCTUnwrap(controller.shellSidebar.navRows.first { $0.item == .todo }?.onPress)()
        XCTAssertEqual(controller.destination, .todo)
    }

    /// The Search row raises the spotlight — the same panel ⌃Space and ⌘K
    /// raise — without touching the destination.
    func testTheSearchRowRaisesTheSpotlightWithoutChangingTheDestination() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        XCTAssertEqual(controller.destination, .terminals)
        XCTAssertTrue(controller.palette.model.commands.isEmpty, "nothing presented yet")

        try XCTUnwrap(controller.shellSidebar.navRows.first { $0.item == .search }?.onPress)()

        XCTAssertFalse(controller.palette.model.commands.isEmpty, "the spotlight was presented")
        XCTAssertEqual(controller.destination, .terminals, "and Search selected nothing")
        XCTAssertFalse(controller.workspaceView.isHidden)
        controller.palette.dismiss()
    }

    // MARK: - Helpers

    private func makeController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-nav-sidebar-test.sock")
            ),
            panes: []
        )
    }

    private func placeholderView(in controller: WorkspaceWindowController) -> WorkspacePlaceholderView? {
        controller.window?.contentView.flatMap(firstPlaceholder(under:))
    }

    private func firstPlaceholder(under view: NSView) -> WorkspacePlaceholderView? {
        for subview in view.subviews {
            if let match = subview as? WorkspacePlaceholderView { return match }
            if let match = firstPlaceholder(under: subview) { return match }
        }
        return nil
    }
}
