import AppKit
import XCTest

@testable import OmniAgent

/// The review panel's frame — the 2026-08-20 redesign's §5
/// (docs/superpowers/specs/2026-08-20-copilot-nav-redesign-design.md): the
/// third split item, the tab bar, and the per-session
/// `review_panel_native` row.
final class ReviewPanelTests: XCTestCase {
    // MARK: - Codec

    func testCodecRoundTripsEveryField() {
        let states: [String: ReviewPanelSessionState] = [
            "g-1": ReviewPanelSessionState(
                open: true,
                tabs: ["changes", "files", "browser"],
                activeTab: "browser",
                width: 342,
                openFile: "/tmp/alpha/main.swift",
                treePosition: "right",
                showHidden: true
            ),
            "g-2": ReviewPanelSessionState(open: true),
        ]
        XCTAssertEqual(
            ReviewPanelStateCodec.deserialize(ReviewPanelStateCodec.serialize(states)),
            states
        )
    }

    /// An empty tab set is a legitimate state — the user closed every tab —
    /// and must come back as one, not as the default pair.
    func testCodecRoundTripsAnEmptyTabSet() {
        let states = ["g-1": ReviewPanelSessionState(open: true, tabs: [], activeTab: "")]
        XCTAssertEqual(
            ReviewPanelStateCodec.deserialize(ReviewPanelStateCodec.serialize(states)),
            states
        )
    }

    func testCodecRepairsACorruptEntry() {
        let raw = """
        {"sessions":{
            "g-1": {
                "open": true,
                "tabs": ["changes", "not-a-tab", "changes", "files", 7],
                "activeTab": "not-a-tab",
                "width": -20,
                "treePosition": "top",
                "showHidden": "yes"
            },
            "bad id!": {"open": true},
            "g-2": "not a dictionary"
        }}
        """
        XCTAssertEqual(
            ReviewPanelStateCodec.deserialize(raw),
            [
                "g-1": ReviewPanelSessionState(
                    open: true,
                    tabs: ["changes", "files"],
                    activeTab: "changes"
                ),
            ]
        )
    }

    /// An entry indistinguishable from "never touched the panel" is not
    /// stored, and garbage reads as empty.
    func testCodecDropsDefaultEntriesAndSurvivesGarbage() {
        XCTAssertEqual(
            ReviewPanelStateCodec.serialize(["g-1": ReviewPanelSessionState()]),
            #"{"sessions":{}}"#
        )
        XCTAssertEqual(ReviewPanelStateCodec.deserialize(nil), [:])
        XCTAssertEqual(ReviewPanelStateCodec.deserialize("{broken"), [:])
        XCTAssertEqual(ReviewPanelStateCodec.deserialize(#"{"sessions":[]}"#), [:])
    }

    // MARK: - The view's tab bar

    func testThePanelOpensWithTheDefaultTabs() {
        let panel = ReviewPanelView()
        XCTAssertEqual(panel.openTabs, [.changes, .files])
        XCTAssertEqual(panel.activeTab, .changes)
        XCTAssertEqual(panel.tabItems.map(\.tab), [.changes, .files])
        XCTAssertEqual(panel.placeholders[.changes]?.isHidden, false)
    }

    func testSelectingATabSwapsTheContentAndReports() {
        let panel = ReviewPanelView()
        var reported = 0
        panel.onTabsChanged = { reported += 1 }

        panel.selectTab(.files)

        XCTAssertEqual(panel.activeTab, .files)
        XCTAssertEqual(reported, 1)
        XCTAssertEqual(panel.placeholders[.files]?.isHidden, false)
        XCTAssertEqual(panel.placeholders[.changes]?.isHidden, true)
        XCTAssertTrue(panel.tabItems.first { $0.tab == .files }?.isSelected ?? false)

        // Selecting the already-active tab is not a change.
        panel.selectTab(.files)
        XCTAssertEqual(reported, 1)
    }

    /// The "+" menu offers exactly the views not already open — Browser and
    /// Insights from the default set — and picking one adds and selects it.
    func testTheAddMenuAddsAndSelectsATab() throws {
        let panel = ReviewPanelView()
        var reported = 0
        panel.onTabsChanged = { reported += 1 }

        let menu = panel.addMenu()
        XCTAssertEqual(menu.items.map(\.title), ["Browser", "Insights"])

        try XCTUnwrap(menu.items.first as? ShellMenuItem).performForTesting()

        XCTAssertEqual(panel.openTabs, [.changes, .files, .browser])
        XCTAssertEqual(panel.activeTab, .browser)
        XCTAssertEqual(reported, 1)
        XCTAssertEqual(panel.addMenu().items.map(\.title), ["Insights"])
    }

    /// Closing the active tab selects the neighbour that slid into its
    /// place; closing the last falls back to the new last.
    func testClosingTabsSelectsTheNeighbour() {
        let panel = ReviewPanelView()
        panel.load(tabs: [.changes, .files, .browser], active: .files)
        var reported = 0
        panel.onTabsChanged = { reported += 1 }

        panel.closeTab(.files)
        XCTAssertEqual(panel.openTabs, [.changes, .browser])
        XCTAssertEqual(panel.activeTab, .browser)

        panel.closeTab(.browser)
        XCTAssertEqual(panel.openTabs, [.changes])
        XCTAssertEqual(panel.activeTab, .changes)

        panel.closeTab(.changes)
        XCTAssertEqual(panel.openTabs, [])
        XCTAssertNil(panel.activeTab)
        XCTAssertEqual(reported, 3)

        // Closing what is not open reports nothing.
        panel.closeTab(.changes)
        XCTAssertEqual(reported, 3)
    }

    /// `load` is the restore path — it must not report a change back.
    func testLoadDoesNotReport() {
        let panel = ReviewPanelView()
        var reported = 0
        panel.onTabsChanged = { reported += 1 }
        panel.load(tabs: [.browser, .insights], active: .insights)
        XCTAssertEqual(panel.openTabs, [.browser, .insights])
        XCTAssertEqual(panel.activeTab, .insights)
        XCTAssertEqual(reported, 0)
    }

    // MARK: - The split item

    func testTheToggleShowsAndHidesTheSplitItem() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.applyRestoredReviewPanel(nil)
        let item = try XCTUnwrap(controller.reviewPanelItem)
        XCTAssertTrue(item.isCollapsed, "closed until a session opens it")

        // The menu item and toolbar button are live now.
        let probe = NSMenuItem(
            title: "Toggle Review Panel",
            action: #selector(WorkspaceWindowController.toggleReviewPanel(_:)),
            keyEquivalent: ""
        )
        XCTAssertTrue(controller.validateMenuItem(probe))

        controller.toggleReviewPanel(nil)
        XCTAssertFalse(item.isCollapsed)
        XCTAssertEqual(item.minimumThickness, ReviewPanelView.minimumWidth)

        controller.toggleReviewPanel(nil)
        XCTAssertTrue(item.isCollapsed)
    }

    /// Open state, tabs and selection persist per session in the
    /// `review_panel_native` row, and switching sessions swaps the whole
    /// panel to the arriving session's own state.
    func testPerSessionStateRoundTripsAcrossASessionSwitch() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-2", group: "g-2"),
        ])
        defer { controller.close() }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredReviewPanel(nil)
        let item = try XCTUnwrap(controller.reviewPanelItem)
        // Restoration leaves the last-added session active; start from g-1.
        // `activateGroup` directly — `enterDeskSession` on the canvas is a
        // camera flight that lands asynchronously.
        controller.workspaceView.activateGroup("g-1")
        XCTAssertEqual(controller.workspaceView.activeGroup, "g-1")

        controller.toggleReviewPanel(nil)
        controller.reviewPanel.addTab(.browser)

        var persisted = ReviewPanelStateCodec.deserialize(written[SettingsKey.reviewPanel])
        XCTAssertEqual(persisted["g-1"]?.open, true)
        XCTAssertEqual(persisted["g-1"]?.tabs, ["changes", "files", "browser"])
        XCTAssertEqual(persisted["g-1"]?.activeTab, "browser")

        // The other session has its own answer: closed, default tabs.
        controller.workspaceView.activateGroup("g-2")
        XCTAssertTrue(item.isCollapsed)
        XCTAssertEqual(controller.reviewPanel.openTabs, [.changes, .files])

        // Coming back restores what g-1 recorded.
        controller.workspaceView.activateGroup("g-1")
        XCTAssertFalse(item.isCollapsed)
        XCTAssertEqual(controller.reviewPanel.openTabs, [.changes, .files, .browser])
        XCTAssertEqual(controller.reviewPanel.activeTab, .browser)

        persisted = ReviewPanelStateCodec.deserialize(written[SettingsKey.reviewPanel])
        XCTAssertEqual(persisted["g-1"]?.open, true)
        XCTAssertNil(persisted["g-2"], "a session that never touched the panel stores nothing")
    }

    /// The row read on connect reopens the panel for the session on screen —
    /// the relaunch half of persistence.
    func testARestoredRowReopensThePanelForTheActiveSession() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        controller.applyRestoredReviewPanel(
            ReviewPanelStateCodec.serialize([
                "g-1": ReviewPanelSessionState(
                    open: true,
                    tabs: ["files", "insights"],
                    activeTab: "insights"
                ),
            ])
        )
        XCTAssertEqual(try XCTUnwrap(controller.reviewPanelItem).isCollapsed, false)
        XCTAssertEqual(controller.reviewPanel.openTabs, [.files, .insights])
        XCTAssertEqual(controller.reviewPanel.activeTab, .insights)
    }

    /// Entries for vanished sessions are pruned on restore and the cleaned
    /// row written back — `applyRestoredSessionMeta`'s contract.
    func testRestorePrunesEntriesForVanishedGroups() throws {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }
        controller.applyRestoredReviewPanel(
            ReviewPanelStateCodec.serialize([
                "g-1": ReviewPanelSessionState(open: true),
                "g-gone": ReviewPanelSessionState(open: true),
            ])
        )
        XCTAssertEqual(
            controller.reviewPanelStates,
            ["g-1": ReviewPanelSessionState(open: true)]
        )
        XCTAssertEqual(
            ReviewPanelStateCodec.deserialize(written[SettingsKey.reviewPanel]),
            ["g-1": ReviewPanelSessionState(open: true)]
        )
    }

    /// Nothing writes the row before it has been read — the write gate every
    /// settings row here holds.
    func testTheWriteGateStaysShutBeforeTheRestore() {
        let controller = makeController(panes: [
            PersistedTab(project: "alpha", engine: .claude, cwd: "/tmp/alpha", id: "s-1", group: "g-1"),
        ])
        defer { controller.close() }
        var written: [String: String] = [:]
        controller.settingsWriter = { key, value in written[key] = value }

        controller.toggleReviewPanel(nil)
        controller.reviewPanel.addTab(.insights)

        XCTAssertNil(written[SettingsKey.reviewPanel])
    }

    // MARK: - Helpers

    private func makeController(panes: [PersistedTab]) -> WorkspaceWindowController {
        let controller = WorkspaceWindowController(
            connection: SessionConnection(
                socketURL: URL(fileURLWithPath: "/tmp/omniagent-review-panel-test.sock")
            ),
            panes: []
        )
        controller.sessionEnsurer = { _ in }
        controller.sessionKiller = { _ in }
        controller.applyRestoredPanes(
            WorkspaceRestoration.plan(fromLayout: PersistedLayoutCodec.serialize(panes))
        )
        // The review panel only syncs while the Desk is on screen; these tests
        // are about the panel, not the destination default, so restore that
        // precondition explicitly now that `.home` is the initial destination.
        controller.applyDestination(.terminals)
        return controller
    }
}
