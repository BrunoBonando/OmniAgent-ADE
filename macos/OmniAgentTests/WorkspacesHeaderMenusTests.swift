import AppKit
import XCTest

@testable import OmniAgent

/// The Workspaces section header's two menus (group-by and plus) and the
/// three tree shapes the group-by choice selects — the 2026-08-20 redesign's
/// §2. Menu construction is asserted structurally; the shapes are asserted on
/// what `WorkspacesTreeView` actually renders.
final class WorkspacesHeaderMenusTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The sidebar's own tree persists into the standard defaults; a mode
        // or fold left behind by an earlier run would bend these assertions.
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.collapsedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.groupModeDefaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.collapsedDefaultsKey)
        UserDefaults.standard.removeObject(forKey: WorkspacesTreeView.groupModeDefaultsKey)
        super.tearDown()
    }

    // MARK: - Menu construction

    /// The spec's shape: a "Group by" title, then Project / Status / Last
    /// updated with a checkmark on the current mode.
    func testGroupByMenuShowsTheThreeModesWithTheCurrentOneChecked() throws {
        var picked: [WorkspacesGroupMode] = []
        let menu = WorkspacesHeaderMenus.groupBy(current: .project) { picked.append($0) }

        XCTAssertEqual(
            menu.items.map(\.title),
            ["Group by", "Project", "Status", "Last updated"]
        )
        XCTAssertFalse(menu.items[0].isEnabled, "the title is a title, not a choice")
        XCTAssertEqual(menu.items.map(\.state), [.off, .on, .off, .off])

        try XCTUnwrap(menu.items[2] as? ShellMenuItem).performForTesting()
        XCTAssertEqual(picked, [.status])

        let byStatus = WorkspacesHeaderMenus.groupBy(current: .lastUpdated) { _ in }
        XCTAssertEqual(byStatus.items.map(\.state), [.off, .off, .off, .on])
    }

    /// The plus menu: start a session in any listed workspace, add a project
    /// from a local folder, and the visible-but-disabled remote future.
    func testPlusMenuOffersEveryWorkspaceThenTheLocalFolderThenADisabledRemote() throws {
        var started: [String] = []
        var added = 0
        let menu = WorkspacesHeaderMenus.plus(
            workspaces: [(id: "p1", label: "Alpha"), (id: "p2", label: "Beta")],
            startSession: { started.append($0) },
            addLocalFolder: { added += 1 }
        )

        XCTAssertEqual(
            menu.items.map(\.title),
            [
                "Start session in", "Alpha", "Beta",
                "Add project from", "Local folder or repository…",
                "", "Resume remote session…",
            ]
        )
        XCTAssertTrue(menu.items[5].isSeparatorItem)
        XCTAssertFalse(menu.items[0].isEnabled)
        XCTAssertFalse(menu.items[3].isEnabled)
        XCTAssertTrue(menu.items[1].isEnabled)
        XCTAssertTrue(menu.items[4].isEnabled)
        XCTAssertFalse(
            menu.items[6].isEnabled,
            "Resume remote session… is announced, not clickable — a future, not a dead end"
        )

        try XCTUnwrap(menu.items[2] as? ShellMenuItem).performForTesting()
        XCTAssertEqual(started, ["p2"], "each workspace item starts a session in that workspace")
        try XCTUnwrap(menu.items[4] as? ShellMenuItem).performForTesting()
        XCTAssertEqual(added, 1)
    }

    // MARK: - Grouping rules

    /// Status mode's bucketing, aggregated over a session's panes: anything
    /// asking or broken outranks work in progress, which outranks quiet — and
    /// an empty bucket does not render a header over nothing.
    func testStatusBucketsFollowThePrecedenceAndSkipEmptyBuckets() {
        let sessions = [
            session("ask", panes: ["a"]),
            session("broken-but-busy", panes: ["b", "c"]),
            session("busy", panes: ["d"]),
            session("tooling", panes: ["e"]),
            session("done", panes: ["f"]),
            session("silent", panes: ["g"]),
        ]
        let statuses: [String: RemoteSessionStatus] = [
            "a": .awaitingApproval, "b": .error, "c": .thinking,
            "d": .thinking, "e": .toolExecution, "f": .ready,
        ]

        let buckets = WorkspacesGrouping.statusBuckets(sessions, statuses: statuses)

        XCTAssertEqual(buckets.map(\.title), ["Needs attention", "Working", "Idle"])
        XCTAssertEqual(buckets[0].sessions.map(\.id), ["ask", "broken-but-busy"])
        XCTAssertEqual(buckets[1].sessions.map(\.id), ["busy", "tooling"])
        XCTAssertEqual(buckets[2].sessions.map(\.id), ["done", "silent"])

        let calm = WorkspacesGrouping.statusBuckets(
            [session("done", panes: ["f"])],
            statuses: ["f": .ready]
        )
        XCTAssertEqual(calm.map(\.title), ["Idle"], "only buckets with members render")
    }

    /// Last-updated mode: the session whose panes most recently reported a
    /// status event first; sessions that never reported one keep their tree
    /// order at the end.
    func testLastUpdatedPutsTheMostRecentEventFirstAndSilentSessionsLast() {
        let sessions = [
            session("s1", panes: ["a"]),
            session("s2", panes: ["b", "c"]),
            session("s3", panes: ["d"]),
            session("s4", panes: ["e"]),
        ]
        let times: [String: Double] = ["a": 100, "b": 20, "c": 300]

        XCTAssertEqual(
            WorkspacesGrouping.lastUpdatedFirst(sessions, eventTimes: times).map(\.id),
            ["s2", "s1", "s3", "s4"]
        )
    }

    // MARK: - The tree's three shapes

    func testProjectModeIsTheDefaultAndDrawsTheWorkspaceTree() throws {
        let (tree, _) = try makeTree()
        XCTAssertEqual(tree.groupMode, .project)

        tree.reload(entries: twoWorkspaces(), focusedPaneID: nil, statuses: [:])

        XCTAssertEqual(tree.renderedWorkspaceIDs, ["p1", "p2"])
        XCTAssertEqual(tree.descendants(WorkspaceRowView.self).count, 2)
        XCTAssertTrue(tree.renderedBucketTitles.isEmpty)
    }

    func testStatusModeBucketsTheSessionsUnderHeadersInsteadOfWorkspaces() throws {
        let (tree, _) = try makeTree()
        tree.reload(
            entries: twoWorkspaces(),
            focusedPaneID: nil,
            statuses: ["a": .awaitingApproval, "b": .thinking]
        )

        tree.setGroupMode(.status)

        XCTAssertEqual(tree.renderedBucketTitles, ["Needs attention", "Working", "Idle"])
        XCTAssertEqual(
            tree.descendants(WorkspacesBucketHeaderView.self).map(\.title),
            ["Needs attention", "Working", "Idle"]
        )
        XCTAssertEqual(tree.renderedSessionIDs, ["s1", "s2", "s3"])
        XCTAssertTrue(
            tree.descendants(WorkspaceRowView.self).isEmpty,
            "Status mode has no workspace rows"
        )
    }

    func testLastUpdatedModeIsAFlatMostRecentFirstList() throws {
        let (tree, _) = try makeTree()
        tree.setGroupMode(.lastUpdated)

        tree.reload(
            entries: twoWorkspaces(),
            focusedPaneID: nil,
            statuses: [:],
            eventTimes: ["b": 500, "a": 100]
        )

        XCTAssertEqual(tree.renderedSessionIDs, ["s2", "s1", "s3"])
        XCTAssertEqual(tree.descendants(SessionRowView.self).count, 3)
        XCTAssertTrue(tree.descendants(WorkspaceRowView.self).isEmpty)
        XCTAssertTrue(tree.descendants(WorkspacesBucketHeaderView.self).isEmpty)
    }

    /// Switching modes re-renders on the spot from what the tree already has,
    /// and the choice survives a relaunch.
    func testTheModeSwitchReRendersInPlaceAndPersists() throws {
        let (tree, defaults) = try makeTree()
        tree.reload(entries: twoWorkspaces(), focusedPaneID: nil, statuses: [:])
        XCTAssertEqual(tree.descendants(WorkspaceRowView.self).count, 2)

        tree.setGroupMode(.status)
        XCTAssertTrue(tree.descendants(WorkspaceRowView.self).isEmpty, "re-rendered without a reload")

        let rebuilt = WorkspacesTreeView(defaults: defaults)
        XCTAssertEqual(rebuilt.groupMode, .status, "the choice persisted")
    }

    // MARK: - The header's buttons and the sidebar's menus

    func testTheHeaderCarriesTheTwoWiredIconButtons() {
        let sidebar = makeSidebar()
        let header = sidebar.workspacesHeader
        XCTAssertTrue(header.groupButton.superview === header)
        XCTAssertTrue(header.plusButton.superview === header)
        XCTAssertNotNil(header.groupButton.onPress, "the group-by button opens its menu")
        XCTAssertNotNil(header.plusButton.onPress, "the plus button opens its menu")
    }

    /// The sidebar's group-by menu reads and writes the tree's mode.
    func testTheSidebarsGroupByMenuSwitchesTheTreeShape() throws {
        let sidebar = makeSidebar()
        sidebar.reloadWorkspaces(
            workspaces: [BrainProjectSummary(id: "p1", label: "Alpha", path: nil)],
            panes: [pane("a", group: "s1")],
            focusedPaneID: nil,
            statuses: ["a": .ready],
            projectLabels: [:]
        )

        let menu = sidebar.makeGroupByMenu()
        XCTAssertEqual(menu.items[1].state, .on, "Project is the default")

        try XCTUnwrap(menu.items[2] as? ShellMenuItem).performForTesting()

        XCTAssertEqual(sidebar.workspacesTree.groupMode, .status)
        XCTAssertEqual(sidebar.workspacesTree.renderedBucketTitles, ["Idle"])
        XCTAssertEqual(sidebar.makeGroupByMenu().items[2].state, .on, "the checkmark followed")
    }

    /// The plus menu lists exactly what the tree renders — the brain's
    /// workspaces and any pane-only project — and fires the sidebar's seams.
    func testTheSidebarsPlusMenuListsEveryRenderedWorkspace() throws {
        let sidebar = makeSidebar()
        var started: [String] = []
        var added = 0
        sidebar.onStartSession = { started.append($0) }
        sidebar.onAddLocalFolder = { added += 1 }
        sidebar.reloadWorkspaces(
            workspaces: [BrainProjectSummary(id: "p1", label: "Alpha", path: nil)],
            panes: [pane("a", group: "s9", project: "p9")],
            focusedPaneID: nil,
            statuses: [:],
            projectLabels: [:]
        )

        let menu = sidebar.makePlusMenu()

        XCTAssertEqual(
            menu.items.map(\.title),
            [
                "Start session in", "Alpha", "p9",
                "Add project from", "Local folder or repository…",
                "", "Resume remote session…",
            ]
        )
        try XCTUnwrap(menu.items[2] as? ShellMenuItem).performForTesting()
        XCTAssertEqual(started, ["p9"])
        try XCTUnwrap(menu.items[4] as? ShellMenuItem).performForTesting()
        XCTAssertEqual(added, 1)
    }

    // MARK: - The controller's side

    /// "Last updated" needs to know *when*, so the controller tracks a
    /// timestamp for every status event, cleared strictly alongside
    /// `lastStatus` when a pane closes.
    func testStatusEventTimesTrackLastStatusAndClearWithIt() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView
        controller.newTerminalPane(nil)
        let closing = try XCTUnwrap(workspace.focusedPaneID)
        let survivor = try XCTUnwrap(workspace.paneIDs.first { $0 != closing })

        let before = Date().timeIntervalSince1970 * 1000
        for id in [closing, survivor] {
            controller.recordNotification(
                for: SessionStatusEvent(id: id, status: .thinking, notify: false, engine: "shell")
            )
        }

        XCTAssertEqual(Set(controller.lastStatusEventAt.keys), [closing, survivor])
        for stamp in controller.lastStatusEventAt.values {
            XCTAssertGreaterThanOrEqual(stamp, before)
        }

        controller.closePane(nil)

        XCTAssertEqual(
            Set(controller.lastStatusEventAt.keys),
            [survivor],
            "a closed pane's timestamp must not outlive it"
        )
    }

    /// The plus menu's two seams land on the controller: a workspace item
    /// starts a session in that workspace, the folder item runs the existing
    /// add-workspace chooser.
    func testThePlusMenuSeamsReachTheController() throws {
        let controller = makeController()
        defer { controller.close() }
        controller.showWindow(nil)
        let workspace = controller.workspaceView

        try XCTUnwrap(controller.shellSidebar.onStartSession)("p7")
        XCTAssertTrue(
            workspace.allPaneIDs
                .compactMap { workspace.descriptor(for: $0) }
                .contains { $0.project == "p7" },
            "a session started in the picked workspace"
        )

        controller.directoryChooser = { _, completion in completion("/tmp/chosen-folder") }
        try XCTUnwrap(controller.shellSidebar.onAddLocalFolder)()
        XCTAssertTrue(
            workspace.allPaneIDs
                .compactMap { workspace.descriptor(for: $0) }
                .contains { $0.cwd == "/tmp/chosen-folder" },
            "the folder item opened the workspace-folder chooser"
        )
    }

    // MARK: - Helpers

    private func makeController() -> WorkspaceWindowController {
        WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-header-menus-test.sock")
            ),
            sessionID: "native-terminal"
        )
    }

    private func makeSidebar() -> NavigationSidebarView {
        let sidebar = NavigationSidebarView()
        sidebar.frame = NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 700)
        sidebar.layoutSubtreeIfNeeded()
        return sidebar
    }

    private func makeTree() throws -> (WorkspacesTreeView, UserDefaults) {
        let suite = "header-menus-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let tree = WorkspacesTreeView(defaults: defaults)
        tree.frame = NSRect(x: 0, y: 0, width: ShellMetrics.sidebarWidth, height: 500)
        return (tree, defaults)
    }

    /// Two workspaces, three sessions: s1 (pane a) and s2 (pane b) under p1,
    /// s3 (pane c) under p2.
    private func twoWorkspaces() -> [WorkspaceTreeEntry] {
        [
            WorkspaceTreeEntry(
                id: "p1",
                label: "Alpha",
                sessions: [session("s1", panes: ["a"]), session("s2", panes: ["b"])]
            ),
            WorkspaceTreeEntry(
                id: "p2",
                label: "Beta",
                sessions: [session("s3", project: "p2", panes: ["c"])]
            ),
        ]
    }

    private func session(
        _ id: String,
        project: String = "p1",
        panes: [String]
    ) -> SessionGroupNode {
        SessionGroupNode(
            id: id,
            project: project,
            name: id,
            label: id,
            cwd: "/tmp",
            paneIDs: panes,
            isCurrent: false
        )
    }

    private func pane(_ id: String, group: String, project: String = "p1") -> PaneDescriptor {
        PaneDescriptor(
            sessionID: id,
            group: group,
            groupLabel: group,
            title: "term",
            project: project,
            engine: .claude,
            cwd: "/tmp"
        )
    }
}

private extension NSView {
    /// Every matching descendant, in tree order — the rows live in a private
    /// stack, and walking the view tree is how a test sees what a user sees.
    func descendants<View: NSView>(_ type: View.Type) -> [View] {
        var found: [View] = []
        for subview in subviews {
            if let match = subview as? View { found.append(match) }
            found += subview.descendants(type)
        }
        return found
    }
}
