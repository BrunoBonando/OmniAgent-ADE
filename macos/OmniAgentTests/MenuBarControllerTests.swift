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
            shareState: .off,
            revealSession: { _ in XCTFail("nothing to reveal") },
            createInWorkspace: { _ in },
            chooseFolder: {},
            toggleSharing: {},
            showSettings: {},
            quit: {}
        )

        // Account line, headline, separator, Create Session…, separator,
        // Share this environment, separator, Settings…, separator, Quit —
        // nothing about sessions when there are none.
        XCTAssertEqual(menu.items.map(\.title), [
            "Logged in as Bruno Bonando",
            "0 sessions · 0 terminals · 0 working agents",
            "",
            "Create Session…",
            "",
            "Share this environment",
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
            shareState: .off,
            revealSession: { _ in },
            createInWorkspace: { _ in },
            chooseFolder: {},
            toggleSharing: {},
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
            shareState: .off,
            revealSession: { revealed = $0 },
            createInWorkspace: { _ in },
            chooseFolder: {},
            toggleSharing: {},
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
            shareState: .off,
            revealSession: { _ in },
            createInWorkspace: { startedIn = $0 },
            chooseFolder: { choseFolder = true },
            toggleSharing: {},
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
            shareState: .off,
            revealSession: { _ in },
            createInWorkspace: { _ in },
            chooseFolder: {},
            toggleSharing: {},
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

    // MARK: - Sharing icon (2026-09-01 remote environment sharing spec §2)

    /// Tinting a template image would leave a wash the same colour every
    /// state, so `.sharing`/`.connected` must turn `isTemplate` off to show
    /// their colour at all — `.off` stays a template so it keeps adapting to
    /// light/dark menu bars the way every other status icon does.
    func testShareIconIsTemplateOnlyWhenSharingIsOff() {
        XCTAssertTrue(MenuBarMenu.shareIcon(.off).isTemplate)
        XCTAssertFalse(MenuBarMenu.shareIcon(.sharing).isTemplate)
        XCTAssertFalse(MenuBarMenu.shareIcon(.connected).isTemplate)
        XCTAssertFalse(MenuBarMenu.shareIcon(.driving).isTemplate)
    }

    /// The menu's own checkmark, `WorkspacesHeaderMenus.groupBy`'s pattern —
    /// on while sharing (or connected), off while sharing is off.
    func testSharingToggleItemReflectsState() {
        for (state, expected) in [(MenuBarShareState.off, NSControl.StateValue.off), (.sharing, .on), (.connected, .on)] {
            let menu = NSMenu()
            MenuBarMenu.build(
                into: menu,
                summary: MenuBarSummary(),
                accountLabel: "Bruno",
                shareState: state,
                revealSession: { _ in },
                createInWorkspace: { _ in },
                chooseFolder: {},
                toggleSharing: {},
                showSettings: {},
                quit: {}
            )
            let item = try! XCTUnwrap(menu.items.first { $0.title == "Share this environment" })
            XCTAssertEqual(item.state, expected, "for \(state)")
        }
    }

    /// Clicking the item is the one way this menu can turn sharing on or
    /// off — `testClickingASessionRevealsIt`'s pattern.
    func testClickingTheShareItemFiresToggleSharing() {
        var toggled = false
        let menu = NSMenu()
        MenuBarMenu.build(
            into: menu,
            summary: MenuBarSummary(),
            accountLabel: "Bruno",
            shareState: .off,
            revealSession: { _ in },
            createInWorkspace: { _ in },
            chooseFolder: {},
            toggleSharing: { toggled = true },
            showSettings: {},
            quit: {}
        )
        let item = try! XCTUnwrap(menu.items.first { $0.title == "Share this environment" } as? ShellMenuItem)
        item.performForTesting()
        XCTAssertTrue(toggled)
    }

    /// `refreshShareIcon` is the live push `RemoteSharingModel.onChange`
    /// drives (through `WorkspaceWindowController.onRemoteSharingChanged`,
    /// wired by `AppDelegate`) — the icon has to update the instant sharing
    /// is switched on from Settings, not only the next time the menu opens.
    @MainActor
    func testRefreshShareIconReflectsTheWorkspacesSharingState() throws {
        // The account row is what makes sharing switchable on at all
        // (`RemoteSharingModel.setSharing`).
        let store = SettingsStore(client: FakeSettingsClient(
            rows: ["auth_account_email": "bruno@bonando.com"]
        ))
        let controller = WorkspaceWindowController(
            connection: SessionConnection(socketURL: URL(fileURLWithPath: "/tmp/omniagent-menubar-share-test.sock")),
            panes: [],
            remoteSharing: RemoteSharingModel(store: store),
            authDefaults: try throwawayDefaults()
        )
        defer { controller.close() }
        let menuBar = MenuBarController(workspace: controller)

        // Seeded at construction: sharing starts off.
        XCTAssertEqual(menuBar.statusItem.button?.image?.isTemplate, true)

        controller.toggleRemoteSharing()
        XCTAssertTrue(controller.isSharingEnvironment, "the fake store's write always succeeds")
        menuBar.refreshShareIcon()
        XCTAssertEqual(
            menuBar.statusItem.button?.image?.isTemplate, false,
            "the icon turns non-template — tinted — the moment sharing goes on, without opening the menu"
        )
    }

    /// The blue state (spec §2, Task 16): the icon goes blue for exactly as
    /// long as somebody is driving this Mac — the same span the takeover
    /// panel is up for, because both are one reading of
    /// `RemoteSharingModel.liveConnection`. `.connected` was unreachable
    /// until this landed: nothing set it.
    @MainActor
    func testTheIconGoesBlueForExactlyAsLongAsAMachineIsConnected() throws {
        let store = SettingsStore(client: FakeSettingsClient(
            rows: ["auth_account_email": "bruno@bonando.com"]
        ))
        let controller = WorkspaceWindowController(
            connection: SessionConnection(socketURL: URL(fileURLWithPath: "/tmp/omniagent-menubar-blue-test.sock")),
            panes: [],
            remoteSharing: RemoteSharingModel(store: store),
            authDefaults: try throwawayDefaults()
        )
        defer { controller.close() }
        let menuBar = MenuBarController(workspace: controller)

        controller.toggleRemoteSharing()
        menuBar.refreshShareIcon()
        let green = try tint(of: XCTUnwrap(menuBar.statusItem.button?.image))
        XCTAssertGreaterThan(green.green, green.blue, "sharing and idle is green")

        controller.applyRemoteViewers([RemoteViewer(
            viewerID: "v-air",
            machineName: "Air",
            sessions: ["s1"],
            since: "2026-09-01T09:00:00Z",
            accountEmail: "bruno@bonando.com"
        )])
        XCTAssertNotNil(controller.liveRemoteConnection)
        XCTAssertNotNil(controller.takeoverPanel, "and the panel is up for the same span")
        menuBar.refreshShareIcon()
        let blue = try tint(of: XCTUnwrap(menuBar.statusItem.button?.image))
        XCTAssertGreaterThan(blue.blue, blue.green, "somebody is driving this Mac")

        controller.applyRemoteViewers([])
        XCTAssertNil(controller.takeoverPanel, "and it goes with them")
        menuBar.refreshShareIcon()
        let again = try tint(of: XCTUnwrap(menuBar.statusItem.button?.image))
        XCTAssertGreaterThan(again.green, again.blue, "back to green, still sharing")
    }

    /// The purple state (Task 25's carried item): the icon must not read
    /// "sharing and idle" — green — while this Mac's own daemon has, quite
    /// correctly, dropped its control channel because it is busy driving
    /// somebody else. Built the way `ConnectionSwapTests.makeController`
    /// does: a local socket that does not exist and a remote WebSocket that
    /// dials nothing, both parked on a long reconnect delay so the test
    /// only has to look at `isDrivingRemote`, never a real connect.
    @MainActor
    func testTheIconGoesPurpleWhileThisMacIsDrivingAnother() async throws {
        let store = SettingsStore(client: FakeSettingsClient(
            rows: ["auth_account_email": "bruno@bonando.com"]
        ))
        let local = SessionConnection(
            socketURL: URL(fileURLWithPath: "/tmp/omniagent-menubar-purple-\(UUID().uuidString).sock"),
            reconnectDelay: 60
        )
        let remote = SessionConnection(
            transport: .webSocket(URL(string: "wss://127.0.0.1:1/v1/viewer/device-studio")!, bearer: { nil }),
            reconnectDelay: 60
        )
        let controller = WorkspaceWindowController(
            connection: local,
            panes: [],
            remoteSharing: RemoteSharingModel(store: store),
            authDefaults: try throwawayDefaults()
        )
        defer {
            controller.close()
            remote.disconnect()
        }
        let menuBar = MenuBarController(workspace: controller)

        controller.toggleRemoteSharing()
        menuBar.refreshShareIcon()
        let green = try tint(of: XCTUnwrap(menuBar.statusItem.button?.image))
        XCTAssertGreaterThan(green.green, green.blue, "sharing and idle, before the takeover")

        // A roster from *before* the takeover began, left standing — the
        // exact staleness `MenuBarController.shareState`'s doc comment
        // describes: `RemoteViewers` is a local-only push
        // (`applyRemoteViewers`'s own `isDrivingRemote` guard), so nothing
        // ever corrects it once the local connection is gone for the
        // takeover. If `.connected` were checked ahead of `.driving`, this
        // stale roster is exactly what would make the icon lie.
        controller.applyRemoteViewers([RemoteViewer(
            viewerID: "v-air", machineName: "Air", sessions: ["s1"],
            since: "2026-09-01T09:00:00Z", accountEmail: "bruno@bonando.com"
        )])
        XCTAssertNotNil(controller.liveRemoteConnection)

        controller.remoteConnectionProvider = { _ in remote }
        try await controller.connectRemote(to: RemoteMachine(deviceID: "device-studio", name: "Mac Studio"))
        XCTAssertTrue(controller.isDrivingRemote)
        XCTAssertNotNil(controller.liveRemoteConnection, "still stale, untouched by the takeover")
        menuBar.refreshShareIcon()
        let purple = try tint(of: XCTUnwrap(menuBar.statusItem.button?.image))
        XCTAssertGreaterThan(purple.red, purple.green, "purple reads red-and-blue, not green")
        XCTAssertGreaterThan(purple.blue, purple.green, "purple reads red-and-blue, not green")

        controller.disconnectRemote()
        XCTAssertFalse(controller.isDrivingRemote, "back on this Mac's own daemon")
        menuBar.refreshShareIcon()
        let backToLocal = try tint(of: XCTUnwrap(menuBar.statusItem.button?.image))
        XCTAssertFalse(
            backToLocal.red > backToLocal.green && backToLocal.blue > backToLocal.green,
            "no longer purple — `isDrivingRemote` alone is what the icon read while it was"
        )
    }

    /// The colour of the most opaque pixel in a status icon — the mark is
    /// filled `.sourceAtop` with one flat tint, so this is that tint.
    private func tint(of image: NSImage) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat) {
        let data = try XCTUnwrap(image.tiffRepresentation)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data))
        var best: NSColor?
        var bestAlpha: CGFloat = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.alphaComponent > bestAlpha {
                    bestAlpha = color.alphaComponent
                    best = color
                }
            }
        }
        let color = try XCTUnwrap(best)
        return (color.redComponent, color.greenComponent, color.blueComponent)
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
