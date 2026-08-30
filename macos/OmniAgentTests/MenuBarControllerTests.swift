import XCTest
@testable import OmniAgent

/// `MenuBarMenu.build` is pure — no `NSStatusItem`, no controller — so these
/// drive it directly with hand-built summaries, the same way
/// `SessionContextMenuTests` drives `SessionContextMenu.build`.
final class MenuBarControllerTests: XCTestCase {
    func testHeadlinePluralizesEachCount() {
        XCTAssertEqual(
            MenuBarMenu.headline(MenuBarSummary(sessionCount: 1, terminalCount: 1, workingCount: 0)),
            "1 session · 1 terminal · 0 working agents"
        )
        XCTAssertEqual(
            MenuBarMenu.headline(MenuBarSummary(sessionCount: 2, terminalCount: 3, workingCount: 1)),
            "2 sessions · 3 terminals · 1 working agent"
        )
    }

    func testEmptySummaryHasNoSessionRows() {
        let menu = NSMenu()
        MenuBarMenu.build(
            into: menu,
            summary: MenuBarSummary(),
            accountLabel: "Bruno Bonando",
            revealSession: { _ in XCTFail("nothing to reveal") },
            createInWorkspace: { _ in },
            chooseFolder: {},
            showSettings: {},
            quit: {}
        )

        // Account line, headline, separator, Create Session…, separator,
        // Settings…, separator, Quit — nothing about sessions when there
        // are none.
        XCTAssertEqual(menu.items.map(\.title), [
            "Logged in as Bruno Bonando",
            "0 sessions · 0 terminals · 0 working agents",
            "",
            "Create Session…",
            "",
            "Settings…",
            "",
            "Quit",
        ])
        XCTAssertTrue(menu.items[2].isSeparatorItem)
        XCTAssertFalse(menu.items[0].isEnabled, "the account line is a label, not a choice")
        XCTAssertFalse(menu.items[1].isEnabled, "and so is the headline")
    }

    func testRecentSessionsGroupByProjectAndIndent() {
        let summary = MenuBarSummary(
            sessionCount: 2,
            terminalCount: 2,
            workingCount: 1,
            recentSessions: [
                .init(id: "s1", label: "Code exploration", project: "OmniAgent-ADE", projectLabel: "OmniAgent-ADE", firstPaneID: "p1"),
                .init(id: "s2", label: "Docs", project: "OmniAgent-ADE", projectLabel: "OmniAgent-ADE", firstPaneID: "p2"),
            ],
            recentWorkspaces: [.init(project: "OmniAgent-ADE", label: "OmniAgent-ADE")]
        )
        let menu = NSMenu()
        MenuBarMenu.build(
            into: menu,
            summary: summary,
            accountLabel: "Bruno Bonando",
            revealSession: { _ in },
            createInWorkspace: { _ in },
            chooseFolder: {},
            showSettings: {},
            quit: {}
        )

        // One project header, both sessions indented under it, exactly once.
        let projectHeaders = menu.items.filter { $0.title == "OmniAgent-ADE" && $0.action == nil }
        XCTAssertEqual(projectHeaders.count, 1)
        let sessionItems = menu.items.filter { ["Code exploration", "Docs"].contains($0.title) }
        XCTAssertEqual(sessionItems.count, 2)
        XCTAssertTrue(sessionItems.allSatisfy { $0.indentationLevel == 1 })
    }

    func testClickingASessionRevealsIt() {
        let summary = MenuBarSummary(recentSessions: [
            .init(id: "s1", label: "Code exploration", project: "ADE", projectLabel: "ADE", firstPaneID: "pane-1"),
        ])
        var revealed: String?
        let menu = NSMenu()
        MenuBarMenu.build(
            into: menu,
            summary: summary,
            accountLabel: "Bruno Bonando",
            revealSession: { revealed = $0 },
            createInWorkspace: { _ in },
            chooseFolder: {},
            showSettings: {},
            quit: {}
        )

        let item = try! XCTUnwrap(menu.items.first { $0.title == "Code exploration" } as? ShellMenuItem)
        item.performForTesting()
        XCTAssertEqual(revealed, "pane-1")
    }

    func testCreateSessionSubmenuOffersRecentWorkspacesAndAFolderPicker() {
        let summary = MenuBarSummary(recentWorkspaces: [.init(project: "ade", label: "OmniAgent-ADE")])
        var startedIn: String?
        var choseFolder = false
        let menu = NSMenu()
        MenuBarMenu.build(
            into: menu,
            summary: summary,
            accountLabel: "Bruno Bonando",
            revealSession: { _ in },
            createInWorkspace: { startedIn = $0 },
            chooseFolder: { choseFolder = true },
            showSettings: {},
            quit: {}
        )

        let submenu = try! XCTUnwrap(menu.items.first { $0.title == "Create Session…" }?.submenu)
        let workspaceItem = try! XCTUnwrap(submenu.items.first { $0.title == "OmniAgent-ADE" } as? ShellMenuItem)
        workspaceItem.performForTesting()
        XCTAssertEqual(startedIn, "ade")

        let folderItem = try! XCTUnwrap(
            submenu.items.first { $0.title == "Local folder or repository…" } as? ShellMenuItem
        )
        folderItem.performForTesting()
        XCTAssertTrue(choseFolder)
    }

    func testSettingsAndQuitFireTheirHandlers() {
        var openedSettings = false
        var quit = false
        let menu = NSMenu()
        MenuBarMenu.build(
            into: menu,
            summary: MenuBarSummary(),
            accountLabel: "Bruno Bonando",
            revealSession: { _ in },
            createInWorkspace: { _ in },
            chooseFolder: {},
            showSettings: { openedSettings = true },
            quit: { quit = true }
        )

        (try! XCTUnwrap(menu.items.first { $0.title == "Settings…" } as? ShellMenuItem)).performForTesting()
        (try! XCTUnwrap(menu.items.first { $0.title == "Quit" } as? ShellMenuItem)).performForTesting()
        XCTAssertTrue(openedSettings)
        XCTAssertTrue(quit)
    }

    // MARK: - Account (2026-08-30 account-scoped workspace spec)

    func testTheFirstLineSaysWhoIsLoggedIn() {
        XCTAssertEqual(MenuBarMenu.accountLine("Bruno Bonando"), "Logged in as Bruno Bonando")
        XCTAssertEqual(MenuBarMenu.accountLine("bruno@bonando.com"), "Logged in as bruno@bonando.com")
        XCTAssertEqual(MenuBarMenu.accountLine(""), "Logged in", "rows not read yet: no invented name")
    }

    /// The status item exists only between the gate resolving signed in and
    /// a log-out: `AppDelegate` creates and releases the controller on the
    /// window's `onSignedInStateChanged`.
    func testTheStatusItemExistsOnlyWhileSignedIn() throws {
        let delegate = AppDelegate()
        let workspace = WorkspaceWindowController(
            connection: SessionConnection(socketURL: URL(fileURLWithPath: "/tmp/omniagent-menubar-test.sock")),
            panes: [],
            authDefaults: try throwawayDefaults()
        )
        defer { workspace.close() }
        XCTAssertNil(delegate.menuBar, "nothing in the menu bar before anyone signs in")

        delegate.signedInStateChanged(true, workspace: workspace)
        XCTAssertNotNil(delegate.menuBar)
        let first = delegate.menuBar
        delegate.signedInStateChanged(true, workspace: workspace)
        XCTAssertTrue(delegate.menuBar === first, "a second sign-in keeps the one item")

        delegate.signedInStateChanged(false, workspace: workspace)
        XCTAssertNil(delegate.menuBar, "logging out takes the item down")

        delegate.signedInStateChanged(true, workspace: workspace)
        XCTAssertNotNil(delegate.menuBar, "signing back in puts the item back up")
        XCTAssertFalse(delegate.menuBar === first, "a fresh controller, not the released one")
    }

    /// A suite of its own, torn down after — never the real app's defaults,
    /// which is where the real launch decision lives (`RealPreferencesGuard`).
    private func throwawayDefaults() throws -> UserDefaults {
        let name = "digital.bruno.omniagent.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return defaults
    }
}
